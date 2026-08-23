const std = @import("std");
const zigimg = @import("zigimg");
const builtin = @import("builtin");

pub const maximum_rom_size = 78 * 1024 * 1024;
pub const sprite_width = 256;
pub const sprite_height = 179;
pub const title_id_capacity = 7;
pub const TitleId = [title_id_capacity]u8;

const rom_extensions = [_][]const u8{ ".n64", ".v64", ".z64" };
const image_extensions = [_][]const u8{ ".bmp", ".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff" };
const n64_playlist_name = "Nintendo - Nintendo 64.lpl";
const maximum_playlist_size = 8 * 1024 * 1024;

pub const Config = struct {
    output_root: []const u8 = "",
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
    id: TitleId,
    content_hash: [32]u8 = @splat(0),
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

pub const DecodedArtwork = struct {
    width: usize,
    height: usize,
    pixels: []u8,

    pub fn deinit(self: *DecodedArtwork, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn decodeArtwork(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !DecodedArtwork {
    var read_buffer: [64 * 1024]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(allocator, io, path, &read_buffer);
    defer image.deinit(allocator);
    try image.convert(allocator, .rgba32);
    const pixels = image.pixels.rgba32;
    const bytes = try allocator.alloc(u8, pixels.len * 4);
    for (pixels, 0..) |pixel, index| {
        bytes[index * 4] = pixel.r;
        bytes[index * 4 + 1] = pixel.g;
        bytes[index * 4 + 2] = pixel.b;
        bytes[index * 4 + 3] = pixel.a;
    }
    return .{ .width = image.width, .height = image.height, .pixels = bytes };
}

pub const RetroArchPlaylistEntry = struct {
    path: []u8,
    label: []u8,
    db_name: []u8,

    fn deinit(self: *RetroArchPlaylistEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.label);
        allocator.free(self.db_name);
    }
};

pub const RetroArchPlaylist = struct {
    entries: []RetroArchPlaylistEntry,

    pub fn deinit(self: *RetroArchPlaylist, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const RetroArchSource = struct {
    playlist_path: []u8,
    system_name: []u8,
    retroarch_root: ?[]u8,
    playlist_entries: usize,
    resolved_entries: usize,
    unsupported_entries: usize,

    pub fn deinit(self: *RetroArchSource, allocator: std.mem.Allocator) void {
        allocator.free(self.playlist_path);
        allocator.free(self.system_name);
        if (self.retroarch_root) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const RetroArchScanResult = struct {
    source: RetroArchSource,
    preview: ScanResult,

    pub fn deinit(self: *RetroArchScanResult, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        self.preview.deinit(allocator);
        self.* = undefined;
    }
};

pub const RetroArchDiscoveryOptions = struct {
    /// Overrides automatic platform locations when non-empty.
    search_roots: []const []const u8 = &.{},
    /// Overrides automatically detected Windows drive roots when non-empty.
    mounted_roots: []const []const u8 = &.{},
    maximum_search_depth: usize = 7,
    environ: std.process.Environ = .empty,
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
        const assigned = try uniqueNormalizedId(normalized, titles.items);

        const display_name = try allocator.dupe(u8, basenameWithoutExtension(rom_path));
        errdefer allocator.free(display_name);
        const match = try findArtwork(allocator, io, rom_path, images.items, retro_images.items);
        errdefer if (match) |found| allocator.free(found.path);
        try titles.append(allocator, .{
            .rom_path = try allocator.dupe(u8, rom_path),
            .display_name = display_name,
            .id = assigned.id,
            .content_hash = assigned.digest,
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
    try validateDirectory(io, config.output_root);
    var result = try scanLibrary(allocator, io, config);
    errdefer result.deinit(allocator);

    try stageTitles(allocator, io, config.output_root, result.titles, progress);
    return result;
}

/// Finds the best usable RetroArch N64 playlist and returns its source details and title preview.
pub fn scanRetroArchLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RetroArchDiscoveryOptions,
) !RetroArchScanResult {
    var owned_roots: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &owned_roots);
    const search_roots = if (options.search_roots.len != 0)
        options.search_roots
    else blk: {
        try appendDefaultSearchRoots(allocator, io, options.environ, &owned_roots);
        break :blk owned_roots.items;
    };

    var owned_mounts: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &owned_mounts);
    const mounted_roots = if (options.mounted_roots.len != 0)
        options.mounted_roots
    else blk: {
        try appendMountedRoots(allocator, io, &owned_mounts);
        break :blk owned_mounts.items;
    };

    var candidates: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &candidates);
    for (search_roots) |root| {
        collectPlaylistCandidates(allocator, io, root, options.maximum_search_depth, &candidates) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied, error.NetworkNotFound => continue,
            else => return err,
        };
    }
    deduplicateAndSortPaths(allocator, &candidates);
    if (candidates.items.len == 0) return error.NoRetroArchPlaylistFound;

    var best: ?RetroArchSource = null;
    errdefer if (best) |*source| source.deinit(allocator);
    var best_score: CandidateScore = undefined;
    for (candidates.items) |playlist_path| {
        var candidate = inspectPlaylistCandidate(allocator, io, playlist_path, mounted_roots) catch |err| switch (err) {
            error.InvalidPlaylist, error.NoRomsFound, error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        };
        const score = candidateScore(candidate);
        if (best == null or candidateBetter(score, best_score)) {
            if (best) |*previous| previous.deinit(allocator);
            best = candidate;
            best_score = score;
        } else candidate.deinit(allocator);
    }
    var source = best orelse return error.NoUsableRetroArchPlaylist;
    best = null;
    errdefer source.deinit(allocator);
    return .{
        .source = source,
        .preview = try scanRetroArchPlaylist(allocator, io, source, mounted_roots),
    };
}

/// Stages the detected RetroArch playlist preview without rescanning arbitrary ROM folders.
pub fn importRetroArchLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_root: []const u8,
    options: RetroArchDiscoveryOptions,
    progress: ?Progress,
) !RetroArchScanResult {
    try validateDirectory(io, output_root);
    var result = try scanRetroArchLibrary(allocator, io, options);
    errdefer result.deinit(allocator);
    try stageTitles(allocator, io, output_root, result.preview.titles, progress);
    return result;
}

fn stageTitles(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_root: []const u8,
    titles: []Title,
    progress: ?Progress,
) !void {
    const cwd = std.Io.Dir.cwd();
    const title_root = try std.fs.path.join(allocator, &.{ output_root, "menu", "title" });
    defer allocator.free(title_root);
    try cwd.createDirPath(io, title_root);

    for (titles, 0..) |*title, index| {
        const destination = try std.fs.path.join(allocator, &.{ title_root, titleIdSlice(&title.id) });
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
            .total = titles.len,
            .title = title,
        });
    }

    const csv = try titleCsvBytes(allocator, titles);
    defer allocator.free(csv);
    const csv_path = try std.fs.path.join(allocator, &.{ output_root, "menu", "title.csv" });
    defer allocator.free(csv_path);
    try cwd.writeFile(io, .{ .sub_path = csv_path, .data = csv });
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

const CandidateScore = struct {
    duplicate_components: usize,
    resolved_entries: usize,
    playlist_entries: usize,
    path_depth: usize,
    path_length: usize,
};

fn candidateScore(source: RetroArchSource) CandidateScore {
    return .{
        .duplicate_components = duplicatePathComponents(source.playlist_path),
        .resolved_entries = source.resolved_entries,
        .playlist_entries = source.playlist_entries,
        .path_depth = pathDepth(source.playlist_path),
        .path_length = source.playlist_path.len,
    };
}

fn candidateBetter(a: CandidateScore, b: CandidateScore) bool {
    if (a.duplicate_components != b.duplicate_components) return a.duplicate_components < b.duplicate_components;
    if (a.resolved_entries != b.resolved_entries) return a.resolved_entries > b.resolved_entries;
    if (a.playlist_entries != b.playlist_entries) return a.playlist_entries > b.playlist_entries;
    if (a.path_depth != b.path_depth) return a.path_depth < b.path_depth;
    return a.path_length < b.path_length;
}

fn duplicatePathComponents(path: []const u8) usize {
    var count: usize = 0;
    var previous: ?[]const u8 = null;
    var iterator = std.mem.tokenizeAny(u8, path, "/\\");
    while (iterator.next()) |component| {
        if (previous) |last| if (std.ascii.eqlIgnoreCase(last, component)) {
            count += 1;
        };
        previous = component;
    }
    return count;
}

fn pathDepth(path: []const u8) usize {
    var count: usize = 0;
    for (path) |byte| if (byte == '/' or byte == '\\') {
        count += 1;
    };
    return count;
}

fn appendDefaultSearchRoots(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, roots: *std.ArrayList([]u8)) !void {
    switch (builtin.os.tag) {
        .windows => {
            const names = [_][]const u8{ "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "USERPROFILE" };
            for (names) |name| {
                const value = std.process.Environ.getAlloc(environ, allocator, name) catch continue;
                defer allocator.free(value);
                const suffixes: []const []const u8 = if (std.ascii.eqlIgnoreCase(name, "APPDATA"))
                    &.{ "RetroArch", "retroarch" }
                else if (std.ascii.eqlIgnoreCase(name, "USERPROFILE"))
                    &.{ "RetroArch", ".config\\retroarch" }
                else
                    &.{ "RetroArch", "retroarch" };
                for (suffixes) |suffix| try appendDirectoryIfPresent(allocator, io, roots, value, suffix);
            }
        },
        .macos => {
            const home = std.process.Environ.getAlloc(environ, allocator, "HOME") catch return;
            defer allocator.free(home);
            try appendDirectoryIfPresent(allocator, io, roots, home, "Library/Application Support/RetroArch");
            try appendDirectoryIfPresent(allocator, io, roots, home, ".config/retroarch");
        },
        else => {
            const home = std.process.Environ.getAlloc(environ, allocator, "HOME") catch return;
            defer allocator.free(home);
            try appendDirectoryIfPresent(allocator, io, roots, home, ".config/retroarch");
            try appendDirectoryIfPresent(allocator, io, roots, home, ".var/app/org.libretro.RetroArch/config/retroarch");
        },
    }
    try appendMountedRoots(allocator, io, roots);
}

fn appendDirectoryIfPresent(allocator: std.mem.Allocator, io: std.Io, roots: *std.ArrayList([]u8), parent: []const u8, child: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ parent, child });
    if (directoryExists(io, path)) try roots.append(allocator, path) else allocator.free(path);
}

fn appendMountedRoots(allocator: std.mem.Allocator, io: std.Io, roots: *std.ArrayList([]u8)) !void {
    if (builtin.os.tag == .windows) {
        for ('A'..'Z' + 1) |letter| {
            const path = try std.fmt.allocPrint(allocator, "{c}:\\", .{@as(u8, @intCast(letter))});
            if (directoryExists(io, path)) try roots.append(allocator, path) else allocator.free(path);
        }
        return;
    }
    const candidates: []const []const u8 = if (builtin.os.tag == .macos)
        &.{"/Volumes"}
    else
        &.{ "/media", "/mnt", "/run/media" };
    for (candidates) |path| {
        if (!directoryExists(io, path)) continue;
        try roots.append(allocator, try allocator.dupe(u8, path));
        try appendChildDirectories(allocator, io, roots, path, 2);
    }
}

fn appendChildDirectories(allocator: std.mem.Allocator, io: std.Io, roots: *std.ArrayList([]u8), parent: []const u8, depth: usize) !void {
    if (depth == 0) return;
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(allocator, &.{ parent, entry.name });
        errdefer allocator.free(path);
        try roots.append(allocator, path);
        try appendChildDirectories(allocator, io, roots, path, depth - 1);
    }
}

