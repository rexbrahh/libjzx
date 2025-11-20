---

## 1. Error model (finalized)

We’ll stick with:

- `0` = success
- negative values = errors
- no positive error codes

### 1.1 Unified error enum

```c
typedef enum {
    JZX_OK                 = 0,

    JZX_ERR_UNKNOWN        = -1,
    JZX_ERR_NO_MEMORY      = -2,
    JZX_ERR_INVALID_ARG    = -3,
    JZX_ERR_LOOP_CLOSED    = -4,

    JZX_ERR_NO_SUCH_ACTOR  = -5,
    JZX_ERR_ACTOR_NOT_LOCAL= -6, // future distributed use; v1 always local

    JZX_ERR_MAILBOX_FULL   = -7,
    JZX_ERR_TIMER_INVALID  = -8,
    JZX_ERR_IO_REG_FAILED  = -9,
    JZX_ERR_IO_NOT_WATCHED = -10,

    JZX_ERR_MAX_ACTORS     = -11,
} jzx_err;
```

### 1.2 Per-function failure conditions

- `jzx_loop_create`

  - `JZX_ERR_INVALID_ARG` if `cfg` invalid (e.g. max_actors == 0).
  - returns `NULL` on NO_MEMORY, not an error code.

- `jzx_loop_run`

  - `JZX_ERR_LOOP_CLOSED` if called after stop / destroy.
  - `JZX_ERR_UNKNOWN` only if some unrecoverable internal assertion trips.

- `jzx_spawn` / `jzx_spawn_supervisor`

  - `JZX_ERR_LOOP_CLOSED` if loop stopping or destroyed.
  - `JZX_ERR_MAX_ACTORS` if actor table is exhausted.
  - `JZX_ERR_NO_MEMORY` if alloc fails.
  - `JZX_ERR_INVALID_ARG` if behavior is NULL.

- `jzx_send` / `jzx_send_async`

  - `JZX_ERR_LOOP_CLOSED` if loop is not running.
  - `JZX_ERR_NO_SUCH_ACTOR` if id not found or generation mismatch.
  - `JZX_ERR_MAILBOX_FULL` if mailbox cannot accept the message.

- `jzx_actor_stop` / `jzx_actor_fail`

  - `JZX_ERR_NO_SUCH_ACTOR` for invalid id.
  - `JZX_ERR_LOOP_CLOSED` otherwise.

- `jzx_send_after`

  - `JZX_ERR_NO_SUCH_ACTOR` if target invalid.
  - `JZX_ERR_NO_MEMORY` for timer record.
  - `JZX_ERR_LOOP_CLOSED` if loop not active.

- `jzx_cancel_timer`

  - `JZX_ERR_TIMER_INVALID` if timer id unknown or already fired/cancelled.

- `jzx_watch_fd`

  - `JZX_ERR_IO_REG_FAILED` if libxev registration fails.
  - `JZX_ERR_NO_SUCH_ACTOR` if owner invalid.

---

## 2. Fairness and defaults

We need explicit semantics plus reasonable default config.

### 2.1 Message ordering guarantees

- Within a single actor’s mailbox, **messages are FIFO** in the order they are successfully enqueued via `jzx_send` / `jzx_send_async` and internal system sends.
- `jzx_behavior_fn` for a given actor sees messages in that FIFO order, unless the actor crashes before consuming them.
- There is no cross-actor ordering guarantee.

### 2.2 Scheduling fairness

Parameters (tunable in `jzx_config`):

- `max_msgs_per_actor` Max messages processed for a given actor on a single “visit” to the run queue.

- `max_actors_per_tick` Max actors popped from the run queue before we go back to I/O polling.

Semantics:

- The scheduler repeatedly:

  1. drains async send envelope queue
  2. polls I/O
  3. dispatches I/O/timer events as messages
  4. processes up to `max_actors_per_tick` actors from the run queue, each up to `max_msgs_per_actor` messages

Guarantee:

- A constantly busy actor cannot monopolize the loop; it’s limited by `max_msgs_per_actor`.
- If there’s a finite number of non-empty mailboxes, everyone gets progress as long as they’re in the run queue.

