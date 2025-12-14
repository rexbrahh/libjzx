const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
const posix = std.posix;

const ListenerState = struct {
    fd: posix.socket_t,
};

const ConnState = struct {
    fd: posix.socket_t,
    pending_len: usize = 0,
    pending_off: usize = 0,
    buf: [4096]u8 = undefined,
};

fn setNonBlocking(fd: posix.fd_t) !void {
    const raw = try posix.fcntl(fd, posix.F.GETFL, 0);
    var flags: posix.O = @bitCast(@as(u32, @intCast(raw)));
    flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
}

fn setCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

fn connBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));

    if (msg_ptr.tag != c.JZX_TAG_SYS_IO or msg_ptr.data == null) {
        return c.JZX_BEHAVIOR_OK;
    }

    const state = @as(*ConnState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    const ev = @as(*c.jzx_io_event, @ptrCast(@alignCast(msg_ptr.data.?)));
    defer c.jzx_loop_free(ctx_ptr.loop.?, msg_ptr.data.?);

    if ((ev.readiness & c.JZX_IO_WRITE) != 0 and state.pending_off < state.pending_len) {
        const slice = state.buf[state.pending_off..state.pending_len];
        const wrote = posix.write(state.fd, slice) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => {
                posix.close(state.fd);
                std.heap.c_allocator.destroy(state);
                return c.JZX_BEHAVIOR_STOP;
            },
        };
        state.pending_off += wrote;
        if (state.pending_off >= state.pending_len) {
            state.pending_len = 0;
            state.pending_off = 0;
            _ = c.jzx_watch_fd(ctx_ptr.loop.?, state.fd, ctx_ptr.self, c.JZX_IO_READ);
        }
    }

    if ((ev.readiness & c.JZX_IO_READ) != 0 and state.pending_len == 0) {
        const n = posix.read(state.fd, state.buf[0..]) catch |err| switch (err) {
            error.WouldBlock => return c.JZX_BEHAVIOR_OK,
            else => {
                posix.close(state.fd);
                std.heap.c_allocator.destroy(state);
                return c.JZX_BEHAVIOR_STOP;
            },
        };
        if (n == 0) {
            posix.close(state.fd);
            std.heap.c_allocator.destroy(state);
            return c.JZX_BEHAVIOR_STOP;
        }

        state.pending_len = n;
        state.pending_off = 0;

        const wrote = posix.write(state.fd, state.buf[0..n]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => {
                posix.close(state.fd);
                std.heap.c_allocator.destroy(state);
                return c.JZX_BEHAVIOR_STOP;
            },
        };
        state.pending_off = wrote;
        if (state.pending_off < state.pending_len) {
            _ = c.jzx_watch_fd(ctx_ptr.loop.?, state.fd, ctx_ptr.self, c.JZX_IO_WRITE);
        } else {
            state.pending_len = 0;
            state.pending_off = 0;
            _ = c.jzx_watch_fd(ctx_ptr.loop.?, state.fd, ctx_ptr.self, c.JZX_IO_READ);
        }
    }

    if (state.pending_off >= state.pending_len) {
        state.pending_len = 0;
        state.pending_off = 0;
    }

    return c.JZX_BEHAVIOR_OK;
}

fn listenerBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));

    if (msg_ptr.tag != c.JZX_TAG_SYS_IO or msg_ptr.data == null) {
        return c.JZX_BEHAVIOR_OK;
    }

    const state = @as(*ListenerState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    const ev = @as(*c.jzx_io_event, @ptrCast(@alignCast(msg_ptr.data.?)));
    defer c.jzx_loop_free(ctx_ptr.loop.?, msg_ptr.data.?);

    if ((ev.readiness & c.JZX_IO_READ) == 0) {
        return c.JZX_BEHAVIOR_OK;
    }

    while (true) {
        const client_fd = posix.accept(state.fd, null, null, 0) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                std.debug.print("[listener] accept error: {s}\n", .{@errorName(err)});
                break;
            },
        };

        setNonBlocking(client_fd) catch {};
        setCloexec(client_fd) catch {};

        const conn_state = std.heap.c_allocator.create(ConnState) catch {
            posix.close(client_fd);
            continue;
        };
        conn_state.* = .{ .fd = client_fd };

        var opts = c.jzx_spawn_opts{
            .behavior = connBehavior,
            .state = conn_state,
            .supervisor = 0,
            .mailbox_cap = 0,
            .name = null,
        };
        var actor_id: c.jzx_actor_id = 0;
        const rc = c.jzx_spawn(ctx_ptr.loop.?, &opts, &actor_id);
        if (rc != c.JZX_OK) {
            std.heap.c_allocator.destroy(conn_state);
            posix.close(client_fd);
            continue;
        }

        const watch_rc = c.jzx_watch_fd(ctx_ptr.loop.?, client_fd, actor_id, c.JZX_IO_READ);
        if (watch_rc != c.JZX_OK) {
            posix.close(client_fd);
            std.heap.c_allocator.destroy(conn_state);
            _ = c.jzx_actor_stop(ctx_ptr.loop.?, actor_id);
            continue;
        }

        std.debug.print("[listener] accepted fd={d} actor={d}\n", .{ client_fd, actor_id });
    }

    return c.JZX_BEHAVIOR_OK;
}

pub fn main() !void {
    const argv = try std.process.argsAlloc(std.heap.c_allocator);
    defer std.process.argsFree(std.heap.c_allocator, argv);

    const port: u16 = if (argv.len >= 2) blk: {
        break :blk std.fmt.parseUnsigned(u16, argv[1], 10) catch 5555;
    } else 5555;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    const addr = try std.net.Address.parseIp4("0.0.0.0", port);
    const listen_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listen_fd);

    var yes: c_int = 1;
    try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&yes));

    try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
    try posix.listen(listen_fd, 128);

    var listener_state = ListenerState{ .fd = listen_fd };
    var listener_opts = c.jzx_spawn_opts{
        .behavior = listenerBehavior,
        .state = &listener_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = "listener",
    };
    var listener_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &listener_opts, &listener_id) != c.JZX_OK) {
        std.debug.print("failed to spawn listener actor\n", .{});
        return;
    }
    try loop.watchFd(@intCast(listen_fd), listener_id, c.JZX_IO_READ);

    std.debug.print("echo server listening on 0.0.0.0:{d}\n", .{port});
    std.debug.print("connect with: nc 127.0.0.1 {d}\n", .{port});

    try loop.run();
}
