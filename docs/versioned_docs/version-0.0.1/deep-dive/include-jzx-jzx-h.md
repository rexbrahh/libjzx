---
title: C ABI — include/jzx/jzx.h
sidebar_position: 2
---

# C ABI — `include/jzx/jzx.h`

This header is the **public C99 ABI contract** for libjzx. If you’re integrating from another language, or you’re changing runtime semantics, this is the file you treat as canonical.

The style of this page is intentionally “textbook”: small snippets, then explanation of what each line means and why it exists.

## Header envelope (include guard + C++ ABI)

<!-- snippet: include/jzx/jzx.h#L1-L9 -->
```c title="Header guard and C++ ABI compatibility" showLineNumbers=1
#ifndef JZX_JZX_H
#define JZX_JZX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
```

This block is “plumbing” that makes the header safe to include and usable from both C and C++.

- `#ifndef` / `#define`: prevents multiple inclusion from redefining types and declarations.
- `#include <stddef.h>`: provides `size_t` used for payload lengths and allocator sizes.
- `#include <stdint.h>`: provides fixed-width integer types (`uint32_t`, `uint64_t`, …).
- `extern "C"`: ensures the exported symbol names remain C ABI when compiled as C++ (no name mangling).

## Error model (all APIs speak `jzx_err`)

<!-- snippet: include/jzx/jzx.h#L11-L25 -->
```c title="Error codes" showLineNumbers=11
// --- Error Model -----------------------------------------------------------

typedef enum {
    JZX_OK = 0,
    JZX_ERR_UNKNOWN = -1,
    JZX_ERR_NO_MEMORY = -2,
    JZX_ERR_INVALID_ARG = -3,
    JZX_ERR_LOOP_CLOSED = -4,
    JZX_ERR_NO_SUCH_ACTOR = -5,
    JZX_ERR_MAILBOX_FULL = -7,
    JZX_ERR_TIMER_INVALID = -8,
    JZX_ERR_IO_REG_FAILED = -9,
    JZX_ERR_IO_NOT_WATCHED = -10,
    JZX_ERR_MAX_ACTORS = -11,
} jzx_err;
```

This `enum` is the project’s “error language”.

- `JZX_OK = 0`: success. Zero-as-success is idiomatic in C and convenient when bridging to other languages.
- All `JZX_ERR_*` are negative: this keeps a clean separation between “success / positive values” and “failure values”.

Each error code exists to make failure modes **explicit and machine-checkable**:

- `JZX_ERR_NO_MEMORY`: allocation failed (runtime or user allocator).
- `JZX_ERR_INVALID_ARG`: caller violated a contract (null pointer, invalid fd, invalid interest mask, etc).
- `JZX_ERR_LOOP_CLOSED`: operation attempted after the loop is closing/stopped/destroyed.
- `JZX_ERR_NO_SUCH_ACTOR`: invalid or stale `jzx_actor_id` (generation mismatch or slot unused).
- `JZX_ERR_MAILBOX_FULL`: bounded mailbox is full (backpressure signal).
- `JZX_ERR_TIMER_INVALID`: invalid or stale `jzx_timer_id` (already fired/cancelled/unknown).
- `JZX_ERR_IO_REG_FAILED`: underlying I/O backend rejected registration.
- `JZX_ERR_IO_NOT_WATCHED`: you tried to unwatch an fd that is not currently watched.
- `JZX_ERR_MAX_ACTORS`: runtime is at capacity (`cfg.max_actors`).

## Core identifiers and the opaque loop type

<!-- snippet: include/jzx/jzx.h#L27-L32 -->
```c title="Opaque handle types" showLineNumbers=27
// --- Core types ------------------------------------------------------------

typedef uint64_t jzx_actor_id;
typedef uint64_t jzx_timer_id;

typedef struct jzx_loop jzx_loop;
```

- `jzx_actor_id`: identifies an actor in a running loop.
- `jzx_timer_id`: identifies a scheduled timer.
- `typedef struct jzx_loop jzx_loop;`: `jzx_loop` is opaque in the public header so callers can only interact through the ABI functions (this keeps internal layout flexible).

## Allocator interface (how the runtime allocates)

