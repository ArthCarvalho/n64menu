const std = @import("std");
const zigimg = @import("zigimg");

pub const maximum_titles = 40;
pub const maximum_rom_size = 78 * 1024 * 1024;
pub const sprite_width = 256;
pub const sprite_height = 179;

const rom_extensions = [_][]const u8{ ".n64", ".v64", ".z64" };
const image_extensions = [_][]const u8{ ".bmp", ".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff" };

pub const Config = struct {
    output_root: []const u8,
    rom_root: []const u8,
    image_root: ?[]const u8 = null,
    /// May point either at Named_Boxarts or at its parent directory.
    retroarch_thumbnail_root: ?[]const u8 = null,
    recursive: bool = false,
};

pub const ArtworkStatus = enum {
    exact_sibling,
    sole_sibling,
    image_root_exact,
    image_root_normalized,
    retroarch_exact,
    retroarch_normalized,
    generated,
};

pub const Title = struct {
    rom_path: []u8,
    display_name: []u8,
    id: [5]u8,
    artwork_path: ?[]u8,
    artwork_status: ArtworkStatus,

    fn deinit(self: *Title, allocator: std.mem.Allocator) void {
        allocator.free(self.rom_path);
        allocator.free(self.display_name);
        if (self.artwork_path) |path| allocator.free(path);
    }
};

pub const ScanResult = struct {
    titles: []Title,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        for (self.titles) |*title| title.deinit(allocator);
        allocator.free(self.titles);
        self.* = undefined;
    }
};

pub const ProgressEvent = struct {
    completed: usize,
    total: usize,
    title: *const Title,
};

pub const Progress = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, ProgressEvent) void,
};

const Match = struct {
    path: []const u8,
    status: ArtworkStatus,
};

const ByteOrder = enum { z64, v64, n64 };

pub fn scanLibrary(allocator: std.mem.Allocator, io: std.Io, config: Config) !ScanResult {
    try validateDirectory(io, config.output_root);
    try validateDirectory(io, config.rom_root);
    if (config.image_root) |path| try validateDirectory(io, path);

    const retro_root = if (config.retroarch_thumbnail_root) |path|
        try resolveRetroRoot(allocator, io, path)
    else
        null;
    defer if (retro_root) |path| allocator.free(path);

    var roms: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &roms);
    try collectFiles(allocator, io, config.rom_root, config.recursive, &rom_extensions, &roms);
    std.mem.sort([]u8, roms.items, {}, pathLessThan);
    if (roms.items.len == 0) return error.NoRomsFound;
    if (roms.items.len > maximum_titles) return error.TooManyTitles;

    var images: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &images);
    if (config.image_root) |path| {
        try collectFiles(allocator, io, path, config.recursive, &image_extensions, &images);
        std.mem.sort([]u8, images.items, {}, pathLessThan);
    }

    var retro_images: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &retro_images);
    if (retro_root) |path| {
        try collectFiles(allocator, io, path, false, &image_extensions, &retro_images);
        std.mem.sort([]u8, retro_images.items, {}, pathLessThan);
    }

    var titles: std.ArrayList(Title) = .empty;
    errdefer {
        for (titles.items) |*title| title.deinit(allocator);
        titles.deinit(allocator);
    }

    for (roms.items) |rom_path| {
        const normalized = try readNormalizedRom(allocator, io, rom_path);
        defer allocator.free(normalized);
        const id = normalizedId(normalized);
        for (titles.items) |title| if (std.mem.eql(u8, &title.id, &id)) return error.IdCollision;

        const display_name = try allocator.dupe(u8, basenameWithoutExtension(rom_path));
        errdefer allocator.free(display_name);
        const match = try findArtwork(allocator, io, rom_path, images.items, retro_images.items);
        errdefer if (match) |found| allocator.free(found.path);
        try titles.append(allocator, .{
            .rom_path = try allocator.dupe(u8, rom_path),
            .display_name = display_name,
            .id = id,
            .artwork_path = if (match) |found| @constCast(found.path) else null,
            .artwork_status = if (match) |found| found.status else .generated,
        });
    }
    return .{ .titles = try titles.toOwnedSlice(allocator) };
}

