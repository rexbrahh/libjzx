## 1. Actor id and actor table design

### 1.1 Requirements

- Lookup `actor_id -> *Actor` must be O(1) average.
- Ids must not be accidentally reused in a way that lets a stale handle talk to a new actor.
- Upper bound on actors is configurable at loop creation.
- Table operations are single threaded in v1.

### 1.2 Id format

Use a 64 bit id split into:

- 32 bit slot index
- 32 bit generation

Layout (from least significant to most):

- bits 0-31: index
- bits 32-63: generation

```c
typedef uint64_t jzx_actor_id;

static inline uint32_t jzx_id_index(jzx_actor_id id) {
    return (uint32_t)(id & 0xffffffffu);
}

static inline uint32_t jzx_id_generation(jzx_actor_id id) {
    return (uint32_t)(id >> 32);
}

static inline jzx_actor_id jzx_make_id(uint32_t gen, uint32_t idx) {
    return ((uint64_t)gen << 32) | (uint64_t)idx;
}
```

### 1.3 Actor table structure

At loop init:

```c
typedef struct {
    struct jzx_actor** slots;   // length = max_actors
    uint32_t*          gens;    // same length, generation per slot
    uint32_t           max;
    uint32_t           used;
    uint32_t*          free_stack;
    uint32_t           free_top;
} jzx_actor_table;
```

Initialization:

- `slots[i] = NULL` for all i
- `gens[i] = 1` for all i (start generation at 1)
- `free_stack` initially contains all indices `[max_actors - 1 .. 0]`
- `free_top = max_actors`

### 1.4 Allocating a slot (spawning an actor)

On spawn:

1. If `free_top == 0`, return `JZX_ERR_NO_MEMORY` or `JZX_ERR_MAX_ACTORS`.
2. Pop an index `idx = free_stack[--free_top]`.
3. Read `gen = gens[idx]`.
4. Allocate and initialize `jzx_actor` object.
5. Store pointer `slots[idx] = actor`.
6. Create id `id = jzx_make_id(gen, idx)` and return it.

### 1.5 Looking up an actor

```c
static inline struct jzx_actor* jzx_actor_lookup(
    jzx_actor_table* tab,
    jzx_actor_id id
) {
    uint32_t idx = jzx_id_index(id);
    uint32_t gen = jzx_id_generation(id);
    if (idx >= tab->max) return NULL;
    if (tab->gens[idx] != gen) return NULL;
    return tab->slots[idx];  // may be NULL if not allocated
}
```

### 1.6 Freeing a slot (actor death)

When an actor is stopped or failed and fully torn down:

1. Compute `idx = jzx_id_index(id)`.
2. `slots[idx] = NULL`.
3. Increment `gens[idx] += 1` (wrapping is fine, 32 bit is huge).
4. Push `idx` onto `free_stack[free_top++]`.
5. Decrement `used`.

This means any stale `jzx_actor_id` from an old generation fails lookup cleanly.

---

## 2. Threading and send semantics

### 2.1 v1 model

- All loop and actor operations run on one thread that owns `jzx_loop`.
- The public API is only safe to call from that thread, except for a special async send function.

So:

- `jzx_loop_run` must be called from the owner thread.
- `jzx_spawn`, `jzx_send`, `jzx_watch_fd`, etc are only safe from that thread.
- If you want cross thread sends, you use `jzx_send_async`.

You can document that v1 libjzx is single threaded by design, with a clear future path for multi loop.

### 2.2 Cross thread send: `jzx_send_async`

Introduce an optional safe entry point from foreign threads:

```c
jzx_err jzx_send_async(
    jzx_loop* loop,
    jzx_actor_id target,
    void* data,
    size_t len,
    uint32_t tag
);
```

Implementation idea:

- `jzx_loop` owns a `MPMC` queue of envelopes:

```c
typedef struct {
    jzx_actor_id target;
    void*        data;
    size_t       len;
    uint32_t     tag;
} jzx_envelope;
```

- `jzx_send_async` just pushes an envelope into this queue.
- Inside the loop, before running actors, the scheduler drains this queue:

```c
static void jzx_drain_async_queue(jzx_loop* loop) {
    jzx_envelope env;
    size_t count = loop->max_async_drain;
    while (count-- > 0 && mpmc_pop(&loop->async_q, &env)) {
        jzx_send(loop, env.target, 0, env.data, env.len, env.tag);
    }
}
```

So the core logic stays single threaded; only the async envelope queue is shared.

### 2.3 Rules to document