### 2.3 Default values

Initial defaults (you can tune in code):

```c
default_mailbox_cap   = 1024;  // per actor
max_msgs_per_actor    = 64;
max_actors_per_tick   = 1024;
max_actors            = 65536; // configurable
```

Reasonable for a single threaded event loop with tens of thousands of actors.

---

## 3. Backoff spec (final)

We define per-child backoff as **optional** and purely a supervision concern.

### 3.1 Backoff struct

```c
typedef struct {
    uint32_t initial_delay_ms;  // e.g. 100
    uint32_t max_delay_ms;      // e.g. 10_000
    float    factor;            // e.g. 2.0
    uint32_t jitter_ms;         // random +/- jitter; 0 = none
} jzx_backoff_spec;
```

Extend `jzx_child_spec`:

```c
typedef struct {
    const char*       name;
    jzx_behavior_fn   behavior;
    jzx_init_fn       init;          // may be NULL
    jzx_child_mode    mode;
    uint32_t          mailbox_cap;   // 0 = default
    const jzx_backoff_spec* backoff; // NULL = no backoff, restart immediately
} jzx_child_spec;
```

### 3.2 Backoff behavior

For each child, supervisor keeps:

- `current_delay_ms` (starts at 0)
- `last_restart_ts`

On abnormal failure:

1. If `backoff == NULL`: restart immediately (subject to intensity/period).
2. Else:

   - if `current_delay_ms == 0` → set to `initial_delay_ms`, else `current_delay_ms *= factor`, clamped to `max_delay_ms`.
   - apply jitter: sample a random delta in `[-jitter_ms, +jitter_ms]` and clamp to `[0, max_delay_ms]`.
   - schedule a timer that, when fired, sends a `JZX_TAG_SYS_CHILD_RESTART` message to the supervisor.

On successful restart and stable running (you decide definition, e.g. no failures for `period_ms`), supervisor may reset `current_delay_ms` to 0.

If intensity/period limit is reached, supervisor escalates regardless of backoff.

---

## 4. I/O unregister & closed-fd behavior

We need symmetry and clear guarantees.

### 4.1 New API: unwatch

```c
jzx_err jzx_unwatch_fd(
    jzx_loop* loop,
    int fd
);
```

Semantics:

- Remove the fd from libxev interest sets.
- Drop any pending I/O events for this fd that haven’t yet been turned into messages.
- It is **idempotent**: calling it again for the same fd returns `JZX_ERR_IO_NOT_WATCHED`.

### 4.2 Behavior when actor dies

Policy:

- When an actor that owns an fd (registered via `jzx_watch_fd`) stops or fails, runtime automatically calls `jzx_unwatch_fd(loop, fd)` internally for all fds mapped to that actor.
- That guarantees:

  - no further I/O events will arrive for that actor after its death
  - resource leak is avoided at libxev level

User’s responsibility:

- Closing the fd itself is up to user code inside the actor; libjzx doesn’t call `close()` for you.

### 4.3 Behavior when fd is closed externally

If user closes the fd but forgets/unable to unwatch:

- libxev will eventually report error/EOF.
- jazz will translate that into a `jzx_io_event` message, where `readiness` contains error indication (you can define a flag like `JZX_IO_ERROR`).
- After delivering that, the actor should either:

  - call `jzx_unwatch_fd`, or
  - stop/fail itself, relying on automatic unwatch on death.

You can document: “Calling `close(fd)` without `jzx_unwatch_fd` is allowed but will generate at least one error-ready event.”

---

## 5. Threading model (final rules)

Make it explicit and simple.

### 5.1 Owner thread

- Each `jzx_loop` has a single **owner thread**: the one that calls `jzx_loop_run`.
- All actor behaviors and internal runtime logic run on that thread.

### 5.2 API classification

**Loop-thread only API** (undefined behavior if called from other threads):

