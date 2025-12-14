---
title: Integration tests — zig/tests/basic.zig
sidebar_position: 7
---

# Integration tests — `zig/tests/basic.zig`

This file is an end-to-end test suite: it exercises the runtime through the public C ABI and the Zig wrapper. Treat it as executable documentation of runtime contracts.

This page uses a textbook style: focused snippets with explanation, plus an appendix with the full source.

## Imports and shared helpers

<!-- snippet: zig/tests/basic.zig#L1-L11 -->
```zig title="Imports and AsyncArgs" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
const posix = std.posix;

const AsyncArgs = struct {
    loop: *c.jzx_loop,
    actor: c.jzx_actor_id,
    payload: *u32,
};
```

- `std`: Zig standard library, including `std.testing`.
- `jzx`: Zig wrapper module under `zig/jzx/lib.zig`.
- `c = jzx.c`: the C ABI import namespace.
- `posix`: used for fd helpers in I/O tests.
- `AsyncArgs`: arguments passed into helper threads for async-send tests.

## A minimal “increment and stop” behavior

<!-- snippet: zig/tests/basic.zig#func=increment_behavior -->
```zig title="increment_behavior()" showLineNumbers=12
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
```

This behavior is intentionally small and deterministic:

- It interprets `ctx_ptr.state` as `*u32` and increments it by the incoming payload `*u32`.
- It returns `JZX_BEHAVIOR_STOP`, which makes the actor stop after processing the message.

Why it exists: many tests want “spawn actor → send message → run loop → assert state changed” without having to write a bespoke behavior each time.

## Shared state structs (test-owned state)

Many tests in this file use small, test-owned state structs. They are deliberately minimal:

- values are plain integers/bools so assertions are deterministic
- state is passed to the runtime as `void*` and recovered via pointer casts in behaviors

### TimerState

<!-- snippet: zig/tests/basic.zig#L23-L26 -->
```zig title="TimerState: count timer hits until target" showLineNumbers=23
const TimerState = struct {
    target: u32,
    hits: u32 = 0,
};
```

- `target`: how many timer events we expect to observe before stopping.
- `hits`: counter incremented on each timer message delivery.
- Why it exists: it turns “timers are firing” into a concrete, testable condition.

### ObserverState

<!-- snippet: zig/tests/basic.zig#L28-L35 -->
```zig title="ObserverState: accumulate lifecycle callbacks" showLineNumbers=28
const ObserverState = struct {
    start_count: u32 = 0,
    stop_count: u32 = 0,
    mailbox_full_count: u32 = 0,
    last_start: c.jzx_actor_id = 0,
    last_stop: c.jzx_actor_id = 0,
    last_stop_reason: c.jzx_exit_reason = c.JZX_EXIT_NORMAL,
};
```

This struct is what makes observer callbacks testable:

- counters (`*_count`) let tests assert “event happened exactly N times”.
- `last_*` fields let tests assert “the event referred to the expected actor”.

## Observer hooks used by tests

<!-- snippet: zig/tests/basic.zig#func=observerOnStart -->
```zig title="observerOnStart()" showLineNumbers=37
fn observerOnStart(ctx: ?*anyopaque, id: c.jzx_actor_id, name: [*c]const u8) callconv(.c) void {
    _ = name;
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.start_count += 1;
    state.last_start = id;
}
```

<!-- snippet: zig/tests/basic.zig#func=observerOnStop -->
```zig title="observerOnStop()" showLineNumbers=44
fn observerOnStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.stop_count += 1;
    state.last_stop = id;
    state.last_stop_reason = reason;
}
```

<!-- snippet: zig/tests/basic.zig#func=observerOnMailboxFull -->
```zig title="observerOnMailboxFull()" showLineNumbers=51
fn observerOnMailboxFull(ctx: ?*anyopaque, target: c.jzx_actor_id) callconv(.c) void {
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.mailbox_full_count += 1;
    _ = target;
}
```

These callbacks accumulate counts and last-seen ids into a test-owned `ObserverState`.

Why it exists: observer behavior is part of the runtime’s contract, so tests assert it fires correctly without requiring logs.

## Timer behavior used by tests

<!-- snippet: zig/tests/basic.zig#func=timer_behavior -->
```zig title="timer_behavior()" showLineNumbers=57
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
```

This behavior counts timer hits and stops after reaching `target`.

Why it exists: timer tests need an actor that can receive repeated timer messages and stop deterministically.

## Tests (complete suite)

Most tests follow a small harness pattern:

1. Create a loop (`jzx.Loop.create`).
2. Spawn actor(s) or supervisor(s).
3. Queue work (message, timer, I/O watch, or `jzx_send_async`).
4. Run the loop (`loop.run()`).
5. Assert on observable outcomes (state changes, error codes, observer counters, ordering, fairness).

Below are all tests in `zig/tests/basic.zig`, grouped by subsystem.

### Messaging and actor ids

#### Message delivery: actor receives and processes a message

<!-- snippet: zig/tests/basic.zig#zigtest=actor receives and processes a message -->
```zig title="test: actor receives and processes a message" showLineNumbers=68
test "actor receives and processes a message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 5;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));

    try loop.run();
    try std.testing.expectEqual(@as(u32, 5), state);
    try std.testing.expectEqual(c.JZX_ERR_NO_SUCH_ACTOR, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));
}
```

What it’s asserting:

- `c.jzx_spawn` creates an actor and returns an id.
- `c.jzx_send` enqueues a message.
- `loop.run()` drives delivery and actor teardown (because `increment_behavior` returns `STOP`).
- After stop, sending to the same id returns `JZX_ERR_NO_SUCH_ACTOR` (stale id is rejected).

#### Actor id generations: stale ids are rejected after slot reuse

<!-- snippet: zig/tests/basic.zig#zigtest=actor id generations reject stale ids after slot reuse -->
```zig title="test: actor id generations reject stale ids after slot reuse" showLineNumbers=91
test "actor id generations reject stale ids after slot reuse" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state_a: u32 = 0;
    var opts_a = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state_a,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_a: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_a, &actor_a));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_a, &payload, @sizeOf(u32), 0));
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), state_a);

    var state_b: u32 = 0;
    var opts_b = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state_b,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_b: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_b, &actor_b));
    try std.testing.expect(actor_b != actor_a);

    const raw_a: u64 = @intCast(actor_a);
    const raw_b: u64 = @intCast(actor_b);
    const idx_a: u32 = @truncate(raw_a);
    const idx_b: u32 = @truncate(raw_b);
    const gen_a: u32 = @intCast(raw_a >> 32);
    const gen_b: u32 = @intCast(raw_b >> 32);
    try std.testing.expectEqual(idx_a, idx_b);
    try std.testing.expectEqual(gen_a + 1, gen_b);

    try std.testing.expectEqual(c.JZX_ERR_NO_SUCH_ACTOR, c.jzx_send(loop.ptr, actor_a, &payload, @sizeOf(u32), 0));

    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_b, &payload, @sizeOf(u32), 0));
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), state_b);
}
```

