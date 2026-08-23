const std = @import("std");

pub const maximum_registry_size = 8 * 1024 * 1024;
pub const maximum_artifact_size = 96 * 1024 * 1024;
pub const maximum_variants_per_title = 8;
pub const bundled_registry = @embedFile("testdata/registry-v1.json");

pub const PatchFormat = enum { bps, vcdiff };

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    authors: []const []const u8,
    projectUrl: []const u8,
    source: Source,
    base: Base,
    patch: Patch,
    output: Output = .{},
    compatibility: []const u8,
    saveType: ?[]const u8 = null,
    rights: Rights,
};

pub const Source = struct {
    provider: []const u8,
    metadataUrl: []const u8,
    retrievedAt: []const u8,
};

pub const Base = struct {
    name: []const u8,
    variant: []const u8,
    gameCode: ?[]const u8 = null,
    normalizedCrc32: []const u8,
    normalizedSha256: []const u8,
};

pub const Patch = struct {
    format: PatchFormat,
    url: []const u8,
    size: usize,
    sha256: []const u8,
    archiveMember: ?[]const u8 = null,
    memberSize: ?usize = null,
    memberSha256: ?[]const u8 = null,
    sourceCrc32: ?[]const u8 = null,
    targetCrc32: ?[]const u8 = null,
    patchCrc32: ?[]const u8 = null,
};

pub const Output = struct {
    sha1: ?[]const u8 = null,
};

pub const Rights = struct {
    patchRedistributionAllowed: bool,
    artworkRedistributionAllowed: bool,
};

const Document = struct {
    schemaVersion: u32,
    generatedAt: []const u8,
    notice: []const u8,
    entries: []Entry,
};

pub const Registry = struct {
    parsed: std.json.Parsed(Document),

    pub fn deinit(self: *Registry) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn entries(self: *const Registry) []const Entry {
        return self.parsed.value.entries;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Registry {
    if (bytes.len > maximum_registry_size) return error.RegistryTooLarge;
    var parsed = try std.json.parseFromSlice(Document, allocator, bytes, .{ .ignore_unknown_fields = false });
    errdefer parsed.deinit();
    if (parsed.value.schemaVersion != 1 or parsed.value.entries.len == 0) return error.InvalidRegistry;
    for (parsed.value.entries, 0..) |entry, index| {
        try validateEntry(entry);
        for (parsed.value.entries[0..index]) |previous| if (std.mem.eql(u8, previous.id, entry.id)) return error.DuplicateRegistryId;
    }
    return .{ .parsed = parsed };
}

pub fn matching(registry: *const Registry, normalized_crc32: u32, normalized_sha256: *const [32]u8, output: []usize) usize {
    var count: usize = 0;
    for (registry.entries(), 0..) |entry, index| {
        const expected = std.fmt.parseUnsigned(u32, entry.base.normalizedCrc32, 16) catch continue;
        if (expected != normalized_crc32) continue;
        const actual_sha256 = std.fmt.bytesToHex(normalized_sha256.*, .upper);
        if (!std.ascii.eqlIgnoreCase(&actual_sha256, entry.base.normalizedSha256)) continue;
        if (count < output.len) output[count] = index;
        count += 1;
    }
    return count;
}

pub fn download(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: Entry,
    cache_directory: []const u8,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, cache_directory);
    const destination = try cachedArtifactPath(allocator, entry, cache_directory);
    errdefer allocator.free(destination);
    if (try cachedArtifactReady(io, destination, entry)) return destination;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const response_bytes = try allocator.alloc(u8, entry.patch.size);
    defer allocator.free(response_bytes);
    var response: std.Io.Writer = .fixed(response_bytes);
    const result = try client.fetch(.{
        .location = .{ .url = entry.patch.url },
        .response_writer = &response,
        .headers = .{ .user_agent = .{ .override = "m64menu-importer/0.1" } },
    });
    if (result.status != .ok) return error.DownloadFailed;
    const written = response.buffered();
    if (written.len != entry.patch.size) return error.DownloadSizeMismatch;
    if (!sha256Matches(written, entry.patch.sha256)) return error.DownloadHashMismatch;
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{destination});
    defer allocator.free(temporary);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = written });
    std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, io) catch {
        std.Io.Dir.cwd().deleteFile(io, destination) catch {};
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), destination, io);
    };
    return destination;
}