fn directoryExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn collectPlaylistCandidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    remaining_depth: usize,
    candidates: *std.ArrayList([]u8),
) anyerror!void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.ascii.eqlIgnoreCase(entry.name, n64_playlist_name)) {
            try candidates.append(allocator, try std.fs.path.join(allocator, &.{ root, entry.name }));
        } else if (entry.kind == .directory and remaining_depth != 0 and shouldSearchDirectory(entry.name)) {
            const path = try std.fs.path.join(allocator, &.{ root, entry.name });
            defer allocator.free(path);
            collectPlaylistCandidates(allocator, io, path, remaining_depth - 1, candidates) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied, error.NetworkNotFound => {},
                else => return err,
            };
        }
    }
}

fn shouldSearchDirectory(name: []const u8) bool {
    const names = [_][]const u8{
        "RetroArch",               "retroarch", "playlists", "config",        "configs",               "backup", "backups",
        "RetroArch_config_backup", "Android",   "data",      "com.retroarch", "com.retroarch.aarch64", "files",
    };
    for (names) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return false;
}

fn deduplicateAndSortPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    std.mem.sort([]u8, paths.items, {}, pathLessThan);
    var write: usize = 0;
    for (paths.items) |path| {
        if (write != 0 and std.ascii.eqlIgnoreCase(paths.items[write - 1], path)) {
            allocator.free(path);
            continue;
        }
        paths.items[write] = path;
        write += 1;
    }
    paths.shrinkRetainingCapacity(write);
}

