const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
const posix = std.posix;

const AsyncArgs = struct {
    loop: *c.jzx_loop,
    actor: c.jzx_actor_id,
    payload: *u32,
};

fn increment_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));
    const state_ptr = @as(*u32, @ptrFromInt(@intFromPtr(ctx_ptr.state.?)));
    if (msg_ptr.data) |data_ptr| {
        const value_ptr = @as(*const u32, @ptrFromInt(@intFromPtr(data_ptr)));
        state_ptr.* += value_ptr.*;
    }
    return c.JZX_BEHAVIOR_STOP;
}

const TimerState = struct {
    target: u32,
    hits: u32 = 0,
};

fn timer_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TimerState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    _ = msg;
    state.hits += 1;
    if (state.hits >= state.target) {
        return c.JZX_BEHAVIOR_STOP;
    }
    return c.JZX_BEHAVIOR_OK;
}

test "actor receives and processes a message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 5;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));

    try loop.run();
    try std.testing.expectEqual(@as(u32, 5), state);
    try std.testing.expectEqual(c.JZX_ERR_NO_SUCH_ACTOR, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));
}

test "mailbox full returns error" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));
    try std.testing.expectEqual(c.JZX_ERR_MAILBOX_FULL, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    try loop.run();
}

fn async_sender(args: AsyncArgs) void {
    _ = c.jzx_send_async(args.loop, args.actor, args.payload, @sizeOf(u32), 2);
}

test "async send dispatches message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 7;
    var thread = try std.Thread.spawn(.{}, async_sender, .{AsyncArgs{
        .loop = loop.ptr,
        .actor = actor_id,
        .payload = &payload,
    }});
    thread.join();

    try loop.run();
    try std.testing.expectEqual(@as(u32, 7), state);
}

test "timer delivers message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 3;
    var timer_id: c.jzx_timer_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 5, &payload, @sizeOf(u32), 9, &timer_id));

    try loop.run();
    try std.testing.expectEqual(@as(u32, 3), state);
    try std.testing.expectEqual(c.JZX_ERR_TIMER_INVALID, c.jzx_cancel_timer(loop.ptr, timer_id));
}

test "cancelled timer does not fire" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 11;
    var timer_id: c.jzx_timer_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 5, &payload, @sizeOf(u32), 4, &timer_id));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_cancel_timer(loop.ptr, timer_id));

    _ = c.jzx_actor_stop(loop.ptr, actor_id);
    try loop.run();
    try std.testing.expectEqual(@as(u32, 0), state);
}

test "many timers fire" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    const timer_count: u32 = 32;
    var timer_state = TimerState{ .target = timer_count };
    var opts = c.jzx_spawn_opts{
        .behavior = timer_behavior,
        .state = &timer_state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var timer_ids = [_]c.jzx_timer_id{0} ** timer_count;
    var payloads = [_]u32{0} ** timer_count;
    for (&timer_ids, 0..) |tid_ptr, idx| {
        payloads[idx] = 1;
        try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 1, &payloads[idx], @sizeOf(u32), 0, tid_ptr));
    }

    try loop.run();
    try std.testing.expectEqual(timer_count, timer_state.hits);
}

const PingPongState = struct {
    loop: *c.jzx_loop,
    partner: *?c.jzx_actor_id,
    remaining: u32,
    hits: u32,
};

fn pingPongBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*PingPongState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    _ = msg;
    state.hits += 1;
    if (state.remaining == 0) {
        return c.JZX_BEHAVIOR_STOP;
    }
    state.remaining -= 1;
    if (state.partner.*) |partner_id| {
        var payload: u32 = 1;
        _ = c.jzx_send(state.loop, partner_id, &payload, @sizeOf(u32), 0);
    }
    return c.JZX_BEHAVIOR_OK;
}

test "ping pong actors share work fairly" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    var partner_a: ?c.jzx_actor_id = 0;
    var partner_b: ?c.jzx_actor_id = 0;
    var state_a = PingPongState{ .loop = loop.ptr, .partner = &partner_a, .remaining = 10, .hits = 0 };
    var state_b = PingPongState{ .loop = loop.ptr, .partner = &partner_b, .remaining = 10, .hits = 0 };

    var opts_a = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_a, .supervisor = 0, .mailbox_cap = 0 };
    var opts_b = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_b, .supervisor = 0, .mailbox_cap = 0 };
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_a, &id_a));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_b, &id_b));
    partner_a = id_b;
    partner_b = id_a;

    var init: u32 = 1;
    _ = c.jzx_send(loop.ptr, id_a, &init, @sizeOf(u32), 0);
    _ = c.jzx_send(loop.ptr, id_b, &init, @sizeOf(u32), 0);

    try loop.run();
    try std.testing.expectEqual(@as(u32, 11), state_a.hits);
    try std.testing.expectEqual(@as(u32, 11), state_b.hits);
}

