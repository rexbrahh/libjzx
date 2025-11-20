const std = @import("std");

pub const c = @cImport({
    @cInclude("jzx/jzx.h");
});

pub const LoopError = error{
    CreateFailed,
    InvalidArgument,
    LoopClosed,
    Unknown,
};

pub const Loop = struct {
    ptr: *c.jzx_loop,

    pub fn create(config: ?c.jzx_config) !Loop {
        var cfg = config orelse blk: {
            var tmp: c.jzx_config = undefined;
            c.jzx_config_init(&tmp);
            break :blk tmp;
        };

        const loop_ptr = c.jzx_loop_create(&cfg);
        if (loop_ptr == null) {
            return LoopError.CreateFailed;
        }
        return Loop{ .ptr = loop_ptr.? };
    }

    pub fn deinit(self: *Loop) void {
        c.jzx_loop_destroy(self.ptr);
        self.* = undefined;
    }

    pub fn run(self: *Loop) !void {
        const rc = c.jzx_loop_run(self.ptr);
        if (rc == c.JZX_OK) return;
        return mapError(rc);
    }

    pub fn requestStop(self: *Loop) void {
        c.jzx_loop_request_stop(self.ptr);
    }
};

fn mapError(code: c_int) LoopError {
    return switch (code) {
        c.JZX_ERR_INVALID_ARG => LoopError.InvalidArgument,
        c.JZX_ERR_LOOP_CLOSED => LoopError.LoopClosed,
        else => LoopError.Unknown,
    };
}
