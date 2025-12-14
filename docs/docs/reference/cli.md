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

TODO: List installed binaries (for example, `zig-out/bin/jzx-stress`) and their flags once stabilized.
