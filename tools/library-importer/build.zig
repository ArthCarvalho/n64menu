const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });

    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("zigimg", zigimg.module("zigimg"));

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.addImport("sokol", sokol.module("sokol"));
    app.addImport("importer", core);

    const exe = b.addExecutable(.{ .name = "m64importer", .root_module = app });
    b.installArtifact(exe);

    const check = b.step("check", "Compile m64importer without installing");
    check.dependOn(&exe.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run m64importer");
    run_step.dependOn(&run.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("zigimg", zigimg.module("zigimg"));
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run importer core tests");
    test_step.dependOn(&run_tests.step);
}
