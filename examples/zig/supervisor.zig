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
