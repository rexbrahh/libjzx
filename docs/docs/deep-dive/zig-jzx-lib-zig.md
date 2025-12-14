---
title: Zig wrapper — zig/jzx/lib.zig
sidebar_position: 4
---

# Zig wrapper — `zig/jzx/lib.zig`

This file is a small, Zig-friendly layer over the C ABI (`include/jzx/jzx.h`). It does two main things:

1. Wraps `*c.jzx_loop` in a `Loop` type with `create/deinit/run/...` methods.
2. Provides a `Actor(State, MsgPtr)` generic that builds a typed actor interface and a C-ABI trampoline.

This page is intentionally “textbook style”: small snippets, then explanation.

## Importing the standard library and the C ABI

<!-- snippet: zig/jzx/lib.zig#L1-L5 -->
```zig title="Imports and C ABI import" showLineNumbers=1
const std = @import("std");

pub const c = @cImport({
    @cInclude("jzx/jzx.h");
});
```

- `std`: Zig standard library; used here mostly for `std.mem.Allocator`.
- `pub const c = @cImport(...)`: generates a namespace (`c`) containing all C ABI symbols:
  - types like `c.jzx_loop`, `c.jzx_actor_id`
  - constants like `c.JZX_OK`
  - functions like `c.jzx_loop_create`, `c.jzx_spawn`

Why it exists: Zig can call C directly, so this wrapper keeps the ABI as the single source of truth.

## Error mapping (`LoopError`)

<!-- snippet: zig/jzx/lib.zig#L7-L15 -->
```zig title="Zig error set used by the wrapper" showLineNumbers=7
pub const LoopError = error{
    CreateFailed,
    InvalidArgument,
    LoopClosed,
    NoSuchActor,
    IoRegistrationFailed,
    NotWatched,
    Unknown,
};
```

Zig prefers typed errors rather than magic integers. This error set is the wrapper’s opinionated mapping of `jzx_err` codes.

- `CreateFailed`: `jzx_loop_create` returned null.
- The other variants are mapped from negative error codes returned by the C runtime.

Important: this mapping is intentionally incomplete; unknown C error codes map to `.Unknown`.

## Small public helper types (behavior and context)

<!-- snippet: zig/jzx/lib.zig#L17-L27 -->
```zig title="BehaviorResult, ActorContext, SpawnOptions" showLineNumbers=17
pub const BehaviorResult = enum { ok, stop, fail };

pub const ActorContext = struct {
    loop: *c.jzx_loop,
    self: c.jzx_actor_id,
};

pub const SpawnOptions = struct {
    supervisor: c.jzx_actor_id = 0,
    mailbox_cap: u32 = 0,
};
```

These mirror key C ABI concepts in a Zig-friendly form:

- `BehaviorResult`: Zig enum that parallels `c.jzx_behavior_result`.
- `ActorContext`: a minimal context passed to typed actor behaviors.
- `SpawnOptions`: ergonomic defaults for typed actor spawn (supervisor and mailbox).

## `Loop`: RAII-ish wrapper for `*c.jzx_loop`

<!-- snippet: zig/jzx/lib.zig#L29-L72 -->
```zig title="Loop wrapper" showLineNumbers=29
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
```

Line-by-line intent:

- `ptr: *c.jzx_loop`: the wrapper’s only field; it holds the C loop pointer.
- `create(config: ?c.jzx_config) !Loop`:
  - If `config` is null, it calls `c.jzx_config_init` to fill defaults.
  - Calls `c.jzx_loop_create(&cfg)` and errors if it returns null.
- `deinit`: calls `c.jzx_loop_destroy` and then poisons `self` (`self.* = undefined`) to catch use-after-free bugs early.
- `run`: forwards to `c.jzx_loop_run` and maps a non-OK return code to a Zig error.
- `requestStop`: forwards to `c.jzx_loop_request_stop`.
- `watchFd` / `unwatchFd`: forwards to the C I/O watch APIs and maps errors.

Why this exists: it converts “raw pointers + int error codes” into an ergonomic Zig API while still being a thin wrapper.

## Compile-time guard for typed actor payloads

<!-- snippet: zig/jzx/lib.zig#L74-L79 -->
```zig title="ensurePointerType" showLineNumbers=74
fn ensurePointerType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => return,
        else => @compileError("Message pointer type must be a pointer. Use pointers to structs or opaque data."),
    }
}
```

The typed actor API requires `MsgPtr` to be a pointer type (e.g., `*MyMessage`).

Why it exists: the runtime passes `void*` payloads; the typed actor wrapper must be able to reinterpret that as a pointer safely. Rejecting non-pointer `MsgPtr` at compile time prevents an entire class of errors.

## `Actor(State, MsgPtr)`: typed actor helper

At a high level, the typed actor helper works like this:

1. Allocate a small heap object (`Shim`) holding:
   - the user’s Zig behavior function pointer
   - the user’s state pointer