fn inspectPlaylistCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    playlist_path: []const u8,
    mounted_roots: []const []const u8,
) !RetroArchSource {
    var playlist = try readRetroArchPlaylist(allocator, io, playlist_path);
    defer playlist.deinit(allocator);
    if (playlist.entries.len == 0) return error.InvalidPlaylist;
    var resolved: usize = 0;
    var unsupported: usize = 0;
    for (playlist.entries) |entry| {
        if (!isSupportedPlaylistRom(entry.path)) {
            unsupported += 1;
            continue;
        }
        const path = resolvePlaylistRomPath(allocator, io, entry.path, mounted_roots) catch continue;
        allocator.free(path);
        resolved += 1;
    }
    if (resolved == 0) return error.NoRomsFound;
    const system_name = try playlistSystemName(allocator, playlist_path, playlist.entries);
    errdefer allocator.free(system_name);
    return .{
        .playlist_path = try allocator.dupe(u8, playlist_path),
        .system_name = system_name,
        .retroarch_root = try findNearbyRetroArchRoot(allocator, io, playlist_path, system_name),
        .playlist_entries = playlist.entries.len,
        .resolved_entries = resolved,
        .unsupported_entries = unsupported,
    };
}

fn scanRetroArchPlaylist(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: RetroArchSource,
    mounted_roots: []const []const u8,
) !ScanResult {
    var playlist = try readRetroArchPlaylist(allocator, io, source.playlist_path);
    defer playlist.deinit(allocator);
    var boxarts: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &boxarts);
    var snaps: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &snaps);
    if (source.retroarch_root) |root| {
        try collectThumbnailKind(allocator, io, root, source.system_name, "Named_Boxarts", &boxarts);
        try collectThumbnailKind(allocator, io, root, source.system_name, "Named_Snaps", &snaps);
    }

    var titles: std.ArrayList(Title) = .empty;
    errdefer {
        for (titles.items) |*title| title.deinit(allocator);
        titles.deinit(allocator);
    }
    for (playlist.entries) |entry| {
        if (!isSupportedPlaylistRom(entry.path)) continue;
        const rom_path = resolvePlaylistRomPath(allocator, io, entry.path, mounted_roots) catch continue;
        errdefer allocator.free(rom_path);
        const normalized = try readNormalizedRom(allocator, io, rom_path);
        defer allocator.free(normalized);
        const assigned = try uniqueNormalizedId(normalized, titles.items);
        const artwork = try findRetroArchPlaylistArtwork(allocator, entry, rom_path, boxarts.items, snaps.items);
        errdefer if (artwork) |match| allocator.free(match.path);
        try titles.append(allocator, .{
            .rom_path = rom_path,
            .display_name = try allocator.dupe(u8, if (entry.label.len != 0) entry.label else basenameWithoutExtension(rom_path)),
            .id = assigned.id,
            .content_hash = assigned.digest,
            .artwork_path = if (artwork) |match| @constCast(match.path) else null,
            .artwork_status = if (artwork) |match| match.status else .generated,
        });
    }
    if (titles.items.len == 0) return error.NoRomsFound;
    return .{ .titles = try titles.toOwnedSlice(allocator) };
}