/// Imports all scanned titles and returns the same owned preview data for UI display.
pub fn importLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    progress: ?Progress,
) !ScanResult {
    var result = try scanLibrary(allocator, io, config);
    errdefer result.deinit(allocator);

    const cwd = std.Io.Dir.cwd();
    const title_root = try std.fs.path.join(allocator, &.{ config.output_root, "menu", "title" });
    defer allocator.free(title_root);
    try cwd.createDirPath(io, title_root);

    for (result.titles, 0..) |*title, index| {
        const destination = try std.fs.path.join(allocator, &.{ title_root, &title.id });
        defer allocator.free(destination);
        try cwd.createDirPath(io, destination);

        const rom = try readNormalizedRom(allocator, io, title.rom_path);
        defer allocator.free(rom);
        const rom_path = try outputPath(allocator, destination, title.id, "_e.z64");
        defer allocator.free(rom_path);
        try cwd.writeFile(io, .{ .sub_path = rom_path, .data = rom });

        const name_path = try outputPath(allocator, destination, title.id, "_e.name");
        defer allocator.free(name_path);
        const ascii_name = try asciiText(allocator, title.display_name);
        defer allocator.free(ascii_name);
        try cwd.writeFile(io, .{ .sub_path = name_path, .data = ascii_name });

        const sprite_path = try outputPath(allocator, destination, title.id, "_e.sprite");
        defer allocator.free(sprite_path);
        if (title.artwork_path) |artwork_path| {
            try writeArtworkSprite(allocator, io, artwork_path, sprite_path);
        } else {
            try writeGeneratedSprite(allocator, io, title.display_name, sprite_path);
        }
        if (progress) |reporter| reporter.callback(reporter.context, .{
            .completed = index + 1,
            .total = result.titles.len,
            .title = title,
        });
    }

    const csv = try titleCsvBytes(allocator, result.titles);
    defer allocator.free(csv);
    const csv_path = try std.fs.path.join(allocator, &.{ config.output_root, "menu", "title.csv" });
    defer allocator.free(csv_path);
    try cwd.writeFile(io, .{ .sub_path = csv_path, .data = csv });
    return result;
}

fn validateDirectory(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    dir.close(io);
}

fn resolveRetroRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(root), "Named_Boxarts")) {
        try validateDirectory(io, root);
        return allocator.dupe(u8, root);
    }
    const path = try std.fs.path.join(allocator, &.{ root, "Named_Boxarts" });
    errdefer allocator.free(path);
    try validateDirectory(io, path);
    return path;
}

fn collectFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    recursive: bool,
    extensions: []const []const u8,
    paths: *std.ArrayList([]u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const path = try std.fs.path.join(allocator, &.{ root, entry.name });
        errdefer allocator.free(path);
        switch (entry.kind) {
            .file => if (hasExtension(entry.name, extensions)) try paths.append(allocator, path) else allocator.free(path),
            .directory => if (recursive) {
                defer allocator.free(path);
                try collectFiles(allocator, io, path, true, extensions, paths);
            } else allocator.free(path),
            else => allocator.free(path),
        }
    }
}

fn freePaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn pathLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hasExtension(path: []const u8, extensions: []const []const u8) bool {
    const extension = std.fs.path.extension(path);
    for (extensions) |candidate| if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    return false;
}

fn basenameWithoutExtension(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    return basename[0 .. basename.len - std.fs.path.extension(basename).len];
}

fn parentName(path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(path) orelse "");
}

