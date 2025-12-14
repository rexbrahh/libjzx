---
title: Zig wrapper — zig/jzx/lib.zig (annotated)
sidebar_position: 4
---

# Zig wrapper — `zig/jzx/lib.zig`

This file exposes a small Zig-friendly surface over the C ABI:

- `Loop`: RAII-ish wrapper around `*c.jzx_loop`
- `Actor(State, MsgPtr)`: a typed actor helper that converts a Zig function into a `jzx_behavior_fn`

## Full source (with line numbers)

```zig title="zig/jzx/lib.zig" showLineNumbers
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
                .name = null,
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
```

## Line-by-line commentary

| Line | What it is / why it exists |
| ---: | --- |
| 1 | Imports Zig’s standard library as `std` for allocators and builtins. |
| 2 | Blank line separating imports from public API exports. |
| 3 | Exposes `c`, the namespace produced by `@cImport` of the public C ABI header. |
| 4 | `@cInclude("jzx/jzx.h")` pulls in the public ABI; this is how Zig sees `c.jzx_loop`, `c.jzx_spawn`, etc. |
| 5 | Closes the `@cImport` block. |
| 6 | Blank line. |
| 7 | Defines `LoopError`, the Zig error set this wrapper uses instead of raw negative ints. |
| 8 | `CreateFailed`: `jzx_loop_create` returned null. |
| 9 | `InvalidArgument`: caller provided invalid inputs (`JZX_ERR_INVALID_ARG`). |
| 10 | `LoopClosed`: loop is closed/stopped (`JZX_ERR_LOOP_CLOSED`). |
| 11 | `NoSuchActor`: target actor id is invalid/stale (`JZX_ERR_NO_SUCH_ACTOR`). |
| 12 | `IoRegistrationFailed`: backend failed to register I/O watcher (`JZX_ERR_IO_REG_FAILED`). |
| 13 | `NotWatched`: fd was not watched (`JZX_ERR_IO_NOT_WATCHED`). |
| 14 | `Unknown`: fallback for all other C error codes. |
| 15 | Closes the error set definition. |
| 16 | Blank line. |
| 17 | Defines `BehaviorResult`, a Zig-level enum mirroring `c.jzx_behavior_result`. |
| 18 | Blank line. |
| 19 | Defines `ActorContext`, a Zig-friendly subset of `c.jzx_context`. |
| 20 | `loop`: pointer to the runtime loop, used for calling back into C APIs. |
| 21 | `self`: the actor id of the currently running actor. |
| 22 | Closes the struct. |
| 23 | Blank line. |
| 24 | Defines `SpawnOptions`, convenience defaults for typed actor spawn. |
| 25 | `supervisor`: optional supervisor id (0 means root/unmanaged). |
| 26 | `mailbox_cap`: optional mailbox capacity override (0 means runtime default). |
| 27 | Closes spawn options struct. |
| 28 | Blank line. |
| 29 | Defines `Loop`, a small wrapper around the raw `*c.jzx_loop` pointer. |
| 30 | `ptr`: the owned loop pointer; freed by `deinit`. |
| 31 | Blank line. |
| 32 | `create`: constructs a `Loop`, optionally taking an already-filled `c.jzx_config`. |
| 33 | `config orelse blk`: if no config provided, build one using `jzx_config_init`. |
| 34 | Declares `tmp` config as `undefined` (uninitialized) to be filled by C. |
| 35 | Calls `c.jzx_config_init` to set defaults. |
| 36 | `break :blk tmp` returns the initialized config from the block expression. |
| 37 | Ends the block expression and binds the result to `cfg`. |
| 38 | Blank line. |
| 39 | Calls into C to allocate/init the loop; returns nullable pointer. |
| 40 | Checks for `null` and maps it to a Zig error instead of a null deref. |
| 41 | Returns `LoopError.CreateFailed` if allocation failed. |
| 42 | Ends the null check. |
| 43 | Constructs the wrapper with the non-null pointer (`.?` unwrap). |
| 44 | Ends `create`. |
| 45 | Blank line. |
| 46 | `deinit`: destroys the loop and poisons `self` to catch use-after-free. |
| 47 | Calls the C destructor, which should free all loop-owned resources. |
| 48 | `self.* = undefined` is a defensive pattern to make accidental reuse crash earlier. |
| 49 | Ends `deinit`. |
| 50 | Blank line. |
| 51 | `run`: enters the C event loop. On error, maps the C int code to a Zig error. |
| 52 | Calls `c.jzx_loop_run`; returns an int error code. |
| 53 | If `JZX_OK`, return success (`void`). |
| 54 | Otherwise map the error code into a `LoopError`. |
| 55 | Ends `run`. |
| 56 | Blank line. |
| 57 | `requestStop`: signals the loop to stop cooperatively. |
| 58 | Forwards directly to `c.jzx_loop_request_stop`. |
| 59 | Ends `requestStop`. |
| 60 | Blank line. |
| 61 | `watchFd`: registers fd interest for an actor (I/O readiness → messages). |
| 62 | Calls C `jzx_watch_fd` and captures return code. |
| 63 | If OK, return success. |
| 64 | Otherwise map error. |
| 65 | Ends `watchFd`. |
| 66 | Blank line. |
| 67 | `unwatchFd`: unregisters fd. |
| 68 | Calls C `jzx_unwatch_fd`. |
| 69 | If OK, return success. |
| 70 | Otherwise map error. |
| 71 | Ends `unwatchFd`. |
| 72 | Ends `Loop` struct. |
| 73 | Blank line. |
| 74 | `ensurePointerType`: compile-time guard for typed actor message pointers. |
| 75 | Uses `@typeInfo` to inspect the compile-time type parameter. |
| 76 | Accepts only pointer types (e.g., `*MyMsg`, `*const MyMsg`, `[*]u8`, etc.). |
| 77 | Otherwise fails compilation with a helpful error message. |
| 78 | Ends the switch. |
| 79 | Ends `ensurePointerType`. |
| 80 | Blank line. |
| 81 | `Actor(State, MsgPtr)`: generic factory that returns a typed actor wrapper type. |
| 82 | Enforces `MsgPtr` is a pointer type at compile time. |
| 83 | Blank line. |
| 84 | `BehaviorFn`: Zig function pointer signature the user provides for typed actors. |
| 85 | Blank line. |
| 86 | `Shim`: heap-allocated struct holding the behavior function pointer and state pointer. |
| 87 | `behavior`: the user’s handler function. |
| 88 | `state`: pointer to user-managed state. |
| 89 | Ends `Shim`. |
| 90 | Blank line. |
| 91 | Returns the concrete actor wrapper struct type. This struct owns the `Shim` allocation. |
| 92 | `Self`: alias for the returned struct type itself. |
| 93 | Blank line. |
| 94 | `loop`: the loop pointer the actor was spawned into. |
| 95 | `allocator`: allocator used to allocate/free the `Shim`. |
| 96 | `shim`: pointer to the heap-allocated shim for this actor. |
| 97 | `id`: actor id assigned by the runtime. |
| 98 | Blank line. |
| 99 | `spawn`: allocates the shim, wires up a C ABI trampoline, and calls `c.jzx_spawn`. |
| 100 | `loop`: raw loop pointer to spawn into (the typed actor doesn’t own the loop). |
| 101 | `allocator`: allocator used to allocate the shim. |
| 102 | `state`: user state pointer. |
| 103 | `behavior`: typed behavior function pointer. |
| 104 | `opts`: spawn options (supervisor and mailbox). |
| 105 | Returns `!Self` (either a typed actor wrapper or an error). |
| 106 | Allocates a `Shim` on the heap. |
| 107 | Stores the behavior and state pointers into the shim. |
| 108 | Blank line. |
| 109 | Builds a C `jzx_spawn_opts` struct; the critical field is `.behavior = trampoline`. |
| 110 | `trampoline`: C-callable function that converts C pointers into typed Zig values. |
| 111 | `.state = shim`: passes the shim through the C API as an opaque `void*`. |
| 112 | `.supervisor`: passes through supervisor id. |
| 113 | `.mailbox_cap`: passes through mailbox cap. |
| 114 | `.name = null`: no name by default (could be extended to accept names). |
| 115 | Closes the spawn options literal. |
| 116 | Initializes `actor_id` output var for C to fill. |
| 117 | Calls `c.jzx_spawn` to create the actor. |
| 118 | Checks return code for failure. |
| 119 | On failure, free the shim to avoid leaking memory. |
| 120 | Map the error code. |
| 121 | Ends error path. |
| 122 | Returns the typed actor wrapper with references to loop/allocator/shim/id. |
| 123 | Stores the loop pointer (not owned). |
| 124 | Stores allocator so `destroy` can free the shim. |
| 125 | Stores shim pointer. |
| 126 | Stores id. |
| 127 | Closes the return struct literal. |
| 128 | Ends `spawn`. |
| 129 | Blank line. |
| 130 | `destroy`: frees the shim allocation and poisons the wrapper. |
| 131 | Destroys the heap allocation for the shim. |
| 132 | Poisons wrapper to catch accidental use after destroy. |
| 133 | Ends `destroy`. |
| 134 | Blank line. |
| 135 | `getId`: returns the actor id (useful for sends or linking). |
| 136 | Returns the `id` field. |
| 137 | Ends `getId`. |
| 138 | Blank line. |
| 139 | `trampoline`: C ABI entrypoint called by the runtime when delivering messages. |
| 140 | `ctx.*` dereferences the C pointer to a `c.jzx_context` struct value. |
| 141 | Reinterprets `ctx_ptr.state` as `*Shim` (undoes the cast performed at spawn). |
| 142 | Builds a Zig `ActorContext` with a non-null loop and actor id. |
| 143 | Unwraps `ctx_ptr.loop` (nullable in C) into non-null. |
| 144 | Copies actor id. |
| 145 | Closes context literal. |
| 146 | Decodes the message payload pointer into the user’s `MsgPtr`. |
| 147 | Calls the user behavior and maps the result to the C enum expected by runtime. |
| 148 | Ends `trampoline`. |
| 149 | Blank line. |
| 150 | `decodeMsgPtr`: converts the C `void*` payload into the typed message pointer type. |
| 151 | Checks that the payload is non-null. |
| 152 | Casts the raw pointer to the desired message pointer type with alignment enforcement. |
| 153 | Returns the typed pointer. |
| 154 | Ends the non-null branch. |
| 155 | Panics if the payload is null because the typed actor API assumes a payload exists. |
| 156 | Ends `decodeMsgPtr`. |
| 157 | Blank line. |
| 158 | `mapBehaviorResult`: maps Zig enum to C enum so the runtime can interpret it. |
| 159 | Uses a switch to map each enum tag. |
| 160 | `.ok` → `JZX_BEHAVIOR_OK`. |
| 161 | `.stop` → `JZX_BEHAVIOR_STOP`. |
| 162 | `.fail` → `JZX_BEHAVIOR_FAIL`. |
| 163 | Ends the switch. |
| 164 | Ends `mapBehaviorResult`. |
| 165 | Ends the returned actor wrapper struct type. |
| 166 | Ends `Actor` type factory. |
| 167 | Blank line. |
| 168 | `mapError`: converts C int error codes into Zig `LoopError` values. |
| 169 | Switch on numeric error codes. |
| 170 | Invalid arg mapping. |
| 171 | Loop closed mapping. |
| 172 | No such actor mapping. |
| 173 | I/O registration failed mapping. |
| 174 | Not watched mapping. |
| 175 | Fallback to unknown. |
| 176 | Ends the switch. |
| 177 | Ends `mapError`. |
