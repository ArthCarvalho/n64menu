const std = @import("std");
const builtin = @import("builtin");

const title_csv_limit = 16 * 1024 * 1024;
const title_name_limit = 4 * 1024;
pub const TitleId = [7]u8;

pub const Card = struct {
    root: []u8,
    has_menu_rom: bool,
    has_library: bool,
};

pub const CardList = struct {
    cards: []Card,

    pub fn deinit(self: *CardList, allocator: std.mem.Allocator) void {
        for (self.cards) |card| allocator.free(card.root);
        allocator.free(self.cards);
        self.* = undefined;
    }
};

pub const InstalledTitle = struct {
    id: TitleId,
    name: []u8,

    pub fn idSlice(self: *const InstalledTitle) []const u8 {
        return self.id[0 .. std.mem.indexOfScalar(u8, &self.id, 0) orelse self.id.len];
    }
};

pub const InstalledLibrary = struct {
    titles: []InstalledTitle,

    pub fn deinit(self: *InstalledLibrary, allocator: std.mem.Allocator) void {
        for (self.titles) |title| allocator.free(title.name);
        allocator.free(self.titles);
        self.* = undefined;
    }
};

pub const ProgressEvent = struct {
    current: usize,
    total: usize,
    path: []const u8,
};

pub const Progress = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, ProgressEvent) void,
};

pub const PlannedFile = struct {
    relative_path: []u8,
};

pub const SyncPlan = struct {
    files: []PlannedFile,

    pub fn deinit(self: *SyncPlan, allocator: std.mem.Allocator) void {
        for (self.files) |file| allocator.free(file.relative_path);
        allocator.free(self.files);
        self.* = undefined;
    }
};

const Candidate = struct {
    card: Card,
    removable: bool,
};

/// Detects mounted SummerCart SD roots. Signature files, rather than volume
/// type or name, determine whether a mounted volume is returned.
pub fn detectCards(allocator: std.mem.Allocator, io: std.Io) !CardList {
    var roots: std.ArrayList([]u8) = .empty;
    defer freePaths(allocator, &roots);

    if (builtin.os.tag == .windows) {
        for ('A'..'Z' + 1) |letter_value| {
            const letter: u8 = @intCast(letter_value);
            const root = try std.fmt.allocPrint(allocator, "{c}:\\", .{letter});
            errdefer allocator.free(root);
            if (!directoryExists(io, root)) {
                allocator.free(root);
                continue;
            }
            if (!isRemovableWindowsRoot(root)) {
                allocator.free(root);
                continue;
            }
            try roots.append(allocator, root);
        }
    } else {
        const mount_bases: []const []const u8 = if (builtin.os.tag == .macos)
            &.{"/Volumes"}
        else
            &.{ "/media", "/run/media", "/mnt" };
        for (mount_bases) |base| {
            if (!directoryExists(io, base)) continue;
            try appendMountedChildren(allocator, io, &roots, base, 2);
        }
    }

    return detectCardsFromRoots(allocator, io, roots.items);
}

/// Detects cards among explicit candidate roots. This is useful for callers
/// which already have mount information and for deterministic tests.
pub fn detectCardsFromRoots(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
) !CardList {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| allocator.free(candidate.card.root);
        candidates.deinit(allocator);
    }

    for (roots) |root| {
        const menu_rom = try std.fs.path.join(allocator, &.{ root, "sc64menu.n64" });
        defer allocator.free(menu_rom);
        const title_csv = try std.fs.path.join(allocator, &.{ root, "menu", "title.csv" });
        defer allocator.free(title_csv);
        const has_menu_rom = fileExists(io, menu_rom);
        const has_library = fileExists(io, title_csv);
        // Automatic writes require an existing SummerCart installation, not merely
        // a similarly named file on an arbitrary volume.
        if (!has_menu_rom or !has_library) continue;
        const removable = isRemovableWindowsRoot(root);

        const card_root = try allocator.dupe(u8, root);
        candidates.append(allocator, .{
            .card = .{
                .root = card_root,
                .has_menu_rom = has_menu_rom,
                .has_library = has_library,
            },
            .removable = removable,
        }) catch |err| {
            allocator.free(card_root);
            return err;
        };
    }

    std.mem.sort(Candidate, candidates.items, {}, candidateLessThan);
    const cards = try allocator.alloc(Card, candidates.items.len);
    for (candidates.items, 0..) |candidate, index| cards[index] = candidate.card;
    candidates.deinit(allocator);
    return .{ .cards = cards };
}