const CounterState = struct {
    total: u32 = 0,
};

const CounterMsg = struct {
    value: u32,
};

fn counterBehavior(state: *CounterState, msg: *CounterMsg, ctx: jzx.ActorContext) jzx.BehaviorResult {
    _ = ctx;
    state.total += msg.value;
    return .stop;
}

test "typed actor increments state" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var counter = CounterState{};
    var actor = try jzx.Actor(CounterState, *CounterMsg).spawn(
        loop.ptr,
        std.heap.c_allocator,
        &counter,
        &counterBehavior,
        .{},
    );
    defer actor.destroy();

    var msg = CounterMsg{ .value = 8 };
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor.getId(), &msg, @sizeOf(CounterMsg), 0));
    try loop.run();
    try std.testing.expectEqual(@as(u32, 8), counter.total);
}

fn io_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));
    if (msg_ptr.tag == c.JZX_TAG_SYS_IO and msg_ptr.data != null) {
        const data_ptr = msg_ptr.data.?;
        const state_ptr = @as(*u32, @ptrFromInt(@intFromPtr(ctx_ptr.state.?)));
        const event = @as(*c.jzx_io_event, @ptrFromInt(@intFromPtr(data_ptr)));
        if ((event.readiness & c.JZX_IO_READ) != 0) {
            state_ptr.* += 1;
        }
        std.c.free(@ptrCast(data_ptr));
        return c.JZX_BEHAVIOR_STOP;
    }
    return c.JZX_BEHAVIOR_OK;
}

fn pipe_writer(fd: posix.fd_t) void {
    const msg = "ping";
    _ = posix.write(fd, msg) catch {};
}

test "io watcher delivers readiness" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = io_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    const pipefds = try posix.pipe();
    defer {
        posix.close(pipefds[0]);
        posix.close(pipefds[1]);
    }

    try std.testing.expectEqual(c.JZX_OK, c.jzx_watch_fd(loop.ptr, pipefds[0], actor_id, c.JZX_IO_READ));

    var writer = try std.Thread.spawn(.{}, pipe_writer, .{pipefds[1]});
    writer.join();

    try loop.run();
    try std.testing.expectEqual(@as(u32, 1), state);
}

test "io rapid watch and unwatch" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    const pipefds = try posix.pipe();
    defer {
        posix.close(pipefds[0]);
        posix.close(pipefds[1]);
    }

    for (0..8) |_| {
        try std.testing.expectEqual(c.JZX_OK, c.jzx_watch_fd(loop.ptr, pipefds[0], actor_id, c.JZX_IO_READ));
        try std.testing.expectEqual(c.JZX_OK, c.jzx_unwatch_fd(loop.ptr, pipefds[0]));
    }

    try std.testing.expectEqual(c.JZX_OK, c.jzx_watch_fd(loop.ptr, pipefds[0], actor_id, c.JZX_IO_READ));
    var writer = try std.Thread.spawn(.{}, pipe_writer, .{pipefds[1]});
    writer.join();

    try loop.run();
    try std.testing.expect(state >= 1);
}

const RestartState = struct {
    runs: u32 = 0,
};

fn failThenStop(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return if (state.runs == 1) c.JZX_BEHAVIOR_FAIL else c.JZX_BEHAVIOR_STOP;
}

test "supervisor restarts transient child once" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var child_state = RestartState{};
    var child_spec = [_]c.jzx_child_spec{.{
        .behavior = failThenStop,
        .state = &child_state,
        .mode = c.JZX_CHILD_TRANSIENT,
        .mailbox_cap = 0,
        .restart_delay_ms = 0,
        .backoff = c.JZX_BACKOFF_NONE,
    }};
    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));

    var child_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, child_id, null, 0, 0));
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // After restart, child id may change; fetch and send again.
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, child_id, null, 0, 0));

    std.Thread.sleep(20 * std.time.ns_per_ms);
    loop.requestStop();

    runner.join();

    try std.testing.expectEqual(@as(u32, 2), child_state.runs);
}

fn alwaysFail(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return c.JZX_BEHAVIOR_FAIL;
}

test "supervisor escalates when intensity exceeded" {
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
    }};
    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 2,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));

    var child_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    // Drive three failures to exceed intensity window.
    for (0..3) |_| {
        try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
        try std.testing.expect(child_id != 0);
        _ = c.jzx_send(loop.ptr, child_id, null, 0, 0);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    loop.requestStop();
    runner.join();

    try std.testing.expectEqual(@as(u32, 3), child_state.runs);
}

const BackoffState = struct {
    runs: u32 = 0,
    t1_ms: u64 = 0,
    t2_ms: u64 = 0,
};

