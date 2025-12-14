# Observability hooks

libjzx exposes a lightweight `jzx_observer` callback table for actor lifecycle, supervision, and mailbox backpressure events.

The observer is intended for metrics collection, structured logging, and CI smoke/stress tooling.

## API

- `jzx_loop_set_observer(loop, &obs, ctx)` installs callbacks + a user context pointer.
- `jzx_loop_set_observer(loop, NULL, NULL)` clears the observer.

All callbacks:

- Run on the loop owner thread (the thread calling `jzx_loop_run`).
- Must be non-blocking and fast (avoid allocations and re-entrancy into runtime APIs).

## Events

- `on_actor_start(ctx, id, name)`: after a successful spawn; `name` may be `NULL`.
- `on_actor_stop(ctx, id, reason)`: after teardown; `reason` is `JZX_EXIT_NORMAL`, `JZX_EXIT_FAIL`, or `JZX_EXIT_PANIC`.
- `on_actor_restart(ctx, supervisor, child, attempt)`: when a supervisor restarts a child.
- `on_supervisor_escalate(ctx, supervisor)`: when a supervisor hits its intensity limit and escalates/fails.
- `on_mailbox_full(ctx, target)`: when a send fails with `JZX_ERR_MAILBOX_FULL`.

## C usage

```c
typedef struct {
    uint32_t starts;
    uint32_t stops;
    uint32_t mailbox_full;
} obs_counts;

static void on_start(void* ctx, jzx_actor_id id, const char* name) {
    (void)id;
    (void)name;
    ((obs_counts*)ctx)->starts++;
}

static void on_stop(void* ctx, jzx_actor_id id, jzx_exit_reason reason) {
    (void)id;
    (void)reason;
    ((obs_counts*)ctx)->stops++;
}

static void on_mailbox_full(void* ctx, jzx_actor_id target) {
    (void)target;
    ((obs_counts*)ctx)->mailbox_full++;
}

obs_counts counts = {0};
jzx_observer obs = {
    .on_actor_start = on_start,
    .on_actor_stop = on_stop,
    .on_actor_restart = NULL,
    .on_supervisor_escalate = NULL,
    .on_mailbox_full = on_mailbox_full,
};
jzx_loop_set_observer(loop, &obs, &counts);
```

## Zig usage

The Zig wrapper can call into the same C ABI observer struct. See `zig/tests/basic.zig` for a runnable example.

## Stress tooling

`tools/stress.zig` wires an observer sink that counts events per scenario and prints a compact summary.

Run the default smoke set (used in CI):

```sh
zig build stress
```

Enable verbose event logging and/or pick scenarios:

```sh
zig build stress -- --verbose
zig build stress -- --mailbox
zig build stress -- --pingpong --timers --restarts --mailbox
zig build stress -- --no-observer
```