fn findArtwork(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom_path: []const u8,
    images: []const []u8,
    retro_images: []const []u8,
) !?Match {
    const parent = std.fs.path.dirname(rom_path) orelse ".";
    var siblings: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &siblings);
    try collectFiles(allocator, io, parent, false, &image_extensions, &siblings);
    std.mem.sort([]u8, siblings.items, {}, pathLessThan);
    const rom_name = basenameWithoutExtension(rom_path);

    if (uniqueExact(rom_name, siblings.items)) |path| return .{
        .path = try allocator.dupe(u8, path),
        .status = .exact_sibling,
    };
    if (siblings.items.len == 1) return .{
        .path = try allocator.dupe(u8, siblings.items[0]),
        .status = .sole_sibling,
    };

    const base_names = [_][]const u8{ rom_name, parentName(rom_path) };
    var revisionless: [2]?[]u8 = .{ null, null };
    defer for (revisionless) |candidate| if (candidate) |name| allocator.free(name);
    var names: [4][]const u8 = undefined;
    var name_count: usize = 0;
    for (base_names, 0..) |name, index| {
        names[name_count] = name;
        name_count += 1;
        const candidate = try withoutRevision(allocator, name);
        if (!std.mem.eql(u8, candidate, name)) {
            revisionless[index] = candidate;
            names[name_count] = candidate;
            name_count += 1;
        } else allocator.free(candidate);
    }
    if (try indexedMatch(allocator, names[0..name_count], images, .image_root_exact, .image_root_normalized)) |match| return match;
    if (try indexedMatch(allocator, names[0..name_count], retro_images, .retroarch_exact, .retroarch_normalized)) |match| return match;
    return null;
}

fn indexedMatch(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    images: []const []u8,
    exact_status: ArtworkStatus,
    normalized_status: ArtworkStatus,
) !?Match {
    for (names) |name| if (uniqueExact(name, images)) |path| return .{
        .path = try allocator.dupe(u8, path),
        .status = exact_status,
    };
    for (names) |name| {
        const key = try normalizedName(allocator, name);
        defer allocator.free(key);
        var found: ?[]const u8 = null;
        var count: usize = 0;
        for (images) |path| {
            const image_key = try normalizedName(allocator, basenameWithoutExtension(path));
            defer allocator.free(image_key);
            if (std.mem.eql(u8, key, image_key)) {
                found = path;
                count += 1;
            }
        }
        if (count == 1) return .{ .path = try allocator.dupe(u8, found.?), .status = normalized_status };
    }
    return null;
}

fn uniqueExact(name: []const u8, images: []const []u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var count: usize = 0;
    for (images) |path| if (std.ascii.eqlIgnoreCase(name, basenameWithoutExtension(path))) {
        found = path;
        count += 1;
    };
    return if (count == 1) found else null;
}

fn normalizedName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) try result.append(allocator, std.ascii.toLower(byte)) else if (byte >= 0x80) try result.append(allocator, byte);
    }
    return result.toOwnedSlice(allocator);
}

fn withoutRevision(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var start: usize = 0;
    var index: usize = 0;
    while (index < name.len) : (index += 1) {
        if (name[index] != '(') continue;
        const close = std.mem.indexOfScalarPos(u8, name, index + 1, ')') orelse continue;
        const content = std.mem.trimStart(u8, name[index + 1 .. close], " \t");
        const tagged = startsWithWord(content, "Rev") or startsWithWord(content, "Beta") or startsWithWord(content, "Proto");
        if (!tagged) continue;
        var removal_start = index;
        while (removal_start > start and std.ascii.isWhitespace(name[removal_start - 1])) removal_start -= 1;
        try result.appendSlice(allocator, name[start..removal_start]);
        start = close + 1;
        index = close;
    }
    try result.appendSlice(allocator, name[start..]);
    return result.toOwnedSlice(allocator);
}

fn startsWithWord(text: []const u8, word: []const u8) bool {
    if (text.len < word.len or !std.ascii.eqlIgnoreCase(text[0..word.len], word)) return false;
    return text.len == word.len or std.ascii.isWhitespace(text[word.len]);
}

fn readNormalizedRom(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > maximum_rom_size) return error.RomTooLarge;
    if (stat.size < 4) return error.RomTooSmall;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(maximum_rom_size));
    errdefer allocator.free(bytes);
    try normalizeRom(bytes);
    return bytes;
}

