const std = @import("std");
const builtin = @import("builtin");

const executable_name = if (builtin.os.tag == .windows) "sc64deployer.exe" else "sc64deployer";
const output_limit = 4 * 1024 * 1024;
const title_csv_limit = 16 * 1024 * 1024;
const title_name_limit = 4 * 1024;
pub const TitleId = [7]u8;

pub const InstalledTitle = struct {
    id: TitleId,
    name: []u8,

    pub fn idSlice(self: *const InstalledTitle) []const u8 {
        return self.id[0 .. std.mem.indexOfScalar(u8, &self.id, 0) orelse self.id.len];
    }
};

pub const ReadInstalledOptions = struct {
    cleanup_error: ?*?anyerror = null,
    environ: std.process.Environ = .empty,
};

pub const InstalledLibrary = struct {
    titles: []InstalledTitle,

    pub fn deinit(self: *InstalledLibrary, allocator: std.mem.Allocator) void {
        for (self.titles) |title| allocator.free(title.name);
        allocator.free(self.titles);
        self.* = undefined;
    }
};

pub const LibraryDiff = struct {
    add: usize,
    keep: usize,
    update: usize,
    remove: usize,
};

pub const Device = struct {
    serial: []u8,
    port: []u8,
    backend: []u8,

    fn deinit(self: *Device, allocator: std.mem.Allocator) void {
        allocator.free(self.serial);
        allocator.free(self.port);
        allocator.free(self.backend);
        self.* = undefined;
    }
};

pub const DeviceList = struct {
    devices: []Device,

    pub fn deinit(self: *DeviceList, allocator: std.mem.Allocator) void {
        for (self.devices) |*device| device.deinit(allocator);
        allocator.free(self.devices);
        self.* = undefined;
    }
};

pub const DeviceInfo = struct {
    output: []u8,
    console_powered_on: bool,

    pub fn deinit(self: *DeviceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
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

pub const SyncOptions = struct {
    deployer_path: []const u8,
    port: []const u8,
    staging_root: []const u8,
};

/// Finds a deployer bundled beside the running application, then one on PATH,
/// and finally the optional explicit executable path.
pub fn locate(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit_path: ?[]const u8,
) ![]u8 {
    const application_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(application_dir);
    const bundled = try std.fs.path.join(allocator, &.{ application_dir, executable_name });
    defer allocator.free(bundled);
    if (isFile(io, bundled) and supportsBatchedSync(allocator, io, bundled) catch false) return allocator.dupe(u8, bundled);

    if (try supportsBatchedSync(allocator, io, executable_name)) {
        return allocator.dupe(u8, executable_name);
    }
    if (explicit_path) |path| {
        if (isFile(io, path) and try supportsBatchedSync(allocator, io, path)) return allocator.dupe(u8, path);
    }
    return error.BatchedDeployerNotFound;
}

pub fn detectDevices(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
) !DeviceList {
    const result = try run(allocator, io, &.{ deployer_path, "list" });
    defer freeRunResult(allocator, result);
    if (!termSucceeded(result.term)) return error.DeployerCommandFailed;
    return parseDeviceList(allocator, result.stdout);
}

pub fn parseDeviceList(allocator: std.mem.Allocator, output: []const u8) !DeviceList {
    var devices: std.ArrayList(Device) = .empty;
    errdefer {
        for (devices.items) |*device| device.deinit(allocator);
        devices.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const index_text = std.mem.trim(u8, line[0..colon], " \t");
        _ = std.fmt.parseUnsigned(usize, index_text, 10) catch continue;

        const serial_open = std.mem.indexOfScalarPos(u8, line, colon + 1, '[') orelse return error.InvalidDeviceList;
        const serial_close = std.mem.indexOfScalarPos(u8, line, serial_open + 1, ']') orelse return error.InvalidDeviceList;
        const port_prefix = "at port [";
        const port_marker = std.mem.indexOfPos(u8, line, serial_close + 1, port_prefix) orelse return error.InvalidDeviceList;
        const port_start = port_marker + port_prefix.len;
        const port_close = std.mem.indexOfScalarPos(u8, line, port_start, ']') orelse return error.InvalidDeviceList;
        const backend_prefix = "(using \"";
        const backend_marker = std.mem.indexOfPos(u8, line, port_close + 1, backend_prefix) orelse return error.InvalidDeviceList;
        const backend_start = backend_marker + backend_prefix.len;
        const backend_suffix = "\" backend)";
        const backend_close = std.mem.indexOfPos(u8, line, backend_start, backend_suffix) orelse return error.InvalidDeviceList;
        if (serial_close == serial_open + 1 or port_close == port_start or backend_close == backend_start) return error.InvalidDeviceList;

        const serial = try allocator.dupe(u8, line[serial_open + 1 .. serial_close]);
        errdefer allocator.free(serial);
        const port = try allocator.dupe(u8, line[port_start..port_close]);
        errdefer allocator.free(port);
        const backend = try allocator.dupe(u8, line[backend_start..backend_close]);
        errdefer allocator.free(backend);
        try devices.append(allocator, .{ .serial = serial, .port = port, .backend = backend });
    }
    return .{ .devices = try devices.toOwnedSlice(allocator) };
}

pub fn probeDevice(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
    port: []const u8,
) !DeviceInfo {
    const result = try run(allocator, io, &.{ deployer_path, "--port", port, "info" });
    defer freeRunResult(allocator, result);
    if (!termSucceeded(result.term)) return error.DeployerCommandFailed;
    const output = try joinOutput(allocator, result.stdout, result.stderr);
    errdefer allocator.free(output);
    return .{
        .output = output,
        .console_powered_on = try parseConsolePoweredOn(output),
    };
}

pub fn parseConsolePoweredOn(output: []const u8) !bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const prefix = "Current CIC step:";
        if (startsWithIgnoreCase(line, prefix)) {
            const value = std.mem.trim(u8, line[prefix.len..], " \t");
            if (value.len == 0) return error.InvalidDeviceInfo;
            return !std.ascii.eqlIgnoreCase(value, "Power off");
        }
    }
    return error.InvalidDeviceInfo;
}