pub fn cachedArtifactPath(allocator: std.mem.Allocator, entry: Entry, cache_directory: []const u8) ![]u8 {
    const extension = if (entry.patch.archiveMember != null) ".zip" else switch (entry.patch.format) {
        .bps => ".bps",
        .vcdiff => ".vcdiff",
    };
    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ entry.id, entry.version, extension });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ cache_directory, filename });
}

pub fn cachedArtifactReady(io: std.Io, path: []const u8, entry: Entry) !bool {
    return fileMatches(io, path, entry.patch.size, entry.patch.sha256);
}

pub fn cachedArtifactExists(io: std.Io, path: []const u8, entry: Entry) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.size == entry.patch.size;
}

pub fn readPatchBytes(allocator: std.mem.Allocator, io: std.Io, artifact_path: []const u8, entry: Entry) ![]u8 {
    if (!(try cachedArtifactReady(io, artifact_path, entry))) return error.DownloadHashMismatch;
    if (entry.patch.archiveMember == null) {
        return std.Io.Dir.cwd().readFileAlloc(io, artifact_path, allocator, .limited(maximum_artifact_size));
    }
    var file = try std.Io.Dir.cwd().openFile(io, artifact_path, .{});
    defer file.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    var iterator = try std.zip.Iterator.init(&file_reader);
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const expected = entry.patch.archiveMember.?;
    while (try iterator.next()) |zip_entry| {
        if (zip_entry.filename_len > filename_buffer.len) return error.InvalidArchiveMember;
        try file_reader.seekTo(zip_entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try file_reader.interface.readSliceAll(filename_buffer[0..zip_entry.filename_len]);
        const filename = filename_buffer[0..zip_entry.filename_len];
        if (!std.mem.eql(u8, filename, expected)) continue;
        if (zip_entry.uncompressed_size != entry.patch.memberSize.?) return error.ArchiveMemberSizeMismatch;
        var random: [8]u8 = undefined;
        io.random(&random);
        const temporary_path = try std.fmt.allocPrint(allocator, "{s}.extract-{s}", .{ artifact_path, std.fmt.bytesToHex(random, .lower) });
        defer allocator.free(temporary_path);
        try std.Io.Dir.cwd().createDirPath(io, temporary_path);
        defer std.Io.Dir.cwd().deleteTree(io, temporary_path) catch {};
        var temporary = try std.Io.Dir.cwd().openDir(io, temporary_path, .{});
        defer temporary.close(io);
        try zip_entry.extract(&file_reader, .{}, &filename_buffer, temporary);
        const extracted_path = try std.fs.path.join(allocator, &.{ temporary_path, expected });
        defer allocator.free(extracted_path);
        const extracted = try std.Io.Dir.cwd().readFileAlloc(io, extracted_path, allocator, .limited(maximum_artifact_size));
        errdefer allocator.free(extracted);
        if (!sha256Matches(extracted, entry.patch.memberSha256.?)) return error.ArchiveMemberHashMismatch;
        return extracted;
    }
    return error.ArchiveMemberNotFound;
}

pub fn normalizedCrc32(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn validateEntry(entry: Entry) !void {
    if (!validId(entry.id) or !validComponent(entry.version) or entry.name.len == 0 or std.mem.indexOfAny(u8, entry.name, ",\r\n") != null) return error.InvalidRegistryEntry;
    if (!validHttpsUrl(entry.projectUrl) or !validHttpsUrl(entry.source.metadataUrl) or !validHttpsUrl(entry.patch.url)) return error.InvalidRegistryUrl;
    if (entry.patch.size == 0 or entry.patch.size > maximum_artifact_size) return error.InvalidRegistryEntry;
    if (!validHex(entry.base.normalizedCrc32, 8) or !validHex(entry.base.normalizedSha256, 64) or !validHex(entry.patch.sha256, 64)) return error.InvalidRegistryHash;
    if (entry.patch.sourceCrc32) |value| if (!validHex(value, 8)) return error.InvalidRegistryHash;
    if (entry.patch.targetCrc32) |value| if (!validHex(value, 8)) return error.InvalidRegistryHash;
    if (entry.patch.patchCrc32) |value| if (!validHex(value, 8)) return error.InvalidRegistryHash;
    if (entry.output.sha1) |value| if (!validHex(value, 40)) return error.InvalidRegistryHash;
    if (entry.saveType) |value| if (!validSaveType(value)) return error.InvalidRegistryEntry;
    if (entry.patch.archiveMember) |member| {
        if (std.fs.path.isAbsolute(member) or std.mem.indexOf(u8, member, "..") != null or std.mem.indexOfScalar(u8, member, '\\') != null) return error.InvalidArchiveMember;
        if (entry.patch.memberSize == null or entry.patch.memberSize.? == 0 or entry.patch.memberSize.? > maximum_artifact_size or entry.patch.memberSha256 == null or !validHex(entry.patch.memberSha256.?, 64)) return error.InvalidRegistryEntry;
    }
}

fn validSaveType(value: []const u8) bool {
    const values = [_][]const u8{ "none", "eeprom4k", "eeprom16k", "sram", "srambanked", "sram128k", "flashram", "flashram-pkst2" };
    for (values) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or value[0] == '.' or value[value.len - 1] == '.') return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 96) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

fn validHttpsUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and std.mem.indexOfScalarPos(u8, url, 8, '/') != null;
}