/// Reads menu/title.csv and each optional menu/title/ID/ID_e.name sidecar.
/// Missing or blank sidecars fall back to the title ID.
pub fn readInstalledLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    card_root: []const u8,
) !InstalledLibrary {
    const csv_path = try std.fs.path.join(allocator, &.{ card_root, "menu", "title.csv" });
    defer allocator.free(csv_path);
    const cwd = std.Io.Dir.cwd();
    const csv = cwd.readFileAlloc(io, csv_path, allocator, .limited(title_csv_limit)) catch |err| switch (err) {
        error.FileNotFound => return .{ .titles = try allocator.alloc(InstalledTitle, 0) },
        else => return err,
    };
    defer allocator.free(csv);
    const ids = try parseTitleCsv(allocator, csv);
    defer allocator.free(ids);

    var titles: std.ArrayList(InstalledTitle) = .empty;
    errdefer {
        for (titles.items) |title| allocator.free(title.name);
        titles.deinit(allocator);
    }
    for (ids) |id| {
        const id_slice = id[0 .. std.mem.indexOfScalar(u8, &id, 0) orelse id.len];
        const name_path = try std.fmt.allocPrint(
            allocator,
            "{s}{c}menu{c}title{c}{s}{c}{s}_e.name",
            .{ card_root, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, id_slice, std.fs.path.sep, id_slice },
        );
        defer allocator.free(name_path);

        const raw_name = cwd.readFileAlloc(io, name_path, allocator, .limited(title_name_limit)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (raw_name) |bytes| allocator.free(bytes);
        const name = if (raw_name) |bytes| blk: {
            const trimmed = std.mem.trimEnd(u8, bytes, "\x00\r\n");
            break :blk try allocator.dupe(u8, if (trimmed.len == 0) id_slice else trimmed);
        } else try allocator.dupe(u8, id_slice);
        errdefer allocator.free(name);
        try titles.append(allocator, .{ .id = id, .name = name });
    }
    return .{ .titles = try titles.toOwnedSlice(allocator) };
}

/// Builds the exact copy order. Existing destination files absent from this
/// list are intentionally untouched, and title.csv is always the final item.
pub fn planSync(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_root: []const u8,
) !SyncPlan {
    if (!directoryExists(io, staging_root)) return error.StagingRootNotFound;
    var files: std.ArrayList(PlannedFile) = .empty;
    errdefer {
        for (files.items) |file| allocator.free(file.relative_path);
        files.deinit(allocator);
    }
    try collectStagedFiles(allocator, io, staging_root, "", &files);
    std.mem.sort(PlannedFile, files.items, {}, plannedFileLessThan);

    if (findPlannedFile(files.items, "sc64menu.n64") == null) return error.MenuRomNotFound;
    if (findPlannedFile(files.items, titleCsvRelativePath()) == null) return error.TitleCsvNotFound;
    return .{ .files = try files.toOwnedSlice(allocator) };
}

/// Copies a staging tree directly onto a selected card without deleting any
/// destination content. Save files are excluded even if present in staging.
pub fn syncFromStaging(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_root: []const u8,
    card_root: []const u8,
    progress: ?Progress,
) !void {
    if (!directoryExists(io, card_root)) return error.CardRootNotFound;
    const menu_marker = try std.fs.path.join(allocator, &.{ card_root, "sc64menu.n64" });
    defer allocator.free(menu_marker);
    const catalog_marker = try std.fs.path.join(allocator, &.{ card_root, "menu", "title.csv" });
    defer allocator.free(catalog_marker);
    if (!fileExists(io, menu_marker) or !fileExists(io, catalog_marker)) return error.CardIdentityChanged;
    var plan = try planSync(allocator, io, staging_root);
    defer plan.deinit(allocator);

    const cwd = std.Io.Dir.cwd();
    for (plan.files, 0..) |file, index| {
        const source = try std.fs.path.join(allocator, &.{ staging_root, file.relative_path });
        defer allocator.free(source);
        const destination = try std.fs.path.join(allocator, &.{ card_root, file.relative_path });
        defer allocator.free(destination);
        if (std.fs.path.dirname(destination)) |parent| try cwd.createDirPath(io, parent);

        if (isTitleCsv(file.relative_path)) {
            var random_bytes: [8]u8 = undefined;
            io.random(&random_bytes);
            const temporary = try std.fmt.allocPrint(
                allocator,
                "{s}.m64importer-{s}.tmp",
                .{ destination, std.fmt.bytesToHex(random_bytes, .lower) },
            );
            defer allocator.free(temporary);
            errdefer cwd.deleteFile(io, temporary) catch {};
            try cwd.copyFile(source, cwd, temporary, io, .{});
            var temporary_file = try cwd.openFile(io, temporary, .{ .mode = .read_write });
            defer temporary_file.close(io);
            try temporary_file.sync(io);
            try cwd.rename(temporary, cwd, destination, io);
        } else {
            try cwd.copyFile(source, cwd, destination, io, .{});
        }

        if (progress) |reporter| reporter.callback(reporter.context, .{
            .current = index + 1,
            .total = plan.files.len,
            .path = file.relative_path,
        });
    }
}

fn parseTitleCsv(allocator: std.mem.Allocator, bytes: []const u8) ![]TitleId {
    var ids: std.ArrayList(TitleId) = .empty;
    errdefer ids.deinit(allocator);
    var offset: usize = 0;
    while (offset < bytes.len and bytes[offset] != 0) {
        const end = std.mem.indexOfAnyPos(u8, bytes, offset, ",\x00") orelse bytes.len;
        const length = end - offset;
        if (length == 0 or length > 7) return error.InvalidTitleCsv;
        var id: TitleId = @splat(0);
        @memcpy(id[0..length], bytes[offset..end]);
        for (id[0..length]) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidTitleCsv;
        try ids.append(allocator, id);
        offset = end;
        if (offset == bytes.len or bytes[offset] == 0) break;
        if (bytes[offset] != ',') return error.InvalidTitleCsv;
        offset += 1;
    }
    if (offset < bytes.len and bytes[offset] == 0) offset += 1;
    while (offset < bytes.len) : (offset += 1) if (bytes[offset] != 0) return error.InvalidTitleCsv;
    return ids.toOwnedSlice(allocator);
}

fn collectStagedFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging_root: []const u8,
    relative_root: []const u8,
    files: *std.ArrayList(PlannedFile),
) !void {
    const path = if (relative_root.len == 0)
        try allocator.dupe(u8, staging_root)
    else
        try std.fs.path.join(allocator, &.{ staging_root, relative_root });
    defer allocator.free(path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (relative_root.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ relative_root, entry.name });
        switch (entry.kind) {
            .file => {
                if (isSavePath(relative)) {
                    allocator.free(relative);
                } else {
                    files.append(allocator, .{ .relative_path = relative }) catch |err| {
                        allocator.free(relative);
                        return err;
                    };
                }
            },
            .directory => {
                defer allocator.free(relative);
                if (!isSavePath(relative)) try collectStagedFiles(allocator, io, staging_root, relative, files);
            },
            else => allocator.free(relative),
        }
    }
}

