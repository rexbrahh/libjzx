# Timers

libjzx provides a basic timer engine backed by a background thread.

User code schedules timers via `jzx_send_after()`, which enqueues a message to an actor once the timer is due.

## API

- `jzx_send_after(loop, target, ms, data, len, tag, &out_timer)`
  - Schedules a message to `target` after `ms` milliseconds.
  - Returns a stable `jzx_timer_id` via `out_timer` (optional).
- `jzx_cancel_timer(loop, timer_id)`
  - Cancels a pending timer.
  - Returns `JZX_ERR_TIMER_INVALID` if the timer is unknown, already fired, or already cancelled.

## Timing and clocks

Timer due times are computed using a monotonic clock (`CLOCK_MONOTONIC`), so wall-clock adjustments do not affect when timers fire.

## Ownership and payload lifetime

- `data` is not copied.
- The runtime does not free `data` after delivery.
- If you cancel a timer, the runtime also does not free `data`.
- If an actor dies before a timer fires, the timer message is dropped; `data` is still not freed.

This matches the v1 message model: the sender controls payload lifetime and ownership.

## Message tags

`jzx_send_after()` preserves the provided `tag`. Timer-delivered messages are normal actor messages; the runtime does not override tags.

## Teardown

Destroying a loop stops the timer thread and drops any pending timers.

Pending timer entries are freed internally, but any timer payload pointers are not freed (see ownership rules above).
