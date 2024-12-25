const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zoltan",
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("ziglua", ziglua.module("ziglua"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .test_runner = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = .Debug,
        .error_tracing = true,
        .unwind_tables = true,
        .strip = false,
    });
    const run_test = b.addRunArtifact(exe_tests);

    // Lua

    exe_tests.root_module.addImport("ziglua", ziglua.module("ziglua"));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