/// Parses comma-delimited IDs while retaining existing five-character catalogs.
pub fn parseTitleCsv(allocator: std.mem.Allocator, bytes: []const u8) ![]TitleId {
    var ids: std.ArrayList(TitleId) = .empty;
    errdefer ids.deinit(allocator);

    var offset: usize = 0;
    while (offset < bytes.len and bytes[offset] != 0) {
        const end = std.mem.indexOfAnyPos(u8, bytes, offset, ",\x00") orelse bytes.len;
        const length = end - offset;
        if (length == 0 or length > 7) return error.InvalidTitleCsv;
        var id: TitleId = @splat(0);
        @memcpy(id[0..length], bytes[offset..end]);
        for (id[0..length]) |byte| if (!isTitleIdByte(byte)) return error.InvalidTitleCsv;
        try ids.append(allocator, id);
        offset = end;

        if (offset == bytes.len or bytes[offset] == 0) break;
        if (bytes[offset] != ',') return error.InvalidTitleCsv;
        offset += 1;
    }

    if (offset < bytes.len and bytes[offset] == 0) offset += 1;
    while (offset < bytes.len) : (offset += 1) {
        if (bytes[offset] != 0) return error.InvalidTitleCsv;
    }
    return ids.toOwnedSlice(allocator);
}

/// Reads the installed menu metadata without uploading or deleting SD card files.
pub fn readInstalledLibrary(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
    port: []const u8,
) !InstalledLibrary {
    return readInstalledLibraryOptions(allocator, io, deployer_path, port, .{});
}

