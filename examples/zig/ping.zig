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
    };
    var actor_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn(loop.ptr, &opts, &actor_id) != c.JZX_OK) {
        std.debug.print("failed to spawn actor\n", .{});
        return;
    }

    _ = c.jzx_send(loop.ptr, actor_id, null, 0, 0);
    try loop.run();
}
