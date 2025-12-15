---
title: Build graph — build.zig
---

# Build graph — `build.zig`

This file is the **single source of truth** for how libjzx is built, tested, and packaged via Zig’s build system.

It creates:

- A `libjzx` runtime module that compiles **Zig + C together**:
  - Zig: `src/jzx_xev.zig` (libxev integration + C ABI wrappers)
  - C: `src/jzx_runtime.c` (runtime core)
  - Headers: `include/`
- A static library (`libjzx.a`) and a shared library (`libjzx.dylib`/`libjzx.so`/`libjzx.dll`).
- A Zig module import named `jzx` (`zig/jzx/lib.zig`).
- Test and example executables.
- A stress tool executable.
- A formatting step (`zig build fmt`).

This page explains the build graph in “textbook” style: small snippets with the explanation immediately around them.

## Cross-links {#cross-links}

- Start here: [Source index](source-index)
- Previous: [Dependency manifest — `build.zig.zon`](build-zig-zon)
- Runtime referenced here:
  - [Runtime core — `src/jzx_runtime.c`](src-jzx-runtime-c)
  - [libxev integration — `src/jzx_xev.zig`](src-jzx-xev-zig)
- Practical: [Installation](../getting-started/installation), [Quickstart](../getting-started/quickstart)

## Importing Zig’s build API {#imports}

<!-- snippet: build.zig#L1-L1 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L1"><code>build.zig#L1</code></a></div>
```zig title="Zig build API entry" showLineNumbers=1
const std = @import("std");
```

- `std` provides `std.Build` (the build graph builder) and other build-time utilities.

## The runtime module factory: `makeRuntimeModule` {#runtime-module}

The runtime is compiled as a Zig module that includes:

- `src/jzx_xev.zig` as the root Zig source file
- `src/jzx_runtime.c` as an additional C translation unit
- `include/` on the include path
- a dependency import named `xev`

<!-- snippet: build.zig#L3-L20 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L3-L20"><code>build.zig#L3-L20</code></a></div>
```zig title="makeRuntimeModule(): create a mixed Zig+C module" showLineNumbers=3
fn makeRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    xev_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/jzx_xev.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("xev", xev_module);
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{ .file = b.path("src/jzx_runtime.c") });
    module.linkSystemLibrary("pthread", .{});
    return module;
}
```

Line-by-line intent:

- `b.createModule(...)` creates a build module (roughly: “a compilation unit configuration”).
  - `.root_source_file`: sets the Zig entry point for the module.
  - `.target`: makes the module respect `-Dtarget=...` (cross compilation).
  - `.optimize`: makes the module respect `-Doptimize=...` (Debug/ReleaseFast/etc).
  - `.link_libc = true`: enables linking against libc because:
    - `src/jzx_runtime.c` uses libc (`malloc`, `free`, `memset`, etc).
    - `src/jzx_xev.zig` uses OS/libc facilities via `std`/POSIX.
- `module.addImport("xev", xev_module)` makes `@import("xev")` available inside the runtime module.
  - Why it exists: `src/jzx_xev.zig` needs libxev’s Zig module.
- `module.addIncludePath(b.path("include"))` allows C sources to include headers like `#include "jzx/jzx.h"`.
- `module.addCSourceFile(...)` compiles the C runtime implementation and links it into the module.
- `module.linkSystemLibrary("pthread", ...)` explicitly links pthreads on platforms that require it.
  - Why it exists: libxev and/or async primitives may rely on threading primitives.

## The build entrypoint: `pub fn build` {#build-entrypoint}

Zig calls `build(b)` as the root of the build graph. Everything else hangs off of this.

### Target and optimization options

<!-- snippet: build.zig#L22-L28 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L22-L27"><code>build.zig#L22-L27</code></a></div>
```zig title="Target/optimize + dependency import" showLineNumbers=22
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const xev_module = libxev.module("xev");
```

What’s happening:

- `standardTargetOptions` and `standardOptimizeOption` wire the common CLI flags into the build:
  - `zig build -Dtarget=...`
  - `zig build -Doptimize=ReleaseFast` (etc)
- `b.dependency("libxev", ...)` requests the dependency declared in `build.zig.zon`.
  - Why it exists: the repo doesn’t assume a system-installed libxev; Zig will fetch/cache it.
- `libxev.module("xev")` retrieves the Zig module exported by libxev so we can import it into our own module.

### Building the C/Zig runtime as libraries

This repo builds both:

- a **static** library for embedding
- a **shared** library for dynamic linking / FFI experimentation

<!-- snippet: build.zig#L29-L45 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L29-L44"><code>build.zig#L29-L44</code></a></div>
```zig title="Static + shared libraries" showLineNumbers=29
    const static_module = makeRuntimeModule(b, target, optimize, xev_module);
    const static_lib = b.addLibrary(.{
        .name = "jzx",
        .root_module = static_module,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    const shared_module = makeRuntimeModule(b, target, optimize, xev_module);
    const shared_lib = b.addLibrary(.{
        .name = "jzx",
        .root_module = shared_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(shared_lib);
```