- `jzx_loop_run`
- `jzx_loop_destroy`
- `jzx_spawn`, `jzx_spawn_supervisor`
- `jzx_send`
- `jzx_actor_stop`, `jzx_actor_fail`
- `jzx_send_after`, `jzx_cancel_timer`
- `jzx_watch_fd`, `jzx_unwatch_fd`
- `jzx_loop_set_observer`

**Cross-thread safe API**:

- `jzx_loop_request_stop` (atomic flag + wakeup)
- `jzx_send_async`

Everything else is “loop thread only” in v1.

### 5.3 Waking the loop from other threads

You need a wakeup mechanism (eventfd/pipe) integrated with libxev.

- `jzx_loop` holds a `wakeup_fd` watched by libxev.
- `jzx_send_async` and `jzx_loop_request_stop` both:

  - push an envelope / set stop flag
  - write a byte to `wakeup_fd`

When `wakeup_fd` is readable, loop:

1. clears the wakeup by reading the fd.
2. drains async send queue and stop flag.

This keeps the design coherent and avoids busy-waiting.

---

## 6. Mailbox backpressure: system vs user messages

We picked “hard cap + error” for user messages, but system messages need special handling.

### 6.1 Policy: reserved system capacity

Each mailbox has:

- `cap` total slots
- `user_cap` = `cap - sys_reserved`
- `sys_reserved` = small constant (e.g. 4)

We maintain two logical queues but can implement them in one ring or two separate rings.

Rules:

- Regular `jzx_send` / `jzx_send_async` use the **user portion**; they fail with `JZX_ERR_MAILBOX_FULL` when that space is full.
- System messages (child exit, restart, timers internal, I/O errors) use **system portion**; they only fail if the entire mailbox (user + system) is completely full, which should not happen under normal constraints.

If a system message truly cannot be enqueued:

- treat this as fatal for the actor (and likely its supervisor):

  - log via `on_mailbox_full`
  - force actor failure and propagate upward

This ensures supervision and timers remain functional even when user code abuses mailbox capacity.

### 6.2 Global vs per-actor capacity

Policy:

- Capacity is **per actor**, driven by:

  - `default_mailbox_cap` in `jzx_config`, and
  - per actor / per child overrides in spawn options / child specs.

No global shared cap in v1. That keeps memory predictable.

---

## 7. Observability (final set)

We defined the callback struct; let’s finalize events and payloads.

### 7.1 Observer struct

```c
typedef struct {
    void (*on_actor_start)(
        void* ctx,
        jzx_actor_id id,
        const char* name
    );

    void (*on_actor_stop)(
        void* ctx,
        jzx_actor_id id,
        int reason /* JZX_EXIT_NORMAL, JZX_EXIT_FAIL, JZX_EXIT_PANIC */
    );

    void (*on_actor_restart)(
        void* ctx,
        jzx_actor_id supervisor,
        jzx_actor_id child,
        int attempt
    );

    void (*on_supervisor_escalate)(
        void* ctx,
        jzx_actor_id supervisor
    );

    void (*on_mailbox_full)(
        void* ctx,
        jzx_actor_id target
    );
} jzx_observer;

void jzx_loop_set_observer(
    jzx_loop* loop,
    const jzx_observer* obs,
    void* ctx
);
```

All callbacks:

- Are invoked only on the loop thread.
- Must be non-blocking and reasonably fast.

### 7.2 Exit reason enum

```c
typedef enum {
    JZX_EXIT_NORMAL = 0,  // JZX_BEHAVIOR_STOP or explicit stop
    JZX_EXIT_FAIL   = 1,  // JZX_BEHAVIOR_FAIL or explicit fail
    JZX_EXIT_PANIC  = 2,  // Zig panic guarded to fail
} jzx_exit_reason;
```

Supervisor behavior and observer callbacks both use this.

---

## 8. Invariants and guarantees

Make them explicit so you can test them.

1. **Actor identity**

   - Once an actor is stopped and freed, its `actor_id` will never refer to another actor with a different generation.
   - Lookup using a stale `actor_id` either returns `NO_SUCH_ACTOR` or safely `NULL` internally.

2. **Message ordering**

   - For a given actor, messages are processed FIFO per mailbox, as long as the actor remains alive.

