# I/O readiness

libjzx includes a small fd readiness facility built into the loop.

Register an fd with `jzx_watch_fd()`, and readiness events are delivered to the owning actor as messages tagged `JZX_TAG_SYS_IO`.

## API

- `jzx_watch_fd(loop, fd, owner, interest)`
  - `interest` is a bitmask: `JZX_IO_READ | JZX_IO_WRITE`.
  - Re-registering an existing fd updates its owner/interest.
- `jzx_unwatch_fd(loop, fd)`
  - Removes the fd from the loop watch set.
  - Returns `JZX_ERR_IO_NOT_WATCHED` if the fd is not registered.

## Message shape

When readiness is detected, the loop sends:

- `tag = JZX_TAG_SYS_IO`
- `data = jzx_io_event*`
- `len = sizeof(jzx_io_event)`

Where:

```c
typedef struct {
    int fd;
    uint32_t readiness; // JZX_IO_READ / JZX_IO_WRITE
} jzx_io_event;
```

## Ownership

The `jzx_io_event*` payload is allocated by the runtime and is owned by the receiver.

Free it with:

```c
jzx_loop_free(ctx->loop, msg->data);
```

Do not call `free()` directly if you configured a custom allocator.

## Actor death and cleanup

If an actor stops or fails, the runtime automatically removes any watched fds owned by that actor so no further readiness events are delivered.

The runtime does not call `close(fd)` for you; fd ownership remains with user code.

## Fairness

I/O readiness is delivered as normal messages, so it is subject to the same scheduler bounds:

- `max_msgs_per_actor` limits how many I/O events (and other messages) a single actor can process per visit.
- `max_actors_per_tick` limits how many actors are serviced between I/O polls.

