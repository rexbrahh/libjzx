---
title: Zig example — examples/zig/typed_actor.zig
---

# Zig example — `examples/zig/typed_actor.zig`

This example uses the **typed actor wrapper** from `zig/jzx/lib.zig` to avoid “void pointer everywhere” ergonomics.

Instead of writing a raw C-ABI behavior like:

- `fn behavior(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) ...`

you write a typed behavior like:

- `fn behavior(state: *State, msg: *Message, ctx: jzx.ActorContext) jzx.BehaviorResult`

The wrapper builds a trampoline that:

- receives the C message,
- casts `message.data` to your `MsgPtr`,
- calls your typed function,
- maps `.ok/.stop/.fail` back into the C enum.

## Cross-links

- Run it: [Quickstart](../getting-started/quickstart#build-and-run-the-examples)
- Type-safety layer: [Zig wrapper (`zig/jzx/lib.zig`)](zig-jzx-lib-zig)
- Under the hood: [C ABI (`include/jzx/jzx.h`)](include-jzx-jzx-h), [Runtime core (`src/jzx_runtime.c`)](src-jzx-runtime-c)

## Imports

<!-- snippet: examples/zig/typed_actor.zig#L1-L3 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/typed_actor.zig#L1-L3"><code>examples/zig/typed_actor.zig#L1-L3</code></a></div>
```zig title="Imports" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;
```

## Typed state and message

<!-- snippet: examples/zig/typed_actor.zig#L5-L11 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/typed_actor.zig#L5-L11"><code>examples/zig/typed_actor.zig#L5-L11</code></a></div>
```zig title="State + message types" showLineNumbers=5
const CounterState = struct {
    total: u32 = 0,
};

const Message = struct {
    value: u32,
};
```

Interpretation:

- `CounterState.total` is the accumulated sum.
- `Message.value` is the increment carried by each message.

Why these are `struct`s:

- They’re stable, named layouts that are easy to pass by pointer.
- They map cleanly to “bytes on the wire” if you later want to serialize them.

## The typed behavior function

<!-- snippet: examples/zig/typed_actor.zig#func=counterBehavior -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/typed_actor.zig#L13-L17"><code>examples/zig/typed_actor.zig#L13-L17</code></a></div>
```zig title="counterBehavior(): typed state + typed message" showLineNumbers=13
fn counterBehavior(state: *CounterState, msg: *Message, ctx: jzx.ActorContext) jzx.BehaviorResult {
    _ = ctx;
    state.total += msg.value;
    return .stop;
}
```

Line-by-line intent:

- `state: *CounterState` is the actor’s state pointer.
  - Owned by the caller (this example keeps it on the stack in `main`).
- `msg: *Message` is the decoded message payload pointer.
  - The typed wrapper casts `c.jzx_message.data` to this pointer type.
  - Important contract: the payload pointer must be non-null and properly aligned for `Message`.
- `ctx: jzx.ActorContext` is a small, wrapper-friendly context:
  - includes `loop` and `self` id
  - avoids exposing the full `c.jzx_context` directly
- `state.total += msg.value` is the “work”.
- `return .stop` requests a clean stop after one message.

## main(): spawn typed actor, send message, run

<!-- snippet: examples/zig/typed_actor.zig#func=main -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/typed_actor.zig#L19-L38"><code>examples/zig/typed_actor.zig#L19-L38</code></a></div>
```zig title="main(): spawn and run" showLineNumbers=19
pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var counter = CounterState{};
    var actor = try jzx.Actor(CounterState, *Message).spawn(
        loop.ptr,
        std.heap.c_allocator,
        &counter,
        &counterBehavior,
        .{},
    );
    defer actor.destroy();

    var msg = Message{ .value = 42 };
    _ = c.jzx_send(loop.ptr, actor.getId(), &msg, @sizeOf(Message), 0);
    try loop.run();

    std.debug.print("Counter total = {d}\n", .{counter.total});
}
```

Deep explanation:

- `jzx.Actor(CounterState, *Message)` is a compile-time specialization:
  - `State = CounterState`
  - `MsgPtr = *Message` (must be a pointer type)
- `.spawn(loop.ptr, allocator, state_ptr, behavior_ptr, opts)`:
  - allocates a small “shim” object that stores `{ behavior, state }`
  - spawns a runtime actor whose `state` is that shim
  - the shim trampoline decodes messages and calls your typed behavior
- `defer actor.destroy()`:
  - frees the wrapper’s shim allocation
  - important: this does **not** stop the runtime actor; it only frees wrapper-owned memory
  - why it’s safe here: the behavior returns `.stop`, so the actor stops during `loop.run()`
- `var msg = Message{ .value = 42 };` is stack allocated.
  - This is safe in this example because:
    - the message is sent before `loop.run()`, and
    - `loop.run()` does not return until the message has been processed and the actor stops.
  - If you were scheduling messages with timers or sending from another thread, you would typically heap-allocate the payload (or ensure lifetime another way).

## Full listing (for reference)

<!-- snippet: examples/zig/typed_actor.zig#all -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/examples/zig/typed_actor.zig#L1-L38"><code>examples/zig/typed_actor.zig#L1-L38</code></a></div>
```zig title="examples/zig/typed_actor.zig" showLineNumbers=1
const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

const CounterState = struct {
    total: u32 = 0,
};

const Message = struct {
    value: u32,
};

fn counterBehavior(state: *CounterState, msg: *Message, ctx: jzx.ActorContext) jzx.BehaviorResult {
    _ = ctx;
    state.total += msg.value;
    return .stop;
}

pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var counter = CounterState{};
    var actor = try jzx.Actor(CounterState, *Message).spawn(
        loop.ptr,
        std.heap.c_allocator,
        &counter,
        &counterBehavior,
        .{},
    );
    defer actor.destroy();

    var msg = Message{ .value = 42 };
    _ = c.jzx_send(loop.ptr, actor.getId(), &msg, @sizeOf(Message), 0);
    try loop.run();

    std.debug.print("Counter total = {d}\n", .{counter.total});
}
```
