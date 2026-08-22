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
    const sdcard = b.createModule(.{
        .root_source_file = b.path("src/sdcard.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.addImport("sokol", sokol.module("sokol"));
    app.addImport("importer", core);
    app.addImport("sdcard", sdcard);
    app.addImport("startup", b.createModule(.{
        .root_source_file = b.path("src/startup.zig"),
        .target = target,
        .optimize = optimize,
    }));
    app.addImport("ui_scale", b.createModule(.{
        .root_source_file = b.path("src/ui_scale.zig"),
        .target = target,
        .optimize = optimize,
    }));
    app.addImport("deployer", b.createModule(.{
        .root_source_file = b.path("src/deployer.zig"),
        .target = target,
        .optimize = optimize,
    }));

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
        .optimize = .ReleaseSafe,
    });
    tests_mod.addImport("zigimg", zigimg.module("zigimg"));
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run importer core tests");
    test_step.dependOn(&run_tests.step);

    const deployer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/deployer.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_deployer_tests = b.addRunArtifact(deployer_tests);
    // Zig 0.16 can otherwise compile both large test artifacts concurrently;
    // serializing them avoids a Linux compiler crash under constrained CI memory.
    run_deployer_tests.step.dependOn(&run_tests.step);
    test_step.dependOn(&run_deployer_tests.step);

    const sdcard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdcard.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_sdcard_tests = b.addRunArtifact(sdcard_tests);
    run_sdcard_tests.step.dependOn(&run_deployer_tests.step);
    test_step.dependOn(&run_sdcard_tests.step);

    const startup_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/startup.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_startup_tests = b.addRunArtifact(startup_tests);
    run_startup_tests.step.dependOn(&run_sdcard_tests.step);
    test_step.dependOn(&run_startup_tests.step);

    const ui_scale_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui_scale.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_ui_scale_tests = b.addRunArtifact(ui_scale_tests);
    run_ui_scale_tests.step.dependOn(&run_startup_tests.step);
    test_step.dependOn(&run_ui_scale_tests.step);

    const inspect_mod = b.createModule(.{
        .root_source_file = b.path("src/inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    inspect_mod.addImport("importer", core);
    inspect_mod.addImport("deployer", app.import_table.get("deployer").?);
    const inspect_exe = b.addExecutable(.{ .name = "m64inspect", .root_module = inspect_mod });
    const inspect_run = b.addRunArtifact(inspect_exe);
    const inspect_step = b.step("inspect", "Print detected RetroArch and SummerCart state without writing");
    inspect_step.dependOn(&inspect_run.step);
}
