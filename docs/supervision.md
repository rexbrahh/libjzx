# Supervision quickstart

This runtime uses a built-in supervisor actor to monitor children and restart them according to familiar Erlang/OTP-style rules.

## Concepts
- **Child spec**: defines the child behavior, mode (permanent/transient/temporary), mailbox cap, restart delay, and optional backoff type (none/constant/exponential).
- **Supervisor spec**: strategy (one-for-one/one-for-all/rest-for-one), restart intensity window (intensity + period_ms), default backoff type + delay step.
- **System messages**: child teardown emits `JZX_TAG_SYS_CHILD_EXIT`; restart timers use `JZX_TAG_SYS_CHILD_RESTART`.

## C usage
```c
// Define child behavior
static jzx_behavior_result flapping(jzx_context* ctx, const jzx_message* msg) { /* ... */ }

jzx_child_spec children[] = {
    {
        .behavior = flapping,
        .state = NULL,
        .mode = JZX_CHILD_PERMANENT,
        .restart_delay_ms = 100,
        .backoff = JZX_BACKOFF_EXPONENTIAL,
    },
};
jzx_supervisor_init sup_init = {
    .children = children,
    .child_count = 1,
    .supervisor = {
        .strategy = JZX_SUP_ONE_FOR_ONE,
        .intensity = 5,
        .period_ms = 2000,
        .backoff = JZX_BACKOFF_EXPONENTIAL,
        .backoff_delay_ms = 100,
    },
};
jzx_actor_id sup_id = 0;
jzx_spawn_supervisor(loop, &sup_init, 0, &sup_id);
jzx_actor_id child_id = 0;
jzx_supervisor_child_id(loop, sup_id, 0, &child_id);
```

## Zig usage
See `examples/zig/supervisor.zig` for a runnable sample mirroring the C example. It shows how to export a C ABI behavior, set up a supervisor, and send the first message to a child.

## Behavior
- Permanent children always restart; transient restart only on failure; temporary never restart.
- Intensity limit (intensity/period_ms) triggers supervisor failure and stops dependents.
- Backoff: per-child setting wins; otherwise supervisor default. Constant adds `backoff_delay_ms * restart_count`; exponential doubles each attempt (saturating).