fn normalizeRom(bytes: []u8) !void {
    if (bytes.len < 4) return error.RomTooSmall;
    const order: ByteOrder = if (std.mem.eql(u8, bytes[0..4], &.{ 0x80, 0x37, 0x12, 0x40 }))
        .z64
    else if (std.mem.eql(u8, bytes[0..4], &.{ 0x37, 0x80, 0x40, 0x12 }))
        .v64
    else if (std.mem.eql(u8, bytes[0..4], &.{ 0x40, 0x12, 0x37, 0x80 }))
        .n64
    else
        return error.UnrecognizedByteOrder;
    switch (order) {
        .z64 => {},
        .v64 => {
            if (bytes.len % 2 != 0) return error.InvalidRomSize;
            var i: usize = 0;
            while (i < bytes.len) : (i += 2) std.mem.swap(u8, &bytes[i], &bytes[i + 1]);
        },
        .n64 => {
            if (bytes.len % 4 != 0) return error.InvalidRomSize;
            var i: usize = 0;
            while (i < bytes.len) : (i += 4) {
                std.mem.swap(u8, &bytes[i], &bytes[i + 3]);
                std.mem.swap(u8, &bytes[i + 1], &bytes[i + 2]);
            }
        },
    }
}

fn normalizedId(bytes: []const u8) [5]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const alphabet = "0123456789ABCDEF";
    return .{
        alphabet[digest[0] >> 4], alphabet[digest[0] & 15],
        alphabet[digest[1] >> 4], alphabet[digest[1] & 15],
        alphabet[digest[2] >> 4],
    };
}

fn outputPath(allocator: std.mem.Allocator, directory: []const u8, id: [5]u8, suffix: []const u8) ![]u8 {
    const filename = try std.mem.concat(allocator, u8, &.{ &id, suffix });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

fn asciiText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, index| result[index] = if (byte < 0x80) byte else '?';
    return result;
}

fn titleCsvBytes(allocator: std.mem.Allocator, titles: []const Title) ![]u8 {
    const result = try allocator.alloc(u8, titles.len * 6 + 1);
    var offset: usize = 0;
    for (titles) |title| {
        @memcpy(result[offset..][0..5], &title.id);
        offset += 5;
        result[offset] = ',';
        offset += 1;
    }
    result[offset] = 0;
    return result;
}

const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

fn writeArtworkSprite(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(allocator, io, source, &read_buffer);
    defer image.deinit(allocator);
    try image.convert(allocator, .rgba32);
    const canvas = try allocator.alloc(Rgba, sprite_width * sprite_height);
    defer allocator.free(canvas);
    @memset(canvas, .{ .r = 48, .g = 48, .b = 48, .a = 255 });
    containFit(image.width, image.height, image.pixels.rgba32, canvas);
    try writeSprite(allocator, io, canvas, destination);
}

fn containFit(source_width: usize, source_height: usize, source: anytype, canvas: []Rgba) void {
    if (source_width == 0 or source_height == 0) return;
    const scale = @min(
        @as(f64, @floatFromInt(sprite_width)) / @as(f64, @floatFromInt(source_width)),
        @as(f64, @floatFromInt(sprite_height)) / @as(f64, @floatFromInt(source_height)),
    );
    const draw_width: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(source_width)) * scale))));
    const draw_height: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(source_height)) * scale))));
    const left = (sprite_width - draw_width) / 2;
    const top = (sprite_height - draw_height) / 2;
    for (0..draw_height) |y| for (0..draw_width) |x| {
        const sx = ((@as(f64, @floatFromInt(x)) + 0.5) * @as(f64, @floatFromInt(source_width)) / @as(f64, @floatFromInt(draw_width))) - 0.5;
        const sy = ((@as(f64, @floatFromInt(y)) + 0.5) * @as(f64, @floatFromInt(source_height)) / @as(f64, @floatFromInt(draw_height))) - 0.5;
        const x0: usize = @intFromFloat(@floor(@max(0.0, sx)));
        const y0: usize = @intFromFloat(@floor(@max(0.0, sy)));
        const x1 = @min(x0 + 1, source_width - 1);
        const y1 = @min(y0 + 1, source_height - 1);
        const fx = @max(0.0, sx - @floor(sx));
        const fy = @max(0.0, sy - @floor(sy));
        const pixel = bilinear(source[y0 * source_width + x0], source[y0 * source_width + x1], source[y1 * source_width + x0], source[y1 * source_width + x1], fx, fy);
        canvas[(top + y) * sprite_width + left + x] = composite(pixel, .{ .r = 48, .g = 48, .b = 48, .a = 255 });
    };
}

