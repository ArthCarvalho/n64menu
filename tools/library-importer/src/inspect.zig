const std = @import("std");
const builtin = @import("builtin");
const importer = @import("importer");
const deployer = @import("deployer");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout.interface.flush() catch {};

    var environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = try init.environ_map.createPosixBlock(allocator, .{}) };
    defer if (builtin.os.tag != .windows) environ.block.deinit(allocator);

    var scan = try importer.scanRetroArchLibrary(allocator, init.io, .{ .environ = environ });
    defer scan.deinit(allocator);
    try stdout.interface.print("playlist={s}\nentries={d} resolved={d} unsupported={d} selected={d}\n", .{
        scan.source.playlist_path,
        scan.source.playlist_entries,
        scan.source.resolved_entries,
        scan.source.unsupported_entries,
        scan.preview.titles.len,
    });

    const deployer_path = try deployer.locate(allocator, init.io, null);
    defer allocator.free(deployer_path);
    var devices = try deployer.detectDevices(allocator, init.io, deployer_path);
    defer devices.deinit(allocator);
    if (devices.devices.len == 0) return;
    const device = devices.devices[0];
    var installed = try deployer.readInstalledLibraryOptions(allocator, init.io, deployer_path, device.port, .{ .environ = environ });
    defer installed.deinit(allocator);

    const desired = try allocator.alloc(deployer.InstalledTitle, scan.preview.titles.len);
    defer allocator.free(desired);
    for (scan.preview.titles, 0..) |title, index| desired[index] = .{ .id = title.id, .name = title.display_name };
    const diff = deployer.diffLibrary(desired, installed.titles);
    try stdout.interface.print("device={s} port={s} installed={d} add={d} keep={d} update={d} hide={d}\n", .{
        device.serial,
        device.port,
        installed.titles.len,
        diff.add,
        diff.keep,
        diff.update,
        diff.remove,
    });
}