What it’s asserting:

- Actor ids are **not** simple integers; they include a **generation**.
- When an actor slot is reused:
  - the **index** stays the same
  - the **generation** increments
- A stale id (old generation) is rejected with `JZX_ERR_NO_SUCH_ACTOR`.

#### Backpressure: mailbox full returns error

<!-- snippet: zig/tests/basic.zig#zigtest=mailbox full returns error -->
```zig title="test: mailbox full returns error" showLineNumbers=141
test "mailbox full returns error" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));
    try std.testing.expectEqual(c.JZX_ERR_MAILBOX_FULL, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    try loop.run();
}
```

What it’s asserting:

- Mailboxes are bounded (capacity is enforced).
- With `mailbox_cap = 1`, the second send returns `JZX_ERR_MAILBOX_FULL`.

### Observability (observer hooks)

<!-- snippet: zig/tests/basic.zig#zigtest=observer hooks receive lifecycle + mailbox full -->
```zig title="test: observer hooks receive lifecycle + mailbox full" showLineNumbers=163
test "observer hooks receive lifecycle + mailbox full" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_state = ObserverState{};
    var obs = c.jzx_observer{
        .on_actor_start = observerOnStart,
        .on_actor_stop = observerOnStop,
        .on_actor_restart = null,
        .on_supervisor_escalate = null,
        .on_mailbox_full = observerOnMailboxFull,
    };
    c.jzx_loop_set_observer(loop.ptr, &obs, @ptrCast(&obs_state));

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1,
        .name = "observer-actor",
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));
    try std.testing.expectEqual(c.JZX_ERR_MAILBOX_FULL, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), obs_state.start_count);
    try std.testing.expectEqual(@as(u32, 1), obs_state.stop_count);
    try std.testing.expectEqual(@as(u32, 1), obs_state.mailbox_full_count);
    try std.testing.expectEqual(actor_id, obs_state.last_start);
    try std.testing.expectEqual(actor_id, obs_state.last_stop);
    try std.testing.expectEqual(@as(c.jzx_exit_reason, c.JZX_EXIT_NORMAL), obs_state.last_stop_reason);
}
```

What it’s asserting:

- Observer callbacks fire in the expected places:
  - start (spawn)
  - mailbox full (second send)
  - stop (actor teardown)
- The observer receives the **correct actor id** and **exit reason**.

### Async send (cross-thread enqueue)

Async send tests use a helper thread that calls `jzx_send_async`.

<!-- snippet: zig/tests/basic.zig#func=async_sender -->
```zig title="async_sender(): helper thread entry" showLineNumbers=202
fn async_sender(args: AsyncArgs) void {
    _ = c.jzx_send_async(args.loop, args.actor, args.payload, @sizeOf(u32), 2);
}
```

Key detail:

- The return value is ignored because these tests are asserting the *delivery behavior* of async sends, not the enqueue status.

#### FIFO test scaffolding: SeqState + seq_behavior

Some tests need to assert **ordering**. The simplest deterministic way is:

- send a known sequence of `u32` values
- have the actor verify it receives `0,1,2,...` in order

<!-- snippet: zig/tests/basic.zig#L206-L210 -->
```zig title="SeqState: expected next value + remaining count" showLineNumbers=206
const SeqState = struct {
    expected: u32,
    remaining: u32,
    ok: bool = true,
};
```

<!-- snippet: zig/tests/basic.zig#func=seq_behavior -->
```zig title="seq_behavior(): verify strict in-order delivery" showLineNumbers=212
fn seq_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));
    const state = @as(*SeqState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    if (state.remaining == 0) {
        return c.JZX_BEHAVIOR_STOP;
    }
    if (msg_ptr.data == null) {
        state.ok = false;
        return c.JZX_BEHAVIOR_STOP;
    }
    const value_ptr: *const u32 = @ptrCast(@alignCast(msg_ptr.data.?));
    if (value_ptr.* != state.expected) {
        state.ok = false;
        return c.JZX_BEHAVIOR_STOP;
    }
    state.expected += 1;
    state.remaining -= 1;
    return if (state.remaining == 0) c.JZX_BEHAVIOR_STOP else c.JZX_BEHAVIOR_OK;
}
```

This actor stops as soon as it detects a mismatch, which keeps failures crisp and deterministic.

#### async send dispatches message

<!-- snippet: zig/tests/basic.zig#zigtest=async send dispatches message -->
```zig title="test: async send dispatches message" showLineNumbers=233
test "async send dispatches message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
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
```

What it’s asserting:

- A message enqueued via `jzx_send_async` is delivered when the loop runs.
- The delivery path is the same as `jzx_send` from the actor’s perspective.

#### async send wakes blocking loop

<!-- snippet: zig/tests/basic.zig#zigtest=async send wakes blocking loop -->
```zig title="test: async send wakes blocking loop" showLineNumbers=260
test "async send wakes blocking loop" {
    var cfg: c.jzx_config = undefined;
    c.jzx_config_init(&cfg);
    cfg.io_poll_timeout_ms = 5000;

    var loop = try jzx.Loop.create(cfg);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    std.Thread.sleep(5 * std.time.ns_per_ms);

    var payload: u32 = 9;
    const start_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_async(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    runner.join();

    const end_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try std.testing.expect(end_ms - start_ms < 1000);
    try std.testing.expectEqual(@as(u32, 9), state);
}
```

What it’s asserting:

- With a long I/O poll timeout, the loop thread may block in the backend.
- An async send triggers a wakeup so delivery happens promptly (not after the full timeout).

#### async send preserves FIFO ordering

<!-- snippet: zig/tests/basic.zig#zigtest=async send preserves FIFO ordering -->
```zig title="test: async send preserves FIFO ordering" showLineNumbers=298
test "async send preserves FIFO ordering" {
    const n: u32 = 512;

    var cfg: c.jzx_config = undefined;
    c.jzx_config_init(&cfg);
    cfg.io_poll_timeout_ms = 5000;

    var loop = try jzx.Loop.create(cfg);
    defer loop.deinit();

    var state = SeqState{ .expected = 0, .remaining = n };
    var opts = c.jzx_spawn_opts{
        .behavior = seq_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1024,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    std.Thread.sleep(5 * std.time.ns_per_ms);

    var payloads = [_]u32{0} ** n;
    var sender = try std.Thread.spawn(.{}, struct {
        fn run(lp: *c.jzx_loop, id: c.jzx_actor_id, data: []u32) void {
            for (data, 0..) |*item, idx| {
                item.* = @as(u32, @intCast(idx));
                _ = c.jzx_send_async(lp, id, item, @sizeOf(u32), 0);
            }
        }
    }.run, .{ loop.ptr, actor_id, payloads[0..] });

    sender.join();
    runner.join();

    try std.testing.expect(state.ok);
    try std.testing.expectEqual(@as(u32, 0), state.remaining);
}
```

