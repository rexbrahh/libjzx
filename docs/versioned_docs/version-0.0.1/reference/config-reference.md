---
title: Configuration reference
sidebar_position: 2
---

# Configuration reference

The core runtime configuration type is `jzx_config` (C ABI), initialized via `jzx_config_init(&cfg)`.

Important behavior:

- `jzx_config_init` sets concrete defaults.
- `jzx_loop_create` also applies defaults for “unset” fields (zero values).

This means you can typically:

1. start with `jzx_config_init`
2. override only the fields you care about
3. pass it to `jzx_loop_create`

## Defaults at a glance

Defaults are defined in `src/jzx_runtime.c` in `jzx_config_init()` and `apply_defaults()`.

Current defaults:

- `allocator`: `malloc` / `free` (with `ctx = NULL`)
- `max_actors`: `1024`
- `default_mailbox_cap`: `1024`
- `max_msgs_per_actor`: `64`
- `max_actors_per_tick`: `1024`
- `max_io_watchers`: `1024`
- `io_poll_timeout_ms`: `10`

## Field-by-field reference

### `allocator`

Type: `jzx_allocator`

Controls all allocations performed by the loop (actors, mailboxes, timers, internal events).

Rules:

- If `allocator.alloc` is null, the runtime falls back to its default allocator.
- If `allocator.free` is null, the runtime falls back to its default free function.

Why it exists:

- systems code often needs allocator control (arenas, tracing allocators, embedded constraints).

### `max_actors`

Type: `uint32_t` (capacity)

What it controls:

- the actor table capacity (how many actors can exist at once)

Why it exists:

- actor ids encode a table index; bounding the table bounds memory usage and keeps lookup O(1).

Failure mode:

- spawning beyond capacity returns `JZX_ERR_MAX_ACTORS`.

### `default_mailbox_cap`

Type: `uint32_t` (capacity)

What it controls:

- default mailbox capacity used when an actor is spawned with `mailbox_cap = 0`.

Why it exists:

- provides backpressure and memory bounds without forcing every spawn site to choose a number.

### `max_msgs_per_actor`

Type: `uint32_t` (budget)

What it controls:

- how many messages one actor can process per scheduling run (“per tick of that actor”).

Why it exists:

- prevents one hot actor from monopolizing a loop tick and starving others.

### `max_actors_per_tick`

Type: `uint32_t` (budget)

What it controls:

- how many runnable actors are processed per outer loop iteration (“global tick”).

Why it exists:

- bounds per-iteration latency and improves responsiveness under load.

### `max_io_watchers`

Type: `uint32_t` (capacity)

What it controls:

- how many file descriptors can be watched simultaneously.

Why it exists:

- bounds memory for watcher tables and backend registrations.

### `io_poll_timeout_ms`

Type: `uint32_t` (milliseconds)

What it controls:

- how long the loop will wait in the I/O backend when there is no runnable work.

Why it exists:

- prevents a pure busy-loop when the system is idle while still allowing timely wakeups.

## Related configuration surfaces

- Spawn-time knobs: `jzx_spawn_opts` (per-actor mailbox cap, supervisor linkage, name).
- Supervision knobs: `jzx_supervisor_init` and `jzx_child_spec` (restart strategy, intensity, backoff).

For deep-dive walkthroughs, start at:

- [Source index](../deep-dive/source-index)
