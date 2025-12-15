---
title: Troubleshooting
sidebar_position: 2
---

# Troubleshooting

## Zig version mismatch

Symptoms: build failures or confusing compiler errors after upgrading/downgrading Zig.

- Confirm your version: `zig version`
- This repo’s CI uses Zig `0.15.1`.

## Build errors related to libxev

Symptoms: missing headers/libs, link errors, or `pkg-config` failures.

Expected setup (Zig build):

- `libxev` is fetched as a Zig dependency (pinned in `build.zig.zon`).
- The first `zig build` may download it into Zig’s cache.

If you see `pkg-config` errors:

- Those are typically from a manual compilation path (not required for the Zig build).
- Prefer `zig build` unless you are explicitly debugging C compilation outside Zig.

## “Works locally, fails in CI”

- Ensure you’re running the same commands as CI (`zig build fmt`, `zig build test`, `zig build stress`).
- Check for environment-sensitive assumptions (paths, temp dirs, clock/timeouts).

## See also

- [Installation](../getting-started/installation)
- Build system deep dive:
  - [`build.zig.zon`](../deep-dive/build-zig-zon)
  - [`build.zig`](../deep-dive/build-zig)