What it’s asserting:

- The async queue preserves enqueue order for a single producer thread.
- The runtime does not reorder messages during internal drain/dispatch.

### Timers (delayed enqueue)

#### timer delivers message

<!-- snippet: zig/tests/basic.zig#zigtest=timer delivers message -->
```zig title="test: timer delivers message" showLineNumbers=344
test "timer delivers message" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
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
```

What it’s asserting:

- `jzx_send_after` delivers a delayed message.
- After the actor stops, canceling the timer id reports `JZX_ERR_TIMER_INVALID` (no pending timer).

#### cancelled timer does not fire

<!-- snippet: zig/tests/basic.zig#zigtest=cancelled timer does not fire -->
```zig title="test: cancelled timer does not fire" showLineNumbers=368
test "cancelled timer does not fire" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
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
```

What it’s asserting:

- Canceling a pending timer prevents delivery.

#### timer drop when actor stops

<!-- snippet: zig/tests/basic.zig#zigtest=timer drop when actor stops -->
```zig title="test: timer drop when actor stops" showLineNumbers=393
test "timer drop when actor stops" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 5;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 1, &payload, @sizeOf(u32), 0, null));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_actor_stop(loop.ptr, actor_id));

    try loop.run();
    try std.testing.expectEqual(@as(u32, 0), state);
}
```

What it’s asserting:

- Stopping an actor prevents “late timer delivery” to a dead actor.

#### many timers fire

<!-- snippet: zig/tests/basic.zig#zigtest=many timers fire -->
```zig title="test: many timers fire" showLineNumbers=416
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
        .name = null,
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
```

What it’s asserting:

- The timer thread can enqueue many timers and deliver them all.
- The actor can count and stop deterministically (`TimerState.target`).

#### timer delivery preserves enqueue order

<!-- snippet: zig/tests/basic.zig#zigtest=timer delivery preserves enqueue order -->
```zig title="test: timer delivery preserves enqueue order" showLineNumbers=443
test "timer delivery preserves enqueue order" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    const timer_count: u32 = 32;

    var state = SeqState{
        .expected = 0,
        .remaining = timer_count,
        .ok = true,
    };
    var opts = c.jzx_spawn_opts{
        .behavior = seq_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1024,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payloads = [_]u32{0} ** timer_count;
    for (&payloads, 0..) |*item, idx| {
        item.* = @as(u32, @intCast(idx));
        try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 1, item, @sizeOf(u32), 0, null));
    }

    try loop.run();
    try std.testing.expect(state.ok);
    try std.testing.expectEqual(@as(u32, 0), state.remaining);
}
```

What it’s asserting:

- Timer-enqueued messages preserve the order they are enqueued into the timer list.

### Scheduler fairness (ping pong)

This test uses a tiny “ping pong” behavior: each actor sends work to its partner.

<!-- snippet: zig/tests/basic.zig#L475-L480 -->
```zig title="PingPongState: cross-references partner id" showLineNumbers=475
const PingPongState = struct {
    loop: *c.jzx_loop,
    partner: *?c.jzx_actor_id,
    remaining: u32,
    hits: u32,
};
```

<!-- snippet: zig/tests/basic.zig#func=pingPongBehavior -->
```zig title="pingPongBehavior(): send to partner until remaining == 0" showLineNumbers=482
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
```

<!-- snippet: zig/tests/basic.zig#zigtest=ping pong actors share work fairly -->
```zig title="test: ping pong actors share work fairly" showLineNumbers=498
test "ping pong actors share work fairly" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    var partner_a: ?c.jzx_actor_id = 0;
    var partner_b: ?c.jzx_actor_id = 0;
    var state_a = PingPongState{ .loop = loop.ptr, .partner = &partner_a, .remaining = 10, .hits = 0 };
    var state_b = PingPongState{ .loop = loop.ptr, .partner = &partner_b, .remaining = 10, .hits = 0 };

    var opts_a = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_a, .supervisor = 0, .mailbox_cap = 0, .name = null };
    var opts_b = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_b, .supervisor = 0, .mailbox_cap = 0, .name = null };
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
```

What it’s asserting:

- The scheduler doesn’t starve one runnable actor while another is “chatty”.
- With the configured budgets, both actors make progress.

### Typed actor wrapper (Zig API surface)

This test exercises `jzx.Actor(...)` from the Zig wrapper.

<!-- snippet: zig/tests/basic.zig#L525-L531 -->
```zig title="Typed message + state" showLineNumbers=525
const CounterState = struct {
    total: u32 = 0,
};

const CounterMsg = struct {
    value: u32,
};
```

<!-- snippet: zig/tests/basic.zig#func=counterBehavior -->
```zig title="counterBehavior(): typed actor behavior" showLineNumbers=533
fn counterBehavior(state: *CounterState, msg: *CounterMsg, ctx: jzx.ActorContext) jzx.BehaviorResult {
    _ = ctx;
    state.total += msg.value;
    return .stop;
}
```

<!-- snippet: zig/tests/basic.zig#zigtest=typed actor increments state -->
```zig title="test: typed actor increments state" showLineNumbers=539
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
```

What it’s asserting:

- The Zig wrapper spawns a C actor that calls a typed Zig behavior.
- Typed payload decoding is safe as long as the caller sends the right payload type.

### I/O readiness (fd watchers)

I/O tests use a behavior that expects `JZX_TAG_SYS_IO` and decodes a `jzx_io_event`.

<!-- snippet: zig/tests/basic.zig#func=io_behavior -->
```zig title="io_behavior(): decode SYS_IO event and free payload" showLineNumbers=559
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
        c.jzx_loop_free(ctx_ptr.loop.?, data_ptr);
        return c.JZX_BEHAVIOR_STOP;
    }
    return c.JZX_BEHAVIOR_OK;
}
```

This behavior demonstrates a critical ownership rule:

- The runtime allocates the `jzx_io_event` payload.
- The actor must free it with `jzx_loop_free` (so it goes through the loop allocator).

<!-- snippet: zig/tests/basic.zig#func=pipe_writer -->
```zig title="pipe_writer(): make the pipe readable" showLineNumbers=575
fn pipe_writer(fd: posix.fd_t) void {
    const msg = "ping";
    _ = posix.write(fd, msg) catch {};
}
```

