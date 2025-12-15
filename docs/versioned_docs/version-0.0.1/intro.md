---
title: Introduction
sidebar_position: 1
---

# libjzx

libjzx is an early scaffold for a libxev-backed, single-process actor runtime.

## What you’ll find here

- **Getting started**: build/test the runtime and bindings.
- **Concepts**: architecture and design goals.
- **Guides**: configuration patterns and troubleshooting.
- **Reference**: binaries, configuration knobs, and stable-ish interfaces.
- **Deep dive**: extremely detailed, code-first walkthroughs of every subsystem and example.

## Status

This project is under active development. APIs and on-disk layouts may change.

## Next steps

- [Installation](getting-started/installation)
- [Quickstart](getting-started/quickstart)
- [Architecture](concepts/architecture)
- [Deep dive: source index](deep-dive/source-index)

## Jump into code

- Start here: [Deep dive: source index](deep-dive/source-index)
- Public surface: [C ABI (`include/jzx/jzx.h`)](deep-dive/include-jzx-jzx-h), [Zig wrapper (`zig/jzx/lib.zig`)](deep-dive/zig-jzx-lib-zig)
- Runtime internals: [Internal structs (`src/jzx_internal.h`)](deep-dive/src-jzx-internal-h), [Runtime core (`src/jzx_runtime.c`)](deep-dive/src-jzx-runtime-c), [libxev integration (`src/jzx_xev.zig`)](deep-dive/src-jzx-xev-zig)
- Behavior under load: [Integration tests](deep-dive/zig-tests-basic-zig), [Stress tool](deep-dive/tools-stress-zig)

## See also

- [Configuration](guides/configuration)
- [Configuration reference](reference/config-reference)
- [Troubleshooting](guides/troubleshooting)
- [Contributing](contributing)
- [Security](security)