fn appendMountedChildren(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: *std.ArrayList([]u8),
    parent: []const u8,
    depth: usize,
) !void {
    if (depth == 0) return;
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const child = try std.fs.path.join(allocator, &.{ parent, entry.name });
        roots.append(allocator, child) catch |err| {
            allocator.free(child);
            return err;
        };
        try appendMountedChildren(allocator, io, roots, child, depth - 1);
    }
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.removable != b.removable) return a.removable;
    return std.mem.order(u8, a.card.root, b.card.root) == .lt;
}

fn plannedFileLessThan(_: void, a: PlannedFile, b: PlannedFile) bool {
    const a_csv = isTitleCsv(a.relative_path);
    const b_csv = isTitleCsv(b.relative_path);
    if (a_csv != b_csv) return !a_csv;
    return std.mem.order(u8, a.relative_path, b.relative_path) == .lt;
}

fn findPlannedFile(files: []const PlannedFile, wanted: []const u8) ?usize {
    for (files, 0..) |file, index| if (pathsEqual(file.relative_path, wanted)) return index;
    return null;
}

fn titleCsvRelativePath() []const u8 {
    return if (std.fs.path.sep == '/') "menu/title.csv" else "menu\\title.csv";
}

fn isTitleCsv(path: []const u8) bool {
    return pathsEqual(path, titleCsvRelativePath());
}

