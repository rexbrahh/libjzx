---
title: Configuration
sidebar_position: 1
---

# Configuration

libjzx configuration lives at a few layers:

- Compile-time choices (Zig build options)
- Runtime knobs (loop/scheduler/mailbox parameters)
- Observability (observer callbacks)

## Observer callbacks

The root `README.md` mentions an observer callback table set via `jzx_loop_set_observer()`.

TODO: Link to the exact public header(s) and document the callback contract (threading, reentrancy, lifetimes).

## Runtime knobs

TODO: Document runtime configuration once the public surface is stable (mailbox sizing, scheduling budget, timer resolution, etc.).