<!-- snippet: include/jzx/jzx.h#L34-L38 -->
```c title="Allocator vtable" showLineNumbers=34
typedef struct {
    void* (*alloc)(void* ctx, size_t size);
    void (*free)(void* ctx, void* ptr);
    void* ctx;
} jzx_allocator;
```

This is a minimal “allocator vtable”. The runtime calls it for its internal allocations.

- `alloc(ctx, size)`: must return a suitably aligned pointer for any runtime allocation, or `NULL` on failure.
- `free(ctx, ptr)`: must free a pointer previously returned by `alloc`.
- `ctx`: user-defined pointer passed to both functions (e.g., arena state).

Why it exists: systems code often needs explicit control over allocation (arena allocators, tracing allocators, embedded use cases).

Practical contracts (based on the current runtime implementation):

- Alignment: `alloc(ctx, size)` should return pointers aligned at least like `malloc` would (i.e., suitable for any normal C object; `alignof(max_align_t)` is a good mental model).
- Null frees: the runtime guards null pointers at call sites (so it should not call `free(ctx, NULL)`), but a “`free(NULL)` is a no-op” implementation is still recommended for robustness.

## Runtime config (knobs that shape scheduling and capacity)

<!-- snippet: include/jzx/jzx.h#L40-L50 -->
```c title="jzx_config and initialization" showLineNumbers=40
typedef struct {
    jzx_allocator allocator;
    uint32_t max_actors;
    uint32_t default_mailbox_cap;
    uint32_t max_msgs_per_actor;
    uint32_t max_actors_per_tick;
    uint32_t max_io_watchers;
    uint32_t io_poll_timeout_ms;
} jzx_config;

void jzx_config_init(jzx_config* cfg);
```

`jzx_config` provides **hard caps** and **budgets**. These exist so runtime behavior is bounded and predictable under load.

- `allocator`: which allocator the loop uses for everything it owns.
- `max_actors`: actor table capacity (prevents unbounded growth; used for id stability).
- `default_mailbox_cap`: default mailbox capacity for actors that don’t specify `mailbox_cap`.
- `max_msgs_per_actor`: per-actor message budget per run (fairness; prevents one actor from monopolizing a tick).
- `max_actors_per_tick`: global budget of runnable actors per loop tick (tick latency bound).
- `max_io_watchers`: max number of fd watchers (bounds memory and backend registrations).
- `io_poll_timeout_ms`: how long the loop waits for I/O when idle (backend-specific “sleep” behavior).
- `jzx_config_init`: fills a config struct with safe defaults so callers don’t have to initialize every field manually.

## Message envelope and system tags

<!-- snippet: include/jzx/jzx.h#L52-L61 -->
```c title="jzx_message and system tag space" showLineNumbers=52
// --- Messaging -------------------------------------------------------------

typedef struct {
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
} jzx_message;

#define JZX_TAG_SYS_IO 0xFFFF0001u
```

`jzx_message` is the runtime’s envelope around a payload.

- `data`: pointer to payload bytes (not necessarily owned by the runtime).
- `len`: payload length in bytes.
- `tag`: application/system tag used to route/interpret messages.
- `sender`: actor id of the sender (may be 0/unknown depending on send path).

`JZX_TAG_SYS_IO` reserves a tag value for runtime-generated I/O readiness notifications.

Payload ownership and lifetime rules (critical):

- The runtime does **not** deep-copy arbitrary payload bytes.
  - A mailbox entry stores the `data` pointer + `len` as-is.
- The runtime does **not** free user-provided payload pointers.
  - You choose ownership: sender-owned, receiver-owned, reference-counted, etc.
- Lifetime requirement:
  - `data` must remain valid until the target actor’s behavior has consumed it.
  - Heap allocation is the simplest safe strategy.
  - Stack allocation can be safe only when you can prove the message will be consumed before the stack frame unwinds (e.g., send immediately before `jzx_loop_run`, and the actor stops deterministically).
- Special case: runtime-owned payloads:
  - For `JZX_TAG_SYS_IO`, the runtime allocates a `jzx_io_event` and passes it via `msg.data`.
  - That payload must be freed with `jzx_loop_free(loop, msg.data)` (see the echo server example for the pattern).

## Behavior interface (what an actor “is”)

### Execution context

