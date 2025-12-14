---

## 1. Core mental model

Inside one process we have:

- one `jzx_loop` (built around a libxev loop)
- a set of actors, each with:

  - an ID
  - a behavior function
  - a pointer to its state
  - a mailbox
  - a supervisor reference
- a scheduler that:

  - polls libxev
  - dispatches I O events to actors
  - drains actor mailboxes in a fair way
  - applies supervision decisions

Everything is cooperative, no preemption.

---

## 2. Core data structures

### 2.1 Actor id and handle

```c
typedef uint64_t jzx_actor_id;

typedef struct jzx_actor_handle {
    jzx_actor_id id;
    // internal pointer, not exposed in public header
    struct jzx_actor* _ptr;
} jzx_actor_handle;
```

Public API uses `jzx_actor_id`. Internally the scheduler keeps a pointer table.

### 2.2 Actor state

Internal struct, roughly:

```c
typedef enum {
    JZX_ACTOR_INIT,
    JZX_ACTOR_RUNNING,
    JZX_ACTOR_STOPPING,
    JZX_ACTOR_STOPPED,
    JZX_ACTOR_FAILED,
} jzx_actor_status;

typedef struct jzx_mailbox jzx_mailbox;

typedef struct jzx_actor {
    jzx_actor_id      id;
    jzx_actor_status  status;
    jzx_behavior_fn   behavior;
    void*             state;
    jzx_mailbox*      mbox;
    jzx_actor_id      supervisor;
    // supervision metadata
    uint32_t          restart_count;
    uint64_t          first_failure_ts_ms;
    // scheduling metadata
    uint8_t           in_run_queue;
} jzx_actor;
```

Key points:

- state is opaque, owned by user
- runtime owns mailbox and scheduling metadata
- restart counters support intensity and period checks

---

## 3. Mailbox design

### 3.1 Message representation

We keep messages extremely simple:

```c
typedef struct {
    void*  data;
    size_t len;
    uint32_t tag;         // user defined, 0 for "untyped"
    jzx_actor_id sender;  // optional, zero means "system"
} jzx_message;
```

Ownership rule:

- sender allocates `data`
- receiver is responsible for freeing it or passing it on
- runtime never frees `data`, only the small `jzx_message` shell

### 3.2 Mailbox implementation

Initial implementation:

- per actor mailbox as SPSC ring buffer:

  - sender side multiple producers use a lock or lock free MPMC queue into per actor SPSC rings
  - or simpler, one MPMC per actor to start

For v1, do not over optimize, but the shape should be:

```c
struct jzx_mailbox {
    jzx_message* buf;
    uint32_t     cap;
    uint32_t     head;
    uint32_t     tail;
    uint8_t      full;
};
```

Sending:

1. Append message to target mailbox.
2. If the actor is not already in the run queue, mark `in_run_queue = 1` and push it.

Receiving:

- scheduler pops actor from run queue
- drains up to `N` messages, where `N` is a fairness bound, and calls `behavior` per message

We effectively maintain a run queue of actors that have pending work.

---

## 4. Scheduler and event loop

### 4.1 Loop structure

Conceptual main loop:

```c
void jzx_run(jzx_loop* loop) {
    for (;;) {
        // 1. Poll I O with libxev, delivering completions into an internal queue
        jzx_poll_io(loop);

        // 2. Turn I O completions and timers into messages to actors
        jzx_dispatch_system_events(loop);

        // 3. Run ready actors
        jzx_run_ready_actors(loop);
    }
}
```

### 4.2 Run ready actors

Fairness rule: each tick, for each actor in the run queue, we process up to `k` messages before yielding it.

```c
void jzx_run_ready_actors(jzx_loop* loop) {
    size_t budget = loop->max_actors_per_tick;

    while (budget-- > 0) {
        jzx_actor* a = jzx_run_queue_pop(loop);
        if (!a) break;

        a->in_run_queue = 0;

        size_t msg_budget = loop->max_msgs_per_actor;

        while (msg_budget-- > 0) {
            jzx_message msg;
            if (!jzx_mailbox_pop(a->mbox, &msg)) break;

            jzx_context ctx = {
                .state = a->state,
                .self  = a->id,
                .loop  = loop,
            };

            jzx_behavior_result r = jzx_call_behavior(a, &ctx, &msg);

            // behavior is responsible for freeing msg.data
            if (r == JZX_STOP) {
                jzx_stop_actor(loop, a, JZX_EXIT_NORMAL);
                break;
            }
            if (r == JZX_FAIL) {
                jzx_fail_actor(loop, a, JZX_EXIT_FAILURE);
                break;
            }
        }

        // if still has messages, push back to queue
        if (jzx_mailbox_has_messages(a->mbox) && a->status == JZX_ACTOR_RUNNING) {
            jzx_run_queue_push(loop, a);
            a->in_run_queue = 1;
        }
    }
}
```

This gives us:

- fairness between actors
- bounded work per actor per cycle
- a clear place where failures are detected and passed to supervision

### 4.3 Panic and crash handling

In Zig we can wrap `behavior` calls and convert panics into `JZX_FAIL`. In C builds without Zig, behavior cannot be guarded against UB.

