---
title: Design goals
sidebar_position: 2
---

# Design goals

This page captures the “why” behind libjzx. Keep it short and update it whenever the runtime’s contracts change.

## Goals

- **Predictable scheduling**: bounded work per tick and clear fairness semantics.
- **Explicit backpressure**: mailboxes should surface overload instead of hiding it.
- **Small, stable C ABI**: public headers remain C99-compatible and usable from many languages.
- **Tight event-loop integration**: timers and I/O watchers via libxev.
- **Testability**: deterministic unit tests plus stress suites for scheduling/supervision.

## Non-goals (for now)

TODO: Fill in explicit non-goals (e.g., distributed actors, transparent networking, multi-process clustering).