pub fn readInstalledLibraryOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
    port: []const u8,
    options: ReadInstalledOptions,
) !InstalledLibrary {
    var info = try probeDevice(allocator, io, deployer_path, port);
    defer info.deinit(allocator);
    if (info.console_powered_on) return error.ConsolePoweredOn;

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const temp_name = "m64menu-library-" ++ std.fmt.bytesToHex(random_bytes, .lower);
    const system_temp = std.process.Environ.getAlloc(options.environ, allocator, "TMPDIR") catch
        std.process.Environ.getAlloc(options.environ, allocator, "TEMP") catch
        std.process.Environ.getAlloc(options.environ, allocator, "TMP") catch
        try allocator.dupe(u8, if (builtin.os.tag == .windows) "." else "/tmp");
    defer allocator.free(system_temp);
    const temp_root = try std.fs.path.join(allocator, &.{ system_temp, temp_name });
    defer allocator.free(temp_root);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, temp_root);
    defer cwd.deleteTree(io, temp_root) catch |err| if (options.cleanup_error) |output| {
        output.* = err;
    };

    const csv_path = try std.fs.path.join(allocator, &.{ temp_root, "title.csv" });
    defer allocator.free(csv_path);
    download(allocator, io, deployer_path, port, "/menu/title.csv", csv_path) catch |err| switch (err) {
        error.DownloadNotFound => return .{ .titles = try allocator.alloc(InstalledTitle, 0) },
        else => return err,
    };
    const csv = try cwd.readFileAlloc(io, csv_path, allocator, .limited(title_csv_limit));
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
        const sd_name_path = try std.fmt.allocPrint(allocator, "/menu/title/{s}/{s}_e.name", .{ id_slice, id_slice });
        defer allocator.free(sd_name_path);
        const local_name_path = try std.fmt.allocPrint(allocator, "{s}/{s}.name", .{ temp_root, id_slice });
        defer allocator.free(local_name_path);

        var name: []u8 = undefined;
        if (download(allocator, io, deployer_path, port, sd_name_path, local_name_path)) |_| {
            const raw_name = try cwd.readFileAlloc(io, local_name_path, allocator, .limited(title_name_limit));
            defer allocator.free(raw_name);
            const trimmed = std.mem.trimEnd(u8, raw_name, "\x00\r\n");
            name = if (trimmed.len == 0) try allocator.dupe(u8, id_slice) else try allocator.dupe(u8, trimmed);
        } else |err| switch (err) {
            error.DownloadNotFound => name = try allocator.dupe(u8, id_slice),
            else => return err,
        }
        errdefer allocator.free(name);
        try titles.append(allocator, .{ .id = id, .name = name });
    }
    return .{ .titles = try titles.toOwnedSlice(allocator) };
}

/// Counts title changes only. Save files are not represented or modified.
pub fn diffLibrary(desired: []const InstalledTitle, installed: []const InstalledTitle) LibraryDiff {
    var result: LibraryDiff = .{ .add = 0, .keep = 0, .update = 0, .remove = 0 };
    for (desired) |title| {
        const found = findTitle(installed, title.id);
        if (found == null) {
            result.add += 1;
        } else if (std.mem.eql(u8, found.?.name, found.?.idSlice()) or storedNameEqual(found.?.name, title.name)) {
            // Libraries created before .name sidecars use the ID as their fallback
            // display name. A matching ID is already installed and should not be
            // presented as an update merely because that old metadata is absent.
            result.keep += 1;
        } else {
            result.update += 1;
        }
    }
    for (installed) |title| if (findTitle(desired, title.id) == null) {
        result.remove += 1;
    };
    return result;
}

fn storedNameEqual(installed: []const u8, desired: []const u8) bool {
    if (installed.len != desired.len) return false;
    for (desired, installed) |source, actual| {
        if (actual != if (source < 0x80) source else '?') return false;
    }
    return true;
}

/// Verifies that the console is powered off, then executes the planned SD sync.
pub fn sync(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SyncOptions,
    progress: ?Progress,
) !void {
    var info = try probeDevice(allocator, io, options.deployer_path, options.port);
    defer info.deinit(allocator);
    if (info.console_powered_on) return error.ConsolePoweredOn;

    if (!directoryExists(io, options.staging_root)) return error.StagingRootNotFound;
    var child = try std.process.spawn(io, .{
        .argv = &.{
            options.deployer_path,
            "--port",
            options.port,
            "sd",
            "sync",
            options.staging_root,
            "/",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    });
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    var powered_on_refusal = false;
    while (stdout_reader.interface.takeDelimiter('\n') catch |err| {
        child.kill(io);
        return err;
    }) |line| {
        if (isPoweredOnRefusal(line)) powered_on_refusal = true;
        if (progress) |reporter| reportBatchProgressLine(reporter, line);
    }
    if (!termSucceeded(try child.wait(io))) return error.DeployerCommandFailed;
    if (powered_on_refusal) return error.ConsolePoweredOn;
}

fn download(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
    port: []const u8,
    sd_path: []const u8,
    local_path: []const u8,
) !void {
    const result = try run(allocator, io, &.{ deployer_path, "--port", port, "sd", "download", sd_path, local_path });
    defer freeRunResult(allocator, result);
    if (isPoweredOnRefusal(result.stdout) or isPoweredOnRefusal(result.stderr)) return error.ConsolePoweredOn;
    if (!termSucceeded(result.term)) {
        if (!isFile(io, local_path) and (isMissingRemoteFile(result.stdout) or isMissingRemoteFile(result.stderr))) {
            return error.DownloadNotFound;
        }
        return error.DeployerCommandFailed;
    }
}

pub fn downloadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    deployer_path: []const u8,
    port: []const u8,
    sd_path: []const u8,
    local_path: []const u8,
) !void {
    return download(allocator, io, deployer_path, port, sd_path, local_path);
}

