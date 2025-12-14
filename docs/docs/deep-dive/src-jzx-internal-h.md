---
title: Runtime internals — src/jzx_internal.h (annotated)
sidebar_position: 3
---

# Runtime internals — `src/jzx_internal.h`

This header is **private to the runtime**. It defines the structs and internal helpers that back the public ABI in `include/jzx/jzx.h`.

## Full source (with line numbers)

```c title="src/jzx_internal.h" showLineNumbers
#ifndef JZX_INTERNAL_H
#define JZX_INTERNAL_H

#include "jzx/jzx.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

typedef struct jzx_async_msg jzx_async_msg;
typedef struct jzx_timer_entry jzx_timer_entry;
typedef struct jzx_io_watch jzx_io_watch;
typedef struct jzx_xev jzx_xev;

jzx_xev* jzx_xev_create(void);
void jzx_xev_destroy(jzx_xev* state);
void jzx_xev_wakeup(jzx_xev* state);
void jzx_xev_run(jzx_xev* state, int mode);
jzx_err jzx_xev_watch_fd(jzx_xev* state, jzx_loop* loop, int fd, uint32_t interest);
void jzx_xev_unwatch_fd(jzx_xev* state, int fd);

uint8_t jzx_io_xev_notify(jzx_loop* loop, int fd, uint32_t readiness);

typedef struct {
    jzx_message* buffer;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_mailbox_impl;

typedef struct {
    jzx_child_spec spec;
    jzx_actor_id id;
    uint32_t restart_count;
    uint64_t last_restart_ms;
} jzx_child_state;

typedef struct {
    jzx_supervisor_spec config;
    jzx_child_state* children;
    size_t child_count;
    uint32_t intensity_window_count;
    uint64_t intensity_window_start_ms;
} jzx_supervisor_state;

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

typedef struct {
    jzx_actor** slots;
    uint32_t* generations;
    uint32_t* free_stack;
    uint32_t capacity;
    uint32_t free_top;
    uint32_t used;
} jzx_actor_table;

typedef struct {
    jzx_actor** entries;
    uint32_t capacity;
    uint32_t head;
    uint32_t tail;
    uint32_t count;
} jzx_run_queue;

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

struct jzx_async_msg {
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    jzx_actor_id sender;
    struct jzx_async_msg* next;
};

struct jzx_timer_entry {
    jzx_timer_id id;
    jzx_actor_id target;
    void* data;
    size_t len;
    uint32_t tag;
    uint64_t due_ms;
    struct jzx_timer_entry* next;
};

struct jzx_io_watch {
    int fd;
    jzx_actor_id owner;
    uint32_t interest;
    uint8_t active;
};

#endif
```

## Line-by-line commentary

