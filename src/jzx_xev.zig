const std = @import("std");
const xev = @import("xev");

const c = @cImport({
    @cInclude("jzx/jzx.h");
});

extern fn jzx_io_xev_notify(loop: *c.jzx_loop, fd: c_int, readiness: u32) u8;

const Watch = struct {
    loop: *c.jzx_loop,
    fd: c_int,
    interest: u32,
    removed: bool = false,

    read: xev.Completion = .{},
    read_cancel: xev.Completion = .{},
    write: xev.Completion = .{},
    write_cancel: xev.Completion = .{},
};

pub const XevState = struct {
    loop: xev.Loop,
    wake: xev.Async,
    wake_completion: xev.Completion = .{},
    wake_cancel: xev.Completion = .{},

    watches: std.ArrayListUnmanaged(*Watch) = .{},

    pub fn deinit(self: *XevState) void {
        const allocator = std.heap.c_allocator;
        for (self.watches.items) |watch| {
            allocator.destroy(watch);
        }
        self.watches.deinit(allocator);
        self.wake.deinit();
        self.loop.deinit();
        self.* = undefined;
    }
};

fn supportsPollOps() bool {
    return switch (xev.backend) {
        .io_uring, .epoll, .kqueue => true,
        else => false,
    };
}

fn findWatchIndex(state: *XevState, fd: c_int) ?usize {
    for (state.watches.items, 0..) |watch, idx| {
        if (watch.fd == fd) return idx;
    }
    return null;
}

fn ensureWatch(state: *XevState, loop: *c.jzx_loop, fd: c_int) !*Watch {
    if (findWatchIndex(state, fd)) |idx| {
        const watch = state.watches.items[idx];
        watch.loop = loop;
        return watch;
    }

    const allocator = std.heap.c_allocator;
    const watch = try allocator.create(Watch);
    watch.* = .{
        .loop = loop,
        .fd = fd,
        .interest = 0,
    };
    try state.watches.append(allocator, watch);
    return watch;
}

fn cancelIfNeeded(state: *XevState, target: *xev.Completion, cancel: *xev.Completion) void {
    if (target.state() == .dead) return;
    if (cancel.state() != .dead) return;

    cancel.* = .{
        .op = .{ .cancel = .{ .c = target } },
        .userdata = null,
        .callback = cancelCallback,
    };
    state.loop.add(cancel);
}

fn cancelCallback(_: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, _: xev.Result) xev.CallbackAction {
    return .disarm;
}

fn readCallback(ud: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, _: xev.Result) xev.CallbackAction {
    const watch = @as(*Watch, @ptrCast(@alignCast(ud.?)));
    if (watch.removed or (watch.interest & c.JZX_IO_READ) == 0) {
        return .disarm;
    }
    const ok = jzx_io_xev_notify(watch.loop, watch.fd, c.JZX_IO_READ) != 0;
    return if (ok) .rearm else .disarm;
}

fn writeCallback(ud: ?*anyopaque, _: *xev.Loop, _: *xev.Completion, _: xev.Result) xev.CallbackAction {
    const watch = @as(*Watch, @ptrCast(@alignCast(ud.?)));
    if (watch.removed or (watch.interest & c.JZX_IO_WRITE) == 0) {
        return .disarm;
    }
    const ok = jzx_io_xev_notify(watch.loop, watch.fd, c.JZX_IO_WRITE) != 0;
    return if (ok) .rearm else .disarm;
}

fn armRead(state: *XevState, watch: *Watch) void {
    if (!supportsPollOps()) return;
    if (watch.read.state() != .dead) return;

    watch.read = .{
        .op = switch (xev.backend) {
            .io_uring => .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.IN } },
            .epoll => .{ .poll = .{ .fd = watch.fd, .events = std.os.linux.EPOLL.IN } },
            .kqueue => .{ .read = .{ .fd = watch.fd, .buffer = .{ .slice = &.{} } } },
            else => unreachable,
        },
        .userdata = watch,
        .callback = readCallback,
    };
    state.loop.add(&watch.read);
}

fn armWrite(state: *XevState, watch: *Watch) void {
    if (!supportsPollOps()) return;
    if (watch.write.state() != .dead) return;

    watch.write = .{
        .op = switch (xev.backend) {
            .io_uring => .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.OUT } },
            .epoll => .{ .poll = .{ .fd = watch.fd, .events = std.os.linux.EPOLL.OUT } },
            .kqueue => .{ .write = .{ .fd = watch.fd, .buffer = .{ .slice = &.{} } } },
            else => unreachable,
        },
        .userdata = watch,
        .callback = writeCallback,
    };
    state.loop.add(&watch.write);
}