fn isTitleIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

fn isMissingRemoteFile(output: []const u8) bool {
    return containsIgnoreCase(output, "could not find the file") or
        containsIgnoreCase(output, "could not find the path") or
        containsIgnoreCase(output, "no such file");
}

fn findTitle(titles: []const InstalledTitle, id: TitleId) ?*const InstalledTitle {
    const id_slice = id[0 .. std.mem.indexOfScalar(u8, &id, 0) orelse id.len];
    for (titles) |*title| if (std.mem.eql(u8, title.idSlice(), id_slice)) return title;
    return null;
}

fn reportBatchProgressLine(reporter: Progress, raw: []const u8) void {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (!std.mem.startsWith(u8, line, "SYNC ")) return;
    const first_space = std.mem.indexOfScalarPos(u8, line, 5, ' ') orelse return;
    const fraction = line[5..first_space];
    const slash = std.mem.indexOfScalar(u8, fraction, '/') orelse return;
    const current = std.fmt.parseUnsigned(usize, fraction[0..slash], 10) catch return;
    const total = std.fmt.parseUnsigned(usize, fraction[slash + 1 ..], 10) catch return;
    reporter.callback(reporter.context, .{ .current = current, .total = total, .path = line[first_space + 1 ..] });
}

fn directoryExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn executableWorks(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const result = run(allocator, io, &.{ path, "--version" }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer freeRunResult(allocator, result);
    return termSucceeded(result.term);
}

fn supportsBatchedSync(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    if (!(try executableWorks(allocator, io, path))) return false;
    const result = run(allocator, io, &.{ path, "sd", "sync", "--help" }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer freeRunResult(allocator, result);
    return termSucceeded(result.term) and std.mem.indexOf(u8, result.stdout, "sd sync") != null;
}

fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
        .create_no_window = true,
    });
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn joinOutput(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    if (stdout.len == 0) return allocator.dupe(u8, stderr);
    if (stderr.len == 0) return allocator.dupe(u8, stdout);
    return std.mem.concat(allocator, u8, &.{ stdout, "\n", stderr });
}

fn isPoweredOnRefusal(output: []const u8) bool {
    return containsIgnoreCase(output, "console is powered on") or
        containsIgnoreCase(output, "continue anyways?") or
        containsIgnoreCase(output, "sd card access aborted");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

test "public declarations compile" {
    std.testing.refAllDecls(@This());
}

test "device list parser extracts serial port and backend" {
    const output =
        "Found devices:\r\n" ++
        " 1: [SC64AAAAAA1] at port [serial://COM5] (using \"serial\" backend)\r\n" ++
        " 2: [SC64BBBBBB2] at port [ftdi://1] (using \"ftdi\" backend)\r\n";
    var result = try parseDeviceList(std.testing.allocator, output);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.devices.len);
    try std.testing.expectEqualStrings("SC64AAAAAA1", result.devices[0].serial);
    try std.testing.expectEqualStrings("serial://COM5", result.devices[0].port);
    try std.testing.expectEqualStrings("serial", result.devices[0].backend);
    try std.testing.expectEqualStrings("SC64BBBBBB2", result.devices[1].serial);
    try std.testing.expectEqualStrings("ftdi://1", result.devices[1].port);
    try std.testing.expectEqualStrings("ftdi", result.devices[1].backend);
}

test "device list parser accepts no devices and rejects malformed device lines" {
    var empty = try parseDeviceList(std.testing.allocator, "Found devices:\n");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.devices.len);
    try std.testing.expectError(
        error.InvalidDeviceList,
        parseDeviceList(std.testing.allocator, "1: [SC64A] at port [serial://COM5]\n"),
    );
}

test "device info parser identifies console power state" {
    try std.testing.expect(!(try parseConsolePoweredOn(
        "SummerCart64 diagnostic information:\r\n Current CIC step:  Power off\r\n",
    )));
    try std.testing.expect(try parseConsolePoweredOn(
        "SummerCart64 diagnostic information:\n Current CIC step:  Running\n",
    ));
    try std.testing.expectError(error.InvalidDeviceInfo, parseConsolePoweredOn("Firmware version: v2.20.2\n"));
}

