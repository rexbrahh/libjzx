---
title: Configuration
sidebar_position: 1
---

# Configuration

libjzx configuration lives at a few layers:

- Build-time wiring (dependencies + build graph)
- Runtime knobs (loop/scheduler/mailbox parameters)
- Observability (observer callbacks)

## Build-time wiring

- [`build.zig.zon`](../deep-dive/build-zig-zon): minimum Zig version + pinned `libxev` dependency.
- [`build.zig`](../deep-dive/build-zig): how the runtime (C + Zig) is compiled, plus tests/examples/stress.

## Runtime knobs

Start here:

- [Configuration reference](../reference/config-reference)

Important pattern:

- Call `jzx_config_init(&cfg)` first, then override fields you care about.

## Observer callbacks

The observer interface is a callback table installed per-loop via `jzx_loop_set_observer(...)`.

Deep dive entry points:

- [C ABI walkthrough (`include/jzx/jzx.h`)](../deep-dive/include-jzx-jzx-h)
- [Stress tool walkthrough (`tools/stress.zig`)](../deep-dive/tools-stress-zig)

Callback contract (practical guidance):

- Callbacks run **synchronously** (inline) when the runtime emits the event.
- Keep callbacks fast and non-blocking:
  - avoid I/O, locks, or heavy allocation unless you know it’s safe for your workload.
- Treat the observer context pointer (`ctx`) as loop-owned configuration:
  - it must remain valid for as long as the observer is installed.