#### io watcher delivers readiness

<!-- snippet: zig/tests/basic.zig#zigtest=io watcher delivers readiness -->
```zig title="test: io watcher delivers readiness" showLineNumbers=580
test "io watcher delivers readiness" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = io_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
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
```

What it’s asserting:

- `jzx_watch_fd` registers interest.
- A readiness event is delivered as a system message.
- The owning actor can observe and handle the event.

#### io rapid watch and unwatch

<!-- snippet: zig/tests/basic.zig#zigtest=io rapid watch and unwatch -->
```zig title="test: io rapid watch and unwatch" showLineNumbers=610
test "io rapid watch and unwatch" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
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
```

What it’s asserting:

- Rapid register/unregister cycles do not crash or leak.
- After the final watch, readiness delivery still works.

### Supervision (restart strategies and intensity)

Supervision tests use “driver” actors that tick themselves until they observe the expected supervisor state.

<!-- snippet: zig/tests/basic.zig#L644-L646 -->
```zig title="RestartState: count child runs" showLineNumbers=644
const RestartState = struct {
    runs: u32 = 0,
};
```

<!-- snippet: zig/tests/basic.zig#func=scheduleSelf -->
```zig title="scheduleSelf(): self-tick via timer" showLineNumbers=648
fn scheduleSelf(loop: *c.jzx_loop, self: c.jzx_actor_id, ms: u32) void {
    _ = c.jzx_send_after(loop, self, ms, null, 0, 0, null);
}
```

<!-- snippet: zig/tests/basic.zig#func=failThenStop -->
```zig title="failThenStop(): fail once, then stop" showLineNumbers=652
fn failThenStop(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return if (state.runs == 1) c.JZX_BEHAVIOR_FAIL else c.JZX_BEHAVIOR_STOP;
}
```