fn syncWatch(state: *XevState, watch: *Watch) void {
    if (watch.removed) {
        watch.interest = 0;
    }

    if ((watch.interest & c.JZX_IO_READ) != 0) {
        armRead(state, watch);
    } else {
        cancelIfNeeded(state, &watch.read, &watch.read_cancel);
    }

    if ((watch.interest & c.JZX_IO_WRITE) != 0) {
        armWrite(state, watch);
    } else {
        cancelIfNeeded(state, &watch.write, &watch.write_cancel);
    }
}

fn watchReadyToFree(watch: *Watch) bool {
    return watch.read.state() == .dead and watch.write.state() == .dead and
        watch.read_cancel.state() == .dead and watch.write_cancel.state() == .dead;
}

fn sweep(state: *XevState) void {
    var i: usize = 0;
    while (i < state.watches.items.len) {
        const watch = state.watches.items[i];
        syncWatch(state, watch);

        if (watch.removed and watchReadyToFree(watch)) {
            const allocator = std.heap.c_allocator;
            allocator.destroy(watch);
            const last = state.watches.items.len - 1;
            state.watches.items[i] = state.watches.items[last];
            state.watches.items.len -= 1;
            continue;
        }

        i += 1;
    }
}

fn wakeCallback(_: ?*void, _: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
    _ = result catch return .disarm;
    return .rearm;
}

pub export fn jzx_xev_create() ?*XevState {
    if (!supportsPollOps()) {
        return null;
    }

    const allocator = std.heap.c_allocator;
    const state = allocator.create(XevState) catch return null;
    errdefer allocator.destroy(state);

    const loop = xev.Loop.init(.{}) catch return null;
    errdefer loop.deinit();

    const wake = xev.Async.init() catch return null;
    errdefer wake.deinit();

    state.* = .{
        .loop = loop,
        .wake = wake,
    };

    state.wake.wait(&state.loop, &state.wake_completion, void, null, wakeCallback);
    return state;
}

pub export fn jzx_xev_destroy(state: *XevState) void {
    if (@intFromPtr(state) == 0) return;

    for (state.watches.items) |watch| {
        watch.removed = true;
        syncWatch(state, watch);
    }
    cancelIfNeeded(state, &state.wake_completion, &state.wake_cancel);

    var ticks: usize = 0;
    while (ticks < 64) : (ticks += 1) {
        _ = state.loop.run(.no_wait) catch {};
        sweep(state);
        if (state.watches.items.len == 0 and state.wake_completion.state() == .dead and
            state.wake_cancel.state() == .dead)
        {
            break;
        }
    }

    state.deinit();
    std.heap.c_allocator.destroy(state);
}

pub export fn jzx_xev_wakeup(state: *XevState) void {
    if (@intFromPtr(state) == 0) return;
    state.wake.notify() catch {};
}

pub export fn jzx_xev_run(state: *XevState, mode: c_int) void {
    if (@intFromPtr(state) == 0) return;
    const run_mode: xev.RunMode = switch (mode) {
        0 => .no_wait,
        1 => .once,
        else => .no_wait,
    };
    _ = state.loop.run(run_mode) catch {};
    sweep(state);
}

pub export fn jzx_xev_watch_fd(state: *XevState, loop: *c.jzx_loop, fd: c_int, interest: u32) c_int {
    if (@intFromPtr(state) == 0 or @intFromPtr(loop) == 0 or fd < 0 or interest == 0) {
        return c.JZX_ERR_INVALID_ARG;
    }
    const watch = ensureWatch(state, loop, fd) catch return c.JZX_ERR_NO_MEMORY;
    watch.removed = false;
    watch.interest = interest;
    syncWatch(state, watch);
    return c.JZX_OK;
}

pub export fn jzx_xev_unwatch_fd(state: *XevState, fd: c_int) void {
    if (@intFromPtr(state) == 0 or fd < 0) return;
    const idx = findWatchIndex(state, fd) orelse return;
    const watch = state.watches.items[idx];
    watch.removed = true;
    syncWatch(state, watch);
}
