---
title: Contributing
sidebar_position: 1
---

# Contributing

## Development workflow

From the repo root:

```sh
zig build
zig build test
```

## Formatting

CI runs `zig build fmt`.

For C formatting, the repo guideline is:

```sh
clang-format -i include/**/*.h src/**/*.c
```

## Tests + stress

```sh
zig build test
zig build stress
```

Pointers:

- Tests: `zig/tests/basic.zig` ([walkthrough](/docs/deep-dive/zig-tests-basic-zig))
- Stress tool: `tools/stress.zig` ([walkthrough](/docs/deep-dive/tools-stress-zig))

## Documentation site

The docs website lives under `docs/` (Node.js 20+).

See `docs/README.md` for local commands.
