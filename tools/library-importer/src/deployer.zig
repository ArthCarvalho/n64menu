const std = @import("std");
const builtin = @import("builtin");

const executable_name = if (builtin.os.tag == .windows) "sc64deployer.exe" else "sc64deployer";
const output_limit = 4 * 1024 * 1024;
const title_csv_limit = 64 * 1024;
const title_name_limit = 4 * 1024;

pub const InstalledTitle = struct {
    id: [5]u8,
    name: []u8,
};

pub const ReadInstalledOptions = struct {
    cleanup_error: ?*?anyerror = null,
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

pub const Command = struct {
    kind: Kind,
    local_path: ?[]u8,
    sd_path: []u8,

    pub const Kind = enum { mkdir, upload };

    pub const Argv = struct {
        values: [7][]const u8,
        len: usize,

        pub fn slice(self: *const Argv) []const []const u8 {
            return self.values[0..self.len];
        }
    };

    pub fn argv(self: Command, deployer_path: []const u8, port: []const u8) Argv {
        var result: Argv = .{ .values = undefined, .len = 0 };
        result.values[0] = deployer_path;
        result.values[1] = "--port";
        result.values[2] = port;
        result.values[3] = "sd";
        switch (self.kind) {
            .mkdir => {
                result.values[4] = "mkdir";
                result.values[5] = self.sd_path;
                result.len = 6;
            },
            .upload => {
                result.values[4] = "upload";
                result.values[5] = self.local_path.?;
                result.values[6] = self.sd_path;
                result.len = 7;
            },
        }
        return result;
    }

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        if (self.local_path) |path| allocator.free(path);
        allocator.free(self.sd_path);
        self.* = undefined;
    }
};

pub const Plan = struct {
    commands: []Command,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.commands) |*command| command.deinit(allocator);
        allocator.free(self.commands);
        self.* = undefined;
    }
};