fn isSavePath(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    const first = parts.next() orelse return false;
    const second = parts.next() orelse return false;
    return std.ascii.eqlIgnoreCase(first, "menu") and std.ascii.eqlIgnoreCase(second, "save");
}

fn pathsEqual(a: []const u8, b: []const u8) bool {
    var a_parts = std.mem.tokenizeAny(u8, a, "/\\");
    var b_parts = std.mem.tokenizeAny(u8, b, "/\\");
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null or b_part == null) return a_part == null and b_part == null;
        if (!std.ascii.eqlIgnoreCase(a_part.?, b_part.?)) return false;
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

fn freePaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8)) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}

fn isRemovableWindowsRoot(root: []const u8) bool {
    if (builtin.os.tag != .windows or root.len < 2 or root[1] != ':') return false;
    const Native = struct {
        extern "kernel32" fn GetDriveTypeW(root_path_name: [*:0]const u16) callconv(.winapi) u32;
    };
    const wide_root = [_:0]u16{ std.ascii.toUpper(root[0]), ':', '\\' };
    return Native.GetDriveTypeW(&wide_root) == 2; // DRIVE_REMOVABLE
}

test "detection requires both authoritative card markers" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "card/menu");
    try temp.dir.createDirPath(std.testing.io, "rom-only");
    try temp.dir.createDirPath(std.testing.io, "library-only/menu");
    try temp.dir.createDirPath(std.testing.io, "empty-card");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/sc64menu.n64", .data = "menu" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/menu/title.csv", .data = "" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "rom-only/sc64menu.n64", .data = "menu" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "library-only/menu/title.csv", .data = "" });
    const card = try tempPath(allocator, temp, "card");
    defer allocator.free(card);
    const rom_only = try tempPath(allocator, temp, "rom-only");
    defer allocator.free(rom_only);
    const library_only = try tempPath(allocator, temp, "library-only");
    defer allocator.free(library_only);
    const empty_card = try tempPath(allocator, temp, "empty-card");
    defer allocator.free(empty_card);

    var cards = try detectCardsFromRoots(allocator, std.testing.io, &.{ empty_card, rom_only, library_only, card });
    defer cards.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cards.cards.len);
    try std.testing.expectEqualStrings(card, cards.cards[0].root);
    try std.testing.expect(cards.cards[0].has_menu_rom and cards.cards[0].has_library);
}

test "installed library reads sidecar names and falls back to IDs" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "menu/title/ABCDE");
    try temp.dir.createDirPath(std.testing.io, "menu/title/12345");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "menu/title.csv", .data = "ABCDE,12345,\x00" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "menu/title/ABCDE/ABCDE_e.name", .data = "Named Game\r\n" });
    const root = try tempPath(allocator, temp, "");
    defer allocator.free(root);

    var library = try readInstalledLibrary(allocator, std.testing.io, root);
    defer library.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), library.titles.len);
    try std.testing.expectEqualStrings("Named Game", library.titles[0].name);
    try std.testing.expectEqualStrings("12345", library.titles[1].name);
}

