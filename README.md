# libjzx

Early scaffold for libjzx, a libxev-backed actor runtime. This repository currently provides:

- C headers in `include/jzx/` describing the public ABI
- A runnable single-threaded runtime core in `src/` with actor tables, mailboxes, timers, and basic I/O watchers
- Zig wrapper + tooling under `zig/` (including typed actor helpers)
- Example programs in `examples/` and a starter test in `zig/tests/`

## Building

The project standardizes on Zig 0.15.1 for orchestrating builds:

```sh
zig build           # builds static + shared libraries and installs headers
zig build test      # runs Zig wrapper tests (links against the C runtime)
zig build examples  # compiles the sample Zig program under examples/zig
zig build fmt       # formats Zig sources
```

The generated artifacts and headers will land under `zig-out/` following Zig’s install conventions (`include/jzx`, `lib/libjzx.{a,so}` on Unix, `.dylib` on macOS).

## Directory layout

```
include/jzx/    C headers (public ABI)
src/            C runtime implementation
zig/jzx/        Zig bindings over the C ABI
zig/tests/      Zig-based integration/unit tests
examples/c/     Plain C samples
examples/zig/   Zig samples leveraging the wrapper

### Zig typed actors

The Zig bindings expose `jzx.Actor(State, *Message)` to keep typed state/message handling on the Zig side. See `examples/zig/typed_actor.zig` for a minimal counter.
```

### Quick smoke tests

```sh
zig build test        # exercises sync/async send, timers, and I/O watchers from Zig
zig build examples    # builds the Zig example and links it against the runtime
cc examples/c/loop.c src/jzx_runtime.c -Iinclude -lpthread -o /tmp/jzx_example && /tmp/jzx_example
cc examples/c/supervisor.c src/jzx_runtime.c -Iinclude -lpthread -o /tmp/jzx_sup && /tmp/jzx_sup
zig build examples    # also builds zig-supervisor; run zig-out/bin/zig-supervisor
```

These exercises instantiate the runtime, spawn actors, verify timers/I-O (`jzx_send_after`, `jzx_watch_fd`), and drive the scheduler until all queued work completes.

Each subsystem has its own placeholder implementation so new contributors can iterate on runtime behavior, Zig ergonomics, or examples independently.

### Supervision

- C example: `examples/c/supervisor.c`
- Zig example: `examples/zig/supervisor.zig`
- Design/usage notes: `docs/supervision.md`

### Nix + direnv dev shell

The repo ships with a flake-based development shell. If you use [direnv](https://direnv.net/):

```sh
direnv allow   # loads the flake-defined shell (requires Nix 2.4+)
```

The shell provides Zig, clang/LLVM, pkg-config, and build tools so `zig build ...` commands Just Work on macOS and Linux.
