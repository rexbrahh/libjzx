---
title: Quickstart
sidebar_position: 2
---

# Quickstart

## Build and run the examples

From the repo root:

```sh
zig build examples
```

The Zig build installs binaries under `zig-out/bin/`.

Expected example binaries:

- `zig-out/bin/zig-example` (source: `examples/zig/ping.zig`) — minimal spawn + stop
- `zig-out/bin/zig-typed-actor` (source: `examples/zig/typed_actor.zig`) — typed wrapper example
- `zig-out/bin/zig-supervisor` (source: `examples/zig/supervisor.zig`) — restart modes + deterministic driver
- `zig-out/bin/zig-echo-server` (source: `examples/zig/echo_server.zig`) — I/O watchers + TCP echo

Suggested run order:

1. `./zig-out/bin/zig-example`
2. `./zig-out/bin/zig-typed-actor`
3. `./zig-out/bin/zig-supervisor`
4. `./zig-out/bin/zig-echo-server 5555` and then `nc 127.0.0.1 5555`

Deep-dive walkthroughs (with code snippets + explanations):

- [Zig ping example](../deep-dive/examples-zig-ping-zig)
- [Zig typed actor example](../deep-dive/examples-zig-typed-actor-zig)
- [Zig supervisor example](../deep-dive/examples-zig-supervisor-zig)
- [Zig echo server example](../deep-dive/examples-zig-echo-server-zig)

## Stress tool (optional)

From the repo root:

```sh
zig build stress
```

This runs the smoke variant by default. You can also run the installed binary directly:

```sh
./zig-out/bin/jzx-stress --smoke
```

Deep dive:

- [Stress tool walkthrough](../deep-dive/tools-stress-zig)

## C examples

The repository includes plain C examples under `examples/c/`.

If you prefer compiling them directly (bypassing Zig), see the commands in the repo root `README.md`.

## Next

- [Architecture](../concepts/architecture)