3. **At-most-once delivery**

   - A message is either:

     - successfully enqueued and eventually delivered exactly once to the behavior, or
     - rejected with an error (`MAILBOX_FULL`, `NO_SUCH_ACTOR`, etc.).
   - There is no “maybe delivered, maybe not, but no error”.

4. **Supervision**

   - If a child fails, exactly one `CHILD_EXIT` system message will be delivered to its supervisor, unless the supervisor is already dead.
   - Restart decisions follow the configured `child_mode` and `restart_strategy`.
   - If the restart intensity exceeds `intensity` within `period_ms`, supervisor escalates exactly once.

5. **Timer semantics**

   - If `jzx_send_after` returns `JZX_OK`, then either:

     - the target actor eventually receives that message once, or
     - `jzx_cancel_timer` succeeds and the message is never delivered.

6. **I/O semantics**

   - When a watched fd becomes readable/writable, owner actor will eventually receive exactly one `jzx_io_event` describing that readiness state, unless the actor dies or fd is unwatched.

7. **Loop lifetime**

   - Once `jzx_loop_destroy` is called, no public API except `jzx_loop_destroy` itself and `jzx_loop_run` (which must error) is valid.
   - No callbacks are invoked after destroy.

You can literally turn each invariant into an integration test.

---

## 9. Zig layer: concrete decisions

We don’t need full code, just clear semantics.

### 9.1 Message representation

To avoid serialization complexity in v1:

- Zig actor wrappers support _pointer-based_ messages only.
- A generic Actor definition:

```zig
pub fn Actor(comptime State: type, comptime MsgPtr: type) type {
    comptime {
        if (@typeInfo(MsgPtr) != .Pointer) {
            @compileError("MsgPtr must be a pointer type");
        }
    }

    return struct {
        id: c.jzx_actor_id,

        pub const StateType = State;
        pub const MsgType = MsgPtr;

        // spawn, send, etc.
    };
}
```

User owns allocation for messages; actors treat message pointers as ephemeral view into that data, free or recycle as they like.

### 9.2 Panic handling

Zig trampoline around C behavior:

- Every Zig actor created with the wrapper uses a shared C callback.

Pseudo:

```zig
fn behaviorTrampoline(
    ctx: *c.jzx_context,
    msg: *const c.jzx_message,
) callconv(.C) c.jzx_behavior_result {
    const state = @ptrCast(*State, ctx.state);
    const mptr = @ptrCast(MsgPtr, msg.data);

    var wrappedCtx = JazzContext(State){
        .state = state,
        .self = ctx.self,
        .loop = ctx.loop,
    };

    const result = userBehavior(&wrappedCtx, mptr) catch {
        // any panic -> fail
        return c.JZX_BEHAVIOR_FAIL;
    };

    return switch (result) {
        .ok => c.JZX_BEHAVIOR_OK,
        .stop => c.JZX_BEHAVIOR_STOP,
        .fail => c.JZX_BEHAVIOR_FAIL,
    };
}
```

This gives you “panic = failure” semantics similar to BEAM exceptions under a supervisor.

---

## 10. SydraDB mapping: slightly more concrete

Just enough to be actionable.

### 10.1 Suggested tree

- `SupRoot` (per process)

  - `SupIngest` (one or multiple, e.g. per shard)

    - `HeadActor(series_head_id)` for each active head
  - `SupMerge`

    - `MergeActor(job_id)` per merge job
  - `SupIndex`

    - `IndexActor(index_task_id)`
  - `MetricsActor`
  - `MaintenanceActor` (compaction, vacuum, etc.)

### 10.2 Ingest head behavior

State fields:

- WAL file descriptor or handle
- write buffer
- series metadata (id, retention policy…)
- outstanding bytes since last flush

Messages:

- `Append{ points: *PointBuf }`
- `Flush` (timer-driven)
- `RotateWal` (maintenance)
- `Shutdown`

Supervisor:

- `child_mode = PERMANENT`
- `one_for_one`
- backoff for repeated failures to avoid thrash

You can write one concrete example actor on your Mac and exercise the runtime as you build it.

---