<!-- snippet: include/jzx/jzx.h#L63-L69 -->
```c title="jzx_context" showLineNumbers=63
// --- Behavior --------------------------------------------------------------

typedef struct {
    void* state;
    jzx_actor_id self;
    jzx_loop* loop;
} jzx_context;
```

`jzx_context` is passed to every behavior invocation.

- `state`: user-owned pointer (per-actor state).
- `self`: actor id of the currently running actor.
- `loop`: loop pointer so behaviors can call back into the runtime (send messages, watch fds, schedule timers, etc).

### Behavior result (what the actor returns)

<!-- snippet: include/jzx/jzx.h#L71-L75 -->
```c title="jzx_behavior_result" showLineNumbers=71
typedef enum {
    JZX_BEHAVIOR_OK = 0,
    JZX_BEHAVIOR_STOP = 1,
    JZX_BEHAVIOR_FAIL = 2,
} jzx_behavior_result;
```

This enum is how a behavior tells the runtime what to do:

- `OK`: keep running; actor remains live.
- `STOP`: graceful stop; runtime transitions actor to stopped and tears it down.
- `FAIL`: failure; runtime marks the actor failed and triggers supervision logic if configured.

### Actor lifecycle status (used in system messages)

<!-- snippet: include/jzx/jzx.h#L77-L84 -->
```c title="jzx_actor_status" showLineNumbers=77
// Actor status codes for lifecycle/supervision messages.
typedef enum {
    JZX_ACTOR_INIT = 0,
    JZX_ACTOR_RUNNING,
    JZX_ACTOR_STOPPING,
    JZX_ACTOR_STOPPED,
    JZX_ACTOR_FAILED,
} jzx_actor_status;
```

These statuses are used when reporting lifecycle/supervision events (e.g., child exit).

### Exit reason (why an actor stopped)

<!-- snippet: include/jzx/jzx.h#L86-L90 -->
```c title="jzx_exit_reason" showLineNumbers=86
typedef enum {
    JZX_EXIT_NORMAL = 0,
    JZX_EXIT_FAIL = 1,
    JZX_EXIT_PANIC = 2,
} jzx_exit_reason;
```

Separating “status” from “exit reason” makes it possible to communicate intent:

- “stopped normally” vs “failed” vs “panic/unrecoverable”.

### Behavior function pointer type

<!-- snippet: include/jzx/jzx.h#L92-L92 -->
```c title="jzx_behavior_fn" showLineNumbers=92
typedef jzx_behavior_result (*jzx_behavior_fn)(jzx_context* ctx, const jzx_message* msg);
```

This is the core ABI: the runtime calls this function for each delivered message.

## Supervision types (policy, strategy, backoff)

### Child mode (restart policy)

<!-- snippet: include/jzx/jzx.h#L94-L98 -->
```c title="jzx_child_mode" showLineNumbers=94
typedef enum {
    JZX_CHILD_PERMANENT,
    JZX_CHILD_TRANSIENT,
    JZX_CHILD_TEMPORARY,
} jzx_child_mode;
```

- `PERMANENT`: always restart on exit.
- `TRANSIENT`: restart only on abnormal exit.
- `TEMPORARY`: never restart.

### Supervisor strategy (how sibling restarts happen)

<!-- snippet: include/jzx/jzx.h#L100-L104 -->
```c title="jzx_supervisor_strategy" showLineNumbers=100
typedef enum {
    JZX_SUP_ONE_FOR_ONE,
    JZX_SUP_ONE_FOR_ALL,
    JZX_SUP_REST_FOR_ONE,
} jzx_supervisor_strategy;
```

- `ONE_FOR_ONE`: restart only the failing child.
- `ONE_FOR_ALL`: restart all children when one fails.
- `REST_FOR_ONE`: restart the failing child and those started after it.

### Backoff model (how restart delays evolve)

<!-- snippet: include/jzx/jzx.h#L106-L110 -->
```c title="jzx_backoff_type" showLineNumbers=106
typedef enum {
    JZX_BACKOFF_NONE,
    JZX_BACKOFF_CONSTANT,
    JZX_BACKOFF_EXPONENTIAL,
} jzx_backoff_type;
```

Backoff exists to prevent restart storms from saturating the system.

## Spawning API (creating actors and supervisors)