test "sync copies menu tree and ROM while preserving saves and unrelated files" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "staging/menu/title/ABCDE");
    try temp.dir.createDirPath(std.testing.io, "staging/menu/save");
    try temp.dir.createDirPath(std.testing.io, "card/menu/save");
    try temp.dir.createDirPath(std.testing.io, "card/menu/title/OLD00");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/sc64menu.n64", .data = "old menu" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/menu/title.csv", .data = "OLD00,\x00" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/sc64menu.n64", .data = "new menu" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/title/ABCDE/ABCDE_e.z64", .data = "rom" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/title/ABCDE/ABCDE_e.sprite", .data = "sprite" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/title.csv", .data = "ABCDE,\x00" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/save/ABCDE.sav", .data = "staged save" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/menu/save/ABCDE.sav", .data = "player save" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/menu/title/OLD00/OLD00_e.z64", .data = "old rom" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card/unrelated.txt", .data = "keep me" });
    const staging = try tempPath(allocator, temp, "staging");
    defer allocator.free(staging);
    const card = try tempPath(allocator, temp, "card");
    defer allocator.free(card);

    var capture = ProgressCapture{};
    try syncFromStaging(allocator, std.testing.io, staging, card, .{
        .context = &capture,
        .callback = ProgressCapture.report,
    });
    try expectFile(temp, "card/sc64menu.n64", "new menu");
    try expectFile(temp, "card/menu/title/ABCDE/ABCDE_e.z64", "rom");
    try expectFile(temp, "card/menu/title/ABCDE/ABCDE_e.sprite", "sprite");
    try expectFile(temp, "card/menu/save/ABCDE.sav", "player save");
    try expectFile(temp, "card/menu/title/OLD00/OLD00_e.z64", "old rom");
    try expectFile(temp, "card/unrelated.txt", "keep me");
    try std.testing.expect(capture.count > 0);
    try std.testing.expect(pathsEqual(capture.last_path[0..capture.last_len], titleCsvRelativePath()));

    try temp.dir.deleteFile(std.testing.io, "card/sc64menu.n64");
    try std.testing.expectError(error.CardIdentityChanged, syncFromStaging(allocator, std.testing.io, staging, card, null));
}

test "sync plan puts title csv last and excludes saves" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "staging/menu/save");
    try temp.dir.createDirPath(std.testing.io, "staging/menu/title/ABCDE");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/sc64menu.n64", .data = "menu" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/title/ABCDE/ABCDE_e.z64", .data = "rom" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/save/slot.sav", .data = "save" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "staging/menu/title.csv", .data = "ABCDE,\x00" });
    const staging = try tempPath(allocator, temp, "staging");
    defer allocator.free(staging);

    var plan = try planSync(allocator, std.testing.io, staging);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), plan.files.len);
    try std.testing.expect(isTitleCsv(plan.files[plan.files.len - 1].relative_path));
    for (plan.files) |file| try std.testing.expect(!isSavePath(file.relative_path));
}

const ProgressCapture = struct {
    count: usize = 0,
    last_path: [512]u8 = undefined,
    last_len: usize = 0,

    fn report(context: ?*anyopaque, event: ProgressEvent) void {
        const self: *ProgressCapture = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.last_len = @min(event.path.len, self.last_path.len);
        @memcpy(self.last_path[0..self.last_len], event.path[0..self.last_len]);
        std.debug.assert(event.current <= event.total);
    }
};

fn expectFile(temp: std.testing.TmpDir, relative_path: []const u8, expected: []const u8) !void {
    const bytes = try temp.dir.readFileAlloc(std.testing.io, relative_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

fn tempPath(allocator: std.mem.Allocator, temp: std.testing.TmpDir, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temp.sub_path, child });
}
