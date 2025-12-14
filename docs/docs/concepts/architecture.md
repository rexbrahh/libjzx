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

The runtime is designed to be single-process and “loop-thread owned”:

- Actor behaviors run on the **loop thread** (the thread calling `jzx_loop_run`).
- Actor mailboxes, the actor table, supervision state, and the run queue are all treated as **single-threaded data structures**.

There are two deliberate exceptions where other threads can participate safely:

1. **Timers**
   - The loop starts a dedicated timer thread.
   - When a timer fires, the timer thread enqueues a message via the async queue (it does not directly mutate actor mailboxes).
2. **Cross-thread sends**
   - `jzx_send_async` is designed to be thread-safe:
     - it enqueues into an internal async queue protected by a mutex
     - it wakes the loop so the loop thread can deliver the message safely

Practical safety rule:

- Treat everything except `jzx_send_async` as “call from the loop thread (or before the loop starts)”.