Notes:

- Both libraries share the same source set (the runtime module factory).
- `installArtifact(...)` attaches the library to the default install step (so `zig build` produces it under `zig-out/`).
- The shared library has an explicit version.
  - Why it exists: it’s useful metadata for dynamic linking workflows.

### Installing public headers

<!-- snippet: build.zig#L46-L51 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L46-L51"><code>build.zig#L46-L51</code></a></div>
```zig title="Install include/ as headers" showLineNumbers=46
    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "jzx",
    });
    b.getInstallStep().dependOn(&install_headers.step);
```

What this does:

- Copies `include/` into the install prefix under the “header” directory.
- The `install_subdir = "jzx"` means downstream include paths can look like `.../include/jzx/...`.

Why the explicit `dependOn`:

- `installArtifact` hooks artifacts into the install step automatically.
- `addInstallDirectory` creates a separate step, so we must depend on it to ensure headers are installed too.

### Exporting a Zig wrapper module (`@import("jzx")`)

The Zig wrapper (`zig/jzx/lib.zig`) is exposed as a build module named `"jzx"`.

<!-- snippet: build.zig#L53-L60 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L53-L60"><code>build.zig#L53-L60</code></a></div>
```zig title="Expose zig/jzx/lib.zig as module 'jzx'" showLineNumbers=53
    const jzx_module = b.addModule("jzx", .{
        .root_source_file = b.path("zig/jzx/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    jzx_module.addIncludePath(b.path("include"));
    jzx_module.linkLibrary(static_lib);
    jzx_module.linkSystemLibrary("pthread", .{});
```

Why it’s wired this way:

- `jzx_module.addIncludePath("include")` allows the wrapper to import C headers via `@cImport`.
- `linkLibrary(static_lib)` ensures Zig code that imports `jzx` automatically links against the runtime.

### Tests (`zig build test`)

The test suite is a Zig test artifact built from `zig/tests/basic.zig`.

<!-- snippet: build.zig#L62-L72 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L62-L72"><code>build.zig#L62-L72</code></a></div>
```zig title="Test step wiring" showLineNumbers=62
    const tests_module = b.createModule(.{
        .root_source_file = b.path("zig/tests/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const tests = b.addTest(.{ .root_module = tests_module });

    const test_step = b.step("test", "Run Zig bindings tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
```

The “shape” here is:

- create a module with `imports = { jzx }`
- build a test artifact from it
- create a named step (`"test"`)
- attach a run step so `zig build test` actually executes the tests

### Examples (`zig build examples`)

The examples are installed as executables under `zig-out/bin/`.

<!-- snippet: build.zig#L74-L127 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L74-L126"><code>build.zig#L74-L126</code></a></div>
```zig title="Examples step wiring" showLineNumbers=74
    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/ping.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_example = b.addExecutable(.{
        .name = "zig-example",
        .root_module = example_module,
    });
    b.installArtifact(zig_example);

    const example_step = b.step("examples", "Build example binaries");
    example_step.dependOn(&zig_example.step);

    const sup_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/supervisor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_sup = b.addExecutable(.{
        .name = "zig-supervisor",
        .root_module = sup_module,
    });
    b.installArtifact(zig_sup);
    example_step.dependOn(&zig_sup.step);

    const echo_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/echo_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_echo = b.addExecutable(.{
        .name = "zig-echo-server",
        .root_module = echo_module,
    });
    b.installArtifact(zig_echo);
    example_step.dependOn(&zig_echo.step);

    const typed_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/typed_actor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_typed = b.addExecutable(.{
        .name = "zig-typed-actor",
        .root_module = typed_module,
    });
    b.installArtifact(zig_typed);
    example_step.dependOn(&zig_typed.step);
```

Why there’s an explicit `examples` step:

- It provides a discoverable entry point: `zig build examples`
- It acts as a grouping mechanism (build all examples with one command)

Important subtlety:

- Each example imports the `jzx` module, which already links the runtime.
- The `example_step.dependOn(&exe.step)` pattern ensures the build step builds these artifacts even if the default install step isn’t run.

### Stress tool (`zig build stress`)

The stress tool is a normal executable wired into a named step.

<!-- snippet: build.zig#L128-L143 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L128-L143"><code>build.zig#L128-L143</code></a></div>
```zig title="Stress tool step wiring" showLineNumbers=128
    const stress_module = b.createModule(.{
        .root_source_file = b.path("tools/stress.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const stress_exe = b.addExecutable(.{
        .name = "jzx-stress",
        .root_module = stress_module,
    });
    b.installArtifact(stress_exe);

    const stress_step = b.step("stress", "Run stress tools (smoke)");
    const run_stress = b.addRunArtifact(stress_exe);
    run_stress.addArgs(&.{"--smoke"});
    stress_step.dependOn(&run_stress.step);
```

