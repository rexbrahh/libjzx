# CI workflows

The repository uses GitHub Actions for CI.

## What runs

Workflow: `.github/workflows/ci.yml`

On every push to `main` and on pull requests, CI runs:

- `zig build fmt`
- `zig build test`
- `zig build stress` (smoke harness)
- `zig build examples`

The stress harness prints basic throughput/timing lines and observer summaries; CI parses these and writes a small performance table into the GitHub Actions step summary.

## Optional full stress

The CI workflow supports a manual run via `workflow_dispatch` with `full_stress=true`, which runs the non-smoke scenarios:

```sh
zig-out/bin/jzx-stress --pingpong --timers --restarts --mailbox
```

## Caching

CI caches:

- `~/.cache/zig` (Zig global cache)
- `.zig-cache` (project build cache)

This is keyed by OS + Zig version + commit SHA with a prefix restore key, so consecutive runs can reuse previous build artifacts.

## Secrets / system dependencies

No GitHub secrets are required.

The build is self-contained (Zig + the in-repo C runtime) and only relies on libc + pthreads on Linux runners.

## Running locally

```sh
zig build fmt
zig build test
zig build stress
zig build examples
```