test "title CSV parser accepts generated and legacy-ish terminators" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "ABCDE,12345,\x00",
        "ABCDE,12345,",
        "ABCDE,12345",
        "ABCDE,12345\x00",
    };
    for (cases) |bytes| {
        const ids = try parseTitleCsv(allocator, bytes);
        defer allocator.free(ids);
        try std.testing.expectEqual(@as(usize, 2), ids.len);
        try std.testing.expectEqualSlices(u8, "ABCDE", ids[0][0..5]);
        try std.testing.expectEqualSlices(u8, "12345", ids[1][0..5]);
    }
}

test "title CSV parser accepts empty input and rejects malformed IDs" {
    const allocator = std.testing.allocator;
    const empty = try parseTitleCsv(allocator, "\x00");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const short = try parseTitleCsv(allocator, "ABCD,");
    defer allocator.free(short);
    try std.testing.expectEqualSlices(u8, "ABCD", short[0][0..4]);
    const extended = try parseTitleCsv(allocator, "ABCDEF,ABCDEFG,");
    defer allocator.free(extended);
    try std.testing.expectEqual(@as(usize, 2), extended.len);
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABCDE,,12345"));
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABC/E,12345"));
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABCDE\x00junk"));
}

test "library diff compares IDs and names" {
    const desired = [_]InstalledTitle{
        .{ .id = "AAAAA\x00\x00".*, .name = @constCast("Same") },
        .{ .id = "BBBBB\x00\x00".*, .name = @constCast("Renamed") },
        .{ .id = "CCCCC\x00\x00".*, .name = @constCast("New") },
    };
    const installed = [_]InstalledTitle{
        .{ .id = "AAAAA\x00\x00".*, .name = @constCast("Same") },
        .{ .id = "BBBBB\x00\x00".*, .name = @constCast("Old name") },
        .{ .id = "DDDDD\x00\x00".*, .name = @constCast("Removed") },
    };
    try std.testing.expectEqual(LibraryDiff{ .add = 1, .keep = 1, .update = 1, .remove = 1 }, diffLibrary(&desired, &installed));

    const legacy = [_]InstalledTitle{.{ .id = "AAAAA\x00\x00".*, .name = @constCast("AAAAA") }};
    try std.testing.expectEqual(LibraryDiff{ .add = 2, .keep = 1, .update = 0, .remove = 0 }, diffLibrary(&desired, &legacy));
}

test "powered-on deployer prompt is recognized without interaction" {
    try std.testing.expect(isPoweredOnRefusal("The console is powered on. Continue anyways? [y/N]"));
    try std.testing.expect(isPoweredOnRefusal("SD card access aborted"));
    try std.testing.expect(!isPoweredOnRefusal("Successfully uploaded /menu/title.csv"));
    try std.testing.expect(isMissingRemoteFile("Could not find the file"));
    try std.testing.expect(!isMissingRemoteFile("The physical drive does not work"));
}

test "batched stdout detects late powered-on refusal" {
    try std.testing.expect(isPoweredOnRefusal("SD card access aborted"));
    try std.testing.expect(!isPoweredOnRefusal("SYNC 1/3 /sc64menu.n64"));
}

test "batched deployer progress is parsed" {
    const Capture = struct {
        var events: [3]ProgressEvent = undefined;
        var count: usize = 0;

        fn callback(_: ?*anyopaque, event: ProgressEvent) void {
            events[count] = event;
            count += 1;
        }
    };
    Capture.count = 0;
    const reporter = Progress{ .callback = Capture.callback };
    reportBatchProgressLine(reporter, "noise");
    reportBatchProgressLine(reporter, "SYNC 1/3 /menu/title/A/A_e.sprite");
    reportBatchProgressLine(reporter, "SYNC 2/3 /sc64menu.n64");
    reportBatchProgressLine(reporter, "SYNC 3/3 /menu/title.csv");
    try std.testing.expectEqual(@as(usize, 3), Capture.count);
    try std.testing.expectEqual(@as(usize, 1), Capture.events[0].current);
    try std.testing.expectEqual(@as(usize, 3), Capture.events[2].total);
    try std.testing.expectEqualStrings("/menu/title.csv", Capture.events[2].path);
}

fn tempPath(allocator: std.mem.Allocator, temp: std.testing.TmpDir, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temp.sub_path, child });
}