- `jzx_send` is only valid on loop thread.
- `jzx_send_async` is safe from any thread but introduces a small delay and relies on extra memory allocation for envelopes.
- For low latency, code should prefer `jzx_send` inside actors, and reserve `jzx_send_async` for integration points.

---

## 3. Mailbox backpressure policy

You need one clear policy for v1 or it gets muddy.

### 3.1 Default policy: hard cap and error

For each actor you have:

- `mailbox_cap` in `jzx_spawn_opts` or per child spec.
- `jzx_mailbox_push` returns `false` when full.

In `jzx_send`:

- If push fails, return `JZX_ERR_MAILBOX_FULL`.
- The runtime does not block, does not drop automatically.

Rationale:

- It is honest and explicit.
- Callers can pick their own policy around `JZX_ERR_MAILBOX_FULL`:

  - drop message
  - retry
  - escalate as actor failure
  - backpressure to upstream

You can add more policies later, but this keeps v1 simple.

### 3.2 Optional future policies

Not for now, but worth naming:

- sliding buffer: drop oldest when inserting new
- bounded retries with spin or sleep
- shared mailbox capacity across actor groups

These are additive, not required for initial implementation.

---

## 4. Observability hooks

If you do not bake this in early, it gets annoying.

### 4.1 Events you care about

At minimum:

- actor started
- actor stopped (normal)
- actor failed (abnormal)
- actor restarted
- supervisor escalation
- message dropped due to mailbox full
- loop start and stop

### 4.2 Callback interface

Expose a small observer struct:

```c
typedef struct {
    void (*on_actor_start)(void* ctx, jzx_actor_id id, const char* name);
    void (*on_actor_stop)(void* ctx, jzx_actor_id id, int reason);
    void (*on_actor_restart)(void* ctx, jzx_actor_id id, int attempt);
    void (*on_supervisor_escalate)(void* ctx, jzx_actor_id id);
    void (*on_mailbox_full)(void* ctx, jzx_actor_id id);
} jzx_observer;

void jzx_loop_set_observer(
    jzx_loop* loop,
    const jzx_observer* obs,
    void* ctx
);
```

All callbacks are called on the loop thread, so no extra locking needed.

You can connect these to:

- logging
- metrics (counters for restarts, failures, etc)
- debug tooling

For v1, you can stub some of these and call only the relevant ones.

---

## 5. Zig wrapper API design

The Zig layer should make this pleasant, while still mapping mostly 1:1 to the C ABI.

I will outline shape, not full code.

### 5.1 Zig module layout

File structure in `src/`:

- `jzx.zig`

  - main Zig interface
  - wraps C ABI
- `jzx/actor.zig`
- `jzx/supervisor.zig`
- `jzx/io.zig`

You can decide if you want multiple files or a single module.

### 5.2 Loop wrapper

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("jzx.h");
});