| Line | What it is / why it exists |
| ---: | --- |
| 1 | Header guard start for this private header. |
| 2 | Header guard define. |
| 3 | Blank line to keep sections visually separated. |
| 4 | Includes the public ABI so internal types match public declarations (`jzx_loop`, `jzx_message`, etc.). |
| 5 | Blank line. |
| 6 | Includes pthread primitives used by async send + timer thread. |
| 7 | Includes `stddef.h` for `size_t` used in payload sizes and arrays. |
| 8 | Includes `stdint.h` for `uint32_t/uint64_t/uint8_t` fields. |
| 9 | Blank line. |
| 10 | Forward-declare `jzx_async_msg` so the loop struct can refer to it without ordering constraints. |
| 11 | Forward-declare `jzx_timer_entry` (timer list node). |
| 12 | Forward-declare `jzx_io_watch` (fd watch table entry). |
| 13 | Forward-declare `jzx_xev` (opaque state for the libxev integration). |
| 14 | Blank line. |
| 15 | `jzx_xev_create`: allocates/initializes the libxev backend state. |
| 16 | `jzx_xev_destroy`: tears down the backend state (must stop watchers and free resources). |
| 17 | `jzx_xev_wakeup`: wakes the event loop (used when cross-thread work is enqueued). |
| 18 | `jzx_xev_run`: drives the backend loop for one “tick”/mode (implementation-defined). |
| 19 | `jzx_xev_watch_fd`: register interest in fd readiness with the backend and associate with `loop`. |
| 20 | `jzx_xev_unwatch_fd`: remove a previously registered fd watch from the backend. |
| 21 | Blank line. |
| 22 | `jzx_io_xev_notify`: callback used by the backend to notify the runtime that an fd is ready. |
| 23 | Blank line. |
| 24 | Starts `jzx_mailbox_impl`, the internal mailbox ring buffer representation. |
| 25 | `buffer`: contiguous ring buffer storing `jzx_message` envelopes. |
| 26 | `capacity`: total number of message slots allocated. |
| 27 | `head`: index of the next message to pop. |
| 28 | `tail`: index where the next push will write. |
| 29 | `count`: current number of queued messages (distinguishes empty vs full). |
| 30 | Closes mailbox implementation struct. |
| 31 | Blank line. |
| 32 | Starts `jzx_child_state`, the runtime-tracked state for one supervised child. |
| 33 | `spec`: immutable template describing behavior/restart policy for the child. |
| 34 | `id`: current actor id for the live child instance (0 when not running). |
| 35 | `restart_count`: number of restarts attempted (used for intensity/backoff). |
| 36 | `last_restart_ms`: last restart timestamp (used for backoff timing and intensity windows). |
| 37 | Closes child state struct. |
| 38 | Blank line. |
| 39 | Starts `jzx_supervisor_state`, the runtime state for a supervisor’s child set. |
| 40 | `config`: the supervisor config (strategy/intensity/backoff). |
| 41 | `children`: heap array of `jzx_child_state` entries (one per configured child). |
| 42 | `child_count`: number of children in the `children` array. |
| 43 | `intensity_window_count`: restart attempts observed in the current window. |
| 44 | `intensity_window_start_ms`: window start timestamp (0 means “not started yet”). |
| 45 | Closes supervisor state struct. |
| 46 | Blank line. |
| 47 | Starts `jzx_actor`, the runtime’s internal representation of an actor. |
| 48 | `id`: stable actor id for this live actor instance. |
| 49 | `status`: lifecycle state (running/stopped/failed). |
| 50 | `behavior`: message handler function pointer (C ABI behavior). |
| 51 | `state`: user state pointer passed back via `jzx_context.state`. |
| 52 | `supervisor`: supervisor id (0 means “no supervisor / root”). |
| 53 | `supervisor_state`: non-null only for supervisor actors that manage children. |
| 54 | `mailbox`: per-actor message queue implementation. |
| 55 | `in_run_queue`: whether the actor is currently enqueued as runnable (avoid duplicates). |
| 56 | Closes actor struct typedef. |
| 57 | Blank line. |
| 58 | Starts `jzx_actor_table`, a compact slot table used to map `jzx_actor_id` → `jzx_actor*`. |
| 59 | `slots`: array of pointers indexed by actor slot index. |
| 60 | `generations`: per-slot generation counters; combined with index to form `jzx_actor_id`. |
| 61 | `free_stack`: LIFO stack of free slot indices (fast allocate/free). |
| 62 | `capacity`: total size of `slots/generations/free_stack` arrays. |
| 63 | `free_top`: stack pointer for `free_stack`. |
| 64 | `used`: number of live actors in the table (helps enforce caps and debugging). |
| 65 | Closes actor-table struct. |
| 66 | Blank line. |
| 67 | Starts `jzx_run_queue`, the scheduler’s queue of runnable actors. |
| 68 | `entries`: ring buffer of `jzx_actor*` pointers. |
| 69 | `capacity`: size of the ring buffer. |
| 70 | `head`: index of next actor to run. |
| 71 | `tail`: index where next enqueue will write. |
| 72 | `count`: number of runnable actors queued. |
| 73 | Closes run queue struct. |
| 74 | Blank line. |
| 75 | Starts the definition of the opaque `struct jzx_loop` (opaque publicly, concrete privately). |
| 76 | `cfg`: a copy of user-provided config for later access. |
| 77 | `allocator`: effective allocator (may be derived from cfg). |
| 78 | `observer`: installed observer callback table (may contain null function pointers). |
| 79 | `observer_ctx`: opaque user pointer passed to observer callbacks. |
| 80 | `actors`: actor table (id → actor mapping). |
| 81 | `run_queue`: scheduler run queue of runnable actors. |
| 82 | `xev`: pointer to the libxev integration state. |
| 83 | `async_mutex`: guards the cross-thread async message list. |
| 84 | `async_mutex_initialized`: tracks whether the mutex was successfully initialized. |
| 85 | `async_head`: head of the async message singly-linked list. |
| 86 | `async_tail`: tail pointer to append in O(1). |
| 87 | `timer_mutex`: guards the timer list and timer thread coordination. |
| 88 | `timer_cond`: condition variable for waking the timer thread when timers change. |
| 89 | `timer_mutex_initialized`: tracks whether the timer mutex is initialized. |
| 90 | `timer_cond_monotonic`: whether the condvar uses a monotonic clock (timeout correctness). |
| 91 | `timer_thread_running`: indicates the timer thread is alive/running. |
| 92 | `timer_thread`: pthread handle for the timer thread. |
| 93 | `timer_stop`: stop flag checked by the timer thread. |
| 94 | `timer_head`: head of the sorted timer list. |
| 95 | `next_timer_id`: monotonically increasing id generator for timers. |
| 96 | `io_watchers`: array of watch entries (fd → owner/interest). |
| 97 | `io_capacity`: size of `io_watchers` array. |
| 98 | `io_count`: number of active io watchers. |
| 99 | `running`: loop is currently running (used for reentrancy/stop semantics). |
| 100 | `stop_requested`: cooperative stop flag checked by the run loop. |
| 101 | Closes `struct jzx_loop`. |
| 102 | Blank line. |
| 103 | Starts `struct jzx_async_msg`, node type for cross-thread “send_async” enqueues. |
| 104 | `target`: actor id the message will be delivered to. |
| 105 | `data`: raw payload pointer (not copied). |
| 106 | `len`: payload byte length. |
| 107 | `tag`: message tag. |
| 108 | `sender`: sender actor id (often 0 for cross-thread sends). |
| 109 | `next`: linked-list pointer for queueing. |
| 110 | Closes async-msg node struct. |
| 111 | Blank line. |
| 112 | Starts `struct jzx_timer_entry`, node type for the timer linked list. |
| 113 | `id`: timer id returned to callers. |
| 114 | `target`: actor id that will receive the message when timer fires. |
| 115 | `data`: raw payload pointer (lifetime requirements apply; not copied). |
| 116 | `len`: payload byte length. |
| 117 | `tag`: message tag delivered when timer fires. |
| 118 | `due_ms`: absolute due time in monotonic milliseconds. |
| 119 | `next`: linked-list pointer. |
| 120 | Closes timer-entry node struct. |
| 121 | Blank line. |
| 122 | Starts `struct jzx_io_watch`, the runtime’s record for an fd watch. |
| 123 | `fd`: watched file descriptor. |
| 124 | `owner`: actor that will receive readiness notifications. |
| 125 | `interest`: bitmask of `JZX_IO_READ`/`JZX_IO_WRITE`. |
| 126 | `active`: whether this watch entry is currently in use. |
| 127 | Closes io-watch struct. |
| 128 | Blank line. |
| 129 | Header guard end. |
