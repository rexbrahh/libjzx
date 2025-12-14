---
title: Zig example — examples/zig/echo_server.zig
---

# Zig example — `examples/zig/echo_server.zig`

This is a libxev-backed TCP echo server built on top of libjzx’s **I/O watcher** mechanism.

It demonstrates:

- watching a listening socket for readability
- accepting clients and spawning one actor per connection
- watching each client socket for read/write readiness
- a simple “read → write back” state machine with backpressure
- correct memory ownership when receiving runtime-allocated I/O events

## High-level architecture

There are two actor types:

1. **Listener actor**
   - owns the listening socket
   - watches it for `READ` readiness
   - accepts as many connections as possible per readiness notification
   - spawns a connection actor for each accepted socket
2. **Connection actor**
   - owns a client socket and a buffer
   - watches for `READ` when it wants to receive data
   - watches for `WRITE` when it has pending data to flush

The runtime delivers I/O readiness as normal messages:

- `msg.tag == JZX_TAG_SYS_IO`
- `msg.data` points to a `jzx_io_event` allocated by the loop

That means the actor must:

- cast `msg.data` to `*c.jzx_io_event`
- free it using `c.jzx_loop_free(loop, msg.data)`

## Imports and state structs

<!-- snippet: examples/zig/echo_server.zig#L1-L15 -->
```zig title="Imports and actor state" showLineNumbers=1
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
```

What’s here:

- `posix = std.posix` gives access to low-level syscalls (socket, accept, read, write, fcntl).
- `ListenerState` is the listener actor’s state:
  - a single field `fd` for the listening socket.
- `ConnState` is per-connection state:
  - `fd`: client socket
  - `buf`: fixed buffer for reads and writes
  - `pending_len` / `pending_off`: “how much data remains to be written”

The “pending” fields implement a simple, explicit backpressure model:

- If we couldn’t write everything immediately, we remember how much remains and wait for a `WRITE` readiness event.

## Helper: set sockets non-blocking

Accepted sockets need to be non-blocking, because readiness-driven loops must treat `WouldBlock` as “try again later”.

<!-- snippet: examples/zig/echo_server.zig#func=setNonBlocking -->
```zig title="setNonBlocking(): fcntl(SETFL) + O_NONBLOCK" showLineNumbers=17
fn setNonBlocking(fd: posix.fd_t) !void {
    const raw = try posix.fcntl(fd, posix.F.GETFL, 0);
    var flags: posix.O = @bitCast(@as(u32, @intCast(raw)));
    flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
}
```

What this does:

- `fcntl(GETFL)` reads current file status flags.
- It sets the `NONBLOCK` bit.
- `fcntl(SETFL)` writes the updated flags back.

The conversions (`@intCast`, `@bitCast`) are Zig’s way of making the integer/bitfield transitions explicit.

## Helper: set close-on-exec

This prevents leaking sockets into child processes if the program ever `exec`s something.

<!-- snippet: examples/zig/echo_server.zig#func=setCloexec -->
```zig title="setCloexec(): fcntl(SETFD) + FD_CLOEXEC" showLineNumbers=24
fn setCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}
```

## Connection actor behavior

The connection actor handles two kinds of readiness:

- `READ`: data available from client
- `WRITE`: socket can accept more bytes (finish flushing pending output)

### Decode runtime I/O messages

<!-- snippet: examples/zig/echo_server.zig#L29-L40 -->
```zig title="Filter messages and decode jzx_io_event" showLineNumbers=29
fn connBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));

    if (msg_ptr.tag != c.JZX_TAG_SYS_IO or msg_ptr.data == null) {
        return c.JZX_BEHAVIOR_OK;
    }

    const state = @as(*ConnState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    const ev = @as(*c.jzx_io_event, @ptrCast(@alignCast(msg_ptr.data.?)));
    defer c.jzx_loop_free(ctx_ptr.loop.?, msg_ptr.data.?);
```

Key details:

- This actor ignores all non-I/O messages:
  - `msg_ptr.tag != JZX_TAG_SYS_IO` → ignore
  - `msg_ptr.data == null` → ignore (defensive)
- `ctx_ptr.state.?` is the per-actor state pointer set during spawn.
  - It is cast to `*ConnState`.