The important UX detail is `addArgs(&.{"--smoke"})`:

- `zig build stress` runs a shorter smoke variant by default to keep CI times reasonable.

### Formatting (`zig build fmt`)

The `fmt` step is a curated list of Zig source files to run `zig fmt` on.

<!-- snippet: build.zig#L145-L158 -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L145-L158"><code>build.zig#L145-L158</code></a></div>
```zig title="zig fmt step" showLineNumbers=145
    const fmt = b.addFmt(.{ .paths = &.{
        "build.zig",
        "src/jzx_xev.zig",
        "zig/jzx/lib.zig",
        "zig/tests/basic.zig",
        "examples/zig/echo_server.zig",
        "examples/zig/ping.zig",
        "examples/zig/supervisor.zig",
        "examples/zig/typed_actor.zig",
        "tools/stress.zig",
    } });
    const fmt_step = b.step("fmt", "Run zig fmt on Zig sources");
    fmt_step.dependOn(&fmt.step);
}
```

Why the list is explicit (instead of formatting “everything”):

- It ensures formatting applies to exactly the sources that should be Zig-formatted.
- It avoids formatting vendored dependencies or generated files.

## Full listing (for reference) {#full-listing}

<!-- snippet: build.zig#all -->
<div className="jzx-source">Source: <a href="https://github.com/rexbrahh/libjzx/blob/main/build.zig#L1-L158"><code>build.zig#L1-L158</code></a></div>
```zig title="build.zig" showLineNumbers=1
const std = @import("std");

fn makeRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    xev_module: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/jzx_xev.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("xev", xev_module);
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{ .file = b.path("src/jzx_runtime.c") });
    module.linkSystemLibrary("pthread", .{});
    return module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const xev_module = libxev.module("xev");

    const static_module = makeRuntimeModule(b, target, optimize, xev_module);
    const static_lib = b.addLibrary(.{
        .name = "jzx",
        .root_module = static_module,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    const shared_module = makeRuntimeModule(b, target, optimize, xev_module);
    const shared_lib = b.addLibrary(.{
        .name = "jzx",
        .root_module = shared_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    b.installArtifact(shared_lib);

    const install_headers = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "jzx",
    });
    b.getInstallStep().dependOn(&install_headers.step);

    const jzx_module = b.addModule("jzx", .{
        .root_source_file = b.path("zig/jzx/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    jzx_module.addIncludePath(b.path("include"));
    jzx_module.linkLibrary(static_lib);
    jzx_module.linkSystemLibrary("pthread", .{});

    const tests_module = b.createModule(.{
        .root_source_file = b.path("zig/tests/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const tests = b.addTest(.{ .root_module = tests_module });

    const test_step = b.step("test", "Run Zig bindings tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/ping.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_example = b.addExecutable(.{
        .name = "zig-example",
        .root_module = example_module,
    });
    b.installArtifact(zig_example);

    const example_step = b.step("examples", "Build example binaries");
    example_step.dependOn(&zig_example.step);

    const sup_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/supervisor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_sup = b.addExecutable(.{
        .name = "zig-supervisor",
        .root_module = sup_module,
    });
    b.installArtifact(zig_sup);
    example_step.dependOn(&zig_sup.step);

    const echo_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/echo_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_echo = b.addExecutable(.{
        .name = "zig-echo-server",
        .root_module = echo_module,
    });
    b.installArtifact(zig_echo);
    example_step.dependOn(&zig_echo.step);

    const typed_module = b.createModule(.{
        .root_source_file = b.path("examples/zig/typed_actor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const zig_typed = b.addExecutable(.{
        .name = "zig-typed-actor",
        .root_module = typed_module,
    });
    b.installArtifact(zig_typed);
    example_step.dependOn(&zig_typed.step);

    const stress_module = b.createModule(.{
        .root_source_file = b.path("tools/stress.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jzx", .module = jzx_module }},
    });
    const stress_exe = b.addExecutable(.{
        .name = "jzx-stress",
        .root_module = stress_module,
    });
    b.installArtifact(stress_exe);

    const stress_step = b.step("stress", "Run stress tools (smoke)");
    const run_stress = b.addRunArtifact(stress_exe);
    run_stress.addArgs(&.{"--smoke"});
    stress_step.dependOn(&run_stress.step);

    const fmt = b.addFmt(.{ .paths = &.{
        "build.zig",
        "src/jzx_xev.zig",
        "zig/jzx/lib.zig",
        "zig/tests/basic.zig",
        "examples/zig/echo_server.zig",
        "examples/zig/ping.zig",
        "examples/zig/supervisor.zig",
        "examples/zig/typed_actor.zig",
        "tools/stress.zig",
    } });
    const fmt_step = b.step("fmt", "Run zig fmt on Zig sources");
    fmt_step.dependOn(&fmt.step);
}
```
