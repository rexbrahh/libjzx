---
title: Zig example — examples/zig/supervisor.zig
---

# Zig example — `examples/zig/supervisor.zig`

This example is a self-terminating supervisor demo written in Zig.

It shows:

- configuring a supervisor with multiple children
- exercising different child restart modes (`TRANSIENT`, `TEMPORARY`)
- handling the fact that **child actor ids change across restarts**
- building a small “driver” actor that:
  - triggers child work by sending messages
  - periodically polls supervisor child ids
  - stops the loop deterministically

## Cross-links

- Run it: [Quickstart](../getting-started/quickstart#build-and-run-the-examples)
- Public API knobs: [Supervisor APIs (`include/jzx/jzx.h`)](include-jzx-jzx-h#spawning)
- Under the hood: [Runtime core (`src/jzx_runtime.c`)](src-jzx-runtime-c)
- Stress complement: [Stress tool (`tools/stress.zig`)](tools-stress-zig)

## Imports

<!-- snippet: examples/zig/supervisor.zig#L1-L3 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L1-L3"><code>examples/zig/supervisor.zig#L1-L3</code></a></div>
```zig title="Imports" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
```

This example uses the C ABI layer (`c.*`) for supervision structs and calls, and uses the wrapper (`jzx.Loop`) for loop lifecycle.

## Child A: fail once, then stop

Child A keeps a bit of state to count how many times it has run.

<!-- snippet: examples/zig/supervisor.zig#L5-L7 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L5-L7"><code>examples/zig/supervisor.zig#L5-L7</code></a></div>
```zig title="ChildState" showLineNumbers=5
const ChildState = struct {
    runs: u32 = 0,
};
```

The behavior:

<!-- snippet: examples/zig/supervisor.zig#func=failOnceThenStop -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L9-L20"><code>examples/zig/supervisor.zig#L9-L20</code></a></div>
```zig title="failOnceThenStop(): FAIL on first run, STOP on second" showLineNumbers=9
fn failOnceThenStop(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*ChildState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    if (state.runs == 1) {
        std.debug.print("[child-a] fail (runs={d})\n", .{state.runs});
        return c.JZX_BEHAVIOR_FAIL;
    }
    std.debug.print("[child-a] stop (runs={d})\n", .{state.runs});
    return c.JZX_BEHAVIOR_STOP;
}
```

Deep explanation:

- The message payload is ignored (the message is just a “kick”).
- `ctx_ptr.state.?` asserts the state pointer is non-null and then casts it to `*ChildState`.
- The first time the child runs, it returns `FAIL`.
  - With `TRANSIENT` mode (see below), this triggers a restart.
- The second time it runs (after restart), it returns `STOP`.
  - With `TRANSIENT` mode, a normal stop should *not* trigger a restart.

## Child B: stop immediately

Child B has no state; it stops on the first message it receives.

<!-- snippet: examples/zig/supervisor.zig#func=stopImmediately -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L22-L27"><code>examples/zig/supervisor.zig#L22-L27</code></a></div>
```zig title="stopImmediately(): STOP on first message" showLineNumbers=22
fn stopImmediately(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    std.debug.print("[child-b] stop id={d}\n", .{ctx_ptr.self});
    return c.JZX_BEHAVIOR_STOP;
}
```

## Scheduling helper

The driver actor uses a tiny helper to schedule a message to itself.

<!-- snippet: examples/zig/supervisor.zig#func=scheduleSelf -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L29-L31"><code>examples/zig/supervisor.zig#L29-L31</code></a></div>
```zig title="scheduleSelf(): send_after wrapper" showLineNumbers=29
fn scheduleSelf(loop: *c.jzx_loop, id: c.jzx_actor_id, ms: u32) void {
    _ = c.jzx_send_after(loop, id, ms, null, 0, 0, null);
}
```

Notes:

- This example ignores the return code for brevity.
- It uses `send_after` with a null payload; the timer message is just a “tick”.

## Driver actor: orchestrate and terminate

The driver’s purpose is to make the supervisor demo deterministic:

- It keeps checking the supervisor’s current child ids.
- When a new child id appears, it sends that child a message so it will run.
- When both children have stopped (ids are 0), it stops the loop.

### Driver state

<!-- snippet: examples/zig/supervisor.zig#L33-L38 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L33-L38"><code>examples/zig/supervisor.zig#L33-L38</code></a></div>
```zig title="DriverState" showLineNumbers=33
const DriverState = struct {
    sup_id: c.jzx_actor_id,
    last_ids: [2]c.jzx_actor_id = .{ 0, 0 },
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

What each field means:

- `sup_id`: supervisor actor id to query.
- `last_ids`: last observed child ids (used to detect restarts).
- `ticks`: number of driver “ticks” (self-messages processed).
- `timed_out`: a “safety fuse” so the demo can’t hang forever.

### Driver behavior

<!-- snippet: examples/zig/supervisor.zig#func=driver -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L40-L73"><code>examples/zig/supervisor.zig#L40-L73</code></a></div>
```zig title="driver(): poll child ids, kick children, stop loop when done" showLineNumbers=40
fn driver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*DriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var a: c.jzx_actor_id = 0;
    var b: c.jzx_actor_id = 0;
    _ = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &a);
    _ = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 1, &b);

    if (a != 0 and a != state.last_ids[0]) {
        _ = c.jzx_send(ctx_ptr.loop.?, a, null, 0, 0);
        state.last_ids[0] = a;
    }
    if (b != 0 and b != state.last_ids[1]) {
        _ = c.jzx_send(ctx_ptr.loop.?, b, null, 0, 0);
        state.last_ids[1] = b;
    }

    if (a == 0 and b == 0) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