- `msg_ptr.data.?` is cast to `*c.jzx_io_event`.
- `defer c.jzx_loop_free(...)` is crucial:
  - The runtime allocates the `jzx_io_event` using the loop’s allocator.
  - The actor must return it to that same allocator.

### WRITE readiness: flush pending output

If there’s pending output, a `WRITE` readiness notification is our chance to flush more bytes.

<!-- snippet: examples/zig/echo_server.zig#L41-L57 -->
```zig title="WRITE readiness: continue writing buffered data" showLineNumbers=41
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
```

What’s happening:

- `slice = buf[pending_off..pending_len]` selects the unsent portion.
- `posix.write` attempts to write it:
  - `WouldBlock` means “try again later” → wrote 0 bytes.
  - Any other error is treated as fatal:
    - close fd
    - free state
    - stop actor
- After writing enough bytes to finish the pending range:
  - reset pending counters
  - change interest back to `READ` (we’re ready to read again)

Why flip the watch interest:

- It avoids continuous `WRITE` notifications when we don’t have anything to write.

### READ readiness: read, then echo back

The echo path reads into `buf`, then immediately attempts to write the same bytes back.

<!-- snippet: examples/zig/echo_server.zig#L59-L93 -->
```zig title="READ readiness: read into buffer, then try to echo back" showLineNumbers=59
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
```

Important details:

- The read path only runs if `pending_len == 0`.
  - Why: if we already have unsent output, we don’t want to read more and grow buffering.
  - This is a simple “one buffer in flight” rule.
- `n == 0` means EOF (client closed connection).
  - This actor closes fd, frees state, and stops.
- It tries to write immediately after reading:
  - If the socket accepts all bytes, we go back to `READ`.
  - If the socket accepts only some bytes (or wouldblock), we switch to `WRITE` and wait for the next writable event.

### Final cleanup invariants

<!-- snippet: examples/zig/echo_server.zig#L95-L100 -->
```zig title="Normalize pending counters" showLineNumbers=95
    if (state.pending_off >= state.pending_len) {
        state.pending_len = 0;
        state.pending_off = 0;
    }

    return c.JZX_BEHAVIOR_OK;
```

This ensures:

- if we “caught up” on writes, pending state resets to “no pending output”.

## Listener actor behavior

The listener actor:

- receives `SYS_IO` events for the listening socket
- loops `accept()` until it would block (drain the accept queue)
- spawns a connection actor for each accepted socket
- registers the new socket for `READ` events owned by the connection actor

### Decode runtime I/O messages

<!-- snippet: examples/zig/echo_server.zig#L103-L117 -->
```zig title="listenerBehavior(): filter to SYS_IO + READ readiness" showLineNumbers=103
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
```

Same ownership rule as the connection actor:

- `msg.data` is runtime-allocated `jzx_io_event` → must be freed via `jzx_loop_free`.

### Accept loop + spawn connection actor

<!-- snippet: examples/zig/echo_server.zig#between=while (true) {|return c.JZX_BEHAVIOR_OK; -->
```zig title="Accept as many clients as possible, spawn one actor per client" showLineNumbers=119
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
```

Key details:

- The accept loop drains the kernel accept queue:
  - it keeps accepting until `WouldBlock`.
  - This avoids “one accept per readiness event” under load.
- `ConnState` is allocated with `std.heap.c_allocator`.
  - Unlike `jzx_io_event`, this is user-owned memory; the connection actor frees it on stop.
- After spawning the connection actor, the listener registers the client fd with the runtime:
  - `owner = actor_id` → I/O events for that fd are delivered to the connection actor.

## main(): bind, listen, spawn listener, watch fd

The `main` function:

- parses an optional port argument
- creates a listening socket
- spawns the listener actor
- registers the listening socket for `READ` readiness

<!-- snippet: examples/zig/echo_server.zig#func=main -->
```zig title="main(): setup and run" showLineNumbers=166
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
```

Key details:

- The listening socket is created with `NONBLOCK` and `CLOEXEC` already.
- `ListenerState` lives on the stack:
  - safe because `loop.run()` doesn’t return until the program exits or loop stops.
- `loop.watchFd(listen_fd, listener_id, READ)` registers the listen fd with the runtime:
  - The runtime will deliver `SYS_IO` messages to `listener_id` when clients connect.

## Full listing (for reference)

<!-- snippet: examples/zig/echo_server.zig#all -->
```zig title="examples/zig/echo_server.zig" showLineNumbers=1
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
```