So `jzx_call_behavior` in Zig will be something like:

```zig
fn jzx_call_behavior(a: *Actor, ctx: *jzx_context, msg: *jzx_message) jzx_behavior_result {
    // try / catch panic, translate to FAIL
}
```

If a panic occurs, we mark actor as failed and let supervision handle it.

---

## 5. Supervision

This is the part that maps closest to Erlang.

### 5.1 Child spec

A supervisor needs a declarative description of its children.

```c
typedef jzx_behavior_result (*jzx_init_fn)(void** out_state);

typedef struct {
    jzx_behavior_fn behavior;
    jzx_init_fn     init;          // optional, can be NULL
    jzx_restart_mode     mode;     // permanent, transient, temporary
    const char*          name;     // optional
} jzx_child_spec;
```

Supervisor spec:

```c
typedef struct {
    jzx_restart_strategy strategy; // one_for_one etc
    uint8_t              intensity;  // max restarts
    uint32_t             period_ms;  // time window
} jzx_supervisor_spec;
```

Supervisor actor state holds:

- list of children and their specs
- restart counters
- backoff timers per child

### 5.2 Failure event model

When an actor fails, `jzx_fail_actor` will:

- mark `status = JZX_ACTOR_FAILED`
- send a system message to its supervisor

System message tag example:

```c
#define JZX_TAG_CHILD_EXIT  1
#define JZX_TAG_CHILD_START 2
```

Payload for child exit:

```c
typedef struct {
    jzx_actor_id child;
    int          exit_reason;  // enum, normal, error, panic, etc
} jzx_child_exit;
```

Supervisor behavior receives that message and runs a library provided helper:

```c
jzx_supervisor_action jzx_handle_child_exit(
    jzx_supervisor_state* sup_state,
    const jzx_child_exit* ev
);
```

That helper decides:

- restart child immediately
- restart child after backoff
- escalate (stop supervisor and notify its own supervisor)
- ignore (in case of temporary child)

### 5.3 Restart rules

For `one_for_one`:

- only the failed child is restarted

For `one_for_all`:

- failed child and all siblings are stopped and then restarted

For `rest_for_one`:

- failed child and all children that started after it are restarted

Restart is allowed only if:

- child mode is permanent, or
- child mode is transient and exit was abnormal

Restart intensity:

- if `restart_count` within `period_ms` exceeds `intensity`, supervisor itself fails

That failure bubbles upward, giving you supervision trees.

---

## 6. Timers and I O

### 6.1 Timers

Wrap libxev timers as actor messages.

API:

```c
int jzx_send_after(
    jzx_loop* loop,
    jzx_actor_id target,
    uint32_t ms,
    void* msg,
    size_t len,
    uint32_t tag
);
```

Internally:

- set up a libxev timer
- when it fires, push the message into the actor’s mailbox
- mark the actor runnable

No separate callback style. Everything is actor messaging.

### 6.2 I O

We do the same for sockets or file descriptors:

- user registers a socket with a specific actor
- libxev notifies us about readiness
- jazz wraps the event as a `jzx_message` with a known tag, for example `JZX_TAG_IO_READABLE`
- actor reacts in its behavior function

Later we can add small helpers:

```c
int jzx_watch_fd(
    jzx_loop* loop,
    int fd,
    jzx_actor_id owner,
    uint32_t interest_flags
);
```

Again, no callbacks leaking from libxev into user code. All surfaced as messages.

---

## 7. Spawn and lifecycle API

Let us refine spawn semantics to something practical.

### 7.1 Simple spawn

```c
typedef struct {
    jzx_behavior_fn behavior;
    void*           state;
    jzx_actor_id    supervisor;   // 0 for "root"
} jzx_spawn_opts;

jzx_actor_id jzx_spawn(jzx_loop* loop, const jzx_spawn_opts* opts);
```

In Zig you probably wrap this with generics for typed state.

### 7.2 Supervisor spawn

```c
typedef struct {
    const jzx_child_spec* children;
    size_t                child_count;
    jzx_supervisor_spec   sup_spec;
} jzx_supervisor_init;

jzx_actor_id jzx_spawn_supervisor(
    jzx_loop* loop,
    const jzx_supervisor_init* init,
    jzx_actor_id parent
);
```

Internally this will:

- allocate supervisor state
- spawn the supervisor actor with a built in behavior function that:

  - listens for `CHILD_EXIT` and timer messages
  - maintains restart bookkeeping
  - restarts children when needed

So library users do not write supervision logic manually. They just declare child specs and possibly react to high level events.

---

## 8. Where this goes next

Now that we have:

- actor representation
- mailbox concept
- scheduler outline
- supervision primitives
- timer and I O integration shape
- spawn and lifecycle semantics

The next logical layer is one of:

1. **Concrete C header design** for public API, including error codes and initialization.
2. **Internal scheduler and run queue design** in more detail, including data structures for actors and queues.
3. **A worked example** of how jazz would model a real system, for example:

   - a TCP server where each connection is an actor under a supervisor
   - or SydraDB ingestion heads and indexers modeled as actors
