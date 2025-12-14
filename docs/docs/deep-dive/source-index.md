---
title: Source index
sidebar_position: 1
---

# Source index

This section is for **extremely detailed, code-first documentation**: what each file does, how the pieces fit, and (where useful) line-by-line commentary.

## Reading order

If you’re new, this order minimizes context switching:

1. `include/jzx/jzx.h` — C ABI: types, errors, and public functions.
2. `zig/jzx/lib.zig` — Zig wrapper: ergonomic surface + typed actor helper.
3. `src/jzx_internal.h` — private runtime structs backing the public ABI.
4. `src/jzx_runtime.c` — the runtime implementation (scheduler/mailboxes/supervision/timers).
5. `src/jzx_xev.zig` — libxev integration (I/O watchers + wakeups).
6. `zig/tests/basic.zig` — integration tests that exercise the ABI end-to-end.

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
- **Docusaurus deep-dive**: curated narrative explanations (this section), plus selectively embedded code with `showLineNumbers` for review-friendly reading.

## Quick links

- [C ABI: `include/jzx/jzx.h` (annotated)](include-jzx-jzx-h)
- [Zig wrapper: `zig/jzx/lib.zig` (annotated)](zig-jzx-lib-zig)
- [Runtime internals: `src/jzx_internal.h` (annotated)](src-jzx-internal-h)
- [libxev integration: `src/jzx_xev.zig`](src-jzx-xev-zig)
- [Runtime core: `src/jzx_runtime.c`](src-jzx-runtime-c)
- [Integration tests: `zig/tests/basic.zig`](zig-tests-basic-zig)
