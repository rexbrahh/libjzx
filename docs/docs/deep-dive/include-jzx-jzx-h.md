---
title: C ABI — include/jzx/jzx.h (annotated)
sidebar_position: 2
---

# C ABI — `include/jzx/jzx.h`

This header is the **public C99 ABI** for libjzx.

- If you’re integrating from another language, start here.
- If you’re changing runtime semantics, treat this file as the contract you’re exposing.

## Full source (with line numbers)

```c title="include/jzx/jzx.h" showLineNumbers
#ifndef JZX_JZX_H
#define JZX_JZX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

// --- Core types ------------------------------------------------------------

typedef uint64_t jzx_actor_id;
typedef uint64_t jzx_timer_id;

typedef struct jzx_loop jzx_loop;

typedef struct {
    void* (*alloc)(void* ctx, size_t size);
    void (*free)(void* ctx, void* ptr);
    void* ctx;
} jzx_allocator;

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

// --- Messaging -------------------------------------------------------------

typedef struct {
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
} jzx_message;

#define JZX_TAG_SYS_IO 0xFFFF0001u

// --- Behavior --------------------------------------------------------------

typedef struct {
    void* state;
    jzx_actor_id self;
    jzx_loop* loop;
} jzx_context;

typedef enum {
    JZX_BEHAVIOR_OK = 0,
    JZX_BEHAVIOR_STOP = 1,
    JZX_BEHAVIOR_FAIL = 2,
} jzx_behavior_result;

// Actor status codes for lifecycle/supervision messages.
typedef enum {
    JZX_ACTOR_INIT = 0,
    JZX_ACTOR_RUNNING,
    JZX_ACTOR_STOPPING,
    JZX_ACTOR_STOPPED,
    JZX_ACTOR_FAILED,
} jzx_actor_status;

typedef enum {
    JZX_EXIT_NORMAL = 0,
    JZX_EXIT_FAIL = 1,
    JZX_EXIT_PANIC = 2,
} jzx_exit_reason;

typedef jzx_behavior_result (*jzx_behavior_fn)(jzx_context* ctx, const jzx_message* msg);

typedef enum {
    JZX_CHILD_PERMANENT,
    JZX_CHILD_TRANSIENT,
    JZX_CHILD_TEMPORARY,
} jzx_child_mode;

typedef enum {
    JZX_SUP_ONE_FOR_ONE,
    JZX_SUP_ONE_FOR_ALL,
    JZX_SUP_REST_FOR_ONE,
} jzx_supervisor_strategy;

typedef enum {
    JZX_BACKOFF_NONE,
    JZX_BACKOFF_CONSTANT,
    JZX_BACKOFF_EXPONENTIAL,
} jzx_backoff_type;

// --- Spawning --------------------------------------------------------------

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    uint32_t mailbox_cap;
    const char* name;
} jzx_spawn_opts;

jzx_err jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts, jzx_actor_id* out_id);

typedef struct {
    jzx_behavior_fn behavior;
    void* state;
    jzx_child_mode mode;
    uint32_t mailbox_cap;
    uint32_t restart_delay_ms;
    jzx_backoff_type backoff;
    const char* name;
} jzx_child_spec;

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

// --- Loop management -------------------------------------------------------

jzx_loop* jzx_loop_create(const jzx_config* cfg);
void jzx_loop_destroy(jzx_loop* loop);
int jzx_loop_run(jzx_loop* loop);
void jzx_loop_request_stop(jzx_loop* loop);
void jzx_loop_free(jzx_loop* loop, void* ptr);

typedef struct {
    void (*on_actor_start)(void* ctx, jzx_actor_id id, const char* name);
    void (*on_actor_stop)(void* ctx, jzx_actor_id id, jzx_exit_reason reason);
    void (*on_actor_restart)(void* ctx, jzx_actor_id supervisor, jzx_actor_id child,
                             uint32_t attempt);
    void (*on_supervisor_escalate)(void* ctx, jzx_actor_id supervisor);
    void (*on_mailbox_full)(void* ctx, jzx_actor_id target);
} jzx_observer;

void jzx_loop_set_observer(jzx_loop* loop, const jzx_observer* obs, void* ctx);

// --- Messaging API ---------------------------------------------------------

jzx_err jzx_send(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag);

// Thread-safe enqueue for cross-thread sends. Payload is not copied.
// Returns JZX_OK once queued; delivery is best-effort and not reported back to the caller.
jzx_err jzx_send_async(jzx_loop* loop, jzx_actor_id target, void* data, size_t len, uint32_t tag);

jzx_err jzx_actor_stop(jzx_loop* loop, jzx_actor_id id);
jzx_err jzx_actor_fail(jzx_loop* loop, jzx_actor_id id);

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

#ifdef __cplusplus
}
#endif

#endif // JZX_JZX_H
```

