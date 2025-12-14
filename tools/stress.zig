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