fn isSupportedPlaylistRom(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '#') != null) return false;
    return hasExtension(path, &rom_extensions);
}

fn collectThumbnailKind(
    allocator: std.mem.Allocator,
    io: std.Io,
    retroarch_root: []const u8,
    system_name: []const u8,
    kind: []const u8,
    images: *std.ArrayList([]u8),
) !void {
    const path = try std.fs.path.join(allocator, &.{ retroarch_root, "thumbnails", system_name, kind });
    defer allocator.free(path);
    collectFiles(allocator, io, path, false, &image_extensions, images) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    std.mem.sort([]u8, images.items, {}, pathLessThan);
}

fn findNearbyRetroArchRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    playlist_path: []const u8,
    system_name: []const u8,
) !?[]u8 {
    var current = std.fs.path.dirname(playlist_path) orelse return null;
    var levels: usize = 0;
    while (levels < 5) : (levels += 1) {
        const boxarts = try std.fs.path.join(allocator, &.{ current, "thumbnails", system_name, "Named_Boxarts" });
        const has_boxarts = directoryExists(io, boxarts);
        allocator.free(boxarts);
        const snaps = try std.fs.path.join(allocator, &.{ current, "thumbnails", system_name, "Named_Snaps" });
        const has_snaps = directoryExists(io, snaps);
        allocator.free(snaps);
        if (has_boxarts or has_snaps) return @as(?[]u8, try allocator.dupe(u8, current));
        current = std.fs.path.dirname(current) orelse break;
    }
    return null;
}

