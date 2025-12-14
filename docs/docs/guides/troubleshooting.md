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

TODO: Document the expected way `libxev` is provided (vendored vs system dependency) and list platform-specific setup steps.

## “Works locally, fails in CI”

- Ensure you’re running the same commands as CI (`zig build fmt`, `zig build test`, `zig build stress`).
- Check for environment-sensitive assumptions (paths, temp dirs, clock/timeouts).

TODO: Add common CI failure modes as they are encountered.
