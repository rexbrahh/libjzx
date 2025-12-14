---
title: Runtime internals — src/jzx_internal.h
sidebar_position: 3
---

# Runtime internals — `src/jzx_internal.h`

This header is **private to the runtime**. It defines the concrete layout of `struct jzx_loop` (opaque publicly) and the internal structs that make the C ABI work.

This page uses a “textbook” format: small snippets with immediate explanation.

## Header guard and includes

<!-- snippet: src/jzx_internal.h#L1-L8 -->
```c title="Header guard and includes" showLineNumbers=1
#ifndef JZX_INTERNAL_H
#define JZX_INTERNAL_H

#include "jzx/jzx.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
```

- Includes the public ABI header (`jzx/jzx.h`) to ensure internal structs match public types.
- Pulls in pthread types because the runtime uses:
  - a mutex-protected async send queue
  - a timer thread + condition variable

## Forward declarations (internal node types)

<!-- snippet: src/jzx_internal.h#L10-L13 -->
```c title="Forward declarations" showLineNumbers=10
typedef struct jzx_async_msg jzx_async_msg;
typedef struct jzx_timer_entry jzx_timer_entry;
typedef struct jzx_io_watch jzx_io_watch;
typedef struct jzx_xev jzx_xev;
```

These exist so the file can declare pointers to these structs before defining them later. It keeps the `jzx_loop` layout readable without requiring full type definitions earlier.

## libxev integration hooks (implemented in Zig)

<!-- snippet: src/jzx_internal.h#L15-L22 -->
```c title="xev backend interface" showLineNumbers=15
jzx_xev* jzx_xev_create(void);
void jzx_xev_destroy(jzx_xev* state);
void jzx_xev_wakeup(jzx_xev* state);
void jzx_xev_run(jzx_xev* state, int mode);
jzx_err jzx_xev_watch_fd(jzx_xev* state, jzx_loop* loop, int fd, uint32_t interest);
void jzx_xev_unwatch_fd(jzx_xev* state, int fd);

uint8_t jzx_io_xev_notify(jzx_loop* loop, int fd, uint32_t readiness);
```

The runtime’s event-loop backend is implemented in `src/jzx_xev.zig` and exposed to C via exported functions.

- `jzx_xev_create/destroy`: lifetime management for the backend state.
- `jzx_xev_wakeup`: used to wake a blocking loop when cross-thread work arrives.
- `jzx_xev_run`: advances the backend (mode is implementation-defined).
- `jzx_xev_watch_fd/unwatch_fd`: register/unregister fd readiness interest.
- `jzx_io_xev_notify`: callback invoked by the backend to notify the runtime of readiness.

## Mailbox ring buffer (per-actor queue)

<!-- snippet: src/jzx_internal.h#L24-L30 -->
```c title="jzx_mailbox_impl" showLineNumbers=24
typedef struct {
    jzx_message* buffer;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_mailbox_impl;
```

This struct is the in-memory representation of an actor mailbox:

- `buffer`: ring buffer holding `jzx_message` values.
- `capacity`: fixed size of the ring buffer.
- `head` / `tail`: ring indices.
- `count`: number of queued messages (distinguishes empty vs full).

Why it exists: bounded ring buffers provide predictable memory and explicit backpressure (`JZX_ERR_MAILBOX_FULL`).

## Supervision state (child bookkeeping + restart intensity)

### Per-child state

<!-- snippet: src/jzx_internal.h#L32-L37 -->
```c title="jzx_child_state" showLineNumbers=32
typedef struct {
    jzx_child_spec spec;
    jzx_actor_id id;
    uint32_t restart_count;
    uint64_t last_restart_ms;
} jzx_child_state;
```

- `spec`: the desired “template” for this child (behavior, restart policy).
- `id`: current live actor id for this child (0 when not running).
- `restart_count` / `last_restart_ms`: used for backoff and intensity logic.

### Per-supervisor state

<!-- snippet: src/jzx_internal.h#L39-L45 -->
```c title="jzx_supervisor_state" showLineNumbers=39
typedef struct {
    jzx_supervisor_spec config;
    jzx_child_state* children;
    size_t child_count;
    uint32_t intensity_window_count;
    uint64_t intensity_window_start_ms;
} jzx_supervisor_state;
```

- `config`: strategy + intensity window config.
- `children`: heap array of per-child state.
- `intensity_window_*`: tracking restarts within a time window.

## Actor representation (what the scheduler runs)

<!-- snippet: src/jzx_internal.h#L47-L56 -->
```c title="jzx_actor" showLineNumbers=47
typedef struct jzx_actor {
    jzx_actor_id id;
    jzx_actor_status status;
    jzx_behavior_fn behavior;
    void* state;
    jzx_actor_id supervisor;
    jzx_supervisor_state* supervisor_state;
    jzx_mailbox_impl mailbox;
    uint8_t in_run_queue;
} jzx_actor;
```

Key fields:

