---
title: Stress tool — tools/stress.zig
---

# Stress tool — `tools/stress.zig`

This file implements a runnable “stress harness” for libjzx. It is designed to exercise the runtime in ways that are relevant to systems engineering:

- **Fairness / scheduling** under sustained message traffic (ping-pong)
- **Timer throughput** and delivery correctness (timer storm)
- **Supervisor restarts** and async cross-thread sends (restart thrash)
- **Mailbox backpressure** behavior + observer correctness (mailbox pressure)

The code intentionally uses small, bounded scenarios that either:

- finish by themselves (actors stop), or
- request loop stop explicitly, so it can be used in CI.

This page follows the “textbook” style: small snippets with immediate explanation.

## Cross-links

- Start here: [Source index](source-index)
- Design intent: [Design goals](../concepts/design-goals)
- Contracts exercised: [Configuration reference](../reference/config-reference), [Observer callbacks](include-jzx-jzx-h#observability)
- Under the hood: [Runtime core (`src/jzx_runtime.c`)](src-jzx-runtime-c)

## Imports and C ABI access

<!-- snippet: tools/stress.zig#L1-L3 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L1-L3"><code>tools/stress.zig#L1-L3</code></a></div>
```zig title="Imports" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
```

What each import is doing:

- `std`: Zig standard library (printing, time, threads, arg parsing, etc).
- `jzx`: the Zig wrapper module provided by `zig/jzx/lib.zig`.
- `c = jzx.c`: the wrapper exposes the C ABI types/functions through `@cImport`; this alias makes them convenient to reference.

Why this file uses `c.*` directly (instead of only the wrapper):

- Stress tests often want to call the ABI surface directly (what other languages would see).
- The wrapper is still used for higher-level conveniences like `jzx.Loop.create()` and `loop.requestStop()`.

## Run configuration flags

`RunConfig` is the common “knob bundle” shared by all scenarios.

<!-- snippet: tools/stress.zig#L5-L9 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L5-L9"><code>tools/stress.zig#L5-L9</code></a></div>
```zig title="RunConfig" showLineNumbers=5
const RunConfig = struct {
    smoke: bool,
    use_observer: bool,
    verbose: bool,
};
```

Intent of each field:

- `smoke`: make runs shorter (CI-friendly).
- `use_observer`: attach an observer so we can validate lifecycle/backpressure events.
- `verbose`: print each observer event (useful when debugging behavior).

## Observer accounting

The stress harness uses the observer hook table to count events and (optionally) print them.

### Counters

<!-- snippet: tools/stress.zig#L11-L20 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L11-L20"><code>tools/stress.zig#L11-L20</code></a></div>
```zig title="ObserverStats: per-scenario counters" showLineNumbers=11
const ObserverStats = struct {
    actor_start: u32 = 0,
    actor_stop: u32 = 0,
    actor_stop_normal: u32 = 0,
    actor_stop_fail: u32 = 0,
    actor_stop_panic: u32 = 0,
    actor_restart: u32 = 0,
    supervisor_escalate: u32 = 0,
    mailbox_full: u32 = 0,
};
```

Why it exists:

- Stress tests shouldn’t only “run without crashing”; they should validate **contracts**:
  - “does the observer fire when mailboxes are full?”
  - “does the runtime classify exits correctly?”
  - “are restarts observable?”

### Observer context (“sink”)

Each observer callback receives a `ctx` pointer. The harness uses that `ctx` as a pointer to an `ObserverSink`.

<!-- snippet: tools/stress.zig#L22-L26 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L22-L26"><code>tools/stress.zig#L22-L26</code></a></div>
```zig title="ObserverSink: passed via observer ctx" showLineNumbers=22
const ObserverSink = struct {
    scenario: []const u8,
    verbose: bool,
    stats: *ObserverStats,
};
```

- `scenario`: a human label (`"pingpong"`, `"timers"`, …) included in logs.
- `verbose`: copied from `RunConfig` so callbacks can early-return quickly.
- `stats`: a pointer to the counter struct that callbacks increment.

### Callback: actor start

<!-- snippet: tools/stress.zig#func=obsActorStart -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L28-L38"><code>tools/stress.zig#L28-L38</code></a></div>
```zig title="obsActorStart(): count + optionally print" showLineNumbers=28
fn obsActorStart(ctx: ?*anyopaque, id: c.jzx_actor_id, name: [*c]const u8) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_start += 1;
    if (!sink.verbose) return;
    if (@intFromPtr(name) != 0) {
        const zname: [*:0]const u8 = @ptrCast(name);
        std.debug.print("[{s}] actor_start id={d} name={s}\n", .{ sink.scenario, id, std.mem.span(zname) });
    } else {
        std.debug.print("[{s}] actor_start id={d}\n", .{ sink.scenario, id });
    }
}
```

Deep explanation:

- `callconv(.c)` makes this function ABI-compatible with the C callback signature in `jzx_observer`.
- `ctx: ?*anyopaque` is an opaque pointer coming from the runtime.
  - The `?` means it can be null; this code uses `ctx.?` to assert non-null.
  - Why it’s safe here: `setupObserver` always passes a valid sink pointer.
- `@alignCast` + `@ptrCast` converts `ctx` into `*ObserverSink`.
  - Why it exists: `anyopaque` is intentionally untyped, so Zig requires an explicit cast.
- `name: [*c]const u8` is a C pointer (may be null).
  - The code checks `@intFromPtr(name) != 0` to detect null.
  - If non-null, it casts to a sentinel-terminated string `[ *:0 ]const u8` and uses `std.mem.span` to get a normal slice for printing.

### Callback: actor stop

<!-- snippet: tools/stress.zig#func=obsActorStop -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L40-L51"><code>tools/stress.zig#L40-L51</code></a></div>
```zig title="obsActorStop(): count exit reasons" showLineNumbers=40
fn obsActorStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_stop += 1;
    switch (reason) {
        c.JZX_EXIT_NORMAL => sink.stats.actor_stop_normal += 1,
        c.JZX_EXIT_FAIL => sink.stats.actor_stop_fail += 1,
        c.JZX_EXIT_PANIC => sink.stats.actor_stop_panic += 1,
        else => {},
    }
    if (!sink.verbose) return;
    std.debug.print("[{s}] actor_stop id={d} reason={d}\n", .{ sink.scenario, id, @as(u32, @intCast(reason)) });
}
```

What’s going on:

- `reason` is a C enum (`c.jzx_exit_reason`).
- The `switch` buckets stops into:
  - “normal” stop (behavior returned `STOP`)
  - “fail” stop (behavior returned `FAIL`)
  - “panic” stop (internal/runtime panic path)
- The debug print casts the enum to an integer to keep logging simple.

### Callback: actor restart

<!-- snippet: tools/stress.zig#func=obsActorRestart -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L53-L58"><code>tools/stress.zig#L53-L58</code></a></div>
```zig title="obsActorRestart(): restart attempt counter" showLineNumbers=53
fn obsActorRestart(ctx: ?*anyopaque, supervisor: c.jzx_actor_id, child: c.jzx_actor_id, attempt: u32) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_restart += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] actor_restart supervisor={d} child={d} attempt={d}\n", .{ sink.scenario, supervisor, child, attempt });
}
```

This callback is meant to validate:

- restarts are observable,
- restart attempts increment,
- supervisor/child linkage is preserved in the signal.

### Callback: supervisor escalation

<!-- snippet: tools/stress.zig#func=obsSupervisorEscalate -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L60-L65"><code>tools/stress.zig#L60-L65</code></a></div>
```zig title="obsSupervisorEscalate(): count escalation events" showLineNumbers=60
fn obsSupervisorEscalate(ctx: ?*anyopaque, supervisor: c.jzx_actor_id) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.supervisor_escalate += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] supervisor_escalate supervisor={d}\n", .{ sink.scenario, supervisor });
}
```

Escalation typically means:

- the supervisor hit a restart-intensity limit (crash loop defense), or
- the supervisor decided the failure couldn’t be recovered locally.

### Callback: mailbox full

<!-- snippet: tools/stress.zig#func=obsMailboxFull -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L67-L72"><code>tools/stress.zig#L67-L72</code></a></div>
```zig title="obsMailboxFull(): count backpressure events" showLineNumbers=67
fn obsMailboxFull(ctx: ?*anyopaque, target: c.jzx_actor_id) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.mailbox_full += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] mailbox_full target={d}\n", .{ sink.scenario, target });
}
```

This callback is the bridge between a runtime invariant and an observable contract:

- Invariant: a bounded mailbox must reject pushes once at capacity.
- Contract: rejections should be visible to operators/tests (so overload is diagnosable).

### Installing the observer table

<!-- snippet: tools/stress.zig#func=setupObserver -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L74-L83"><code>tools/stress.zig#L74-L83</code></a></div>
```zig title="setupObserver(): populate jzx_observer and install it" showLineNumbers=74
fn setupObserver(loop: *c.jzx_loop, sink: *ObserverSink) void {
    var obs = c.jzx_observer{
        .on_actor_start = obsActorStart,
        .on_actor_stop = obsActorStop,
        .on_actor_restart = obsActorRestart,
        .on_supervisor_escalate = obsSupervisorEscalate,
        .on_mailbox_full = obsMailboxFull,
    };
    c.jzx_loop_set_observer(loop, &obs, @ptrCast(sink));
}
```

Important details:

- `c.jzx_observer` is a C struct of function pointers.
- Passing `@ptrCast(sink)` as the observer context is what makes `ctx` non-null in callbacks.
- The observer is installed per-loop, so each scenario can have its own counters/verbosity.

### Printing a summary line

<!-- snippet: tools/stress.zig#func=printObserverSummary -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L85-L100"><code>tools/stress.zig#L85-L100</code></a></div>
```zig title="printObserverSummary(): one-line report" showLineNumbers=85
fn printObserverSummary(label: []const u8, stats: ObserverStats) void {
    std.debug.print(
        "observer {s}: start={d} stop={d} (normal={d} fail={d} panic={d}) restart={d} escalate={d} mailbox_full={d}\n",
        .{
            label,
            stats.actor_start,
            stats.actor_stop,
            stats.actor_stop_normal,
            stats.actor_stop_fail,
            stats.actor_stop_panic,
            stats.actor_restart,
            stats.supervisor_escalate,
            stats.mailbox_full,
        },
    );
}
```

This is the “operator UX” for the stress tool:

- It compresses a whole run into one line, which is perfect for CI logs.

## CLI parsing and scenario selection (`main`)

<!-- snippet: tools/stress.zig#func=main -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L102-L150"><code>tools/stress.zig#L102-L150</code></a></div>
```zig title="main(): parse flags and dispatch scenarios" showLineNumbers=102
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    var cfg = RunConfig{
        .smoke = false,
        .use_observer = true,
        .verbose = false,
    };

    var run_pingpong = false;
    var run_timers = false;
    var run_restarts = false;
    var run_mailbox = false;
    var any_selected = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            cfg.smoke = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-observer")) {
            cfg.use_observer = false;
        } else if (std.mem.eql(u8, arg, "--pingpong")) {
            run_pingpong = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--timers")) {
            run_timers = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--restarts")) {
            run_restarts = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--mailbox")) {
            run_mailbox = true;
            any_selected = true;
        }
    }

    if (!any_selected) {
        run_pingpong = true;
        run_timers = true;
        run_restarts = true;
        run_mailbox = true;
    }

    if (run_pingpong) try runPingPong(cfg);
    if (run_timers) try runTimerStorm(cfg);
    if (run_restarts) try runRestartThrash(cfg);
    if (run_mailbox) try runMailboxPressure(cfg);
}
```

Key UX choices:

- If the user doesn’t specify a scenario flag, the tool runs **all** scenarios.
- `--smoke` scales scenarios down so the tool can run in CI.
- `--no-observer` allows focusing purely on runtime throughput without observer overhead.
- `--verbose` is useful when diagnosing unexpected behavior (but very noisy).

## Shared error type

<!-- snippet: tools/stress.zig#L152-L154 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L152-L154"><code>tools/stress.zig#L152-L154</code></a></div>
```zig title="StressError: unified failure for CI" showLineNumbers=152
const StressError = error{
    StressFailed,
};
```

Why it exists:

- Each scenario returns `!void`.
- Returning `StressError.StressFailed` provides a single failure mode for CI to detect.

## Scenario 1: Ping-pong (scheduler fairness)

This scenario creates two actors and has them bounce messages back and forth.

The *mechanical goal* is throughput.

The *systems goal* is fairness: both actors should receive many messages, not just one.

### State layout

<!-- snippet: tools/stress.zig#L156-L161 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L156-L161"><code>tools/stress.zig#L156-L161</code></a></div>
```zig title="PingPongState" showLineNumbers=156
const PingPongState = struct {
    loop: *c.jzx_loop,
    partner: c.jzx_actor_id = 0,
    remaining: u32,
    hits: u32 = 0,
};
```

What each field means:

- `loop`: C loop pointer used by the behavior to send to the partner.
- `partner`: actor id of the other ping-pong participant.
  - Initialized after both actors are spawned (because ids are assigned by the runtime).
- `remaining`: budget of remaining sends (per actor).
- `hits`: number of messages processed (used as a sanity/fairness check).

### Behavior

<!-- snippet: tools/stress.zig#func=pingPongBehavior -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L163-L176"><code>tools/stress.zig#L163-L176</code></a></div>
```zig title="pingPongBehavior(): bounce messages until budget is exhausted" showLineNumbers=163
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
```

Important details:

- The message payload is ignored; the message itself is just a “tick”.
- The actor stops itself once its `remaining` budget reaches zero.
  - This is what makes the scenario terminate without an external stop request.
- It uses `jzx_send` (synchronous enqueue) because everything happens on the loop thread.

### Scenario wiring

<!-- snippet: tools/stress.zig#func=runPingPong -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L178-L240"><code>tools/stress.zig#L178-L240</code></a></div>
```zig title="runPingPong(): spawn two actors and measure" showLineNumbers=178
fn runPingPong(cfg: RunConfig) !void {
    const iterations: u32 = if (cfg.smoke) 50_000 else 500_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "pingpong", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("pingpong", obs_stats);
    }
}
```

Why this gives a fairness signal:

- If scheduling were badly biased, one actor could starve the other and you’d see `hits` collapse.
- The `iterations / 2` check is a coarse “both sides made progress” assertion.

## Scenario 2: Timer storm (timer delivery correctness)

This scenario creates **one actor** and schedules many timers to send it messages.

### State + behavior

<!-- snippet: tools/stress.zig#L242-L256 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L242-L256"><code>tools/stress.zig#L242-L256</code></a></div>
```zig title="TimerState and timerBehavior()" showLineNumbers=242
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
```

The actor stops itself once it has received `target` timer messages.

### Scenario wiring

<!-- snippet: tools/stress.zig#func=runTimerStorm -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L258-L300"><code>tools/stress.zig#L258-L300</code></a></div>
```zig title="runTimerStorm(): schedule many timers" showLineNumbers=258
fn runTimerStorm(cfg: RunConfig) !void {
    const timer_count: u32 = if (cfg.smoke) 2000 else 20_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "timers", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("timers", obs_stats);
    }
}
```

What this validates:

- Timer scheduling doesn’t drop events.
- Timer delivery wakes the loop and schedules the target actor correctly.
- Under load, the mailbox + scheduler still processes all messages.

## Scenario 3: Restart thrash (supervision + async cross-thread send)

This scenario sets up a supervisor with a child that always fails, and then repeatedly pokes it using `jzx_send_async`.

### Child state + always-fail behavior

<!-- snippet: tools/stress.zig#L302-L312 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L302-L312"><code>tools/stress.zig#L302-L312</code></a></div>
```zig title="RestartState + alwaysFail()" showLineNumbers=302
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
```

Why count `runs`:

- Each run represents one delivery into the child before it fails.
- It’s a simple “did the supervisor actually restart the child?” signal.

### Scenario wiring

<!-- snippet: tools/stress.zig#func=runRestartThrash -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L314-L378"><code>tools/stress.zig#L314-L378</code></a></div>
```zig title="runRestartThrash(): supervise a failing child and poke it asynchronously" showLineNumbers=314
fn runRestartThrash(cfg: RunConfig) !void {
    const iterations: u32 = if (cfg.smoke) 100 else 1000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "restarts", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("restarts", obs_stats);
    }
}
```

Why this scenario uses a second thread:

- `loop.run()` is a blocking call (it owns the loop thread).
- The harness wants to send messages concurrently while the loop is running.

Why it uses `jzx_send_async`:

- `jzx_send` is intended for the loop thread (it enqueues directly into actor mailboxes).
- `jzx_send_async` is designed for cross-thread sending:
  - it enqueues into an async queue protected by a mutex,
  - then wakes the loop so it can drain and deliver those messages safely.

What this validates:

- Supervisor restarts continue functioning under concurrent send pressure.
- The async wakeup path is correct (no deadlocks, no missed wakeups).

## Scenario 4: Mailbox pressure (bounded queue + observer contract)

This scenario spawns one actor with a **small mailbox capacity** and then attempts to overfill it.

### Drain behavior

<!-- snippet: tools/stress.zig#func=drain_behavior -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L380-L385"><code>tools/stress.zig#L380-L385</code></a></div>
```zig title="drain_behavior(): stop the loop after one message" showLineNumbers=380
fn drain_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    c.jzx_loop_request_stop(ctx_ptr.loop.?);
    return c.JZX_BEHAVIOR_STOP;
}
```

This actor is intentionally boring:

- It requests loop stop immediately to make the scenario terminate deterministically.
- It returns `STOP` so the actor also terminates cleanly.

### Scenario wiring

<!-- snippet: tools/stress.zig#func=runMailboxPressure -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L387-L433"><code>tools/stress.zig#L387-L433</code></a></div>
```zig title="runMailboxPressure(): overfill a mailbox and check observer counters" showLineNumbers=387
fn runMailboxPressure(cfg: RunConfig) !void {
    const cap: u32 = 8;
    const extra: u32 = if (cfg.smoke) 16 else 1024;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "mailbox", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

    var opts = c.jzx_spawn_opts{
        .behavior = drain_behavior,
        .state = null,
        .supervisor = 0,
        .mailbox_cap = cap,
        .name = "stress-mailbox",
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        return StressError.StressFailed;
    }

    var ok_sends: u32 = 0;
    var full_sends: u32 = 0;
    for (0..(cap + extra)) |_| {
        const rc = c.jzx_send(loop.ptr, actor_id, null, 0, 0);
        if (rc == c.JZX_OK) {
            ok_sends += 1;
        } else if (rc == c.JZX_ERR_MAILBOX_FULL) {
            full_sends += 1;
        } else {
            return StressError.StressFailed;
        }
    }

    try loop.run();
    std.debug.print("stress mailbox: ok={d} full={d}\n", .{ ok_sends, full_sends });
    if (cfg.use_observer) {
        printObserverSummary("mailbox", obs_stats);
        if (obs_stats.mailbox_full != full_sends) {
            return StressError.StressFailed;
        }
    }
}
```

What this validates:

- `mailbox_cap` is honored (bounded mailbox is actually bounded).
- The runtime returns `JZX_ERR_MAILBOX_FULL` as a backpressure signal.
- If the observer is installed, it fires exactly once per rejected enqueue.

## Full listing (for reference)

<!-- snippet: tools/stress.zig#all -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/tools/stress.zig#L1-L433"><code>tools/stress.zig#L1-L433</code></a></div>
```zig title="tools/stress.zig" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

const RunConfig = struct {
    smoke: bool,
    use_observer: bool,
    verbose: bool,
};

const ObserverStats = struct {
    actor_start: u32 = 0,
    actor_stop: u32 = 0,
    actor_stop_normal: u32 = 0,
    actor_stop_fail: u32 = 0,
    actor_stop_panic: u32 = 0,
    actor_restart: u32 = 0,
    supervisor_escalate: u32 = 0,
    mailbox_full: u32 = 0,
};

const ObserverSink = struct {
    scenario: []const u8,
    verbose: bool,
    stats: *ObserverStats,
};

fn obsActorStart(ctx: ?*anyopaque, id: c.jzx_actor_id, name: [*c]const u8) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_start += 1;
    if (!sink.verbose) return;
    if (@intFromPtr(name) != 0) {
        const zname: [*:0]const u8 = @ptrCast(name);
        std.debug.print("[{s}] actor_start id={d} name={s}\n", .{ sink.scenario, id, std.mem.span(zname) });
    } else {
        std.debug.print("[{s}] actor_start id={d}\n", .{ sink.scenario, id });
    }
}

fn obsActorStop(ctx: ?*anyopaque, id: c.jzx_actor_id, reason: c.jzx_exit_reason) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_stop += 1;
    switch (reason) {
        c.JZX_EXIT_NORMAL => sink.stats.actor_stop_normal += 1,
        c.JZX_EXIT_FAIL => sink.stats.actor_stop_fail += 1,
        c.JZX_EXIT_PANIC => sink.stats.actor_stop_panic += 1,
        else => {},
    }
    if (!sink.verbose) return;
    std.debug.print("[{s}] actor_stop id={d} reason={d}\n", .{ sink.scenario, id, @as(u32, @intCast(reason)) });
}

fn obsActorRestart(ctx: ?*anyopaque, supervisor: c.jzx_actor_id, child: c.jzx_actor_id, attempt: u32) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.actor_restart += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] actor_restart supervisor={d} child={d} attempt={d}\n", .{ sink.scenario, supervisor, child, attempt });
}

fn obsSupervisorEscalate(ctx: ?*anyopaque, supervisor: c.jzx_actor_id) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.supervisor_escalate += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] supervisor_escalate supervisor={d}\n", .{ sink.scenario, supervisor });
}

fn obsMailboxFull(ctx: ?*anyopaque, target: c.jzx_actor_id) callconv(.c) void {
    const sink = @as(*ObserverSink, @ptrCast(@alignCast(ctx.?)));
    sink.stats.mailbox_full += 1;
    if (!sink.verbose) return;
    std.debug.print("[{s}] mailbox_full target={d}\n", .{ sink.scenario, target });
}

fn setupObserver(loop: *c.jzx_loop, sink: *ObserverSink) void {
    var obs = c.jzx_observer{
        .on_actor_start = obsActorStart,
        .on_actor_stop = obsActorStop,
        .on_actor_restart = obsActorRestart,
        .on_supervisor_escalate = obsSupervisorEscalate,
        .on_mailbox_full = obsMailboxFull,
    };
    c.jzx_loop_set_observer(loop, &obs, @ptrCast(sink));
}

fn printObserverSummary(label: []const u8, stats: ObserverStats) void {
    std.debug.print(
        "observer {s}: start={d} stop={d} (normal={d} fail={d} panic={d}) restart={d} escalate={d} mailbox_full={d}\n",
        .{
            label,
            stats.actor_start,
            stats.actor_stop,
            stats.actor_stop_normal,
            stats.actor_stop_fail,
            stats.actor_stop_panic,
            stats.actor_restart,
            stats.supervisor_escalate,
            stats.mailbox_full,
        },
    );
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    var cfg = RunConfig{
        .smoke = false,
        .use_observer = true,
        .verbose = false,
    };

    var run_pingpong = false;
    var run_timers = false;
    var run_restarts = false;
    var run_mailbox = false;
    var any_selected = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            cfg.smoke = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-observer")) {
            cfg.use_observer = false;
        } else if (std.mem.eql(u8, arg, "--pingpong")) {
            run_pingpong = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--timers")) {
            run_timers = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--restarts")) {
            run_restarts = true;
            any_selected = true;
        } else if (std.mem.eql(u8, arg, "--mailbox")) {
            run_mailbox = true;
            any_selected = true;
        }
    }

    if (!any_selected) {
        run_pingpong = true;
        run_timers = true;
        run_restarts = true;
        run_mailbox = true;
    }

    if (run_pingpong) try runPingPong(cfg);
    if (run_timers) try runTimerStorm(cfg);
    if (run_restarts) try runRestartThrash(cfg);
    if (run_mailbox) try runMailboxPressure(cfg);
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

fn runPingPong(cfg: RunConfig) !void {
    const iterations: u32 = if (cfg.smoke) 50_000 else 500_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "pingpong", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("pingpong", obs_stats);
    }
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

fn runTimerStorm(cfg: RunConfig) !void {
    const timer_count: u32 = if (cfg.smoke) 2000 else 20_000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "timers", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("timers", obs_stats);
    }
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

fn runRestartThrash(cfg: RunConfig) !void {
    const iterations: u32 = if (cfg.smoke) 100 else 1000;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "restarts", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

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
    if (cfg.use_observer) {
        printObserverSummary("restarts", obs_stats);
    }
}

fn drain_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    c.jzx_loop_request_stop(ctx_ptr.loop.?);
    return c.JZX_BEHAVIOR_STOP;
}

fn runMailboxPressure(cfg: RunConfig) !void {
    const cap: u32 = 8;
    const extra: u32 = if (cfg.smoke) 16 else 1024;

    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var obs_stats = ObserverStats{};
    var sink = ObserverSink{ .scenario = "mailbox", .verbose = cfg.verbose, .stats = &obs_stats };
    if (cfg.use_observer) {
        setupObserver(loop.ptr, &sink);
    }

    var opts = c.jzx_spawn_opts{
        .behavior = drain_behavior,
        .state = null,
        .supervisor = 0,
        .mailbox_cap = cap,
        .name = "stress-mailbox",
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        return StressError.StressFailed;
    }

    var ok_sends: u32 = 0;
    var full_sends: u32 = 0;
    for (0..(cap + extra)) |_| {
        const rc = c.jzx_send(loop.ptr, actor_id, null, 0, 0);
        if (rc == c.JZX_OK) {
            ok_sends += 1;
        } else if (rc == c.JZX_ERR_MAILBOX_FULL) {
            full_sends += 1;
        } else {
            return StressError.StressFailed;
        }
    }

    try loop.run();
    std.debug.print("stress mailbox: ok={d} full={d}\n", .{ ok_sends, full_sends });
    if (cfg.use_observer) {
        printObserverSummary("mailbox", obs_stats);
        if (obs_stats.mailbox_full != full_sends) {
            return StressError.StressFailed;
        }
    }
}
```
