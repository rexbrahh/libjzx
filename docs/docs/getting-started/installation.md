---
title: Installation
sidebar_position: 1
---

# Installation

## Prerequisites

- Zig `0.15.1` (this repo’s CI and root `README.md` assume this version)
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

TODO: Add platform-specific instructions for obtaining/building `libxev` if it is not automatically provided by the Zig build.

See [Troubleshooting](../guides/troubleshooting).
