const std = @import("std");
const builtin = @import("builtin");

const base_url = "https://gamesdb.launchbox-app.com/games/results/";

pub fn searchUrl(allocator: std.mem.Allocator, display_name: []const u8) ![]u8 {
    const title = strippedTitle(display_name);
    var size: usize = base_url.len;
    var previous_space = false;
    for (title) |byte| {
        const normalized = if (byte == '/' or byte == '\\') ' ' else byte;
        if (std.ascii.isWhitespace(normalized)) {
            if (!previous_space) size += 3;
            previous_space = true;
        } else {
            size += if (isUnreserved(normalized)) 1 else 3;
            previous_space = false;
        }
    }

    const result = try allocator.alloc(u8, size);
    @memcpy(result[0..base_url.len], base_url);
    var offset = base_url.len;
    previous_space = false;
    const hex = "0123456789ABCDEF";
    for (title) |byte| {
        const normalized = if (byte == '/' or byte == '\\') ' ' else byte;
        if (std.ascii.isWhitespace(normalized)) {
            if (previous_space) continue;
            result[offset..][0..3].* = "%20".*;
            offset += 3;
            previous_space = true;
        } else if (isUnreserved(normalized)) {
            result[offset] = normalized;
            offset += 1;
            previous_space = false;
        } else {
            result[offset] = '%';
            result[offset + 1] = hex[normalized >> 4];
            result[offset + 2] = hex[normalized & 0x0f];
            offset += 3;
            previous_space = false;
        }
    }
    return result[0..offset];
}

pub fn openSearch(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    display_name: []const u8,
) !void {
    const url = try searchUrl(allocator, display_name);
    defer allocator.free(url);

    try openUrl(allocator, io, environ, url);
}

pub fn attributedUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const separator: u8 = if (std.mem.indexOfScalar(u8, url, '?') == null) '?' else '&';
    return std.fmt.allocPrint(allocator, "{s}{c}utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", .{ url, separator });
}

pub fn openUrl(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, url: []const u8) !void {
    var system_root: ?[]u8 = null;
    defer if (system_root) |path| allocator.free(path);
    var executable: []const u8 = undefined;
    var arguments: []const []const u8 = undefined;
    switch (builtin.os.tag) {
        .windows => {
            const root = std.process.Environ.getAlloc(environ, allocator, "SystemRoot") catch try allocator.dupe(u8, "C:\\Windows");
            system_root = try std.fs.path.join(allocator, &.{ root, "System32", "rundll32.exe" });
            allocator.free(root);
            executable = system_root.?;
            arguments = &.{ executable, "url.dll,FileProtocolHandler", url };
        },
        .macos => {
            executable = "/usr/bin/open";
            arguments = &.{ executable, url };
        },
        else => {
            executable = "xdg-open";
            arguments = &.{ executable, url };
        },
    }
    var child = try std.process.spawn(io, .{
        .argv = arguments,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.BrowserLaunchFailed,
        else => return error.BrowserLaunchFailed,
    }
}

fn strippedTitle(display_name: []const u8) []const u8 {
    var title = std.mem.trim(u8, display_name, " \t");
    var end = title.len;
    while (end != 0) {
        const close = title[end - 1];
        const open: u8 = switch (close) {
            ')' => '(',
            ']' => '[',
            else => break,
        };
        const start = std.mem.lastIndexOfScalar(u8, title[0 .. end - 1], open) orelse break;
        end = std.mem.trimEnd(u8, title[0..start], " \t").len;
    }
    title = title[0..end];
    return title;
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

test "LaunchBox URL strips ROM metadata and encodes a path segment" {
    const url = try searchUrl(std.testing.allocator, "Legend of Zelda, The - Ocarina/Time (USA) (Rev 1)");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gamesdb.launchbox-app.com/games/results/Legend%20of%20Zelda%2C%20The%20-%20Ocarina%20Time",
        url,
    );
}

test "LaunchBox URL encodes UTF-8 and brackets" {
    const url = try searchUrl(std.testing.allocator, "Pokemon [Hack] - Pok\xc3\xa9mon");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://gamesdb.launchbox-app.com/games/results/Pokemon%20%5BHack%5D%20-%20Pok%C3%A9mon",
        url,
    );
}

test "project attribution uses explicit analytics parameters" {
    const plain = try attributedUrl(std.testing.allocator, "https://example.com/mod");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("https://example.com/mod?utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", plain);
    const existing = try attributedUrl(std.testing.allocator, "https://example.com/mod?version=1");
    defer std.testing.allocator.free(existing);
    try std.testing.expectEqualStrings("https://example.com/mod?version=1&utm_source=m64menu&utm_medium=desktop_app&utm_campaign=mod_catalog", existing);
}