pub const SyncOptions = struct {
    deployer_path: []const u8,
    port: []const u8,
    menu_root: []const u8,
    sc64menu_path: ?[]const u8 = null,
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
    if (isFile(io, bundled) and executableWorks(allocator, io, bundled) catch false) return allocator.dupe(u8, bundled);

    if (try executableWorks(allocator, io, executable_name)) {
        return allocator.dupe(u8, executable_name);
    }
    if (explicit_path) |path| {
        if (isFile(io, path)) return allocator.dupe(u8, path);
    }
    return error.DeployerNotFound;
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

/// Parses the comma-delimited five-byte IDs written to menu/title.csv.
pub fn parseTitleCsv(allocator: std.mem.Allocator, bytes: []const u8) ![][5]u8 {
    var ids: std.ArrayList([5]u8) = .empty;
    errdefer ids.deinit(allocator);

    var offset: usize = 0;
    while (offset < bytes.len and bytes[offset] != 0) {
        if (bytes.len - offset < 5) return error.InvalidTitleCsv;
        const id = bytes[offset..][0..5].*;
        for (id) |byte| if (!isTitleIdByte(byte)) return error.InvalidTitleCsv;
        try ids.append(allocator, id);
        offset += 5;

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
    const environ = std.process.Environ{ .block = .global };
    const system_temp = std.process.Environ.getAlloc(environ, allocator, "TMPDIR") catch
        std.process.Environ.getAlloc(environ, allocator, "TEMP") catch
        std.process.Environ.getAlloc(environ, allocator, "TMP") catch
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
        const sd_name_path = try std.fmt.allocPrint(allocator, "/menu/title/{s}/{s}_e.name", .{ id, id });
        defer allocator.free(sd_name_path);
        const local_name_path = try std.fmt.allocPrint(allocator, "{s}/{s}.name", .{ temp_root, id });
        defer allocator.free(local_name_path);

        var name: []u8 = undefined;
        if (download(allocator, io, deployer_path, port, sd_name_path, local_name_path)) |_| {
            const raw_name = try cwd.readFileAlloc(io, local_name_path, allocator, .limited(title_name_limit));
            defer allocator.free(raw_name);
            const trimmed = std.mem.trimEnd(u8, raw_name, "\x00\r\n");
            name = if (trimmed.len == 0) try allocator.dupe(u8, &id) else try allocator.dupe(u8, trimmed);
        } else |err| switch (err) {
            error.DownloadNotFound => name = try allocator.dupe(u8, &id),
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
        } else if (std.mem.eql(u8, found.?.name, &found.?.id) or storedNameEqual(found.?.name, title.name)) {
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

/// Produces a deterministic set of mkdir/upload commands without contacting hardware.
pub fn planSync(
    allocator: std.mem.Allocator,
    io: std.Io,
    menu_root: []const u8,
    sc64menu_path: ?[]const u8,
) !Plan {
    var commands: std.ArrayList(Command) = .empty;
    errdefer {
        for (commands.items) |*command| command.deinit(allocator);
        commands.deinit(allocator);
    }

    try appendCommand(allocator, &commands, .mkdir, null, "/menu");
    var menu_dir = try std.Io.Dir.cwd().openDir(io, menu_root, .{ .iterate = true });
    defer menu_dir.close(io);
    var walker = try menu_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const destination = try menuDestination(allocator, entry.path);
                defer allocator.free(destination);
                try appendCommand(allocator, &commands, .mkdir, null, destination);
            },
            .file => {
                const source = try std.fs.path.join(allocator, &.{ menu_root, entry.path });
                defer allocator.free(source);
                const destination = try menuDestination(allocator, entry.path);
                defer allocator.free(destination);
                try appendCommand(allocator, &commands, .upload, source, destination);
            },
            else => {},
        }
    }
    if (sc64menu_path) |source| {
        if (!isFile(io, source)) return error.Sc64MenuNotFound;
        try appendCommand(allocator, &commands, .upload, source, "/sc64menu.n64");
    }
    std.mem.sort(Command, commands.items, {}, commandLessThan);
    return .{ .commands = try commands.toOwnedSlice(allocator) };
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

    var plan = try planSync(allocator, io, options.menu_root, options.sc64menu_path);
    defer plan.deinit(allocator);
    for (plan.commands, 0..) |command, index| {
        const args = command.argv(options.deployer_path, options.port);
        const result = try run(allocator, io, args.slice());
        defer freeRunResult(allocator, result);
        if (isPoweredOnRefusal(result.stdout) or isPoweredOnRefusal(result.stderr)) return error.ConsolePoweredOn;
        if (!termSucceeded(result.term)) {
            if (command.kind != .mkdir or
                (!isExistingDirectoryError(result.stdout) and !isExistingDirectoryError(result.stderr)))
            {
                return error.DeployerCommandFailed;
            }
        }
        if (progress) |reporter| reporter.callback(reporter.context, .{
            .current = index + 1,
            .total = plan.commands.len,
            .path = command.sd_path,
        });
    }
}

fn isExistingDirectoryError(output: []const u8) bool {
    return containsIgnoreCase(output, "exist") or
        containsIgnoreCase(output, "access denied due to prohibited access");
}

fn appendCommand(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(Command),
    kind: Command.Kind,
    local_path: ?[]const u8,
    sd_path: []const u8,
) !void {
    const owned_local = if (local_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (owned_local) |path| allocator.free(path);
    const owned_sd = try allocator.dupe(u8, sd_path);
    errdefer allocator.free(owned_sd);
    try commands.append(allocator, .{ .kind = kind, .local_path = owned_local, .sd_path = owned_sd });
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

fn isTitleIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

fn isMissingRemoteFile(output: []const u8) bool {
    return containsIgnoreCase(output, "could not find the file") or
        containsIgnoreCase(output, "could not find the path") or
        containsIgnoreCase(output, "no such file");
}

fn findTitle(titles: []const InstalledTitle, id: [5]u8) ?*const InstalledTitle {
    for (titles) |*title| if (std.mem.eql(u8, &title.id, &id)) return title;
    return null;
}

fn menuDestination(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, "/menu/".len + relative_path.len);
    @memcpy(result[0.."/menu/".len], "/menu/");
    for (relative_path, 0..) |byte, index| {
        result["/menu/".len + index] = if (byte == '\\') '/' else byte;
    }
    return result;
}

fn commandLessThan(_: void, a: Command, b: Command) bool {
    if (a.kind != b.kind) return a.kind == .mkdir;
    const a_catalog = std.mem.eql(u8, a.sd_path, "/menu/title.csv");
    const b_catalog = std.mem.eql(u8, b.sd_path, "/menu/title.csv");
    if (a_catalog != b_catalog) return !a_catalog;
    return std.mem.order(u8, a.sd_path, b.sd_path) == .lt;
}

fn executableWorks(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const result = run(allocator, io, &.{ path, "--version" }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer freeRunResult(allocator, result);
    return termSucceeded(result.term);
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
        try std.testing.expectEqualSlices(u8, "ABCDE", &ids[0]);
        try std.testing.expectEqualSlices(u8, "12345", &ids[1]);
    }
}

test "title CSV parser accepts empty input and rejects malformed IDs" {
    const allocator = std.testing.allocator;
    const empty = try parseTitleCsv(allocator, "\x00");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABCD,"));
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABCDE,,12345"));
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABC/E,12345"));
    try std.testing.expectError(error.InvalidTitleCsv, parseTitleCsv(allocator, "ABCDE\x00junk"));
}

test "library diff compares IDs and names" {
    const desired = [_]InstalledTitle{
        .{ .id = "AAAAA".*, .name = @constCast("Same") },
        .{ .id = "BBBBB".*, .name = @constCast("Renamed") },
        .{ .id = "CCCCC".*, .name = @constCast("New") },
    };
    const installed = [_]InstalledTitle{
        .{ .id = "AAAAA".*, .name = @constCast("Same") },
        .{ .id = "BBBBB".*, .name = @constCast("Old name") },
        .{ .id = "DDDDD".*, .name = @constCast("Removed") },
    };
    try std.testing.expectEqual(LibraryDiff{ .add = 1, .keep = 1, .update = 1, .remove = 1 }, diffLibrary(&desired, &installed));

    const legacy = [_]InstalledTitle{.{ .id = "AAAAA".*, .name = @constCast("AAAAA") }};
    try std.testing.expectEqual(LibraryDiff{ .add = 2, .keep = 1, .update = 0, .remove = 0 }, diffLibrary(&desired, &legacy));
}

test "powered-on deployer prompt is recognized without interaction" {
    try std.testing.expect(isPoweredOnRefusal("The console is powered on. Continue anyways? [y/N]"));
    try std.testing.expect(isPoweredOnRefusal("SD card access aborted"));
    try std.testing.expect(!isPoweredOnRefusal("Successfully uploaded /menu/title.csv"));
    try std.testing.expect(isMissingRemoteFile("Could not find the file"));
    try std.testing.expect(!isMissingRemoteFile("The physical drive does not work"));
    try std.testing.expect(isExistingDirectoryError("FatFs error: Access denied due to prohibited access"));
}

test "sync command plan recursively creates directories and uploads files" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "menu/title/ABCDE");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "menu/title.csv", .data = "ABCDE,\x00" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "menu/title/ABCDE/ABCDE_e.name", .data = "Game" });
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "sc64menu.n64", .data = "rom" });

    const root = try tempPath(allocator, temp, "menu");
    defer allocator.free(root);
    const rom = try tempPath(allocator, temp, "sc64menu.n64");
    defer allocator.free(rom);
    var plan = try planSync(allocator, std.testing.io, root, rom);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), plan.commands.len);
    try expectCommand(plan.commands[0], .mkdir, null, "/menu");
    try expectCommand(plan.commands[1], .mkdir, null, "/menu/title");
    try expectCommand(plan.commands[2], .mkdir, null, "/menu/title/ABCDE");
    try expectCommand(plan.commands[3], .upload, null, "/menu/title/ABCDE/ABCDE_e.name");
    try expectCommand(plan.commands[4], .upload, rom, "/sc64menu.n64");
    // Publish the catalog only after every referenced title asset and the boot ROM exist.
    try expectCommand(plan.commands[5], .upload, null, "/menu/title.csv");

    const mkdir_args = plan.commands[1].argv("C:\\app\\sc64deployer.exe", "serial://COM5");
    try expectArgs(&.{ "C:\\app\\sc64deployer.exe", "--port", "serial://COM5", "sd", "mkdir", "/menu/title" }, mkdir_args.slice());
    const upload_args = plan.commands[4].argv("sc64deployer.exe", "serial://COM5");
    try expectArgs(&.{ "sc64deployer.exe", "--port", "serial://COM5", "sd", "upload", rom, "/sc64menu.n64" }, upload_args.slice());
}

fn expectCommand(command: Command, kind: Command.Kind, local_suffix: ?[]const u8, sd_path: []const u8) !void {
    try std.testing.expectEqual(kind, command.kind);
    try std.testing.expectEqualStrings(sd_path, command.sd_path);
    if (local_suffix) |suffix| {
        try std.testing.expect(std.mem.endsWith(u8, command.local_path.?, suffix));
    } else if (kind == .mkdir) {
        try std.testing.expect(command.local_path == null);
    } else {
        try std.testing.expect(command.local_path != null);
    }
}

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| try std.testing.expectEqualStrings(expected_arg, actual_arg);
}

fn tempPath(allocator: std.mem.Allocator, temp: std.testing.TmpDir, child: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temp.sub_path, child });
}
