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

TODO: Add pointers to the most important tests/stress harnesses as they land.

## Documentation site

The docs website lives under `docs/` (Node.js 20+).

See `docs/README.md` for local commands.