<!-- snippet: zig/tests/basic.zig#L660-L666 -->
```zig title="TransientDriverState: detect one restart" showLineNumbers=660
const TransientDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_child_id: c.jzx_actor_id,
    stage: u8 = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

<!-- snippet: zig/tests/basic.zig#func=transientDriver -->
```zig title="transientDriver(): drive supervisor until child id changes" showLineNumbers=668
fn transientDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TransientDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id) != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_child_id, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (child_id != 0 and child_id != state.original_child_id) {
            _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
            state.stage = 2;
        }
    } else {
        if (child_id == 0) {
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

#### supervisor restarts transient child once

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor restarts transient child once -->
```zig title="test: supervisor restarts transient child once" showLineNumbers=706
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
        .name = null,
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

    var driver_state = TransientDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = transientDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), child_state.runs);
    try std.testing.expect(!driver_state.timed_out);
}
```

What it’s asserting:

- A transient child that fails once is restarted.
- After restart, the child can stop normally (no further restart).

#### Intensity escalation when a child fails repeatedly

<!-- snippet: zig/tests/basic.zig#func=alwaysFail -->
```zig title="alwaysFail(): fail every time" showLineNumbers=760
fn alwaysFail(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return c.JZX_BEHAVIOR_FAIL;
}
```

<!-- snippet: zig/tests/basic.zig#L768-L773 -->
```zig title="EscalationObsState: observe escalations + supervisor stop" showLineNumbers=768
const EscalationObsState = struct {
    sup_id: c.jzx_actor_id,
    escalations: u32 = 0,
    sup_stopped: bool = false,
    sup_stop_reason: c.jzx_exit_reason = c.JZX_EXIT_NORMAL,
};
```

<!-- snippet: zig/tests/basic.zig#func=escalationOnSupervisorEscalate -->
```zig title="escalationOnSupervisorEscalate(): observer hook" showLineNumbers=775
fn escalationOnSupervisorEscalate(ctx: ?*anyopaque, supervisor: c.jzx_actor_id) callconv(.c) void {
    const state = @as(*EscalationObsState, @ptrCast(@alignCast(ctx.?)));
    if (supervisor == state.sup_id) {
        state.escalations += 1;
    }
}
```

<!-- snippet: zig/tests/basic.zig#func=escalationOnActorStop -->
```zig title="escalationOnActorStop(): observer hook" showLineNumbers=782
fn escalationOnActorStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const state = @as(*EscalationObsState, @ptrCast(@alignCast(ctx.?)));
    if (id == state.sup_id) {
        state.sup_stopped = true;
        state.sup_stop_reason = reason;
    }
}
```

<!-- snippet: zig/tests/basic.zig#L790-L796 -->
```zig title="EscalationDriverState: poll child id until escalation" showLineNumbers=790
const EscalationDriverState = struct {
    sup_id: c.jzx_actor_id,
    obs: *EscalationObsState,
    last_child_id: c.jzx_actor_id = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

<!-- snippet: zig/tests/basic.zig#func=escalationDriver -->
```zig title="escalationDriver(): keep failing new children until supervisor escalates" showLineNumbers=798
fn escalationDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*EscalationDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.obs.escalations > 0 or state.obs.sup_stopped) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    const rc = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id);
    if (rc == c.JZX_ERR_NO_SUCH_ACTOR) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }
    if (rc != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (child_id != 0 and child_id != state.last_child_id) {
        _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
        state.last_child_id = child_id;
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor escalates when intensity exceeded -->
```zig title="test: supervisor escalates when intensity exceeded" showLineNumbers=836
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
        .name = null,
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

    var obs_state = EscalationObsState{ .sup_id = sup_id };
    var obs = c.jzx_observer{
        .on_actor_start = null,
        .on_actor_stop = escalationOnActorStop,
        .on_actor_restart = null,
        .on_supervisor_escalate = escalationOnSupervisorEscalate,
        .on_mailbox_full = null,
    };
    c.jzx_loop_set_observer(loop.ptr, &obs, @ptrCast(&obs_state));

    var driver_state = EscalationDriverState{
        .sup_id = sup_id,
        .obs = &obs_state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = escalationDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), obs_state.escalations);
    try std.testing.expect(obs_state.sup_stopped);
    try std.testing.expectEqual(@as(c.jzx_exit_reason, c.JZX_EXIT_FAIL), obs_state.sup_stop_reason);
    try std.testing.expect(!driver_state.timed_out);
    try std.testing.expect(child_state.runs >= 3);
}
```

What it’s asserting:

- Restart intensity windows are enforced.
- When restarts exceed the configured intensity, the supervisor escalates (and the observer sees it).

#### Backoff (constant + exponential)

<!-- snippet: zig/tests/basic.zig#L899-L903 -->
```zig title="BackoffState: record timestamps across restarts" showLineNumbers=899
const BackoffState = struct {
    runs: u32 = 0,
    t1_ms: u64 = 0,
    t2_ms: u64 = 0,
};
```

<!-- snippet: zig/tests/basic.zig#func=backoffRecorder -->
```zig title="backoffRecorder(): fail once, record timestamps" showLineNumbers=905
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
```

<!-- snippet: zig/tests/basic.zig#L920-L927 -->
```zig title="BackoffDriverState: poll until second run observed" showLineNumbers=920
const BackoffDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_child_id: c.jzx_actor_id,
    backoff_state: *BackoffState,
    stage: u8 = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

<!-- snippet: zig/tests/basic.zig#func=backoffDriver -->
```zig title="backoffDriver(): trigger child failure across restarts" showLineNumbers=929
fn backoffDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*BackoffDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }
    if (state.backoff_state.runs >= 2) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id) != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_child_id, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (child_id != 0 and child_id != state.original_child_id) {
            _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
            state.stage = 2;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor backoff delays restart -->
```zig title="test: supervisor backoff delays restart" showLineNumbers=966
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
        .name = null,
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

    var driver_state = BackoffDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
        .backoff_state = &state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = backoffDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 50);
    try std.testing.expect(!driver_state.timed_out);
}
```

<!-- snippet: zig/tests/basic.zig#func=backoffRecorderExp -->
```zig title="backoffRecorderExp(): fail once, then stop" showLineNumbers=1021
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
```

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor exponential backoff delays restart -->
```zig title="test: supervisor exponential backoff delays restart" showLineNumbers=1036
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
        .name = null,
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

    var driver_state = BackoffDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
        .backoff_state = &state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = backoffDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 30);
    try std.testing.expect(!driver_state.timed_out);
}
```

#### one_for_all: restart all children when one fails

<!-- snippet: zig/tests/basic.zig#L1091-L1099 -->
```zig title="DuoShared + DuoState: two children share counters" showLineNumbers=1091
const DuoShared = struct {
    runs_a: u32 = 0,
    runs_b: u32 = 0,
};

const DuoState = struct {
    shared: *DuoShared,
    is_a: bool,
};
```

<!-- snippet: zig/tests/basic.zig#func=duoBehavior -->
```zig title="duoBehavior(): A runs, B fails once, then both stop" showLineNumbers=1101
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
```

<!-- snippet: zig/tests/basic.zig#L1121-L1129 -->
```zig title="OneForAllDriverState: observe restart of both children" showLineNumbers=1121
const OneForAllDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_a: c.jzx_actor_id,
    original_b: c.jzx_actor_id,
    stage: u8 = 0,
    observed_restart: bool = false,
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

<!-- snippet: zig/tests/basic.zig#func=oneForAllDriver -->
```zig title="oneForAllDriver(): fail both original children, observe restarts" showLineNumbers=1131
fn oneForAllDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*OneForAllDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &id_a) != c.JZX_OK or
        c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 1, &id_b) != c.JZX_OK)
    {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_a, null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_b, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (id_a != 0 and id_b != 0 and id_a != state.original_a and id_b != state.original_b) {
            state.observed_restart = true;
            _ = c.jzx_send(ctx_ptr.loop.?, id_a, null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, id_b, null, 0, 0);
            state.stage = 2;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor one_for_all restarts all children -->
```zig title="test: supervisor one_for_all restarts all children" showLineNumbers=1170
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
            .name = null,
        },
        .{
            .behavior = duoBehavior,
            .state = &state_b,
            .mode = c.JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = null,
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

    var driver_state = OneForAllDriverState{
        .sup_id = sup_id,
        .original_a = id_a,
        .original_b = id_b,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = oneForAllDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expect(shared.runs_a >= 2);
    try std.testing.expect(shared.runs_b >= 2);
    try std.testing.expect(driver_state.observed_restart);
    try std.testing.expect(!driver_state.timed_out);
}
```

#### rest_for_one: restart downstream children only

<!-- snippet: zig/tests/basic.zig#L1245-L1254 -->
```zig title="TrioShared + TrioState: three children" showLineNumbers=1245
const TrioShared = struct {
    hits_a: u32 = 0,
    hits_b: u32 = 0,
    hits_c: u32 = 0,
};

const TrioState = struct {
    shared: *TrioShared,
    role: enum { A, B, C },
};
```

<!-- snippet: zig/tests/basic.zig#func=trioBehavior -->
```zig title="trioBehavior(): B fails to trigger rest_for_one" showLineNumbers=1256
fn trioBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TrioState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    switch (state.role) {
        .A => {
            state.shared.hits_a += 1;
            return c.JZX_BEHAVIOR_OK;
        },
        .B => {
            state.shared.hits_b += 1;
            return c.JZX_BEHAVIOR_FAIL; // trigger rest_for_one restart for B and C
        },
        .C => {
            state.shared.hits_c += 1;
            return c.JZX_BEHAVIOR_OK;
        },
    }
}
```

<!-- snippet: zig/tests/basic.zig#L1276-L1285 -->
```zig title="RestForOneDriverState: observe restart of B and C" showLineNumbers=1276
const RestForOneDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_b: c.jzx_actor_id,
    original_c: c.jzx_actor_id,
    shared: *TrioShared,
    stage: u8 = 0,
    observed_restart: bool = false,
    ticks: u32 = 0,
    timed_out: bool = false,
};
```

<!-- snippet: zig/tests/basic.zig#func=restForOneDriver -->
```zig title="restForOneDriver(): fail B, observe downstream restart" showLineNumbers=1287
fn restForOneDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestForOneDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var ids = [_]c.jzx_actor_id{0} ** 3;
    for (&ids, 0..) |*idptr, idx| {
        if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, idx, idptr) != c.JZX_OK) {
            state.timed_out = true;
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, ids[2], null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, ids[0], null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, ids[1], null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (ids[1] != 0 and ids[2] != 0 and ids[1] != state.original_b and ids[2] != state.original_c) {
            state.observed_restart = true;
            _ = c.jzx_send(ctx_ptr.loop.?, ids[2], null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, ids[0], null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, ids[1], null, 0, 0);
            state.stage = 2;
        }
    }

    if (state.stage == 2) {
        if (state.shared.hits_a >= 2 and state.shared.hits_b >= 2 and state.shared.hits_c >= 2) {
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}
```

<!-- snippet: zig/tests/basic.zig#zigtest=supervisor rest_for_one restarts downstream children -->
```zig title="test: supervisor rest_for_one restarts downstream children" showLineNumbers=1334
test "supervisor rest_for_one restarts downstream children" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var shared = TrioShared{};
    var state_a = TrioState{ .shared = &shared, .role = .A };
    var state_b = TrioState{ .shared = &shared, .role = .B };
    var state_c = TrioState{ .shared = &shared, .role = .C };

    var child_spec = [_]c.jzx_child_spec{
        .{ .behavior = trioBehavior, .state = &state_a, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
        .{ .behavior = trioBehavior, .state = &state_b, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
        .{ .behavior = trioBehavior, .state = &state_c, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_REST_FOR_ONE,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));
    var ids = [_]c.jzx_actor_id{0} ** 3;
    for (&ids, 0..) |*idptr, idx| {
        try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, idx, idptr));
        try std.testing.expect(idptr.* != 0);
    }

    var driver_state = RestForOneDriverState{
        .sup_id = sup_id,
        .original_b = ids[1],
        .original_c = ids[2],
        .shared = &shared,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = restForOneDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expect(shared.hits_a >= 2);
    try std.testing.expect(shared.hits_b >= 2);
    try std.testing.expect(shared.hits_c >= 2);
    try std.testing.expect(driver_state.observed_restart);
    try std.testing.expect(!driver_state.timed_out);
}
```

## Appendix: full file

<details>
<summary>Show full <code>zig/tests/basic.zig</code></summary>

<!-- snippet: zig/tests/basic.zig#all -->
```zig title="zig/tests/basic.zig (full source)" showLineNumbers=1
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

const ObserverState = struct {
    start_count: u32 = 0,
    stop_count: u32 = 0,
    mailbox_full_count: u32 = 0,
    last_start: c.jzx_actor_id = 0,
    last_stop: c.jzx_actor_id = 0,
    last_stop_reason: c.jzx_exit_reason = c.JZX_EXIT_NORMAL,
};

fn observerOnStart(ctx: ?*anyopaque, id: c.jzx_actor_id, name: [*c]const u8) callconv(.c) void {
    _ = name;
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.start_count += 1;
    state.last_start = id;
}

fn observerOnStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.stop_count += 1;
    state.last_stop = id;
    state.last_stop_reason = reason;
}

fn observerOnMailboxFull(ctx: ?*anyopaque, target: c.jzx_actor_id) callconv(.c) void {
    const state = @as(*ObserverState, @ptrCast(@alignCast(ctx.?)));
    state.mailbox_full_count += 1;
    _ = target;
}

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
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 5;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));

    try loop.run();
    try std.testing.expectEqual(@as(u32, 5), state);
    try std.testing.expectEqual(c.JZX_ERR_NO_SUCH_ACTOR, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 1));
}

test "actor id generations reject stale ids after slot reuse" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state_a: u32 = 0;
    var opts_a = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state_a,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_a: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_a, &actor_a));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_a, &payload, @sizeOf(u32), 0));
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), state_a);

    var state_b: u32 = 0;
    var opts_b = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state_b,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_b: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts_b, &actor_b));
    try std.testing.expect(actor_b != actor_a);

    const raw_a: u64 = @intCast(actor_a);
    const raw_b: u64 = @intCast(actor_b);
    const idx_a: u32 = @truncate(raw_a);
    const idx_b: u32 = @truncate(raw_b);
    const gen_a: u32 = @intCast(raw_a >> 32);
    const gen_b: u32 = @intCast(raw_b >> 32);
    try std.testing.expectEqual(idx_a, idx_b);
    try std.testing.expectEqual(gen_a + 1, gen_b);

    try std.testing.expectEqual(c.JZX_ERR_NO_SUCH_ACTOR, c.jzx_send(loop.ptr, actor_a, &payload, @sizeOf(u32), 0));

    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_b, &payload, @sizeOf(u32), 0));
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), state_b);
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
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));
    try std.testing.expectEqual(c.JZX_ERR_MAILBOX_FULL, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    try loop.run();
}

test "observer hooks receive lifecycle + mailbox full" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_state = ObserverState{};
    var obs = c.jzx_observer{
        .on_actor_start = observerOnStart,
        .on_actor_stop = observerOnStop,
        .on_actor_restart = null,
        .on_supervisor_escalate = null,
        .on_mailbox_full = observerOnMailboxFull,
    };
    c.jzx_loop_set_observer(loop.ptr, &obs, @ptrCast(&obs_state));

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1,
        .name = "observer-actor",
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 1;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));
    try std.testing.expectEqual(c.JZX_ERR_MAILBOX_FULL, c.jzx_send(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), obs_state.start_count);
    try std.testing.expectEqual(@as(u32, 1), obs_state.stop_count);
    try std.testing.expectEqual(@as(u32, 1), obs_state.mailbox_full_count);
    try std.testing.expectEqual(actor_id, obs_state.last_start);
    try std.testing.expectEqual(actor_id, obs_state.last_stop);
    try std.testing.expectEqual(@as(c.jzx_exit_reason, c.JZX_EXIT_NORMAL), obs_state.last_stop_reason);
}

fn async_sender(args: AsyncArgs) void {
    _ = c.jzx_send_async(args.loop, args.actor, args.payload, @sizeOf(u32), 2);
}

const SeqState = struct {
    expected: u32,
    remaining: u32,
    ok: bool = true,
};

fn seq_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const msg_ptr = @as(*const c.jzx_message, @ptrCast(msg));
    const state = @as(*SeqState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    if (state.remaining == 0) {
        return c.JZX_BEHAVIOR_STOP;
    }
    if (msg_ptr.data == null) {
        state.ok = false;
        return c.JZX_BEHAVIOR_STOP;
    }
    const value_ptr: *const u32 = @ptrCast(@alignCast(msg_ptr.data.?));
    if (value_ptr.* != state.expected) {
        state.ok = false;
        return c.JZX_BEHAVIOR_STOP;
    }
    state.expected += 1;
    state.remaining -= 1;
    return if (state.remaining == 0) c.JZX_BEHAVIOR_STOP else c.JZX_BEHAVIOR_OK;
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
        .name = null,
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

test "async send wakes blocking loop" {
    var cfg: c.jzx_config = undefined;
    c.jzx_config_init(&cfg);
    cfg.io_poll_timeout_ms = 5000;

    var loop = try jzx.Loop.create(cfg);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    std.Thread.sleep(5 * std.time.ns_per_ms);

    var payload: u32 = 9;
    const start_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_async(loop.ptr, actor_id, &payload, @sizeOf(u32), 0));

    runner.join();

    const end_ms = @as(u64, @intCast(std.time.milliTimestamp()));
    try std.testing.expect(end_ms - start_ms < 1000);
    try std.testing.expectEqual(@as(u32, 9), state);
}

test "async send preserves FIFO ordering" {
    const n: u32 = 512;

    var cfg: c.jzx_config = undefined;
    c.jzx_config_init(&cfg);
    cfg.io_poll_timeout_ms = 5000;

    var loop = try jzx.Loop.create(cfg);
    defer loop.deinit();

    var state = SeqState{ .expected = 0, .remaining = n };
    var opts = c.jzx_spawn_opts{
        .behavior = seq_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1024,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var runner = try std.Thread.spawn(.{}, struct {
        fn run(lp: *jzx.Loop) void {
            _ = lp.run() catch {};
        }
    }.run, .{&loop});

    std.Thread.sleep(5 * std.time.ns_per_ms);

    var payloads = [_]u32{0} ** n;
    var sender = try std.Thread.spawn(.{}, struct {
        fn run(lp: *c.jzx_loop, id: c.jzx_actor_id, data: []u32) void {
            for (data, 0..) |*item, idx| {
                item.* = @as(u32, @intCast(idx));
                _ = c.jzx_send_async(lp, id, item, @sizeOf(u32), 0);
            }
        }
    }.run, .{ loop.ptr, actor_id, payloads[0..] });

    sender.join();
    runner.join();

    try std.testing.expect(state.ok);
    try std.testing.expectEqual(@as(u32, 0), state.remaining);
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
        .name = null,
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
        .name = null,
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

test "timer drop when actor stops" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var state: u32 = 0;
    var opts = c.jzx_spawn_opts{
        .behavior = increment_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payload: u32 = 5;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 1, &payload, @sizeOf(u32), 0, null));
    try std.testing.expectEqual(c.JZX_OK, c.jzx_actor_stop(loop.ptr, actor_id));

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
        .name = null,
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

test "timer delivery preserves enqueue order" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    const timer_count: u32 = 32;

    var state = SeqState{
        .expected = 0,
        .remaining = timer_count,
        .ok = true,
    };
    var opts = c.jzx_spawn_opts{
        .behavior = seq_behavior,
        .state = &state,
        .supervisor = 0,
        .mailbox_cap = 1024,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &opts, &actor_id));

    var payloads = [_]u32{0} ** timer_count;
    for (&payloads, 0..) |*item, idx| {
        item.* = @as(u32, @intCast(idx));
        try std.testing.expectEqual(c.JZX_OK, c.jzx_send_after(loop.ptr, actor_id, 1, item, @sizeOf(u32), 0, null));
    }

    try loop.run();
    try std.testing.expect(state.ok);
    try std.testing.expectEqual(@as(u32, 0), state.remaining);
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

    var opts_a = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_a, .supervisor = 0, .mailbox_cap = 0, .name = null };
    var opts_b = c.jzx_spawn_opts{ .behavior = pingPongBehavior, .state = &state_b, .supervisor = 0, .mailbox_cap = 0, .name = null };
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
        c.jzx_loop_free(ctx_ptr.loop.?, data_ptr);
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
        .name = null,
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
        .name = null,
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

fn scheduleSelf(loop: *c.jzx_loop, self: c.jzx_actor_id, ms: u32) void {
    _ = c.jzx_send_after(loop, self, ms, null, 0, 0, null);
}

fn failThenStop(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return if (state.runs == 1) c.JZX_BEHAVIOR_FAIL else c.JZX_BEHAVIOR_STOP;
}

const TransientDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_child_id: c.jzx_actor_id,
    stage: u8 = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn transientDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TransientDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id) != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_child_id, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (child_id != 0 and child_id != state.original_child_id) {
            _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
            state.stage = 2;
        }
    } else {
        if (child_id == 0) {
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
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
        .name = null,
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

    var driver_state = TransientDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = transientDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), child_state.runs);
    try std.testing.expect(!driver_state.timed_out);
}

fn alwaysFail(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestartState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    state.runs += 1;
    return c.JZX_BEHAVIOR_FAIL;
}

const EscalationObsState = struct {
    sup_id: c.jzx_actor_id,
    escalations: u32 = 0,
    sup_stopped: bool = false,
    sup_stop_reason: c.jzx_exit_reason = c.JZX_EXIT_NORMAL,
};

fn escalationOnSupervisorEscalate(ctx: ?*anyopaque, supervisor: c.jzx_actor_id) callconv(.c) void {
    const state = @as(*EscalationObsState, @ptrCast(@alignCast(ctx.?)));
    if (supervisor == state.sup_id) {
        state.escalations += 1;
    }
}

fn escalationOnActorStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const state = @as(*EscalationObsState, @ptrCast(@alignCast(ctx.?)));
    if (id == state.sup_id) {
        state.sup_stopped = true;
        state.sup_stop_reason = reason;
    }
}

const EscalationDriverState = struct {
    sup_id: c.jzx_actor_id,
    obs: *EscalationObsState,
    last_child_id: c.jzx_actor_id = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn escalationDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*EscalationDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.obs.escalations > 0 or state.obs.sup_stopped) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    const rc = c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id);
    if (rc == c.JZX_ERR_NO_SUCH_ACTOR) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }
    if (rc != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (child_id != 0 and child_id != state.last_child_id) {
        _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
        state.last_child_id = child_id;
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
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
        .name = null,
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

    var obs_state = EscalationObsState{ .sup_id = sup_id };
    var obs = c.jzx_observer{
        .on_actor_start = null,
        .on_actor_stop = escalationOnActorStop,
        .on_actor_restart = null,
        .on_supervisor_escalate = escalationOnSupervisorEscalate,
        .on_mailbox_full = null,
    };
    c.jzx_loop_set_observer(loop.ptr, &obs, @ptrCast(&obs_state));

    var driver_state = EscalationDriverState{
        .sup_id = sup_id,
        .obs = &obs_state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = escalationDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 1), obs_state.escalations);
    try std.testing.expect(obs_state.sup_stopped);
    try std.testing.expectEqual(@as(c.jzx_exit_reason, c.JZX_EXIT_FAIL), obs_state.sup_stop_reason);
    try std.testing.expect(!driver_state.timed_out);
    try std.testing.expect(child_state.runs >= 3);
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

const BackoffDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_child_id: c.jzx_actor_id,
    backoff_state: *BackoffState,
    stage: u8 = 0,
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn backoffDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*BackoffDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }
    if (state.backoff_state.runs >= 2) {
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var child_id: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &child_id) != c.JZX_OK) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_child_id, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (child_id != 0 and child_id != state.original_child_id) {
            _ = c.jzx_send(ctx_ptr.loop.?, child_id, null, 0, 0);
            state.stage = 2;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
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
        .name = null,
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

    var driver_state = BackoffDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
        .backoff_state = &state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = backoffDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 50);
    try std.testing.expect(!driver_state.timed_out);
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
        .name = null,
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

    var driver_state = BackoffDriverState{
        .sup_id = sup_id,
        .original_child_id = child_id,
        .backoff_state = &state,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = backoffDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expectEqual(@as(u32, 2), state.runs);
    try std.testing.expect(state.t2_ms >= state.t1_ms + 30);
    try std.testing.expect(!driver_state.timed_out);
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

const OneForAllDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_a: c.jzx_actor_id,
    original_b: c.jzx_actor_id,
    stage: u8 = 0,
    observed_restart: bool = false,
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn oneForAllDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*OneForAllDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var id_a: c.jzx_actor_id = 0;
    var id_b: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 0, &id_a) != c.JZX_OK or
        c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, 1, &id_b) != c.JZX_OK)
    {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_a, null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, state.original_b, null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (id_a != 0 and id_b != 0 and id_a != state.original_a and id_b != state.original_b) {
            state.observed_restart = true;
            _ = c.jzx_send(ctx_ptr.loop.?, id_a, null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, id_b, null, 0, 0);
            state.stage = 2;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
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
            .name = null,
        },
        .{
            .behavior = duoBehavior,
            .state = &state_b,
            .mode = c.JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 0,
            .backoff = c.JZX_BACKOFF_NONE,
            .name = null,
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

    var driver_state = OneForAllDriverState{
        .sup_id = sup_id,
        .original_a = id_a,
        .original_b = id_b,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = oneForAllDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expect(shared.runs_a >= 2);
    try std.testing.expect(shared.runs_b >= 2);
    try std.testing.expect(driver_state.observed_restart);
    try std.testing.expect(!driver_state.timed_out);
}

const TrioShared = struct {
    hits_a: u32 = 0,
    hits_b: u32 = 0,
    hits_c: u32 = 0,
};

const TrioState = struct {
    shared: *TrioShared,
    role: enum { A, B, C },
};

fn trioBehavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*TrioState, @ptrCast(@alignCast(ctx_ptr.state.?)));
    switch (state.role) {
        .A => {
            state.shared.hits_a += 1;
            return c.JZX_BEHAVIOR_OK;
        },
        .B => {
            state.shared.hits_b += 1;
            return c.JZX_BEHAVIOR_FAIL; // trigger rest_for_one restart for B and C
        },
        .C => {
            state.shared.hits_c += 1;
            return c.JZX_BEHAVIOR_OK;
        },
    }
}

const RestForOneDriverState = struct {
    sup_id: c.jzx_actor_id,
    original_b: c.jzx_actor_id,
    original_c: c.jzx_actor_id,
    shared: *TrioShared,
    stage: u8 = 0,
    observed_restart: bool = false,
    ticks: u32 = 0,
    timed_out: bool = false,
};

fn restForOneDriver(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const state = @as(*RestForOneDriverState, @ptrCast(@alignCast(ctx_ptr.state.?)));

    state.ticks += 1;
    if (state.ticks > 5000) {
        state.timed_out = true;
        c.jzx_loop_request_stop(ctx_ptr.loop.?);
        return c.JZX_BEHAVIOR_STOP;
    }

    var ids = [_]c.jzx_actor_id{0} ** 3;
    for (&ids, 0..) |*idptr, idx| {
        if (c.jzx_supervisor_child_id(ctx_ptr.loop.?, state.sup_id, idx, idptr) != c.JZX_OK) {
            state.timed_out = true;
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    if (state.stage == 0) {
        _ = c.jzx_send(ctx_ptr.loop.?, ids[2], null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, ids[0], null, 0, 0);
        _ = c.jzx_send(ctx_ptr.loop.?, ids[1], null, 0, 0);
        state.stage = 1;
    } else if (state.stage == 1) {
        if (ids[1] != 0 and ids[2] != 0 and ids[1] != state.original_b and ids[2] != state.original_c) {
            state.observed_restart = true;
            _ = c.jzx_send(ctx_ptr.loop.?, ids[2], null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, ids[0], null, 0, 0);
            _ = c.jzx_send(ctx_ptr.loop.?, ids[1], null, 0, 0);
            state.stage = 2;
        }
    }

    if (state.stage == 2) {
        if (state.shared.hits_a >= 2 and state.shared.hits_b >= 2 and state.shared.hits_c >= 2) {
            c.jzx_loop_request_stop(ctx_ptr.loop.?);
            return c.JZX_BEHAVIOR_STOP;
        }
    }

    scheduleSelf(ctx_ptr.loop.?, ctx_ptr.self, 1);
    return c.JZX_BEHAVIOR_OK;
}

test "supervisor rest_for_one restarts downstream children" {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var shared = TrioShared{};
    var state_a = TrioState{ .shared = &shared, .role = .A };
    var state_b = TrioState{ .shared = &shared, .role = .B };
    var state_c = TrioState{ .shared = &shared, .role = .C };

    var child_spec = [_]c.jzx_child_spec{
        .{ .behavior = trioBehavior, .state = &state_a, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
        .{ .behavior = trioBehavior, .state = &state_b, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
        .{ .behavior = trioBehavior, .state = &state_c, .mode = c.JZX_CHILD_PERMANENT, .mailbox_cap = 0, .restart_delay_ms = 0, .backoff = c.JZX_BACKOFF_NONE, .name = null },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &child_spec,
        .child_count = child_spec.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_REST_FOR_ONE,
            .intensity = 5,
            .period_ms = 1000,
            .backoff = c.JZX_BACKOFF_NONE,
            .backoff_delay_ms = 0,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id));
    var ids = [_]c.jzx_actor_id{0} ** 3;
    for (&ids, 0..) |*idptr, idx| {
        try std.testing.expectEqual(c.JZX_OK, c.jzx_supervisor_child_id(loop.ptr, sup_id, idx, idptr));
        try std.testing.expect(idptr.* != 0);
    }

    var driver_state = RestForOneDriverState{
        .sup_id = sup_id,
        .original_b = ids[1],
        .original_c = ids[2],
        .shared = &shared,
    };
    var driver_opts = c.jzx_spawn_opts{
        .behavior = restForOneDriver,
        .state = &driver_state,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var driver_id: c.jzx_actor_id = 0;
    try std.testing.expectEqual(c.JZX_OK, c.jzx_spawn(loop.ptr, &driver_opts, &driver_id));
    _ = c.jzx_send(loop.ptr, driver_id, null, 0, 0);

    try loop.run();

    try std.testing.expect(shared.hits_a >= 2);
    try std.testing.expect(shared.hits_b >= 2);
    try std.testing.expect(shared.hits_c >= 2);
    try std.testing.expect(driver_state.observed_restart);
    try std.testing.expect(!driver_state.timed_out);
}
```

</details>
