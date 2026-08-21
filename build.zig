const std = @import("std");

pub fn build(b: *std.Build) void {
    const bootstrap = b.addSystemCommand(&.{
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "tools/bootstrap-native.ps1",
    });
    bootstrap.addArg("-Zig");
    bootstrap.addArg(b.graph.zig_exe);

    const menu = b.step("menu", "Build sc64menu.n64 using the native Windows toolchain");
    menu.dependOn(&bootstrap.step);
    b.default_step.dependOn(menu);
}