fn playlistSystemName(allocator: std.mem.Allocator, playlist_path: []const u8, entries: []const RetroArchPlaylistEntry) ![]u8 {
    for (entries) |entry| if (entry.db_name.len != 0) return allocator.dupe(u8, basenameWithoutExtension(entry.db_name));
    return allocator.dupe(u8, basenameWithoutExtension(playlist_path));
}

const JsonPlaylist = struct {
    items: []const JsonPlaylistEntry = &.{},
};

const JsonPlaylistEntry = struct {
    path: []const u8 = "",
    label: []const u8 = "",
    db_name: []const u8 = "",
};

pub fn parseRetroArchPlaylist(allocator: std.mem.Allocator, bytes: []const u8) !RetroArchPlaylist {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPlaylist;
    var entries: std.ArrayList(RetroArchPlaylistEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    if (trimmed[0] == '{') {
        var parsed = std.json.parseFromSlice(JsonPlaylist, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return error.InvalidPlaylist;
        defer parsed.deinit();
        for (parsed.value.items) |item| {
            if (item.path.len == 0) continue;
            try entries.append(allocator, .{
                .path = try allocator.dupe(u8, item.path),
                .label = try allocator.dupe(u8, item.label),
                .db_name = try allocator.dupe(u8, item.db_name),
            });
        }
    } else {
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(allocator);
        var iterator = std.mem.splitScalar(u8, bytes, '\n');
        while (iterator.next()) |line| {
            const clean = std.mem.trimEnd(u8, line, "\r");
            try lines.append(allocator, clean);
        }
        while (lines.items.len != 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
        if (lines.items.len == 0 or lines.items.len % 6 != 0) return error.InvalidPlaylist;
        var index: usize = 0;
        while (index < lines.items.len) : (index += 6) {
            try entries.append(allocator, .{
                .path = try allocator.dupe(u8, lines.items[index]),
                .label = try allocator.dupe(u8, lines.items[index + 1]),
                .db_name = try allocator.dupe(u8, lines.items[index + 5]),
            });
        }
    }
    if (entries.items.len == 0) return error.InvalidPlaylist;
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn readRetroArchPlaylist(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !RetroArchPlaylist {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(maximum_playlist_size));
    defer allocator.free(bytes);
    return parseRetroArchPlaylist(allocator, bytes);
}

pub fn resolvePlaylistRomPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    playlist_path: []const u8,
    mounted_roots: []const []const u8,
) ![]u8 {
    if (fileExists(io, playlist_path)) return allocator.dupe(u8, playlist_path);
    if (!std.mem.startsWith(u8, playlist_path, "/storage/")) return error.FileNotFound;

    const after_storage = playlist_path["/storage/".len..];
    const volume_end = std.mem.indexOfScalar(u8, after_storage, '/') orelse return error.FileNotFound;
    var suffix = after_storage[volume_end + 1 ..];
    while (suffix.len != 0) {
        for (mounted_roots) |root| {
            const native_suffix = try allocator.dupe(u8, suffix);
            defer allocator.free(native_suffix);
            for (native_suffix) |*byte| if (byte.* == '/') {
                byte.* = std.fs.path.sep;
            };
            const candidate = try std.fs.path.join(allocator, &.{ root, native_suffix });
            if (fileExists(io, candidate)) return candidate;
            allocator.free(candidate);
        }
        const separator = std.mem.indexOfScalar(u8, suffix, '/') orelse break;
        suffix = suffix[separator + 1 ..];
    }
    return error.FileNotFound;
}

fn findRetroArchPlaylistArtwork(
    allocator: std.mem.Allocator,
    entry: RetroArchPlaylistEntry,
    rom_path: []const u8,
    boxarts: []const []u8,
    snaps: []const []u8,
) !?Match {
    var names: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &names);
    try appendThumbnailName(allocator, &names, entry.label);
    try appendThumbnailName(allocator, &names, basenameWithoutExtension(rom_path));
    try appendThumbnailName(allocator, &names, parentName(rom_path));
    const original_count = names.items.len;
    for (names.items[0..original_count]) |name| {
        const revisionless = try withoutRevision(allocator, name);
        if (!std.mem.eql(u8, revisionless, name)) try names.append(allocator, revisionless) else allocator.free(revisionless);
        const short = try shortTitleName(allocator, name);
        if (!std.mem.eql(u8, short, name)) try names.append(allocator, short) else allocator.free(short);
    }
    if (try thumbnailMatch(allocator, names.items, boxarts)) |match| return match;
    return thumbnailMatch(allocator, names.items, snaps);
}

fn appendThumbnailName(allocator: std.mem.Allocator, names: *std.ArrayList([]u8), name: []const u8) !void {
    if (name.len == 0) return;
    for (names.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try names.append(allocator, try allocator.dupe(u8, name));
    const sanitized = try retroArchThumbnailName(allocator, name);
    if (!std.mem.eql(u8, sanitized, name)) try names.append(allocator, sanitized) else allocator.free(sanitized);
}

fn thumbnailMatch(allocator: std.mem.Allocator, names: []const []u8, images: []const []u8) !?Match {
    for (names) |name| if (uniqueExact(name, images)) |path| return .{
        .path = try allocator.dupe(u8, path),
        .status = .retroarch_exact,
    };
    if (try indexedMatch(allocator, names, images, .retroarch_exact, .retroarch_normalized)) |match| return match;
    return null;
}

pub fn retroArchThumbnailName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*byte| if (std.mem.indexOfScalar(u8, "&*/:`<>?\\|", byte.*) != null) {
        byte.* = '_';
    };
    return result;
}

fn shortTitleName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var end = name.len;
    while (end != 0) {
        while (end != 0 and std.ascii.isWhitespace(name[end - 1])) end -= 1;
        if (end == 0 or name[end - 1] != ')') break;
        const open = std.mem.lastIndexOfScalar(u8, name[0 .. end - 1], '(') orelse break;
        end = open;
    }
    return allocator.dupe(u8, std.mem.trimEnd(u8, name[0..end], " \t"));
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
        const kind = if (entry.kind == .unknown)
            (std.Io.Dir.cwd().statFile(io, path, .{}) catch {
                allocator.free(path);
                continue;
            }).kind
        else
            entry.kind;
        switch (kind) {
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

fn normalizedId(digest: [32]u8, length: usize) TitleId {
    const alphabet = "0123456789ABCDEF";
    var result: TitleId = @splat(0);
    for (0..length) |index| {
        const byte = digest[index / 2];
        result[index] = alphabet[if (index % 2 == 0) byte >> 4 else byte & 15];
    }
    return result;
}

const AssignedId = struct { id: TitleId, digest: [32]u8 };

fn uniqueNormalizedId(bytes: []const u8, titles: []const Title) !AssignedId {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    for (titles) |title| if (std.mem.eql(u8, &title.content_hash, &digest)) return error.IdCollision;
    for (5..title_id_capacity + 1) |length| {
        const candidate = normalizedId(digest, length);
        var collision = false;
        for (titles) |title| if (std.mem.eql(u8, titleIdSlice(&title.id), titleIdSlice(&candidate))) {
            collision = true;
            break;
        };
        if (!collision) return .{ .id = candidate, .digest = digest };
    }
    return error.IdCollision;
}

pub fn titleIdSlice(id: *const TitleId) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, 0) orelse id.len];
}