How it works:

- Every message to the driver is a “tick”.
  - It doesn’t care about payload; it uses periodic self-scheduling.
- It queries child ids on every tick.
  - Important: child ids can change when children restart.
- When it sees a new id (`a != last_ids[0]`), it sends that child a message.
  - This is critical: a freshly spawned child has an empty mailbox and won’t run until it receives something.
- Exit conditions:
  - If both ids are `0`, there are no live children → request loop stop.
  - If tick count exceeds 5000, request loop stop and mark `timed_out`.
    - This prevents an infinite hang if something goes wrong.

## main(): spawn supervisor + driver, run, report

<!-- snippet: examples/zig/supervisor.zig#func=main -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L75-L142"><code>examples/zig/supervisor.zig#L75-L142</code></a></div>
```zig title="main(): wire it all together" showLineNumbers=75
pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var child_a_state = ChildState{};

    var children = [_]c.jzx_child_spec{
        .{
            .behavior = failOnceThenStop,
            .state = &child_a_state,
            .mode = c.JZX_CHILD_TRANSIENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = "child-a",
        },
        .{
            .behavior = stopImmediately,
            .state = null,
            .mode = c.JZX_CHILD_TEMPORARY,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = "child-b",
        },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &children,
        .child_count = children.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 10,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id) != c.JZX_OK) {
        std.debug.print("failed to spawn supervisor\n", .{});
        return;
    }

    var driver_state = DriverState{ .sup_id = sup_id };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = driver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "driver",
    };
    var driver_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &driver_opts, &driver_id) != c.JZX_OK) {
        std.debug.print("failed to spawn driver\n", .{});
        return;
    }
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    if (driver_state.timed_out) {
        std.debug.print("driver timed out\n", .{});
        return;
    }
    std.debug.print("done: child-a total_runs={d}\n", .{child_a_state.runs});
}
```

Key semantics encoded by the child modes:

- `child-a` is `TRANSIENT`:
  - restart on failure
  - do **not** restart on normal stop
- `child-b` is `TEMPORARY`:
  - never restart (even if it fails)

The expected outcome:

- `child-a` runs twice:
  - once to fail (triggering a restart)
  - once to stop normally
- `child-b` runs once and stops
- the driver observes both children gone and stops the loop

## Full listing (for reference)

<!-- snippet: examples/zig/supervisor.zig#all -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/supervisor.zig#L1-L142"><code>examples/zig/supervisor.zig#L1-L142</code></a></div>
```zig title="examples/zig/supervisor.zig" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

const ChildState = struct {
    runs: u32 = 0,
};

fn failOnceThenStop(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*ChildState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    if (state.runs == 1) {
        std.debug.print("[child-a] fail (runs={d})\n", .{state.runs});
        return c.JZX_BEHAVIOR_FAIL;
    }
    std.debug.print("[child-a] stop (runs={d})\n", .{state.runs});
    return c.JZX_BEHAVIOR_STOP;
}

fn stopImmediately(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    std.debug.print("[child-b] stop id={d}\n", .{ctx_ptr.self});
    return c.JZX_BEHAVIOR_STOP;
}

fn scheduleSelf(loop: *c.jzx_loop, id: c.jzx_actor_id, ms: u32) void {
    _ = c.jzx_send_after(loop, id, ms, null, 0, 0, null);
}

const DriverState = struct {
    sup_id: c.jzx_actor_id,
    last_ids: [2]c.jzx_actor_id = .{ 0, 0 },
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn driver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*DriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var a: c.jzx_actor_id = 0;
    var b: c.jzx_actor_id = 0;
    _ = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &a);
    _ = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 1, &b);

    if (a != 0 and a != state.last_ids[0]) {
        _ = c.jzx_send(ctx_ptr.loop.?, a, null, 0, 0);
        state.last_ids[0] = a;
    }
    if (b != 0 and b != state.last_ids[1]) {
        _ = c.jzx_send(ctx_ptr.loop.?, b, null, 0, 0);
        state.last_ids[1] = b;
    }

    if (a == 0 and b == 0) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}

pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var child_a_state = ChildState{};

    var children = [_]c.jzx_child_spec{
        .{
            .behavior = failOnceThenStop,
            .state = &child_a_state,
            .mode = c.JZX_CHILD_TRANSIENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = "child-a",
        },
        .{
            .behavior = stopImmediately,
            .state = null,
            .mode = c.JZX_CHILD_TEMPORARY,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = "child-b",
        },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &children,
        .child_count = children.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 10,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id) != c.JZX_OK) {
        std.debug.print("failed to spawn supervisor\n", .{});
        return;
    }

    var driver_state = DriverState{ .sup_id = sup_id };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = driver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "driver",
    };
    var driver_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &driver_opts, &driver_id) != c.JZX_OK) {
        std.debug.print("failed to spawn driver\n", .{});
        return;
    }
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    if (driver_state.timed_out) {
        std.debug.print("driver timed out\n", .{});
        return;
    }
    std.debug.print("done: child-a total_runs={d}\n", .{child_a_state.runs});
}
```
