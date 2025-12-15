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

<Why>
This section is not a substitute for reading the source — it is a substitute for tribal knowledge.
The goal is to capture the invariants the code relies on (and the tradeoffs behind them) so the runtime can evolve without losing intent.
</Why>

## Tooling options (recommended)

If you want to keep the docs extremely detailed *and* maintainable as code evolves:

- **C ABI reference**: Doxygen comments in `include/jzx/jzx.h` + generated HTML.
- **Zig API reference**: Zig doc comments (`///`) + `zig doc` output.
- **Deep-dive docs**: curated narrative explanations (this section), plus selectively embedded code with `showLineNumbers` for review-friendly reading.

## Quick links

### Build + packaging {#build}

- [`build.zig.zon` (dependency manifest)](build-zig-zon)
- [`build.zig` (build graph)](build-zig)

### Public surface {#public}

- [C ABI: `include/jzx/jzx.h` (annotated)](include-jzx-jzx-h)
- [Zig wrapper: `zig/jzx/lib.zig` (annotated)](zig-jzx-lib-zig)

### Runtime internals {#runtime}

- [Runtime internals: `src/jzx_internal.h` (annotated)](src-jzx-internal-h)
- [Runtime core: `src/jzx_runtime.c` (annotated)](src-jzx-runtime-c)
- [libxev integration: `src/jzx_xev.zig` (annotated)](src-jzx-xev-zig)

### Testing + stress {#testing}

- [Integration tests: `zig/tests/basic.zig` (annotated)](zig-tests-basic-zig)
- [Stress tool: `tools/stress.zig` (annotated)](tools-stress-zig)

### Examples {#examples}

- [Zig: `examples/zig/ping.zig`](examples-zig-ping-zig)
- [Zig: `examples/zig/typed_actor.zig`](examples-zig-typed-actor-zig)
- [Zig: `examples/zig/supervisor.zig`](examples-zig-supervisor-zig)
- [Zig: `examples/zig/echo_server.zig`](examples-zig-echo-server-zig)
- [C: `examples/c/loop.c`](examples-c-loop-c)
- [C: `examples/c/supervisor.c`](examples-c-supervisor-c)

## Coverage inventory (what the docs cover)

This repo’s “core code” is intentionally small, and the deep-dive section aims for **100% coverage of all non-empty lines**
in those files (excluding `#all` appendices).

Re-check locally:

- `cd docs && npm run check:deep-dive`
- `cd docs && npm run check:coverage:deep-dive`

### Core code (deep-dive, 100% covered)

- Build + packaging: `build.zig.zon`, `build.zig`
- Public ABI: `include/jzx/jzx.h`
- Runtime internals: `src/jzx_internal.h`, `src/jzx_runtime.c`, `src/jzx_xev.zig`
- Zig wrapper + tests: `zig/jzx/lib.zig`, `zig/tests/basic.zig`
- Tools: `tools/stress.zig`
- Examples: `examples/c/loop.c`, `examples/c/supervisor.c`, `examples/zig/ping.zig`, `examples/zig/typed_actor.zig`, `examples/zig/supervisor.zig`, `examples/zig/echo_server.zig`

Each of these files has a corresponding deep-dive page linked above.

### Tracked files not covered in the deep-dive (by design)

These are either “plumbing” (CI/config) or already-human-readable docs:

- CI/workflows: `.github/workflows/*`
- Local dev environment: `.envrc`, `flake.nix`, `flake.lock`
- Formatting config: `.clang-format`
- Legacy/notes docs: `dev_logs/*` (design notes and objectives)
- The documentation site itself: `docs/**` (Docusaurus config, theme, and docs source)

If you later decide you want deep-dive coverage for any of these, add a page under `docs/docs/deep-dive/` and wire it into the sidebar.

<details>
<summary>Tracked files snapshot (<code>git ls-files</code>)</summary>

```text
.clang-format
.envrc
.github/workflows/ci.yml
.github/workflows/docs-build.yml
.github/workflows/docs-deploy.yml
.gitignore
README.md
build.zig
build.zig.zon
dev_logs/ci.md
dev_logs/design_doc_1.md
dev_logs/design_doc_2.md
dev_logs/design_doc_3.md
dev_logs/design_doc_4.md
dev_logs/io.md
dev_logs/objectives.md
dev_logs/observability.md
dev_logs/supervision.md
dev_logs/timers.md
docs/.gitignore
docs/README.md
docs/docs/concepts/_category_.json
docs/docs/concepts/architecture.md
docs/docs/concepts/design-goals.md
docs/docs/contributing/_category_.json
docs/docs/contributing/contributing.md
docs/docs/deep-dive/_category_.json
docs/docs/deep-dive/build-zig-zon.md
docs/docs/deep-dive/build-zig.md
docs/docs/deep-dive/examples-c-loop-c.md
docs/docs/deep-dive/examples-c-supervisor-c.md
docs/docs/deep-dive/examples-zig-echo-server-zig.md
docs/docs/deep-dive/examples-zig-ping-zig.md
docs/docs/deep-dive/examples-zig-supervisor-zig.md
docs/docs/deep-dive/examples-zig-typed-actor-zig.md
docs/docs/deep-dive/include-jzx-jzx-h.md
docs/docs/deep-dive/source-index.md
docs/docs/deep-dive/src-jzx-internal-h.md
docs/docs/deep-dive/src-jzx-runtime-c.md
docs/docs/deep-dive/src-jzx-xev-zig.md
docs/docs/deep-dive/tools-stress-zig.md
docs/docs/deep-dive/zig-jzx-lib-zig.md
docs/docs/deep-dive/zig-tests-basic-zig.md
docs/docs/getting-started/_category_.json
docs/docs/getting-started/installation.md
docs/docs/getting-started/quickstart.md
docs/docs/guides/_category_.json
docs/docs/guides/configuration.md
docs/docs/guides/troubleshooting.md
docs/docs/intro.md
docs/docs/reference/_category_.json
docs/docs/reference/cli.md
docs/docs/reference/config-reference.md
docs/docs/security.md
docs/docusaurus.config.ts
docs/package-lock.json
docs/package.json
docs/scripts/coverage-deep-dive.mjs
docs/scripts/sync-deep-dive.mjs
docs/sidebars.ts
docs/src/components/HomepageFeatures/index.tsx
docs/src/components/HomepageFeatures/styles.module.css
docs/src/css/custom.css
docs/src/pages/index.module.css
docs/src/pages/index.tsx
docs/static/.nojekyll
docs/static/img/favicon.svg
docs/static/img/icon-build.svg
docs/static/img/icon-runtime.svg
docs/static/img/icon-supervision.svg
docs/tsconfig.json
examples/c/loop.c
examples/c/supervisor.c
examples/zig/echo_server.zig
examples/zig/ping.zig
examples/zig/supervisor.zig
examples/zig/typed_actor.zig
flake.lock
flake.nix
include/jzx/jzx.h
src/jzx_internal.h
src/jzx_runtime.c
src/jzx_xev.zig
tools/stress.zig
zig/jzx/lib.zig
zig/tests/basic.zig
```

</details>
