---
title: Zig example — examples/zig/ping.zig
---

# Zig example — `examples/zig/ping.zig`

This is the Zig equivalent of the tiny C “hello actor” example:

- spawn one actor
- send it one message
- print something
- stop

It’s also a good “FFI hygiene” example because it shows how to write a Zig function that matches the **C ABI behavior signature**.

## Imports

<!-- snippet: examples/zig/ping.zig#L1-L3 -->
```zig title="Imports" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
```

- `std`: printing and basic runtime utilities.
- `jzx`: Zig wrapper module for libjzx.
- `c = jzx.c`: alias for the C ABI layer (`c.jzx_spawn`, `c.jzx_context`, enums, etc).

## Behavior function (C ABI compatible)

The behavior signature uses C pointer types and `callconv(.c)` so the runtime can call it.

<!-- snippet: examples/zig/ping.zig#func=print_behavior -->
```zig title="print_behavior(): print and stop" showLineNumbers=5
fn print_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    std.debug.print("actor {d} received message\n", .{ctx_ptr.self});
    return c.JZX_BEHAVIOR_STOP;
}
```

Deep explanation:

- `ctx: [*c]c.jzx_context` is a C pointer (may be null at the type level).
  - This example assumes the runtime passes a valid pointer.
  - Zig represents raw C pointers as `[*c]T`.
- `msg: [*c]const c.jzx_message` is the message envelope pointer.
- `_ = msg;` discards the value (the payload isn’t used here).
- `@ptrCast(ctx)` converts the raw C pointer into a normal Zig pointer `*c.jzx_context`.
  - Why it exists: Zig requires explicit casts when moving between pointer types.
- `ctx_ptr.self` is the actor id (a 64-bit integer).
- Returning `STOP` makes the actor terminate after a single message.

## main(): create loop, spawn, send, run

<!-- snippet: examples/zig/ping.zig#func=main -->
```zig title="main(): spawn and run" showLineNumbers=12
pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var opts = c.jzx_spawn_opts{
        .behavior = print_behavior,
        .state = null,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        std.debug.print("failed to spawn actor\n", .{});
        return;
    }

    _ = c.jzx_send(loop.ptr, actor_id, null, 0, 0);
    try loop.run();
}
```

What’s happening:

- `jzx.Loop.create(null)` constructs a loop using default config.
  - The wrapper returns an error union, so `try` is used.
- `loop.ptr` is the raw `*c.jzx_loop` pointer passed into C ABI calls.
- `c.jzx_spawn_opts{ ... }` is the C struct initializer for spawn options:
  - `.mailbox_cap = 0` means “use the loop default”.
- `c.jzx_spawn(...)` returns a `c.jzx_err` value; `JZX_OK` means success.
- `c.jzx_send(...)` enqueues an empty message (null payload).
- `try loop.run()` runs until the actor stops and the loop becomes idle.

## Full listing (for reference)

<!-- snippet: examples/zig/ping.zig#all -->
```zig title="examples/zig/ping.zig" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

fn print_behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    _ = msg;
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    std.debug.print("actor {d} received message\n", .{ctx_ptr.self});
    return c.JZX_BEHAVIOR_STOP;
}

pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var opts = c.jzx_spawn_opts{
        .behavior = print_behavior,
        .state = null,
        .supervisor = 0,
        .mailbox_cap = 0,
        .name = null,
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        std.debug.print("failed to spawn actor\n", .{});
        return;
    }

    _ = c.jzx_send(loop.ptr, actor_id, null, 0, 0);
    try loop.run();
}
```
