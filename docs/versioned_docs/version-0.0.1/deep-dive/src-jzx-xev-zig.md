---
title: libxev integration — src/jzx_xev.zig
sidebar_position: 5
---

# libxev integration — `src/jzx_xev.zig`

This file is the bridge between:

- the **C runtime** (which wants “watch fd X and deliver messages”), and
- the **xev event loop** (which wants “arm completions, then rearm/disarm via callbacks”).

This page uses a textbook-style format: short snippets with explanation immediately around them.

## Cross-links {#cross-links}

- Start here: [Source index](source-index)
- Public API (watch/unwatch): [C ABI (`include/jzx/jzx.h`)](include-jzx-jzx-h#timers-and-io)
- Runtime delivery path: [Runtime core (`src/jzx_runtime.c`)](src-jzx-runtime-c)
- Example using fd watches: [Zig echo server](examples-zig-echo-server-zig)

## Imports, ABI wiring, and core aliases {#imports}

<!-- snippet: src/jzx_xev.zig#L1-L13 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L1-L13"><code>src/jzx_xev.zig#L1-L13</code></a></div>
```zig title="Imports, C ABI import, and core aliases" showLineNumbers=1
const std = @import("std");
const xev = @import("xev");
const Xev = xev.Dynamic;

const c = @cImport({
    @cInclude("jzx/jzx.h");
});

extern fn jzx_io_xev_notify(loop: *c.jzx_loop, fd: c_int, readiness: u32) u8;

const Loop = Xev.Loop;
const Async = Xev.Async;
const Completion = Xev.Completion;
```

What each line is doing:

- `std`: used for allocator and platform constants (`std.posix`, `std.os.linux`).
- `xev` + `Xev = xev.Dynamic`: selects xev’s dynamic backend wrapper so this code can support multiple polling backends.
- `c = @cImport(...)`: imports the public C ABI types and constants (`JZX_IO_READ`, `jzx_loop`, etc).
- `extern fn jzx_io_xev_notify(...) u8`: declares a C function implemented by the runtime that xev callbacks call to deliver readiness.
- `Loop`, `Async`, `Completion`: aliases that shorten xev types used throughout the file.

Why it exists: the runtime owns scheduling and message delivery, but it needs a backend to translate OS readiness events into “enqueue a message”.

## The per-fd watch object (`Watch`) {#watch}

<!-- snippet: src/jzx_xev.zig#L15-L25 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L15-L25"><code>src/jzx_xev.zig#L15-L25</code></a></div>
```zig title="Watch: one fd + xev completions" showLineNumbers=15
const Watch = struct {
    loop: *c.jzx_loop,
    fd: c_int,
    interest: u32,
    removed: bool = false,

    read: Completion = .{},
    read_cancel: Completion = .{},
    write: Completion = .{},
    write_cancel: Completion = .{},
};
```

`Watch` represents a single fd registration.

- `loop`: pointer back to the owning `jzx_loop` so callbacks know where to deliver.
- `fd`: watched file descriptor.
- `interest`: bitmask (`JZX_IO_READ` / `JZX_IO_WRITE`).
- `removed`: a “logical delete” flag; the watch is freed only when it is safe to do so.
- `read` / `write`: the active xev completions for readiness.
- `read_cancel` / `write_cancel`: cancellation completions used to disarm watches without races.

Why the `*_cancel` completions exist: xev completion objects have a lifecycle; cancelling an active completion is itself an operation that must be tracked until complete.

## Backend state stored inside the C loop (`XevState`) {#xev-state}

<!-- snippet: src/jzx_xev.zig#L27-L45 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L27-L45"><code>src/jzx_xev.zig#L27-L45</code></a></div>
```zig title="XevState: backend-owned state" showLineNumbers=27
pub const XevState = struct {
    loop: Loop,
    wake: Async,
    wake_completion: Completion = .{},
    wake_cancel: Completion = .{},

    watches: std.ArrayListUnmanaged(*Watch) = .{},

    pub fn deinit(self: *XevState) void {
        const allocator = std.heap.c_allocator;
        self.wake.deinit();
        self.loop.deinit();
        for (self.watches.items) |watch| {
            allocator.destroy(watch);
        }
        self.watches.deinit(allocator);
        self.* = undefined;
    }
};
```

`XevState` is allocated by `jzx_xev_create()` and stored in the C loop as an opaque pointer.

- `loop`: the xev loop instance.
- `wake`: an async handle used to wake a blocking wait.
- `watches`: an array of pointers to `Watch` objects.
- `deinit`: tears down the backend:
  - deinitializes wake + loop
  - destroys all allocated watches
  - poisons `self` to catch use-after-free

## Backend capability check (`supportsPollOps`) {#supports}

<!-- snippet: src/jzx_xev.zig#func=supportsPollOps -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L47-L56"><code>src/jzx_xev.zig#L47-L56</code></a></div>
```zig title="supportsPollOps()" showLineNumbers=47
fn supportsPollOps() bool {
    if (comptime Xev.dynamic) {
        return true;
    }

    return switch (Xev.backend) {
        .io_uring, .epoll, .kqueue => true,
        else => false,
    };
}
```

This function answers: “can the chosen xev backend support the polling operations we need?”

- If `Xev.dynamic` is enabled, it returns true because the backend is selected from candidates that support the superset interface.
- Otherwise it whitelists backends known to support poll/read/write operations.

Why it exists: if the backend can’t watch fds, the runtime’s I/O API must fail gracefully.

## Finding and creating watches (`findWatchIndex` and `ensureWatch`) {#watches}

<!-- snippet: src/jzx_xev.zig#func=findWatchIndex -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L58-L63"><code>src/jzx_xev.zig#L58-L63</code></a></div>
```zig title="findWatchIndex()" showLineNumbers=58
fn findWatchIndex(state: *XevState, fd: c_int) ?usize {
    for (state.watches.items, 0..) |watch, idx| {
        if (watch.fd == fd) return idx;
    }
    return null;
}
```

This is a linear search over `state.watches` by fd.

TODO: If watch counts grow large, consider a hashmap (fd → index) to avoid O(n) scans.

<!-- snippet: src/jzx_xev.zig#func=ensureWatch -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L65-L81"><code>src/jzx_xev.zig#L65-L81</code></a></div>
```zig title="ensureWatch()" showLineNumbers=65
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
```

This function ensures there is a `Watch` for an fd:

- If one exists, it updates `watch.loop` (important if the same fd is reused for a different loop).
- Otherwise it allocates a new `Watch`, initializes it with zero interest, and appends it to the list.

Why it exists: it centralizes the “lookup or create” logic so `watch_fd` stays small.

## Cancelling active completions (`cancelIfNeeded`) {#cancel}

<!-- snippet: src/jzx_xev.zig#func=cancelIfNeeded -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L83-L120"><code>src/jzx_xev.zig#L83-L120</code></a></div>
```zig title="cancelIfNeeded()" showLineNumbers=83
fn cancelIfNeeded(state: *XevState, target: *Completion, cancel: *Completion) void {
    if (target.state() == .dead) return;
    if (cancel.state() != .dead) return;

    if (comptime Xev.dynamic) {
        switch (Xev.backend) {
            inline else => |tag| {
                cancel.ensureTag(tag);
                const api = (comptime Xev.superset(tag)).Api();
                const api_cb = (struct {
                    fn callback(
                        _: ?*anyopaque,
                        _: *api.Loop,
                        _: *api.Completion,
                        _: api.Result,
                    ) api.CallbackAction {
                        return .disarm;
                    }
                }).callback;

                @field(cancel.value, @tagName(tag)) = .{
                    .op = .{ .cancel = .{ .c = &@field(target.value, @tagName(tag)) } },
                    .userdata = null,
                    .callback = api_cb,
                };
                @field(state.loop.backend, @tagName(tag)).add(&@field(cancel.value, @tagName(tag)));
            },
        }
        return;
    }

    cancel.* = .{
        .op = .{ .cancel = .{ .c = target } },
        .userdata = null,
        .callback = cancelCallback,
    };
    state.loop.add(cancel);
}
```

This function is subtle and critical:

- If the completion is already `.dead`, there’s nothing to cancel.
- If a cancel operation is already armed, don’t arm another cancel.
- The dynamic-backend path constructs a backend-specific cancel op.
- The static-backend path uses xev’s generic cancel op.

Why it exists: cancelling an in-flight completion is the safe way to stop watching an fd without freeing data structures too early.

<!-- snippet: src/jzx_xev.zig#func=cancelCallback -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L122-L124"><code>src/jzx_xev.zig#L122-L124</code></a></div>
```zig title="cancelCallback()" showLineNumbers=122
fn cancelCallback(_: ?*anyopaque, _: *Loop, _: *Completion, _: Xev.Result) Xev.CallbackAction {
    return .disarm;
}
```

The cancel callback always returns `.disarm`, which tells xev not to rearm the cancellation completion.

## Readiness callbacks (delivering events back into C) {#readiness}

<!-- snippet: src/jzx_xev.zig#func=readCallback -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L126-L133"><code>src/jzx_xev.zig#L126-L133</code></a></div>
```zig title="readCallback()" showLineNumbers=126
fn readCallback(ud: ?*anyopaque, _: *Loop, _: *Completion, _: Xev.Result) Xev.CallbackAction {
    const watch = @as(*Watch, @ptrCast(@alignCast(ud.?)));
    if (watch.removed or (watch.interest & c.JZX_IO_READ) == 0) {
        return .disarm;
    }
    const ok = jzx_io_xev_notify(watch.loop, watch.fd, c.JZX_IO_READ) != 0;
    return if (ok) .rearm else .disarm;
}
```

- Reinterprets `userdata` as `*Watch`.
- If the watch is removed or no longer interested in reads, disarm.
- Otherwise call `jzx_io_xev_notify(loop, fd, JZX_IO_READ)`.
- If C returns “ok”, rearm; otherwise disarm.

The return value from `jzx_io_xev_notify` is the runtime’s way to say: “keep watching” vs “stop watching”.

<!-- snippet: src/jzx_xev.zig#func=writeCallback -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L135-L142"><code>src/jzx_xev.zig#L135-L142</code></a></div>
```zig title="writeCallback()" showLineNumbers=135
fn writeCallback(ud: ?*anyopaque, _: *Loop, _: *Completion, _: Xev.Result) Xev.CallbackAction {
    const watch = @as(*Watch, @ptrCast(@alignCast(ud.?)));
    if (watch.removed or (watch.interest & c.JZX_IO_WRITE) == 0) {
        return .disarm;
    }
    const ok = jzx_io_xev_notify(watch.loop, watch.fd, c.JZX_IO_WRITE) != 0;
    return if (ok) .rearm else .disarm;
}
```

Same logic as `readCallback`, but for `JZX_IO_WRITE`.

## Arming read/write operations (`armRead` / `armWrite`) {#arming}

<!-- snippet: src/jzx_xev.zig#func=armRead -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L144-L195"><code>src/jzx_xev.zig#L144-L195</code></a></div>
```zig title="armRead()" showLineNumbers=144
fn armRead(state: *XevState, watch: *Watch) void {
    if (!supportsPollOps()) return;
    if (watch.read.state() != .dead) return;

    if (comptime Xev.dynamic) {
        switch (Xev.backend) {
            inline else => |tag| {
                watch.read.ensureTag(tag);
                const api = (comptime Xev.superset(tag)).Api();
                const api_cb = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        _: *api.Loop,
                        _: *api.Completion,
                        _: api.Result,
                    ) api.CallbackAction {
                        const watch_ptr = @as(*Watch, @ptrCast(@alignCast(ud.?)));
                        if (watch_ptr.removed or (watch_ptr.interest & c.JZX_IO_READ) == 0) {
                            return .disarm;
                        }
                        const ok = jzx_io_xev_notify(watch_ptr.loop, watch_ptr.fd, c.JZX_IO_READ) != 0;
                        return if (ok) .rearm else .disarm;
                    }
                }).callback;

                @field(watch.read.value, @tagName(tag)) = .{
                    .op = switch (comptime Xev.superset(tag)) {
                        .io_uring => .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.IN } },
                        .epoll => .{ .poll = .{ .fd = watch.fd, .events = std.os.linux.EPOLL.IN } },
                        else => unreachable,
                    },
                    .userdata = watch,
                    .callback = api_cb,
                };
                @field(state.loop.backend, @tagName(tag)).add(&@field(watch.read.value, @tagName(tag)));
            },
        }
        return;
    }

    watch.read = .{
        .op = switch (Xev.backend) {
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
```

This function arms a completion for “readable” readiness.

- It short-circuits if poll ops aren’t supported or if a read op is already armed.
- The dynamic backend path constructs backend-specific poll ops and callback glue.
- The non-dynamic path uses the statically selected backend and attaches `readCallback`.

<!-- snippet: src/jzx_xev.zig#func=armWrite -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L197-L248"><code>src/jzx_xev.zig#L197-L248</code></a></div>
```zig title="armWrite()" showLineNumbers=197
fn armWrite(state: *XevState, watch: *Watch) void {
    if (!supportsPollOps()) return;
    if (watch.write.state() != .dead) return;

    if (comptime Xev.dynamic) {
        switch (Xev.backend) {
            inline else => |tag| {
                watch.write.ensureTag(tag);
                const api = (comptime Xev.superset(tag)).Api();
                const api_cb = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        _: *api.Loop,
                        _: *api.Completion,
                        _: api.Result,
                    ) api.CallbackAction {
                        const watch_ptr = @as(*Watch, @ptrCast(@alignCast(ud.?)));
                        if (watch_ptr.removed or (watch_ptr.interest & c.JZX_IO_WRITE) == 0) {
                            return .disarm;
                        }
                        const ok = jzx_io_xev_notify(watch_ptr.loop, watch_ptr.fd, c.JZX_IO_WRITE) != 0;
                        return if (ok) .rearm else .disarm;
                    }
                }).callback;

                @field(watch.write.value, @tagName(tag)) = .{
                    .op = switch (comptime Xev.superset(tag)) {
                        .io_uring => .{ .poll = .{ .fd = watch.fd, .events = std.posix.POLL.OUT } },
                        .epoll => .{ .poll = .{ .fd = watch.fd, .events = std.os.linux.EPOLL.OUT } },
                        else => unreachable,
                    },
                    .userdata = watch,
                    .callback = api_cb,
                };
                @field(state.loop.backend, @tagName(tag)).add(&@field(watch.write.value, @tagName(tag)));
            },
        }
        return;
    }

    watch.write = .{
        .op = switch (Xev.backend) {
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
```

Same logic as `armRead`, but arms “writable” readiness.

Why the dynamic path is more verbose: xev’s dynamic superset requires constructing backend-tagged completion values at compile time.

## Keeping watch state consistent (`syncWatch`, `sweep`) {#consistency}

<!-- snippet: src/jzx_xev.zig#func=syncWatch -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L250-L266"><code>src/jzx_xev.zig#L250-L266</code></a></div>
```zig title="syncWatch()" showLineNumbers=250
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
```

This function reconciles “desired interest” with “armed completions”:

- If a watch is `removed`, force `interest = 0`.
- If interested in read/write, ensure the corresponding completion is armed.
- If not interested, cancel any armed completion.

<!-- snippet: src/jzx_xev.zig#func=watchReadyToFree -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L268-L271"><code>src/jzx_xev.zig#L268-L271</code></a></div>
```zig title="watchReadyToFree()" showLineNumbers=268
fn watchReadyToFree(watch: *Watch) bool {
    return watch.read.state() == .dead and watch.write.state() == .dead and
        watch.read_cancel.state() == .dead and watch.write_cancel.state() == .dead;
}
```

A watch can be freed only when all four completions (read/write and their cancels) are dead.

<!-- snippet: src/jzx_xev.zig#func=sweep -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L273-L290"><code>src/jzx_xev.zig#L273-L290</code></a></div>
```zig title="sweep()" showLineNumbers=273
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
```

`sweep`:

- calls `syncWatch` for every watch, and
- destroys watches that are both:
  - marked `removed`, and
  - “ready to free”

It removes freed watches by swapping with the last element (O(1) removal, order not preserved).

## Wake callback {#wake-callback}

<!-- snippet: src/jzx_xev.zig#func=wakeCallback -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L292-L295"><code>src/jzx_xev.zig#L292-L295</code></a></div>
```zig title="wakeCallback()" showLineNumbers=292
fn wakeCallback(_: ?*void, _: *Loop, _: *Completion, result: Async.WaitError!void) Xev.CallbackAction {
    _ = result catch return .disarm;
    return .rearm;
}
```

The wake callback rearms itself on success so the async wake handle continues to work for the lifetime of the loop.

## Exported functions (C runtime calls these) {#exports}

### Create backend state

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_create -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L297-L330"><code>src/jzx_xev.zig#L297-L330</code></a></div>
```zig title="jzx_xev_create()" showLineNumbers=297
pub export fn jzx_xev_create() ?*XevState {
    if (!supportsPollOps()) {
        return null;
    }

    const allocator = std.heap.c_allocator;
    const state = allocator.create(XevState) catch return null;
    errdefer allocator.destroy(state);

    var loop: Loop = undefined;
    if (comptime Xev.dynamic) {
        var selected: ?Loop = null;
        for (Xev.candidates) |candidate| {
            if (!Xev.prefer(candidate)) continue;
            selected = Loop.init(.{}) catch continue;
            break;
        }
        loop = selected orelse return null;
    } else {
        loop = Loop.init(.{}) catch return null;
    }
    errdefer loop.deinit();

    const wake = Async.init() catch return null;
    errdefer wake.deinit();

    state.* = .{
        .loop = loop,
        .wake = wake,
    };

    state.wake.wait(&state.loop, &state.wake_completion, void, null, wakeCallback);
    return state;
}
```

Highlights:

- returns null when poll operations aren’t supported.
- allocates `XevState` with the C allocator.
- selects an xev backend (dynamic: chooses preferred candidate; static: uses `Xev.backend`).
- initializes the wake async handle and arms `wait` with `wakeCallback`.

### Destroy backend state

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_destroy -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L332-L337"><code>src/jzx_xev.zig#L332-L337</code></a></div>
```zig title="jzx_xev_destroy()" showLineNumbers=332
pub export fn jzx_xev_destroy(state: *XevState) void {
    if (@intFromPtr(state) == 0) return;

    state.deinit();
    std.heap.c_allocator.destroy(state);
}
```

This frees all backend-owned resources.

### Wake a blocked loop

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_wakeup -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L339-L342"><code>src/jzx_xev.zig#L339-L342</code></a></div>
```zig title="jzx_xev_wakeup()" showLineNumbers=339
pub export fn jzx_xev_wakeup(state: *XevState) void {
    if (@intFromPtr(state) == 0) return;
    state.wake.notify() catch {};
}
```

Used by the C runtime after it enqueues cross-thread work so a blocking wait will return promptly.

### Run one step of the backend loop

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_run -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L344-L353"><code>src/jzx_xev.zig#L344-L353</code></a></div>
```zig title="jzx_xev_run()" showLineNumbers=344
pub export fn jzx_xev_run(state: *XevState, mode: c_int) void {
    if (@intFromPtr(state) == 0) return;
    const run_mode: Xev.RunMode = switch (mode) {
        0 => .no_wait,
        1 => .once,
        else => .no_wait,
    };
    _ = state.loop.run(run_mode) catch {};
    sweep(state);
}
```

The `mode` integer is mapped into an xev `RunMode`:

- `0` → `.no_wait`
- `1` → `.once`

Then `sweep` runs to reconcile interests, cancellations, and frees.

### Watch an fd

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_watch_fd -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L355-L364"><code>src/jzx_xev.zig#L355-L364</code></a></div>
```zig title="jzx_xev_watch_fd()" showLineNumbers=355
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
```

Contract enforcement:

- null state/loop, negative fd, or zero interest → `JZX_ERR_INVALID_ARG`.
- out-of-memory allocating a watch → `JZX_ERR_NO_MEMORY`.

Then it updates interest and syncs the watch immediately.

### Unwatch an fd

<!-- snippet: src/jzx_xev.zig#func=jzx_xev_unwatch_fd -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/src/jzx_xev.zig#L366-L372"><code>src/jzx_xev.zig#L366-L372</code></a></div>
```zig title="jzx_xev_unwatch_fd()" showLineNumbers=366
pub export fn jzx_xev_unwatch_fd(state: *XevState, fd: c_int) void {
    if (@intFromPtr(state) == 0 or fd < 0) return;
    const idx = findWatchIndex(state, fd) orelse return;
    const watch = state.watches.items[idx];
    watch.removed = true;
    syncWatch(state, watch);
}
```

Marks the watch removed and syncs it; actual free happens in `sweep` when it is safe.