- `id`: actor id for lookup and messaging.
- `status`: lifecycle status.
- `behavior`: function pointer called on delivery.
- `state`: user-owned pointer passed through `jzx_context`.
- `supervisor` / `supervisor_state`: supervision linkage and state (only non-null for supervisor actors).
- `mailbox`: per-actor mailbox.
- `in_run_queue`: prevents duplicate enqueue into the run queue.

## Actor table (id → actor mapping, with generations)

<!-- snippet: src/jzx_internal.h#L58-L65 -->
```c title="jzx_actor_table" showLineNumbers=58
typedef struct {
    jzx_actor** slots;
    uint32_t* generations;
    uint32_t* free_stack;
    uint32_t capacity;
    uint32_t free_top;
    uint32_t used;
} jzx_actor_table;
```

This table implements the actor-id scheme:

- `slots[idx]` stores the actor pointer.
- `generations[idx]` increments when a slot is reused.
- `free_stack` enables fast allocate/free of indices.

Why it exists: it enables fast lookup and robust stale-id rejection.

## Run queue (runnable actors waiting to run)

<!-- snippet: src/jzx_internal.h#L67-L73 -->
```c title="jzx_run_queue" showLineNumbers=67
typedef struct {
    jzx_actor** entries;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_run_queue;
```

This is a ring buffer of runnable actor pointers used by the scheduler.

## The loop (everything the runtime owns)

<!-- snippet: src/jzx_internal.h#L75-L101 -->
```c title="struct jzx_loop" showLineNumbers=75
struct jzx_loop {
    jzx_config cfg;
    jzx_allocator allocator;
    jzx_observer observer;
    void* observer_ctx;
    jzx_actor_table actors;
    jzx_run_queue run_queue;
    jzx_xev* xev;
    pthread_mutex_t async_mutex;
    uint8_t async_mutex_initialized;
    jzx_async_msg* async_head;
    jzx_async_msg* async_tail;
    pthread_mutex_t timer_mutex;
    pthread_cond_t timer_cond;
    uint8_t timer_mutex_initialized;
    uint8_t timer_cond_monotonic;
    uint8_t timer_thread_running;
    pthread_t timer_thread;
    uint8_t timer_stop;
    jzx_timer_entry* timer_head;
    jzx_timer_id next_timer_id;
    jzx_io_watch* io_watchers;
    uint32_t io_capacity;
    uint32_t io_count;
    int running;
    int stop_requested;
};
```

This is the runtime’s “world”:

- Configuration and allocator: `cfg`, `allocator`.
- Observability: `observer`, `observer_ctx`.
- Scheduling: `actors` (table), `run_queue`.
- I/O backend: `xev`.
- Cross-thread async send queue:
  - `async_mutex`, `async_head`, `async_tail`
  - `async_mutex_initialized` is a safety flag for partial init failures.
- Timer subsystem:
  - `timer_mutex`, `timer_cond`, `timer_thread`, `timer_head`, `next_timer_id`
  - `timer_cond_monotonic` tracks whether the condvar uses a monotonic clock (timeout correctness).
  - `timer_stop` is the shutdown flag for the timer thread.
- I/O watchers:
  - `io_watchers` array holds fd registrations, `io_capacity`/`io_count` track sizing and usage.
- Loop state: `running` and `stop_requested` implement cooperative stop semantics.

## Async message nodes (cross-thread send queue)

<!-- snippet: src/jzx_internal.h#L103-L110 -->
```c title="struct jzx_async_msg" showLineNumbers=103
struct jzx_async_msg {
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
    struct jzx_async_msg* next;
};
```

This is a singly-linked list node that holds a message payload for later delivery on the loop thread.

Critical semantic note:

- Payload is not copied; `data` must remain valid until the loop thread consumes it.

TODO: Document the intended lifetime rules for async payloads (heap-owned? caller-owned?).

## Timer nodes (sorted due list)

<!-- snippet: src/jzx_internal.h#L112-L120 -->
```c title="struct jzx_timer_entry" showLineNumbers=112
struct jzx_timer_entry {
    jzx_timer_id id;
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    uint64_t due_ms;
    struct jzx_timer_entry* next;
};
```

- `due_ms` is an absolute timestamp in monotonic milliseconds.
- The list is typically maintained in due-time order for efficient “next deadline” waits.

## I/O watch table entries (fd → owner + interest)

<!-- snippet: src/jzx_internal.h#L122-L127 -->
```c title="struct jzx_io_watch" showLineNumbers=122
struct jzx_io_watch {
    int fd;
    jzx_actor_id owner;
    uint32_t interest;
    uint8_t active;
};
```

- `fd`: watched file descriptor.
- `owner`: actor that should receive readiness notifications.
- `interest`: bitmask of read/write interest.
- `active`: whether this entry is in use.

## Footer (end include guard)

<!-- snippet: src/jzx_internal.h#L129-L129 -->
```c title="End of header guard" showLineNumbers=129
#endif
```