fn bilinear(p00: anytype, p10: anytype, p01: anytype, p11: anytype, fx: f64, fy: f64) Rgba {
    return .{
        .r = interpolate(p00.r, p10.r, p01.r, p11.r, fx, fy),
        .g = interpolate(p00.g, p10.g, p01.g, p11.g, fx, fy),
        .b = interpolate(p00.b, p10.b, p01.b, p11.b, fx, fy),
        .a = interpolate(p00.a, p10.a, p01.a, p11.a, fx, fy),
    };
}

fn interpolate(a: u8, b: u8, c: u8, d: u8, fx: f64, fy: f64) u8 {
    const top = @as(f64, @floatFromInt(a)) * (1.0 - fx) + @as(f64, @floatFromInt(b)) * fx;
    const bottom = @as(f64, @floatFromInt(c)) * (1.0 - fx) + @as(f64, @floatFromInt(d)) * fx;
    return @intFromFloat(@round(top * (1.0 - fy) + bottom * fy));
}

fn composite(foreground: Rgba, background: Rgba) Rgba {
    const alpha: u16 = foreground.a;
    return .{
        .r = @intCast((@as(u16, foreground.r) * alpha + @as(u16, background.r) * (255 - alpha) + 127) / 255),
        .g = @intCast((@as(u16, foreground.g) * alpha + @as(u16, background.g) * (255 - alpha) + 127) / 255),
        .b = @intCast((@as(u16, foreground.b) * alpha + @as(u16, background.b) * (255 - alpha) + 127) / 255),
        .a = 255,
    };
}

fn writeGeneratedSprite(allocator: std.mem.Allocator, io: std.Io, title: []const u8, destination: []const u8) !void {
    const canvas = try allocator.alloc(Rgba, sprite_width * sprite_height);
    defer allocator.free(canvas);
    @memset(canvas, .{ .r = 35, .g = 30, .b = 48, .a = 255 });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(title, &digest, .{});
    for (0..16) |bar| {
        const height = 20 + @as(usize, digest[bar]) * 100 / 255;
        const color = Rgba{ .r = 80 + digest[bar] / 2, .g = 55 + digest[bar + 8] / 3, .b = 110 + digest[bar + 16] / 2, .a = 255 };
        for (0..height) |y| {
            for (0..10) |x| canvas[(sprite_height - 20 - y) * sprite_width + 16 + bar * 14 + x] = color;
        }
    }
    try writeSprite(allocator, io, canvas, destination);
}

fn writeSprite(allocator: std.mem.Allocator, io: std.Io, pixels: []const Rgba, destination: []const u8) !void {
    const bytes = try allocator.alloc(u8, 8 + pixels.len * 2);
    defer allocator.free(bytes);
    bytes[0..8].* = .{ 0x01, 0x00, 0x00, 0xB3, 2, 0, 1, 1 };
    for (pixels, 0..) |pixel, index| {
        const value = packRgb5551(pixel);
        bytes[8 + index * 2] = @truncate(value >> 8);
        bytes[9 + index * 2] = @truncate(value);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = bytes });
}

fn packRgb5551(pixel: Rgba) u16 {
    return (@as(u16, pixel.r >> 3) << 11) |
        (@as(u16, pixel.g >> 3) << 6) |
        (@as(u16, pixel.b >> 3) << 1) |
        @intFromBool(pixel.a >= 128);
}

