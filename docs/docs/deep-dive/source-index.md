---
title: Source index
sidebar_position: 1
---

# Source index

This section is for **extremely detailed, code-first documentation**: what each file does, how the pieces fit, and (where useful) line-scoped explanations with small, reviewable snippets.

## Reading order

If you’re new, this order minimizes context switching:

1. `build.zig.zon` — pinned dependencies + minimum Zig version.
2. `build.zig` — build graph: how C/Zig pieces are compiled and wired together.
3. `include/jzx/jzx.h` — C ABI: types, errors, and public functions.
4. `zig/jzx/lib.zig` — Zig wrapper: ergonomic surface + typed actor helper.
5. `src/jzx_internal.h` — private runtime structs backing the public ABI.
6. `src/jzx_runtime.c` — the runtime implementation (scheduler/mailboxes/supervision/timers).
7. `src/jzx_xev.zig` — libxev integration (I/O watchers + wakeups).
8. `zig/tests/basic.zig` — integration tests that exercise the ABI end-to-end.
9. `tools/stress.zig` — stress harness for fairness/timers/restarts/backpressure.
10. `examples/` — runnable demos that “connect the dots” (ping, typed actor, supervisor, echo server).

## Documentation goals (what “extreme detail” means here)

- **Every public API**: every function/type/constant should have:
  - what it does
  - inputs/outputs + error codes
  - ownership/lifetimes
  - invariants and failure modes
  - why it exists (design intent / tradeoff)
- **Every private subsystem**: for each file/major struct:
  - data flow diagrams (message, timer, I/O, supervision)
  - scheduling and fairness rules
  - memory and thread-safety rules
  - “how to debug” checklists

## Tooling options (recommended)

If you want to keep the docs extremely detailed *and* maintainable as code evolves:

- **C ABI reference**: Doxygen comments in `include/jzx/jzx.h` + generated HTML.
- **Zig API reference**: Zig doc comments (`///`) + `zig doc` output.
- **Deep-dive docs**: curated narrative explanations (this section), plus selectively embedded code with `showLineNumbers` for review-friendly reading.

## Quick links

Build + packaging:

- [`build.zig.zon` (dependency manifest)](build-zig-zon)
- [`build.zig` (build graph)](build-zig)

Public surface:

- [C ABI: `include/jzx/jzx.h` (annotated)](include-jzx-jzx-h)
- [Zig wrapper: `zig/jzx/lib.zig` (annotated)](zig-jzx-lib-zig)

Runtime internals:

- [Runtime internals: `src/jzx_internal.h` (annotated)](src-jzx-internal-h)
- [Runtime core: `src/jzx_runtime.c` (annotated)](src-jzx-runtime-c)
- [libxev integration: `src/jzx_xev.zig` (annotated)](src-jzx-xev-zig)

Testing + stress:

- [Integration tests: `zig/tests/basic.zig` (annotated)](zig-tests-basic-zig)
- [Stress tool: `tools/stress.zig` (annotated)](tools-stress-zig)

Examples:

- [Zig: `examples/zig/ping.zig`](examples-zig-ping-zig)
- [Zig: `examples/zig/typed_actor.zig`](examples-zig-typed-actor-zig)
- [Zig: `examples/zig/supervisor.zig`](examples-zig-supervisor-zig)
- [Zig: `examples/zig/echo_server.zig`](examples-zig-echo-server-zig)
- [C: `examples/c/loop.c`](examples-c-loop-c)
- [C: `examples/c/supervisor.c`](examples-c-supervisor-c)