## Line-by-line commentary

| Line | What it is / why it exists |
| ---: | --- |
| 1 | Header guard start. Prevents multiple inclusion from producing duplicate typedefs and declarations. |
| 2 | Header guard define. Must match line 1 to make the guard effective. |
| 3 | Blank line separating the preprocessor guard from system includes for readability. |
| 4 | Includes `stddef.h` for `size_t` (used by payload lengths and allocators). |
| 5 | Includes `stdint.h` for fixed-width integer types (`uint32_t`, `uint64_t`). |
| 6 | Blank line separating includes from C++ interop glue. |
| 7 | Start C++ compatibility block: only enabled when compiled as C++. |
| 8 | `extern "C"` ensures the ABI uses C symbol names (no C++ name mangling). |
| 9 | End of the `extern "C"` opening; the corresponding close is lines 214–216. |
| 10 | Blank line separating ABI glue from the first documented section. |
| 11 | Section divider comment: begins the error model section. |
| 12 | Blank line for readability. |
| 13 | Defines the `jzx_err` enum type: the canonical error code model for the C ABI. |
| 14 | `JZX_OK` is success (`0`), following common C conventions (0 means OK). |
| 15 | `JZX_ERR_UNKNOWN` is a catch-all for unexpected failures (`-1`). |
| 16 | `JZX_ERR_NO_MEMORY` indicates allocation failure (`malloc`/allocator returned `NULL`). |
| 17 | `JZX_ERR_INVALID_ARG` indicates a caller contract violation (null pointers, invalid ids, etc.). |
| 18 | `JZX_ERR_LOOP_CLOSED` indicates an operation was attempted on a stopped/destroyed loop. |
| 19 | `JZX_ERR_NO_SUCH_ACTOR` indicates the `jzx_actor_id` doesn’t resolve to a live actor. |
| 20 | `JZX_ERR_MAILBOX_FULL` indicates the target mailbox is at capacity (backpressure signal). |
| 21 | `JZX_ERR_TIMER_INVALID` indicates a timer id is unknown/stale/cancelled. |
| 22 | `JZX_ERR_IO_REG_FAILED` indicates the underlying event backend could not register the watcher. |
| 23 | `JZX_ERR_IO_NOT_WATCHED` indicates an unwatch operation targeted an fd that wasn’t registered. |
| 24 | `JZX_ERR_MAX_ACTORS` indicates the runtime hit its configured actor capacity. |
| 25 | Closes the enum and names it `jzx_err` so API functions can return a stable error type. |
| 26 | Blank line separating error codes from core type definitions. |
| 27 | Section divider: core types that appear across the API. |
| 28 | Blank line for readability. |
| 29 | `jzx_actor_id` is an opaque actor identifier; the runtime decides its encoding. |
| 30 | `jzx_timer_id` is an opaque timer identifier; used to cancel/track scheduled timers. |
| 31 | Blank line. |
| 32 | Forward-declares `struct jzx_loop`; the loop is opaque from the public header. |
| 33 | Blank line. |
| 34 | Starts `jzx_allocator`, a “pluggable allocator” interface used by the runtime. |
| 35 | `alloc`: user-provided allocation function (or `NULL` if not provided). |
| 36 | `free`: user-provided free function (or `NULL` if not provided). |
| 37 | `ctx`: user-defined context pointer passed to `alloc/free` (e.g., arena state). |
| 38 | Closes the allocator struct type. |
| 39 | Blank line. |
| 40 | Starts `jzx_config`, runtime configuration passed to `jzx_loop_create`. |
| 41 | `allocator`: which allocator the runtime should use for its internal allocations. |
| 42 | `max_actors`: hard cap on actors to bound memory usage and keep ids compact. |
| 43 | `default_mailbox_cap`: default mailbox capacity if a spawn call doesn’t override it. |
| 44 | `max_msgs_per_actor`: per-actor work budget per scheduling run (fairness/backpressure). |
| 45 | `max_actors_per_tick`: cap on how many actors can run per event-loop “tick”. |
| 46 | `max_io_watchers`: bound on how many fds can be watched simultaneously. |
| 47 | `io_poll_timeout_ms`: how long the loop will wait for I/O when idle (backend-specific). |
| 48 | Closes the config struct type. |
| 49 | Blank line. |
| 50 | `jzx_config_init` fills `cfg` with defaults (so callers don’t have to set every field). |
| 51 | Blank line. |
| 52 | Section divider: messaging payload wrapper used by the scheduler. |
| 53 | Blank line. |
| 54 | Starts `jzx_message`, the runtime’s internal envelope around a payload. |
| 55 | `data`: pointer to the payload bytes (not necessarily owned by the runtime). |
| 56 | `len`: byte length of the payload. |
| 57 | `tag`: application/system tag used to discriminate message kinds. |
| 58 | `sender`: actor id of the sender (0/unknown allowed depending on API path). |
| 59 | Closes the message struct type. |
| 60 | Blank line. |
| 61 | `JZX_TAG_SYS_IO`: reserved tag for system I/O notifications (used internally). |
| 62 | Blank line. |
| 63 | Section divider: actor behaviors and behavior-related types. |
| 64 | Blank line. |
| 65 | Starts `jzx_context`, the per-delivery context passed to `jzx_behavior_fn`. |
| 66 | `state`: user state pointer for this actor (opaque to runtime). |
| 67 | `self`: actor’s own id (useful for self-sends or logging). |
| 68 | `loop`: pointer back to the owning loop for performing API operations from behaviors. |
| 69 | Closes the context struct. |
| 70 | Blank line. |
| 71 | Starts `jzx_behavior_result`: how the behavior tells the runtime what to do next. |
| 72 | `JZX_BEHAVIOR_OK`: message handled; keep actor alive. |
| 73 | `JZX_BEHAVIOR_STOP`: graceful stop request; runtime transitions actor to stopped. |
| 74 | `JZX_BEHAVIOR_FAIL`: failure signal; runtime marks actor failed and triggers supervision. |
| 75 | Closes behavior-result enum. |
| 76 | Blank line. |
| 77 | Comment: these status codes appear in lifecycle/supervision system messages. |
| 78 | Starts `jzx_actor_status`: state machine label for an actor’s lifecycle. |
| 79 | `JZX_ACTOR_INIT`: actor allocated/created but not yet running user code. |
| 80 | `JZX_ACTOR_RUNNING`: actor is live and can process messages. |
| 81 | `JZX_ACTOR_STOPPING`: actor is shutting down (typically after stop request). |
| 82 | `JZX_ACTOR_STOPPED`: actor is fully stopped and should not accept messages. |
| 83 | `JZX_ACTOR_FAILED`: actor terminated due to failure. |
| 84 | Closes actor-status enum. |
| 85 | Blank line. |
| 86 | Starts `jzx_exit_reason`: why an actor stopped (normal vs failure). |
| 87 | `JZX_EXIT_NORMAL`: stopped intentionally (behavior returned stop). |
| 88 | `JZX_EXIT_FAIL`: stopped due to failure (behavior returned fail or runtime error). |
| 89 | `JZX_EXIT_PANIC`: abnormal termination (used when runtime catches fatal/unrecoverable error). |
| 90 | Closes exit-reason enum. |
| 91 | Blank line. |
| 92 | Defines `jzx_behavior_fn`: the C function pointer signature for actor behaviors. |
| 93 | Blank line. |
| 94 | Starts `jzx_child_mode`: supervision policy for a child actor. |
| 95 | `PERMANENT`: always restart child on exit (regardless of reason). |
| 96 | `TRANSIENT`: restart only on abnormal exit (fail/panic). |
| 97 | `TEMPORARY`: never restart (one-shot child). |
| 98 | Closes child-mode enum. |
| 99 | Blank line. |
| 100 | Starts `jzx_supervisor_strategy`: how failures propagate among siblings. |
| 101 | `ONE_FOR_ONE`: restart only the failed child. |
| 102 | `ONE_FOR_ALL`: restart all children when one fails. |
| 103 | `REST_FOR_ONE`: restart the failed child and those started after it. |
| 104 | Closes supervisor-strategy enum. |
| 105 | Blank line. |
| 106 | Starts `jzx_backoff_type`: restart backoff model for delaying restarts. |
| 107 | `NONE`: no backoff (restart immediately). |
| 108 | `CONSTANT`: fixed delay backoff. |
| 109 | `EXPONENTIAL`: exponential backoff (typically doubling with saturation). |
| 110 | Closes backoff-type enum. |
| 111 | Blank line. |
| 112 | Section divider: spawn APIs and supervision specs. |
| 113 | Blank line. |
| 114 | Starts `jzx_spawn_opts`, options for spawning a single actor. |
| 115 | `behavior`: function to call for each delivered message. |
| 116 | `state`: user-owned state pointer accessible via `ctx->state`. |
| 117 | `supervisor`: supervisor actor id (0 meaning “no supervisor” / root). |
| 118 | `mailbox_cap`: mailbox capacity override (0 means “use default”). |
| 119 | `name`: optional stable name for observability/debugging. |
| 120 | Closes spawn-options struct. |
| 121 | Blank line. |
| 122 | `jzx_spawn`: creates an actor, assigns it an id, and schedules it to run. |
| 123 | Blank line. |
| 124 | Starts `jzx_child_spec`: template for supervised children. |
| 125 | `behavior`: child’s behavior function. |
| 126 | `state`: child’s state pointer. |
| 127 | `mode`: restart policy (permanent/transient/temporary). |
| 128 | `mailbox_cap`: mailbox capacity override for this child. |
| 129 | `restart_delay_ms`: base delay before restarting this child. |
| 130 | `backoff`: how to expand delay across repeated restarts. |
| 131 | `name`: optional name for this child (observability/debugging). |
| 132 | Closes child-spec struct. |
| 133 | Blank line. |
| 134 | Starts `jzx_supervisor_spec`: config applied to a supervisor actor. |
| 135 | `strategy`: how to restart children as a set. |
| 136 | `intensity`: max restarts allowed within `period_ms` (restart storm protection). |
| 137 | `period_ms`: time window for the intensity counter. |
| 138 | `backoff`: supervisor-level backoff model (if used by implementation). |
| 139 | `backoff_delay_ms`: base delay for the supervisor’s backoff. |
| 140 | Closes supervisor-spec struct. |
| 141 | Blank line. |
| 142 | Starts `jzx_supervisor_init`: initializer for spawning a supervisor with children. |
| 143 | `children`: pointer to an array of `jzx_child_spec` templates. |
| 144 | `child_count`: number of entries in `children`. |
| 145 | `supervisor`: configuration for supervisor strategy/intensity/backoff. |
| 146 | Closes supervisor-init struct. |
| 147 | Blank line. |
| 148 | `jzx_spawn_supervisor`: spawns a supervisor actor and its initial children. |
| 149 | Continuation: returns supervisor id in `out_id` and links supervisor under `parent`. |
| 150 | Blank line. |
| 151 | `jzx_supervisor_child_id`: query helper to retrieve a child’s actor id by index. |
| 152 | Continuation: `index` refers to the child list order in the supervisor init/spec. |
| 153 | Blank line. |
| 154 | Section divider: loop creation/lifecycle APIs. |
| 155 | Blank line. |
| 156 | `jzx_loop_create`: allocates and initializes a runtime loop using `cfg`. |
| 157 | `jzx_loop_destroy`: shuts down the loop and releases all owned resources. |
| 158 | `jzx_loop_run`: enters the event loop and runs until stop is requested or idle. |
| 159 | `jzx_loop_request_stop`: asks the loop to stop as soon as practical. |
| 160 | `jzx_loop_free`: frees memory that was allocated by the loop’s configured allocator. |
| 161 | Blank line. |
| 162 | Starts `jzx_observer`: optional callbacks for lifecycle/supervision/pressure signals. |
| 163 | `on_actor_start`: called when an actor becomes live (after spawn). |
| 164 | `on_actor_stop`: called when an actor stops, with an exit reason. |
| 165 | `on_actor_restart`: called when a supervisor restarts a child, including attempt count. |
| 166 | Continuation line: ensures the signature is readable within the column limit. |
| 167 | `on_supervisor_escalate`: called when restart intensity is exceeded and escalation occurs. |
| 168 | `on_mailbox_full`: called when send fails due to mailbox capacity. |
| 169 | Closes observer struct. |
| 170 | Blank line. |
| 171 | `jzx_loop_set_observer`: installs callbacks + an opaque `ctx` pointer for them. |
| 172 | Blank line. |
| 173 | Section divider: message send APIs. |
| 174 | Blank line. |
| 175 | `jzx_send`: enqueue a message to `target` from the loop thread (synchronous API). |
| 176 | Blank line. |
| 177 | Comment: clarifies that `jzx_send_async` is thread-safe and does not copy payload bytes. |
| 178 | Comment: clarifies semantics: enqueue success does not imply delivery success. |
| 179 | `jzx_send_async`: enqueue from other threads; delivery is best-effort. |
| 180 | Blank line. |
| 181 | `jzx_actor_stop`: request a graceful stop for an actor (as if it returned STOP). |
| 182 | `jzx_actor_fail`: mark an actor failed (as if it returned FAIL) to trigger supervision. |
| 183 | Blank line. |
| 184 | Section divider: timers and I/O watchers. |
| 185 | Blank line. |
| 186 | `jzx_send_after`: schedule a message after `ms` milliseconds; returns `out_timer`. |
| 187 | Continuation: breaks a long signature across lines for readability. |
| 188 | Blank line. |
| 189 | `jzx_cancel_timer`: cancel a previously scheduled timer id. |
| 190 | Blank line. |
| 191 | `jzx_watch_fd`: register interest in fd readiness and deliver system I/O messages. |
| 192 | `jzx_unwatch_fd`: unregister the watch for an fd. |
| 193 | Blank line. |
| 194 | Starts `jzx_io_event`: payload delivered with `JZX_TAG_SYS_IO`. |
| 195 | `fd`: the file descriptor that became ready. |
| 196 | `readiness`: bitmask of `JZX_IO_READ`/`JZX_IO_WRITE` indicating which events fired. |
| 197 | Closes I/O event struct. |
| 198 | Blank line. |
| 199 | `JZX_IO_READ` readiness flag bit. |
| 200 | `JZX_IO_WRITE` readiness flag bit. |
| 201 | Blank line. |
| 202 | `JZX_TAG_SYS_CHILD_EXIT`: reserved system tag for “child exited” supervision message. |
| 203 | `JZX_TAG_SYS_CHILD_RESTART`: reserved system tag for “child restart request/notice”. |
| 204 | Blank line. |
| 205 | Starts `jzx_child_exit`: system-message payload describing an exiting child. |
| 206 | `child`: the child actor id. |
| 207 | `status`: the child’s final status (`STOPPED` vs `FAILED`). |
| 208 | Closes child-exit payload struct. |
| 209 | Blank line. |
| 210 | Starts `jzx_child_restart`: system-message payload describing which child index to restart. |
| 211 | `child_index`: index into the supervisor’s child array (matches `jzx_supervisor_init`). |
| 212 | Closes child-restart payload struct. |
| 213 | Blank line. |
| 214 | Close the C++ `extern "C"` block. |
| 215 | End of `extern "C"` closing brace. |
| 216 | End of C++ conditional compilation block. |
| 217 | Blank line. |
| 218 | Header guard end; ensures only one logical inclusion of this header. |
