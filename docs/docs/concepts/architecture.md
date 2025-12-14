---
title: Architecture
sidebar_position: 1
---

# Architecture

libjzx targets a **single-process actor runtime** built atop **libxev**.

At a high level:

1. Actors communicate by sending messages.
2. Messages are enqueued into actor mailboxes.
3. A scheduler runs actors that have work available.
4. Timers and I/O watchers feed more work into mailboxes via the libxev loop.

## Major components

- **Loop / executor**: drives libxev, timers, and ready queues.
- **Scheduler**: selects runnable actors and advances them.
- **Mailbox**: per-actor queue with explicit backpressure behavior.
- **Supervision**: supervisor trees that restart/replace actors on failure.
- **Observability**: an optional observer callback table for lifecycle and pressure signals.

## Code layout

- `include/jzx/`: public C ABI headers
- `src/`: C runtime implementation (loop, scheduler, mailboxes, supervisors)
- `zig/`: Zig wrappers/bindings over the C ABI
- `examples/`: runnable examples (C and Zig)
- `tests/`: tests and stress tools

## Threading model

The runtime is designed to be single-process.

TODO: Document the intended single-thread vs multi-thread boundary (if/when it exists), plus any safety rules for calling into the runtime from other threads.