test "byte-order conversion equivalence and normalized ID stability" {
    const z64 = [_]u8{ 0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4 };
    var v64 = [_]u8{ 0x37, 0x80, 0x40, 0x12, 2, 1, 4, 3 };
    var n64 = [_]u8{ 0x40, 0x12, 0x37, 0x80, 4, 3, 2, 1 };
    try normalizeRom(&v64);
    try normalizeRom(&n64);
    try std.testing.expectEqualSlices(u8, &z64, &v64);
    try std.testing.expectEqualSlices(u8, &z64, &n64);
    try std.testing.expectEqual(normalizedId(&z64), normalizedId(&v64));
    try std.testing.expectEqual(normalizedId(&z64), normalizedId(&n64));
}

test "normalized name matching" {
    const allocator = std.testing.allocator;
    const a = try normalizedName(allocator, "Super Mario 64 (USA)!");
    defer allocator.free(a);
    const b = try normalizedName(allocator, "super_mario-64 usa");
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    const revisionless = try withoutRevision(allocator, "Game (Rev A) (USA)");
    defer allocator.free(revisionless);
    try std.testing.expectEqualStrings("Game (USA)", revisionless);
}

test "title CSV bytes" {
    const titles = [_]Title{
        .{ .rom_path = undefined, .display_name = undefined, .id = "ABCDE".*, .artwork_path = null, .artwork_status = .generated },
        .{ .rom_path = undefined, .display_name = undefined, .id = "12345".*, .artwork_path = null, .artwork_status = .generated },
    };
    const bytes = try titleCsvBytes(std.testing.allocator, &titles);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "ABCDE,12345,\x00", bytes);
}

test "RGB5551 packing and sprite header" {
    try std.testing.expectEqual(@as(u16, 0xF801), packRgb5551(.{ .r = 255, .g = 0, .b = 0, .a = 255 }));
    try std.testing.expectEqual(@as(u16, 0x07C0), packRgb5551(.{ .r = 0, .g = 255, .b = 0, .a = 0 }));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try tempPath(std.testing.allocator, temp, "one.sprite");
    defer std.testing.allocator.free(path);
    const pixel = [_]Rgba{.{ .r = 255, .g = 0, .b = 0, .a = 255 }};
    try writeSprite(std.testing.allocator, std.testing.io, &pixel, path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var bytes: [10]u8 = undefined;
    var buffer: [32]u8 = undefined;
    var reader = file.readerStreaming(std.testing.io, &buffer);
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 179, 2, 0, 1, 1, 0xF8, 1 }, &bytes);
}

test "end-to-end fallback import" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "roms");
    try temp.dir.createDirPath(std.testing.io, "out");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "roms/Game.z64", .data = &.{ 0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4 } });
    const root = try tempPath(allocator, temp, "");
    defer allocator.free(root);
    const rom_root = try std.fs.path.join(allocator, &.{ root, "roms" });
    defer allocator.free(rom_root);
    const output_root = try std.fs.path.join(allocator, &.{ root, "out" });
    defer allocator.free(output_root);
    var result = try importLibrary(allocator, std.testing.io, .{ .output_root = output_root, .rom_root = rom_root }, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.titles.len);
    try std.testing.expectEqual(ArtworkStatus.generated, result.titles[0].artwork_status);
    const csv_path = try std.fs.path.join(allocator, &.{ output_root, "menu", "title.csv" });
    defer allocator.free(csv_path);
    var csv_file = try std.Io.Dir.cwd().openFile(std.testing.io, csv_path, .{});
    defer csv_file.close(std.testing.io);
    var csv: [7]u8 = undefined;
    var buffer: [32]u8 = undefined;
    var reader = csv_file.readerStreaming(std.testing.io, &buffer);
    try reader.interface.readSliceAll(&csv);
    try std.testing.expectEqualSlices(u8, &result.titles[0].id, csv[0..5]);
    try std.testing.expectEqualSlices(u8, ",\x00", csv[5..]);
}

fn tempPath(allocator: std.mem.Allocator, temp: std.testing.TmpDir, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temp.sub_path, child });
}
