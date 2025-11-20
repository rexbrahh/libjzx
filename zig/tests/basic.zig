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
