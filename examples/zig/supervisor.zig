const std = @import("std");
const jzx = @import("jzx");
const c = jzx.c;

const Tick = struct {
    value: u32,
};

fn allocTick(val: u32) ?*Tick {
    const ptr = std.heap.c_allocator.create(Tick) catch return null;
    ptr.* = .{ .value = val };
    return ptr;
}

fn flapping(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
    const ctx_ptr = @as(*c.jzx_context, @ptrCast(ctx));
    const message = msg.*;
    if (message.data == null) return c.JZX_BEHAVIOR_FAIL;
    const tick = @as(*Tick, @ptrCast(@alignCast(message.data.?)));
    const current = tick.value;
    std.debug.print("[child] tick={d}\n", .{current});
    std.heap.c_allocator.destroy(tick);

    if (current >= 3) {
        std.debug.print("[child] failing at {d}\n", .{current});
        return c.JZX_BEHAVIOR_FAIL;
    }

    const next = allocTick(current + 1) orelse return c.JZX_BEHAVIOR_FAIL;
    const rc = c.jzx_send_after(ctx_ptr.loop.?, ctx_ptr.self, 100, next, @sizeOf(Tick), 0, null);
    if (rc != c.JZX_OK) {
        std.heap.c_allocator.destroy(next);
        return c.JZX_BEHAVIOR_FAIL;
    }
    return c.JZX_BEHAVIOR_OK;
}

pub fn main() !void {
    var loop = try jzx.Loop.create(null);
    defer loop.deinit();

    var children = [_]c.jzx_child_spec{
        .{
            .behavior = flapping,
            .state = null,
            .mode = c.JZX_CHILD_PERMANENT,
            .mailbox_cap = 0,
            .restart_delay_ms = 100,
            .backoff = c.JZX_BACKOFF_EXPONENTIAL,
        },
    };

    var sup_init = c.jzx_supervisor_init{
        .children = &children,
        .child_count = children.len,
        .supervisor = .{
            .strategy = c.JZX_SUP_ONE_FOR_ONE,
            .intensity = 5,
            .period_ms = 2000,
            .backoff = c.JZX_BACKOFF_EXPONENTIAL,
            .backoff_delay_ms = 100,
        },
    };

    var sup_id: c.jzx_actor_id = 0;
    if (c.jzx_spawn_supervisor(loop.ptr, &sup_init, 0, &sup_id) != c.JZX_OK) {
        std.debug.print("failed to spawn supervisor\n", .{});
        return;
    }

    var child_id: c.jzx_actor_id = 0;
    if (c.jzx_supervisor_child_id(loop.ptr, sup_id, 0, &child_id) != c.JZX_OK or child_id == 0) {
        std.debug.print("failed to get child id\n", .{});
        return;
    }

    const first = allocTick(0) orelse {
        std.debug.print("alloc failed\n", .{});
        return;
    };
    if (c.jzx_send(loop.ptr, child_id, first, @sizeOf(Tick), 0) != c.JZX_OK) {
        std.heap.c_allocator.destroy(first);
        std.debug.print("initial send failed\n", .{});
        return;
    }

    try loop.run();
}
