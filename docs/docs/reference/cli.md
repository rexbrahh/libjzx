---
title: CLI
sidebar_position: 1
---

# CLI

libjzx does not currently ship a single “jzx” CLI, but the repository does include a few runnable commands via `zig build`.

## Zig build entry points

From the repo root:

```sh
zig build
zig build test
zig build examples
zig build stress
zig build fmt
```

## Installed binaries

After building, executables are installed under `zig-out/bin/`.

### Examples (via `zig build examples`)

- `zig-out/bin/zig-example` — minimal spawn/send/stop (`examples/zig/ping.zig`)
- `zig-out/bin/zig-typed-actor` — typed wrapper demo (`examples/zig/typed_actor.zig`)
- `zig-out/bin/zig-supervisor` — supervisor restart demo (`examples/zig/supervisor.zig`)
- `zig-out/bin/zig-echo-server` — TCP echo server (`examples/zig/echo_server.zig`)
  - Optional arg: `zig-out/bin/zig-echo-server <port>` (default `5555`)

### Stress tool (via `zig build stress` or direct run)

- `zig-out/bin/jzx-stress` — runtime stress harness (`tools/stress.zig`)

Flags:

- `--smoke` — reduce iteration counts for quick runs
- `--verbose` — print every observer event
- `--no-observer` — disable observer hooks
- Scenario selection (if omitted, runs all):
  - `--pingpong`
  - `--timers`
  - `--restarts`
  - `--mailbox`