fn outputPath(allocator: std.mem.Allocator, directory: []const u8, id: TitleId, suffix: []const u8) ![]u8 {
    const filename = try std.mem.concat(allocator, u8, &.{ titleIdSlice(&id), suffix });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

fn asciiText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, index| result[index] = if (byte < 0x80) byte else '?';
    return result;
}

fn titleCsvBytes(allocator: std.mem.Allocator, titles: []const Title) ![]u8 {
    var size: usize = 1;
    for (titles) |title| size += titleIdSlice(&title.id).len + 1;
    const result = try allocator.alloc(u8, size);
    var offset: usize = 0;
    for (titles) |title| {
        const id = titleIdSlice(&title.id);
        @memcpy(result[offset..][0..id.len], id);
        offset += id.len;
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
    var z64_digest: [32]u8 = undefined;
    var v64_digest: [32]u8 = undefined;
    var n64_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&z64, &z64_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(&v64, &v64_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(&n64, &n64_digest, .{});
    try std.testing.expectEqual(normalizedId(z64_digest, 5), normalizedId(v64_digest, 5));
    try std.testing.expectEqual(normalizedId(z64_digest, 5), normalizedId(n64_digest, 5));
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

test "modern RetroArch playlist parsing uses labels" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":"1.5","items":[
        \\  {"path":"C:\\\\Roms\\\\Mario.z64","label":"Super Mario 64 (USA)","db_name":"Nintendo - Nintendo 64.lpl","crc32":"ignored"}
        \\]}
    ;
    var playlist = try parseRetroArchPlaylist(allocator, json);
    defer playlist.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), playlist.entries.len);
    try std.testing.expectEqualStrings("Super Mario 64 (USA)", playlist.entries[0].label);
    try std.testing.expectEqualStrings("Nintendo - Nintendo 64.lpl", playlist.entries[0].db_name);
}