### Spawn a single actor

<!-- snippet: include/jzx/jzx.h#L112-L122 -->
```c title="jzx_spawn_opts and jzx_spawn()" showLineNumbers=112
// --- Spawning --------------------------------------------------------------

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    uint32_t mailbox_cap;
    const char* name;
} jzx_spawn_opts;

jzx_err jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts, jzx_actor_id* out_id);
```

- `behavior`: message handler function.
- `state`: user state pointer passed via `jzx_context.state`.
- `supervisor`: supervisor id (0 means “no supervisor / root”).
- `mailbox_cap`: mailbox override (0 means “use default_mailbox_cap”).
- `name`: optional stable name (observability/debugging).
- `jzx_spawn`: creates the actor and returns its id via `out_id`.

### Describe a supervised child

<!-- snippet: include/jzx/jzx.h#L124-L132 -->
```c title="jzx_child_spec" showLineNumbers=124
typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_child_mode mode;
    uint32_t mailbox_cap;
    uint32_t restart_delay_ms;
    jzx_backoff_type backoff;
    const char* name;
} jzx_child_spec;
```

`jzx_child_spec` is a template for a supervised child:

- `restart_delay_ms` and `backoff` together describe *how long* to wait before restarting.

### Supervisor configuration and spawn

<!-- snippet: include/jzx/jzx.h#L134-L152 -->
```c title="Supervisor spec and spawn" showLineNumbers=134
typedef struct {
    jzx_supervisor_strategy strategy;
    uint32_t intensity;
    uint32_t period_ms;
    jzx_backoff_type backoff;
    uint32_t backoff_delay_ms;
} jzx_supervisor_spec;

typedef struct {
    const jzx_child_spec* children;
    size_t child_count;
    jzx_supervisor_spec supervisor;
} jzx_supervisor_init;

jzx_err jzx_spawn_supervisor(jzx_loop* loop, const jzx_supervisor_init* init, jzx_actor_id parent,
                             jzx_actor_id* out_id);

jzx_err jzx_supervisor_child_id(jzx_loop* loop, jzx_actor_id supervisor, size_t index,
                                jzx_actor_id* out_id);
```

Key fields:

- `intensity` + `period_ms`: restart-intensity window. If restarts exceed this window, the supervisor escalates.
- `children` + `child_count`: defines the initial child set.
- `jzx_spawn_supervisor`: creates a supervisor (and typically spawns its children).
- `jzx_supervisor_child_id`: maps a child index to the current child actor id.

## Loop lifecycle (create/run/stop/destroy)

<!-- snippet: include/jzx/jzx.h#L154-L160 -->
```c title="Loop lifecycle APIs" showLineNumbers=154
// --- Loop management -------------------------------------------------------

jzx_loop* jzx_loop_create(const jzx_config* cfg);
void jzx_loop_destroy(jzx_loop* loop);
int jzx_loop_run(jzx_loop* loop);
void jzx_loop_request_stop(jzx_loop* loop);
void jzx_loop_free(jzx_loop* loop, void* ptr);
```

- `jzx_loop_create`: allocates and initializes the loop.
- `jzx_loop_run`: runs until stop requested / idle / fatal error (implementation-defined).
- `jzx_loop_request_stop`: cooperative stop signal.
- `jzx_loop_destroy`: shuts down and frees the loop.
- `jzx_loop_free`: frees memory that was allocated by the loop’s allocator.

## Observability (observer callbacks)

<!-- snippet: include/jzx/jzx.h#L162-L171 -->
```c title="Observer callbacks" showLineNumbers=162
typedef struct {
    void (*on_actor_start)(void* ctx, jzx_actor_id id, const char* name);
    void (*on_actor_stop)(void* ctx, jzx_actor_id id, jzx_exit_reason reason);
    void (*on_actor_restart)(void* ctx, jzx_actor_id supervisor, jzx_actor_id child,
                             uint32_t attempt);
    void (*on_supervisor_escalate)(void* ctx, jzx_actor_id supervisor);
    void (*on_mailbox_full)(void* ctx, jzx_actor_id target);
} jzx_observer;

void jzx_loop_set_observer(jzx_loop* loop, const jzx_observer* obs, void* ctx);
```

