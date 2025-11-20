const std = @import("std");

fn makeRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(b.path("include"));
    module.addCSourceFile(.{ .file = b.path("src/jzx_runtime.c") });
    module.linkSystemLibrary("pthread", .{});
    return module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const static_module = makeRuntimeModule(b, target, optimize);
    const static_lib = b.addLibrary(.{
        .name = "jzx",
        .root_module = static_module,
        .linkage = .static,
    });
    b.installArtifact(static_lib);

    const shared_module = makeRuntimeModule(b, target, optimize);
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

    const fmt = b.addFmt(.{ .paths = &.{
        "zig/jzx/lib.zig",
        "zig/tests/basic.zig",
        "examples/zig/ping.zig",
        "examples/zig/supervisor.zig",
    } });
    const fmt_step = b.step("fmt", "Run zig fmt on Zig sources");
    fmt_step.dependOn(&fmt.step);
}