test "legacy RetroArch six-line playlist parsing" {
    const allocator = std.testing.allocator;
    const legacy =
        "G:\\Roms\\Game.z64\r\n" ++
        "Playlist Label\r\n" ++
        "DETECT\r\n" ++
        "DETECT\r\n" ++
        "00000000|crc\r\n" ++
        "Nintendo - Nintendo 64.lpl\r\n";
    var playlist = try parseRetroArchPlaylist(allocator, legacy);
    defer playlist.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), playlist.entries.len);
    try std.testing.expectEqualStrings("G:\\Roms\\Game.z64", playlist.entries[0].path);
    try std.testing.expectEqualStrings("Playlist Label", playlist.entries[0].label);
}

test "Android playlist path remaps to mounted Windows drive suffix" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "Nintendo - Nintendo 64 (BigEndian)/Game");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "Nintendo - Nintendo 64 (BigEndian)/Game/Game.z64", .data = "rom" });
    const root = try tempPath(allocator, temp, "");
    defer allocator.free(root);
    const resolved = try resolvePlaylistRomPath(
        allocator,
        std.testing.io,
        "/storage/38F0-494C/Nintendo - Nintendo 64 (BigEndian)/Game/Game.z64",
        &.{root},
    );
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &.{ root, "Nintendo - Nintendo 64 (BigEndian)", "Game", "Game.z64" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "RetroArch invalid thumbnail filename mapping" {
    const mapped = try retroArchThumbnailName(std.testing.allocator, "Command & Conquer: Red Alert? (USA)");
    defer std.testing.allocator.free(mapped);
    try std.testing.expectEqualStrings("Command _ Conquer_ Red Alert_ (USA)", mapped);
}

test "candidate selection favors more resolved entries then nearby playlist" {
    const many = CandidateScore{ .duplicate_components = 0, .resolved_entries = 2, .playlist_entries = 2, .path_depth = 9, .path_length = 100 };
    const nearby = CandidateScore{ .duplicate_components = 0, .resolved_entries = 1, .playlist_entries = 20, .path_depth = 2, .path_length = 20 };
    try std.testing.expect(candidateBetter(many, nearby));
    const direct = CandidateScore{ .duplicate_components = 0, .resolved_entries = 2, .playlist_entries = 2, .path_depth = 3, .path_length = 40 };
    try std.testing.expect(candidateBetter(direct, many));
    const duplicated = CandidateScore{ .duplicate_components = 1, .resolved_entries = 100, .playlist_entries = 100, .path_depth = 3, .path_length = 40 };
    try std.testing.expect(candidateBetter(direct, duplicated));
}

test "candidate discovery selects direct usable RetroArch playlist" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "RetroArch/playlists");
    try temp.dir.createDirPath(std.testing.io, "RetroArch/RetroArch/playlists");
    try temp.dir.createDirPath(std.testing.io, "roms");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "roms/Game.z64", .data = &.{ 0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4 } });
    const root = try tempPath(allocator, temp, "");
    defer allocator.free(root);
    const rom_path = try std.fs.path.join(allocator, &.{ root, "roms", "Game.z64" });
    defer allocator.free(rom_path);
    const legacy = try std.fmt.allocPrint(allocator, "{s}\nChosen Label\nDETECT\nDETECT\n00000000|crc\nNintendo - Nintendo 64.lpl\n", .{rom_path});
    defer allocator.free(legacy);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "RetroArch/playlists/Nintendo - Nintendo 64.lpl", .data = legacy });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "RetroArch/RetroArch/playlists/Nintendo - Nintendo 64.lpl", .data = legacy });

    var result = try scanRetroArchLibrary(allocator, std.testing.io, .{
        .search_roots = &.{root},
        .mounted_roots = &.{root},
    });
    defer result.deinit(allocator);
    const expected_playlist = try std.fs.path.join(allocator, &.{ root, "RetroArch", "playlists", n64_playlist_name });
    defer allocator.free(expected_playlist);
    try std.testing.expectEqualStrings(expected_playlist, result.source.playlist_path);
    try std.testing.expectEqual(@as(usize, 1), result.source.resolved_entries);
    try std.testing.expectEqualStrings("Chosen Label", result.preview.titles[0].display_name);
}

