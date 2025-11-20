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