These callbacks exist for instrumentation without forcing a logging dependency into the runtime.

- All function pointers are optional; `NULL` means “don’t report that event”.
- `ctx` is an opaque pointer the user provides (often a metrics/logging state struct).

Callback threading and reentrancy (practical guidance):

- Observer callbacks are invoked **synchronously** (inline) when the runtime emits the event.
- If you confine all loop interactions to one thread (recommended), callbacks run on that same thread.
- If you call certain APIs from other threads (not generally recommended; `jzx_send_async` is the exception), callbacks may execute on those threads for events that are triggered by those calls (for example, actor-start hooks during `jzx_spawn`).
- Avoid reentrancy: treat observer callbacks as “read-only” with respect to the loop:
  - don’t call back into libjzx from within an observer callback unless you’ve audited the path for recursion/deadlock.
  - keep callbacks fast; offload heavy work to another queue/thread if needed.

## Messaging API (enqueue work for actors)

<!-- snippet: include/jzx/jzx.h#L173-L182 -->
```c title="Send and lifecycle control" showLineNumbers=173
// --- Messaging API ---------------------------------------------------------

jzx_err jzx_send(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag);

// Thread-safe enqueue for cross-thread sends. Payload is not copied.
// Returns JZX_OK once queued; delivery is best-effort and not reported back to the caller.
jzx_err jzx_send_async(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag);

jzx_err jzx_actor_stop(jzx_loop* loop, jzx_actor_id id);
jzx_err jzx_actor_fail(jzx_loop* loop, jzx_actor_id id);
```

Important semantic split:

- `jzx_send`: intended to be called from the loop thread (synchronous enqueue).
- `jzx_send_async`: thread-safe enqueue from other threads. The payload is **not copied**.

The actor control functions exist to request termination externally:

- `jzx_actor_stop`: request a graceful stop.
- `jzx_actor_fail`: force a failure (supervision should react).

## Timers and I/O (time- and fd-triggered messages)

<!-- snippet: include/jzx/jzx.h#L184-L212 -->
```c title="Timers, fd watches, and system payloads" showLineNumbers=184
// --- Timers & IO -----------------------------------------------------------

jzx_err jzx_send_after(jzx_loop* loop, jzx_actor_id target, uint32_t ms, void* data, size_t len,
                       uint32_t tag, jzx_timer_id* out_timer);

jzx_err jzx_cancel_timer(jzx_loop* loop, jzx_timer_id timer);

jzx_err jzx_watch_fd(jzx_loop* loop, int fd, jzx_actor_id owner, uint32_t interest);
jzx_err jzx_unwatch_fd(jzx_loop* loop, int fd);

typedef struct {
    int fd;
    uint32_t readiness;
} jzx_io_event;

#define JZX_IO_READ (1u << 0)
#define JZX_IO_WRITE (1u << 1)

#define JZX_TAG_SYS_CHILD_EXIT 0xffff0002u
#define JZX_TAG_SYS_CHILD_RESTART 0xffff0003u

typedef struct {
    jzx_actor_id child;
    jzx_actor_status status;
} jzx_child_exit;

typedef struct {
    uint32_t child_index;
} jzx_child_restart;
```

Timers:

- `jzx_send_after`: schedules a message to be enqueued later; returns a `jzx_timer_id`.
- `jzx_cancel_timer`: best-effort cancellation of a pending timer.

I/O:

- `jzx_watch_fd`: register interest in `fd` readiness for `owner`.
- `jzx_unwatch_fd`: unregister the watch.
- `jzx_io_event`: system payload for readiness events.
- `JZX_IO_READ` / `JZX_IO_WRITE`: readiness bit flags.

Supervision system tags:

- `JZX_TAG_SYS_CHILD_EXIT`: child exited notification (payload `jzx_child_exit`).
- `JZX_TAG_SYS_CHILD_RESTART`: child restart message (payload `jzx_child_restart`).

## Footer (close C++ ABI + end include guard)

<!-- snippet: include/jzx/jzx.h#L214-L218 -->
```c title="C++ ABI close + header guard end" showLineNumbers=214
#ifdef __cplusplus
}
#endif

#endif // JZX_JZX_H
```

This is the closing pair for the opening `extern "C"` and include guard at the top.
