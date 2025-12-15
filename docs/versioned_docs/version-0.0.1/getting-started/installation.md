---
title: Installation
sidebar_position: 1
---

# Installation

## Prerequisites

- Zig `0.15.1` (this repo’s CI and root `README.md` assume this version)
  - The floor is enforced in [`build.zig.zon`](../deep-dive/build-zig-zon).
- A C toolchain (clang or gcc)

Optional:

- Nix + direnv (see repo root `README.md`)

## Build the runtime

From the repo root:

```sh
zig build
```

## Run tests

```sh
zig build test
```

## If you hit dependency issues

libjzx is built atop `libxev`.

For normal development via Zig:

- `libxev` is pulled as a Zig dependency (pinned in `build.zig.zon`).
  - `zig build` should fetch it automatically on first build (requires network access the first time).

If you are compiling manually with `cc`/`pkg-config` (outside Zig), you may need a system-provided `libxev`.

See [Troubleshooting](../guides/troubleshooting).

## See also

- Build system deep dive:
  - [`build.zig.zon`](../deep-dive/build-zig-zon)
  - [`build.zig`](../deep-dive/build-zig)
- [Quickstart](quickstart)
