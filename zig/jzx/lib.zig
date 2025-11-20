const std = @import("std");

pub const c = @cImport({
    @cInclude("jzx/jzx.h");
});

pub const LoopError = error{
    CreateFailed,
    InvalidArgument,
    LoopClosed,
    NoSuchActor,
    IoRegistrationFailed,
    NotWatched,
    Unknown,
};

pub const BehaviorResult = enum { ok, stop, fail };

pub const ActorContext = struct {
    loop: *c.jzx_loop,
    self: c.jzx_actor_id,
};

pub const SpawnOptions = struct {
    supervisor: c.jzx_actor_id = 0,
    mailbox_cap: u32 = 0,
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

    pub fn watchFd(self: *Loop, fd: c_int, actor: c.jzx_actor_id, interest: u32) !void {
        const rc = c.jzx_watch_fd(self.ptr, fd, actor, interest);
        if (rc == c.JZX_OK) return;
        return mapError(rc);
    }

    pub fn unwatchFd(self: *Loop, fd: c_int) !void {
        const rc = c.jzx_unwatch_fd(self.ptr, fd);
        if (rc == c.JZX_OK) return;
        return mapError(rc);
    }
};

fn ensurePointerType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => return,
        else => @compileError("Message pointer type must be a pointer. Use pointers to structs or opaque data."),
    }
}

pub fn Actor(comptime State: type, comptime MsgPtr: type) type {
    ensurePointerType(MsgPtr);

    const BehaviorFn = *const fn (*State, MsgPtr, ActorContext) BehaviorResult;

    const Shim = struct {
        behavior: BehaviorFn,
        state: *State,
    };

    return struct {
        const Self = @This();

        loop: *c.jzx_loop,
        allocator: std.mem.Allocator,
        shim: *Shim,
        id: c.jzx_actor_id,

        pub fn spawn(
            loop: *c.jzx_loop,
            allocator: std.mem.Allocator,
            state: *State,
            behavior: BehaviorFn,
            opts: SpawnOptions,
        ) !Self {
            const shim = try allocator.create(Shim);
            shim.* = .{ .behavior = behavior, .state = state };

            var spawn_opts = c.jzx_spawn_opts{
                .behavior = trampoline,
                .state = shim,
                .supervisor = opts.supervisor,
                .mailbox_cap = opts.mailbox_cap,
            };
            var actor_id: c.jzx_actor_id = 0;
            const rc = c.jzx_spawn(loop, &spawn_opts, &actor_id);
            if (rc != c.JZX_OK) {
                allocator.destroy(shim);
                return mapError(rc);
            }
            return Self{
                .loop = loop,
                .allocator = allocator,
                .shim = shim,
                .id = actor_id,
            };
        }

        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self.shim);
            self.* = undefined;
        }

        pub fn getId(self: Self) c.jzx_actor_id {
            return self.id;
        }

        fn trampoline(ctx: [*c]c.jzx_context, msg: [*c]const c.jzx_message) callconv(.c) c.jzx_behavior_result {
            const ctx_ptr = ctx.*;
            const shim_ptr: *Shim = @ptrCast(@alignCast(ctx_ptr.state.?));
            const context = ActorContext{
                .loop = ctx_ptr.loop.?,
                .self = ctx_ptr.self,
            };
            const typed_msg = decodeMsgPtr(msg.*);
            return mapBehaviorResult(shim_ptr.behavior(shim_ptr.state, typed_msg, context));
        }

        fn decodeMsgPtr(message: c.jzx_message) MsgPtr {
            if (message.data) |raw| {
                const ptr: MsgPtr = @ptrCast(@alignCast(raw));
                return ptr;
            }
            @panic("typed actor received null message payload");
        }

        fn mapBehaviorResult(result: BehaviorResult) c.jzx_behavior_result {
            return switch (result) {
                .ok => c.JZX_BEHAVIOR_OK,
                .stop => c.JZX_BEHAVIOR_STOP,
                .fail => c.JZX_BEHAVIOR_FAIL,
            };
        }
    };
}

fn mapError(code: c_int) LoopError {
    return switch (code) {
        c.JZX_ERR_INVALID_ARG => LoopError.InvalidArgument,
        c.JZX_ERR_LOOP_CLOSED => LoopError.LoopClosed,
        c.JZX_ERR_NO_SUCH_ACTOR => LoopError.NoSuchActor,
        c.JZX_ERR_IO_REG_FAILED => LoopError.IoRegistrationFailed,
        c.JZX_ERR_IO_NOT_WATCHED => LoopError.NotWatched,
        else => LoopError.Unknown,
    };
}