2. Spawn an actor via the C ABI, but register `trampoline` as the C behavior function.
3. When the runtime calls `trampoline`, it:
   - reinterprets `ctx->state` back to `*Shim`
   - casts the message payload pointer to `MsgPtr`
   - calls the user’s typed Zig behavior
   - maps the typed result back to the C enum

### The `Actor` type factory and the `Shim`

<!-- snippet: zig/jzx/lib.zig#L81-L90 -->
```zig title="Type factory setup and shim definition" showLineNumbers=81
pub fn Actor(comptime State: type, comptime MsgPtr: type) type {
    ensurePointerType(MsgPtr);

    const BehaviorFn = *const fn (*State, MsgPtr, ActorContext) BehaviorResult;

    const Shim = struct {
        behavior: BehaviorFn,
        state: *State,
    };
```

- `Actor(comptime State, comptime MsgPtr) type`: returns a new struct type specialized to your state/message types.
- `BehaviorFn`: the typed behavior signature: `fn (*State, MsgPtr, ActorContext) BehaviorResult`.
- `Shim`: runtime-owned (allocated by the wrapper) and passed through C as an opaque `void*`.

Why the shim exists: C behaviors accept `void* state`; the shim is the bridge from that `void*` back into typed Zig values.

### The returned actor wrapper type (fields)

<!-- snippet: zig/jzx/lib.zig#L91-L98 -->
```zig title="Actor wrapper fields" showLineNumbers=91
    return struct {
        const Self = @This();

        loop: *c.jzx_loop,
        allocator: std.mem.Allocator,
        shim: *Shim,
        id: c.jzx_actor_id,
```

- `loop`: the loop the actor was spawned into (not owned by the actor wrapper).
- `allocator`: allocator used to allocate/destroy the shim.
- `shim`: pointer to the shim allocation.
- `id`: the actor id returned by the runtime.

### Spawning: allocate shim, then call into C

<!-- snippet: zig/jzx/lib.zig#L99-L128 -->
```zig title="spawn()" showLineNumbers=99
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
```

Key lines and why they exist:

- `allocator.create(Shim)`: allocates the shim object.
- `spawn_opts.behavior = trampoline`: registers the C-callable entrypoint.
- `spawn_opts.state = shim`: passes the shim through `void*`.
- On failure: `allocator.destroy(shim)` ensures no memory leak.

### Destroy: free shim (does not stop the actor)

<!-- snippet: zig/jzx/lib.zig#L130-L137 -->
```zig title="destroy() and getId()" showLineNumbers=130
        pub fn destroy(self: *Self) void {
            self.allocator.destroy(self.shim);
            self.* = undefined;
        }

        pub fn getId(self: Self) c.jzx_actor_id {
            return self.id;
        }
```

Important distinction:

- `destroy()` only frees the wrapper-owned shim allocation.
- It does **not** automatically stop the underlying actor in the runtime.

TODO: Decide whether the wrapper should offer an explicit `stop()` convenience that calls `c.jzx_actor_stop`.

### The C ABI trampoline (typed dispatch)

<!-- snippet: zig/jzx/lib.zig#L139-L148 -->
```zig title="trampoline()" showLineNumbers=139
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
```

This is the most important function in the typed actor system:

- It receives raw C pointers (`[*c]c.jzx_context`, `[*c]const c.jzx_message`).
- It reinterprets `ctx_ptr.state` as a `*Shim` (the allocation created in `spawn()`).
- It constructs a Zig `ActorContext`.
- It decodes the payload into `MsgPtr` and calls the user behavior.
- It maps the typed `BehaviorResult` back to the C enum the runtime expects.

### Decoding the message payload pointer

<!-- snippet: zig/jzx/lib.zig#L150-L156 -->
```zig title="decodeMsgPtr()" showLineNumbers=150
        fn decodeMsgPtr(message: c.jzx_message) MsgPtr {
            if (message.data) |raw| {
                const ptr: MsgPtr = @ptrCast(@alignCast(raw));
                return ptr;
            }
            @panic("typed actor received null message payload");
        }
```

This function enforces a key invariant of the typed actor API:

- `message.data` must be non-null.
- `message.data` must be aligned appropriately for `MsgPtr`.

If those assumptions are violated, the wrapper panics, because continuing would be memory-unsafe.

### Mapping result enums back to C

<!-- snippet: zig/jzx/lib.zig#L158-L165 -->
```zig title="mapBehaviorResult()" showLineNumbers=158
        fn mapBehaviorResult(result: BehaviorResult) c.jzx_behavior_result {
            return switch (result) {
                .ok => c.JZX_BEHAVIOR_OK,
                .stop => c.JZX_BEHAVIOR_STOP,
                .fail => c.JZX_BEHAVIOR_FAIL,
            };
        }
    };
```

This is a pure mapping layer: Zig enum → C enum.

## Error mapping helper (`mapError`)

<!-- snippet: zig/jzx/lib.zig#L168-L177 -->
```zig title="mapError()" showLineNumbers=168
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

This function converts C int error codes into the Zig `LoopError` error set.

Why it exists: it centralizes the mapping and keeps the wrapper methods small.