fn backoffRecorder(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*BackoffState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    if (state.runs == 1) {
        state.t1_ms = now_ms;
        return c.JZX_BEHAVIOR_FAIL;
    }
    state.t2_ms = now_ms;
    c.jzx_loop_request_stop(ctx_ptr.loop.?);
    return c.JZX_BEHAVIOR_STOP;
}

test "supervisor backoff delays restart" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state = BackoffState{};
    var child_spec = [_]c.jzx_child_spec{.{
        .behavior = backoffRecorder,
        .state = &state,
        .mode = c.JZX_CHILD_TRANSIENT,
        .mailbox_cap = 0,
        .restart_delay_ms = 0,
        .backoff = c.JZX_BACKOFF_NONE, // use supervisor default
    }};
    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_CONSTANT,
            .backoff_delay_ms = 50,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));
    var child_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, child_id, null, 0, 0));

    // Wait for restart delay (50ms) then fetch new child id and send again.
    std.Thread.sleep(60 * std.time.ns_per_ms);
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, child_id, null, 0, 0));

    runner.join();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 50);
}

fn backoffRecorderExp(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*BackoffState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    const now_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    if (state.runs == 1) {
        state.t1_ms = now_ms;
        return c.JZX_BEHAVIOR_FAIL;
    }
    state.t2_ms = now_ms;
    c.jzx_loop_request_stop(ctx_ptr.loop.?);
    return c.JZX_BEHAVIOR_STOP;
}

test "supervisor exponential backoff delays restart" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state = BackoffState{};
    var child_spec = [_]c.jzx_child_spec{.{
        .behavior = backoffRecorderExp,
        .state = &state,
        .mode = c.JZX_CHILD_TRANSIENT,
        .mailbox_cap = 0,
        .restart_delay_ms = 20, // base delay
        .backoff = c.JZX_BACKOFF_EXPONENTIAL,
    }};
    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_EXPONENTIAL,
            .backoff_delay_ms = 20,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));
    var child_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id));
    try std.testing.expect(child_id != 0);

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    // First run -> failure.
    _ = c.jzx_send(loop.ptr, child_id, null, 0, 0);

    // Allow restart (delay ~20ms * 2 due to exponential factor).
    std.Thread.sleep(120 * std.time.ns_per_ms);
    _ = c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id);
    try std.testing.expect(child_id != 0);

    // Second run should stop after recording t2.
    _ = c.jzx_send(loop.ptr, child_id, null, 0, 0);

    var wait_attempts: u16 = 0;
    while (wait_attempts < 50 and state.runs < 2) : (wait_attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    if (state.runs < 2) {
        loop.requestStop();
    }

    runner.join();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 30);
}

const DuoShared = struct {
    runs_a: u32 = 0,
    runs_b: u32 = 0,
};

const DuoState = struct {
    shared: *DuoShared,
    is_a: bool,
};

fn duoBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*DuoState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    if (state.is_a) {
        state.shared.runs_a += 1;
        if (state.shared.runs_a >= 2 and state.shared.runs_b >= 2) {
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
        }
        return c.JZX_BEHAVIOR_OK;
    } else {
        state.shared.runs_b += 1;
        if (state.shared.runs_b == 1) {
            return c.JZX_BEHAVIOR_FAIL;
        }
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }
}

test "supervisor one_for_all restarts all children" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var shared = DuoShared{};
    var state_a = DuoState{ .shared = &shared, .is_a = true };
    var state_b = DuoState{ .shared = &shared, .is_a = false };

    var child_spec = [_]c.jzx_child_spec{
        .{
            .behavior = duoBehavior,
            .state = &state_a,
            .mode = c.JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
        },
        .{
            .behavior = duoBehavior,
            .state = &state_b,
            .mode = c.JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
        },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ALL,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &id_a));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, 1, &id_b));
    try std.testing.expect(id_a != 0);
    try std.testing.expect(id_b != 0);

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    // First round: start both, B fails.
    _ = c.jzx_send(loop.ptr, id_a, null, 0, 0);
    _ = c.jzx_send(loop.ptr, id_b, null, 0, 0);

    // Wait for restart to occur and fetch new ids.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    _ = c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &id_a);
    _ = c.jzx_supervisor_child_id(loop.ptr, sup_id, 1, &id_b);
    try std.testing.expect(id_a != 0);
    try std.testing.expect(id_b != 0);

    // Second round after restart.
    _ = c.jzx_send(loop.ptr, id_a, null, 0, 0);
    _ = c.jzx_send(loop.ptr, id_b, null, 0, 0);

    runner.join();

    try std.testing.expect(shared.runs_a >= 2);
    try std.testing.expect(shared.runs_b >= 2);
}
