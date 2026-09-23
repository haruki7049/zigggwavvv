const std = @import("std");

/// Re-export of `FormatCode` for build scripts.
///
/// A package can `@import` a dependency's `build.zig` only for its public declarations, so this is the
/// build-time entry point of zigggwavvv. Dependents such as lightmix use it in their `build.zig`
/// (`const z_wav = @import("zigggwavvv");` and `z_wav.FormatCode`). Do not remove or rename it without
/// treating that as a breaking change.
pub const FormatCode = @import("./src/root.zig").FormatCode;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const riff = b.dependency("riff_zig", .{});

    // Library module declaration
    const lib_mod = b.addModule("zigggwavvv", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "riff", .module = riff.module("riff_zig") },
        },
    });

    // Library installation
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigggwavvv",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Library unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Benchmark executable
    const bench_exe = b.addExecutable(.{
        .name = "wav-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigggwavvv", .module = lib_mod },
                .{ .name = "riff", .module = riff.module("riff_zig") },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the speed and memory benchmark");
    bench_step.dependOn(&run_bench.step);

    // Docs
    const docs_step = b.step("docs", "Emit docs");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "share/zigggwavvv/docs",
    });
    docs_step.dependOn(&docs_install.step);
}