test "title CSV bytes" {
    const titles = [_]Title{
        .{ .rom_path = undefined, .display_name = undefined, .id = "ABCDE\x00\x00".*, .artwork_path = null, .artwork_status = .generated },
        .{ .rom_path = undefined, .display_name = undefined, .id = "12345\x00\x00".*, .artwork_path = null, .artwork_status = .generated },
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
    try std.testing.expectEqualSlices(u8, titleIdSlice(&result.titles[0].id), csv[0..5]);
    try std.testing.expectEqualSlices(u8, ",\x00", csv[5..]);
}

test "recursive scan supports more than forty ROMs and adjacent artwork" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "roms/with-art");
    try temp.dir.createDirPath(std.testing.io, "roms/missing/nested");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "roms/with-art/Game-00.z64", .data = &.{ 0x80, 0x37, 0x12, 0x40, 0, 0, 0, 0 } });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "roms/with-art/Game-00.png", .data = "art" });
    for (1..41) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "roms/missing/nested/Game-{d:0>2}.z64", .{index});
        try temp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &.{ 0x80, 0x37, 0x12, 0x40, 0, 0, 0, @intCast(index) } });
    }

    const root = try tempPath(allocator, temp, "roms");
    defer allocator.free(root);
    var result = try scanLibrary(allocator, std.testing.io, .{ .rom_root = root, .recursive = true });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 41), result.titles.len);

    var exact: usize = 0;
    var missing: usize = 0;
    for (result.titles) |title| {
        if (title.artwork_status == .exact_sibling) exact += 1;
        if (title.artwork_path == null) missing += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), exact);
    try std.testing.expectEqual(@as(usize, 40), missing);
}

fn tempPath(allocator: std.mem.Allocator, temp: std.testing.TmpDir, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temp.sub_path, child });
}
