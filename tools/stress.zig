const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    var smoke = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        }
    }

    try runPingPong(smoke);
    try runTimerStorm(smoke);
    try runRestartThrash(smoke);
}

const StressError = error{
    StressFailed,
};

const PingPongState = struct {
    loop: *c.jzx_loop,
    partner: c.jzx_actor_id = 0,
    remaining: u32,
    hits: u32 = 0,
};

fn pingPongBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*PingPongState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.hits += 1;
    if (state.remaining == 0) {
        return c.JZX_BEHAVIOR_STOP;
    }
    state.remaining -= 1;
    if (state.partner != 0) {
        _ = c.jzx_send(state.loop, state.partner, null, 0, 0);
    }
    return c.JZX_BEHAVIOR_OK;
}

fn runPingPong(smoke: bool) !void {
    const iterations: u32 = if (smoke) 50_000 else 500_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state_a = PingPongState{ .loop = loop.ptr, .remaining = iterations };
    var state_b = PingPongState{ .loop = loop.ptr, .remaining = iterations };

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    var opts_a = c.jzx_spawn_opts{
        .behavior = pingPongBehavior,
        .state = &state_a,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "stress-pingpong-a",
    };
    var opts_b = c.jzx_spawn_opts{
        .behavior = pingPongBehavior,
        .state = &state_b,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "stress-pingpong-b",
    };
    if (c.jzx_spawn(loop.ptr, &opts_a, &id_a) != c.JZX_OK) {
        return StressError.StressFailed;
    }
    if (c.jzx_spawn(loop.ptr, &opts_b, &id_b) != c.JZX_OK) {
        return StressError.StressFailed;
    }
    state_a.partner = id_b;
    state_b.partner = id_a;

    _ = c.jzx_send(loop.ptr, id_a, null, 0, 0);
    _ = c.jzx_send(loop.ptr, id_b, null, 0, 0);

    const start_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try loop.run();
    const end_ms = @as(u64, @intCast(std.time.milliTimestamp()));

    if (state_a.hits == 0 or state_b.hits == 0) {
        return StressError.StressFailed;
    }
    if (state_a.hits < iterations / 2 or state_b.hits < iterations / 2) {
        return StressError.StressFailed;
    }

    std.debug.print("stress pingpong: a_hits={d} b_hits={d} elapsed_ms={d}\n", .{
        state_a.hits,
        state_b.hits,
        end_ms - start_ms,
    });
}

const TimerState = struct {
    target: u32,
    hits: u32 = 0,
};

fn timerBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TimerState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.hits += 1;
    if (state.hits >= state.target) {
        return c.JZX_BEHAVIOR_STOP;
    }
    return c.JZX_BEHAVIOR_OK;
}

fn runTimerStorm(smoke: bool) !void {
    const timer_count: u32 = if (smoke) 2000 else 20_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state = TimerState{ .target = timer_count };
    var opts = c.jzx_spawn_opts{
        .behavior = timerBehavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "stress-timers",
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        return StressError.StressFailed;
    }

    for (0..timer_count) |_| {
        if (c.jzx_send_after(loop.ptr, actor_id, 1, null, 0, 0, null) != c.JZX_OK) {
            return StressError.StressFailed;
        }
    }

    const start_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try loop.run();
    const end_ms = @as(u64, @intCast(std.time.milliTimestamp()));

    if (state.hits != timer_count) {
        return StressError.StressFailed;
    }
    std.debug.print("stress timers: fired={d} elapsed_ms={d}\n", .{ state.hits, end_ms - start_ms });
}

const RestartState = struct {
    runs: u32 = 0,
};

fn alwaysFail(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return c.JZX_BEHAVIOR_FAIL;
}

fn runRestartThrash(smoke: bool) !void {
    const iterations: u32 = if (smoke) 100 else 1000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var child_state = RestartState{};
    var child_spec = [_]c.jzx_child_spec{.{
        .behavior = alwaysFail,
        .state = &child_state,
        .mode = c.JZX_CHILD_TRANSIENT,
        .mailbox_cap = 0,
        .restart_delay_ms = 0,
        .backoff = c.JZX_BACKOFF_NONE,
        .name = "stress-restart-child",
    }};
    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = iterations + 10,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id) != c.JZX_OK) {
        return StressError.StressFailed;
    }

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    for (0..iterations) |_| {
        var child_id: c.jzx_actor_id = 0;
        _ = c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id);
        if (child_id != 0) {
            _ = c.jzx_send_async(loop.ptr, child_id, null, 0, 0);
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    loop.requestStop();
    runner.join();

    if (child_state.runs == 0) {
        return StressError.StressFailed;
    }
    std.debug.print("stress restarts: runs={d}\n", .{child_state.runs});
}