fn validHex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn fileMatches(io: std.Io, path: []const u8, size: usize, expected_sha256: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file or stat.size != size) return false;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.c_allocator, .limited(maximum_artifact_size));
    defer std.heap.c_allocator.free(bytes);
    return sha256Matches(bytes, expected_sha256);
}

fn sha256Matches(bytes: []const u8, expected: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .upper);
    return std.ascii.eqlIgnoreCase(&actual, expected);
}

test "fixture parses and matches Super Mario 64 records" {
    var registry = try parse(std.testing.allocator, bundled_registry);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 4), registry.entries().len);
    var matches: [8]usize = undefined;
    var sha256: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sha256, "17CE077343C6133F8C9F2D6D6D9A4AB62C8CD2AA57C40AEA1F490B4C8BB21D91") catch unreachable;
    try std.testing.expectEqual(@as(usize, 3), matching(&registry, 0x3CE60709, &sha256, &matches));
    try std.testing.expectEqualStrings("SM64 The Green Stars", registry.entries()[matches[0]].name);
}

test "rejects duplicate IDs and unsafe archive paths" {
    const duplicate =
        \\{"schemaVersion":1,"generatedAt":"x","notice":"x","entries":[
        \\{"id":"same","name":"a","version":"1","authors":[],"projectUrl":"https://a/b","source":{"provider":"x","metadataUrl":"https://a/b","retrievedAt":"x"},"base":{"name":"b","variant":"v","normalizedCrc32":"00000000","normalizedSha256":"0000000000000000000000000000000000000000000000000000000000000000"},"patch":{"format":"bps","url":"https://a/p","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"compatibility":"x","rights":{"patchRedistributionAllowed":false,"artworkRedistributionAllowed":false}},
        \\{"id":"same","name":"b","version":"1","authors":[],"projectUrl":"https://a/b","source":{"provider":"x","metadataUrl":"https://a/b","retrievedAt":"x"},"base":{"name":"b","variant":"v","normalizedCrc32":"00000000","normalizedSha256":"0000000000000000000000000000000000000000000000000000000000000000"},"patch":{"format":"bps","url":"https://a/p","size":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"compatibility":"x","rights":{"patchRedistributionAllowed":false,"artworkRedistributionAllowed":false}}
        \\]}
    ;
    try std.testing.expectError(error.DuplicateRegistryId, parse(std.testing.allocator, duplicate));
}

test "bundled archive metadata pins only the BPS member" {
    var catalog = try parse(std.testing.allocator, bundled_registry);
    defer catalog.deinit();
    const entry = catalog.entries()[3];
    try std.testing.expectEqualStrings("mb64_v1_0_0/mb64_v1_0_0.bps", entry.patch.archiveMember.?);
    try std.testing.expect(entry.patch.memberSize.? < maximum_artifact_size);
    try std.testing.expect(!std.mem.endsWith(u8, entry.patch.archiveMember.?, ".exe"));
}
