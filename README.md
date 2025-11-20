# libjzx

Early scaffold for libjzx, a libxev-backed actor runtime. This repository currently provides:

- C headers in `include/jzx/` describing the public ABI
- A runnable single-threaded runtime core in `src/` with actor tables, mailboxes, timers, and a cooperative scheduler
- Zig wrapper + tooling under `zig/`
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
```

### Quick smoke tests

```sh
zig build test        # exercises sync send, async send, and timer delivery from Zig
zig build examples    # builds the Zig example and links it against the runtime
cc examples/c/loop.c src/jzx_runtime.c -Iinclude -lpthread -o /tmp/jzx_example && /tmp/jzx_example
```

These exercises instantiate the runtime, spawn actors, verify timers (`jzx_send_after`), and drive the scheduler until all queued work completes.

Each subsystem has its own placeholder implementation so new contributors can iterate on runtime behavior, Zig ergonomics, or examples independently.