pub const Loop = struct {
    ptr: *c.jzx_loop,

    pub fn init(alloc: std.mem.Allocator, max_actors: u32) !Loop {
        var cfg: c.jzx_config = .{
            .allocator = .{
                .alloc = c_callback_alloc,
                .free  = c_callback_free,
                .ctx   = alloc_context_ptr,
            },
            .max_actors = max_actors,
            .default_mailbox_cap = 1024,
            .max_msgs_per_actor = 128,
            .max_actors_per_tick = 1024,
        };
        const p = c.jzx_loop_create(&cfg);
        if (p == null) return error.OutOfMemory;
        return .{ .ptr = p };
    }

    pub fn run(self: *Loop) !void {
        const rc = c.jzx_loop_run(self.ptr);
        if (rc != c.JZX_OK) return error.LoopError;
    }

    pub fn deinit(self: *Loop) void {
        c.jzx_loop_destroy(self.ptr);
    }
};
```

You will need a way to bridge a Zig allocator to the `jzx_allocator` callbacks.

### 5.3 Typed actor wrapper

You can define a generic helper:

```zig
pub fn Actor(comptime State: type, comptime Msg: type) type {
    return struct {
        id: c.jzx_actor_id,

        pub fn spawn(
            loop: *Loop,
            initial_state: *State,
            behavior: fn (*State, Msg) BehaviorResult,
        ) !Actor(State, Msg) {
            // wrap behavior into a c.jzx_behavior_fn trampoline
        }

        pub fn send(self: Actor(State, Msg), loop: *Loop, msg: Msg) !void {
            // serialize Msg to bytes if needed, or require Msg to be a pointer
        }
    };
}
```

You have a couple of options for message representation in Zig:

- Restrict `Msg` to pointer-like or slice types, so no serialization. Just pass pointer and length and let the user own the memory.
- Or, for nicer ergonomics, provide a default serializer (for example via `std.mem.toBytes`) and allocate a buffer for each message.

Given your preference for control, I would start with pointer based messages:

```zig
pub fn Actor(comptime State: type, comptime MsgPtr: type) type {
    // enforce MsgPtr is a pointer or slice at compile time
}
```

Then users define message structs and send pointers to them, with clear ownership rules.

### 5.4 Panic catching

In Zig you can wrap the C `jzx_behavior_fn` trampoline in a `catch` around user behavior, and translate panic into `JZX_BEHAVIOR_FAIL`.

Sketch:

```zig
fn behaviorTrampoline(
    ctx: *c.jzx_context,
    msg: *const c.jzx_message,
) callconv(.C) c.jzx_behavior_result {
    const self_state = @ptrCast(*State, ctx.state);
    const m = decodeMsg(msg); // pointer cast or deserialization

    const result = userBehavior(self_state, m) catch {
        return c.JZX_BEHAVIOR_FAIL;
    };

    return switch (result) {
        .ok => c.JZX_BEHAVIOR_OK,
        .stop => c.JZX_BEHAVIOR_STOP,
        .fail => c.JZX_BEHAVIOR_FAIL,
    };
}
```

This gives you Erlang-like "panic becomes failure" semantics.

---

## 6. SydraDB integration sketch

This is not code, but a mapping you can later turn into a separate doc like `docs/sydradb-integration.md`.

### 6.1 High level

You can model SydraDB as a supervision tree:

- `RootSupervisor` (one per process)

  - `IngestSupervisor`

    - `IngestHeadActor` per active series head
  - `MergeSupervisor`

    - `MergeActor` per merge job
  - `IndexSupervisor`

    - `IndexActor` per index build or maintenance task
  - `MetricsActor`
  - `CompactionActor` (if you have background compaction)

### 6.2 Ingest heads

Each series head is:

- actor state:

  - handle to WAL file segment
  - in memory write buffer
  - series metadata
- behavior:

  - handles `Append` messages (with data points)
  - flushes to WAL and index queue
  - may batch writes
- supervision:

  - `permanent` children under `IngestSupervisor`
  - `one_for_one` restart strategy
  - if an ingest head fails due to transient error, supervisor restarts it
  - if it fails rapidly beyond intensity, escalate to root

Messages:

- `Append` from client side
- `Flush` from timers
- `Shutdown` from system when series is being rotated or tombstoned

### 6.3 Merge actors

Each merge task for a branch or snapshot:

- actor state:

  - list of source segments
  - target segment handle
  - progress marker
- behavior:

  - on `StartMerge` message begins merge loop
  - streams data from sources, writes to target
  - periodically sends progress to `MetricsActor`
- supervision:

  - `transient` children under `MergeSupervisor`
  - restart on abnormal failure, maybe with backoff
  - if merge keeps failing, escalate to root

This keeps long running file operations in isolated actors.

### 6.4 Index actors

Index building or repair is similar:

- actor state:

  - index target identifier
  - queued segments or keys
- behavior:

  - on `IndexWork` message, consumes some work, yields back
  - uses timers to schedule itself if there is more work
- supervision:

  - `permanent` if index is a core part
  - or `transient` if each index actor is per job

### 6.5 Benefits

- ingestion failures for one series do not poison others
- merge failures do not kill ingestion
- supervision lets you add backoff and controlled retries
- you can introspect everything via observability hooks
- no custom ad hoc thread pools and queues

You can later write an explicit supervision tree diagram and put it in the repo.

---

## 7. Testing and benchmarking plan (short)

You will want a small but focused plan to validate jazz itself.

### 7.1 Correctness tests

- Actor lifecycle:

  - spawn, send messages, stop, fail, restart via supervisor
- Mailbox:

  - push and pop under load, respecting capacity
  - `JZX_ERR_MAILBOX_FULL` behavior
- Supervision:

  - `one_for_one`, `one_for_all`, `rest_for_one` semantics validated with toy children
  - intensity and period limits
  - backoff restart
- Timers:

  - `jzx_send_after` delivers messages within tolerance
  - cancellation works
- I O:

  - basic TCP echo server test using real sockets

### 7.2 Stress tests

- spawn N actors with a ping pong pattern:

  - measure throughput and fairness
- create many timers and confirm loop performs reasonably
- turn on observability hooks and ensure they do not change behavior

### 7.3 Benchmarks

- messages per second for:

  - single actor
  - many actors, random routing
- cost of restart:

  - measure mean and p99 time to restart actor under supervision
- overhead vs naive loop:

  - small comparison between direct libxev usage and jazz for similar workload
