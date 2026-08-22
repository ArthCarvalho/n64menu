const std = @import("std");
const sokol = @import("sokol");
const importer = @import("importer");
const deployer = @import("deployer");
const sdcard = @import("sdcard");
const startup = @import("startup");
const ui_scale = @import("ui_scale");

const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const sglue = sokol.glue;
const slog = sokol.log;

const expected_playlist_name = "Nintendo - Nintendo 64.lpl";

const Color = struct { r: u8, g: u8, b: u8 };
const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

const colors = struct {
    const background = Color{ .r = 12, .g = 5, .b = 28 };
    const panel = Color{ .r = 29, .g = 12, .b = 55 };
    const inset = Color{ .r = 14, .g = 9, .b = 27 };
    const border = Color{ .r = 91, .g = 54, .b = 129 };
    const pink = Color{ .r = 255, .g = 35, .b = 156 };
    const orange = Color{ .r = 255, .g = 122, .b = 0 };
    const yellow = Color{ .r = 255, .g = 214, .b = 0 };
    const white = Color{ .r = 242, .g = 240, .b = 248 };
    const dim = Color{ .r = 178, .g = 168, .b = 198 };
    const good = Color{ .r = 76, .g = 220, .b = 130 };
    const bad = Color{ .r = 255, .g = 90, .b = 112 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const logo_glow = Color{ .r = 116, .g = 0, .b = 70 };
};

const FixedText = struct {
    buffer: [4096]u8 = @splat(0),
    len: usize = 0,

    fn slice(self: *const FixedText) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *FixedText, value: []const u8) bool {
        if (value.len >= self.buffer.len) return false;
        self.len = value.len;
        @memcpy(self.buffer[0..self.len], value);
        self.buffer[self.len] = 0;
        return true;
    }
};

const PowerState = enum { unknown, off, on };
const SyncDestination = enum { direct_sd, usb };
const TitleSyncState = enum { ADD, KEEP, UPDATE };
const UiLibraryDiff = struct { add: usize = 0, keep: usize = 0, update: usize = 0, remove: usize = 0 };

const CardSnapshot = struct {
    root: []u8,
    has_menu_rom: bool,
    has_library: bool,
    detected_count: usize,
    library: ?sdcard.InstalledLibrary = null,

    fn deinit(self: *CardSnapshot) void {
        const allocator = std.heap.c_allocator;
        allocator.free(self.root);
        if (self.library) |*library| library.deinit(allocator);
        self.* = undefined;
    }
};

const DeviceSnapshot = struct {
    deployer_path: []u8,
    serial: []u8,
    port: []u8,
    backend: []u8,
    detected_count: usize,
    power: PowerState,
    library: ?deployer.InstalledLibrary = null,

    fn deinit(self: *DeviceSnapshot) void {
        const allocator = std.heap.c_allocator;
        allocator.free(self.deployer_path);
        allocator.free(self.serial);
        allocator.free(self.port);
        allocator.free(self.backend);
        if (self.library) |*library| library.deinit(allocator);
        self.* = undefined;
    }
};

const DiscoveryConfig = struct {
    playlist_override: FixedText,
};

const SyncConfig = struct {
    destination: SyncDestination,
    playlist_path: FixedText,
    card_root: FixedText,
    deployer_path: FixedText,
    port: FixedText,
};

const CardOutcome = struct {
    card: ?CardSnapshot = null,
    err: ?[]const u8 = null,
};

const DeviceOutcome = struct {
    device: ?DeviceSnapshot = null,
    err: ?[]const u8 = null,
};

const RefreshResult = struct {
    scan: ?importer.RetroArchScanResult = null,
    card: ?CardSnapshot = null,
    device: ?DeviceSnapshot = null,
    scan_error: ?[]const u8 = null,
    card_error: ?[]const u8 = null,
    device_error: ?[]const u8 = null,
    used_override: bool = false,
    override_target_blocked: bool = false,
};

const SyncResult = struct {
    destination: SyncDestination,
    err: ?[]const u8 = null,
    cleanup_error: ?[]const u8 = null,
};

const WorkerResult = union(enum) {
    refresh: RefreshResult,
    sync: SyncResult,
};

const state = struct {
    var threaded: std.Io.Threaded = undefined;
    var io_ready = false;
    var pass_action: sg.PassAction = .{};
    var scan: ?importer.RetroArchScanResult = null;
    var card: ?CardSnapshot = null;
    var device: ?DeviceSnapshot = null;
    var playlist_override = FixedText{};
    var source_is_override = false;
    var scan_error: ?[]const u8 = null;
    var card_error: ?[]const u8 = null;
    var device_error: ?[]const u8 = null;
    var status: [768]u8 = @splat(0);
    var status_len: usize = 0;
    var status_good = true;
    var preview_scroll: usize = 0;
    var worker: ?std.Thread = null;
    var worker_mutex: std.atomic.Mutex = .unlocked;
    var worker_busy = false;
    var worker_done = false;
    var worker_result: ?WorkerResult = null;
    var shutting_down = false;
    var preview_destination: SyncDestination = .usb;
    var startup_elapsed: f64 = 0;
};

const layout = struct {
    fn refresh(width: f32) Rect {
        return .{ .x = width - 552, .y = 50, .w = 104, .h = 38 };
    }

    fn sdSync(width: f32) Rect {
        return .{ .x = width - 436, .y = 50, .w = 190, .h = 38 };
    }

    fn usbSync(width: f32) Rect {
        return .{ .x = width - 234, .y = 50, .w = 190, .h = 38 };
    }
};

export fn init() void {
    state.threaded = std.Io.Threaded.init(std.heap.c_allocator, .{ .environ = currentProcessEnviron() });
    state.io_ready = true;
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });
    sgl.setup(.{ .max_vertices = 131_072, .max_commands = 16_384, .logger = .{ .func = slog.func } });
    sdtx.setup(.{
        .fonts = blk: {
            var fonts: [8]sdtx.FontDesc = @splat(.{});
            fonts[0] = sdtx.fontKc854();
            break :blk fonts;
        },
        .logger = .{ .func = slog.func },
    });
    state.pass_action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.047, .g = 0.020, .b = 0.110, .a = 1 } };
    setStatus(true, "Detecting RetroArch and SummerCart...", .{});
    runRefresh();
}

fn currentProcessEnviron() std.process.Environ {
    if (@import("builtin").os.tag == .windows) return .{ .block = .global };
    const c_environ = std.c.environ;
    var count: usize = 0;
    while (c_environ[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = c_environ[0..count :null] } };
}

export fn cleanup() void {
    state.shutting_down = true;
    if (state.worker) |worker| {
        worker.join();
        state.worker = null;
    }
    harvestWorker();
    clearScan();
    clearCard();
    clearDevice();
    sdtx.shutdown();
    sgl.shutdown();
    sg.shutdown();
    if (state.io_ready) state.threaded.deinit();
}

export fn frame() void {
    harvestWorker();
    state.startup_elapsed += sapp.frameDuration();
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const width = metrics.width;
    const height = metrics.height;
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.ortho(0, width, height, 0, -1, 1);
    sgl.matrixModeModelview();

    if (startup.frameAt(state.startup_elapsed).stage != .done) {
        drawStartup(width, height);
    } else {
        drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = height - 48 }, colors.panel);
        drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = 6 }, colors.pink);
        drawText(44, 50, colors.yellow, "M64 RETROARCH SYNC", .{});
        drawText(44, 78, colors.dim, "Automatic RetroArch -> SummerCart workflow", .{});

        const busy = isBusy();
        drawButton(layout.refresh(width), if (busy) colors.border else colors.orange, "REFRESH");
        drawButton(layout.sdSync(width), if (canSyncSd() and !busy) colors.yellow else colors.border, "SYNC TO SD (FAST)");
        drawButton(layout.usbSync(width), if (canSyncUsb() and !busy) colors.orange else colors.border, "SYNC OVER USB (SLOW)");

        drawRetroArchPanel(width);
        drawDestinationPanels(width);
        drawStatus();
        drawTitles(width, height);
    }

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sgl.draw();
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

fn drawStartup(width: f32, height: f32) void {
    const current = startup.frameAt(state.startup_elapsed);
    drawRect(.{ .x = 0, .y = 0, .w = width, .h = height }, colors.black);
    if (current.stage == .black) return;

    const screen_scale = @min(width / 640.0, height / 480.0);
    const scale = current.scale * screen_scale;
    const center_x = width * 0.5;
    const center_y = height * 0.46;
    const x = center_x - startup.logo_width * scale * 0.5;
    const y = center_y - startup.logo_height * scale * 0.5;

    switch (current.stage) {
        .outline => {
            drawStartupOutline(x, y, scale, scale * 1.5, colors.logo_glow);
            drawStartupOutline(x, y, scale, scale, colors.pink);
            drawLogoRuns(&startup.outer_runs, x, y, scale, 0, startup.logo_height, colors.black);
        },
        .white => drawLogoRuns(&startup.outer_runs, x, y, scale, 0, startup.logo_height, colors.white),
        .color => drawStartupLogo(x, y, scale, current.intensity),
        .black, .done => {},
    }
}

fn drawStartupOutline(x: f32, y: f32, scale: f32, offset: f32, color: Color) void {
    const directions = [_][2]f32{
        .{ -1, 0 },  .{ 1, 0 },  .{ 0, -1 }, .{ 0, 1 },
        .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 },
    };
    for (directions) |direction| {
        drawLogoRuns(&startup.outer_runs, x + direction[0] * offset, y + direction[1] * offset, scale, 0, startup.logo_height, color);
    }
}

fn drawStartupLogo(x: f32, y: f32, scale: f32, intensity: f32) void {
    drawStartupOutline(x, y, scale, scale, colors.black);
    const bands = [_]struct { top: f32, bottom: f32, edge: Color, fill: Color }{
        .{ .top = 0, .bottom = startup.logo_height * 0.44, .edge = .{ .r = 235, .g = 190, .b = 0 }, .fill = colors.yellow },
        .{ .top = startup.logo_height * 0.44, .bottom = startup.logo_height * 0.74, .edge = .{ .r = 235, .g = 104, .b = 0 }, .fill = colors.orange },
        .{ .top = startup.logo_height * 0.74, .bottom = startup.logo_height, .edge = .{ .r = 230, .g = 25, .b = 137 }, .fill = colors.pink },
    };
    for (bands) |band| {
        drawLogoRuns(&startup.outer_runs, x, y, scale, band.top, band.bottom, dimColor(band.edge, intensity));
        drawLogoRuns(&startup.inner_runs, x, y, scale, band.top, band.bottom, dimColor(band.fill, intensity));
    }
}

fn drawLogoRuns(runs: []const startup.Run, x: f32, y: f32, scale: f32, top: f32, bottom: f32, color: Color) void {
    sgl.beginQuads();
    sgl.c3b(color.r, color.g, color.b);
    for (runs) |run| {
        const run_top = @max(top, @as(f32, @floatFromInt(run.y)));
        const run_bottom = @min(bottom, @as(f32, @floatFromInt(run.y)) + 1.0);
        if (run_top >= run_bottom) continue;
        const left = x + @as(f32, @floatFromInt(run.x)) * scale;
        const right = left + @as(f32, @floatFromInt(run.width)) * scale;
        const draw_top = y + run_top * scale;
        const draw_bottom = y + run_bottom * scale;
        sgl.v2f(left, draw_top);
        sgl.v2f(right, draw_top);
        sgl.v2f(right, draw_bottom);
        sgl.v2f(left, draw_bottom);
    }
    sgl.end();
}

fn dimColor(color: Color, intensity: f32) Color {
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) * intensity)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) * intensity)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) * intensity)),
    };
}

fn drawRetroArchPanel(width: f32) void {
    const panel = Rect{ .x = 44, .y = 112, .w = width - 88, .h = 170 };
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    drawText(60, 128, colors.pink, "RETROARCH N64 LIBRARY", .{});
    if (state.scan) |scan| {
        const source = scan.source;
        const coverage = artworkCoverage(scan.preview);
        drawLabelValue(60, 156, "PLAYLIST", tail(source.playlist_path, 108), colors.white);
        drawLabelValue(60, 180, "SYSTEM", source.system_name, colors.white);
        drawText(60, 204, colors.dim, "PLAYLIST ENTRIES", .{});
        drawText(228, 204, colors.white, "{d}", .{source.playlist_entries});
        drawText(330, 204, colors.dim, "RESOLVED", .{});
        drawText(426, 204, colors.white, "{d}", .{source.resolved_entries});
        drawText(520, 204, colors.dim, "SELECTED", .{});
        drawText(616, 204, colors.yellow, "{d}/{d}", .{ scan.preview.titles.len, importer.maximum_titles });
        if (source.unsupported_entries != 0) drawText(760, 204, colors.bad, "{d} UNSUPPORTED", .{source.unsupported_entries});
        drawText(60, 232, colors.dim, "ARTWORK COVERAGE", .{});
        drawText(228, 232, if (coverage == scan.preview.titles.len) colors.good else colors.orange, "{d}/{d}", .{ coverage, scan.preview.titles.len });
        drawText(330, 232, colors.dim, "SOURCE", .{});
        if (state.source_is_override) {
            drawText(426, 232, colors.orange, "DROPPED FALLBACK", .{});
        } else {
            drawText(426, 232, colors.good, "AUTO DETECTED", .{});
        }
        drawText(60, 256, colors.dim, "Drop an .lpl file only to provide a fallback when automatic detection fails.", .{});
    } else {
        drawText(60, 164, colors.dim, "Playlist path: not detected", .{});
        drawText(60, 192, colors.dim, "System: unavailable", .{});
        drawText(60, 220, colors.dim, "Playlist entries: 0   Resolved: 0   Selected: 0/{d}", .{importer.maximum_titles});
        drawText(60, 248, colors.orange, "Drop an .lpl file to retry with its parent directory as fallback.", .{});
    }
}

fn drawDestinationPanels(width: f32) void {
    const gap: f32 = 12;
    const panel_width = (width - 88 - gap) / 2;
    drawCardPanel(.{ .x = 44, .y = 298, .w = panel_width, .h = 144 });
    drawUsbPanel(.{ .x = 44 + panel_width + gap, .y = 298, .w = panel_width, .h = 144 });
}

fn drawCardPanel(panel: Rect) void {
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    drawText(panel.x + 16, 314, colors.pink, "MOUNTED SD CARD (PREFERRED)", .{});
    if (state.card) |card| {
        drawLabelValue(panel.x + 16, 344, "ROOT", tail(card.root, 42), colors.white);
        drawText(panel.x + 16, 370, colors.dim, "MENU ROM", .{});
        drawText(panel.x + 184, 370, if (card.has_menu_rom) colors.good else colors.orange, "{s}", .{if (card.has_menu_rom) "PRESENT" else "MISSING"});
        drawText(panel.x + 16, 396, colors.dim, "INSTALLED", .{});
        if (card.library) |library| {
            drawText(panel.x + 184, 396, colors.white, "{d}", .{library.titles.len});
            drawDiff(panel.x + 16, 420, library.titles.len, libraryDiffFor(library.titles));
        } else {
            drawText(panel.x + 184, 396, colors.orange, "UNAVAILABLE", .{});
        }
        if (card.detected_count > 1) drawText(panel.x + panel.w - 146, 314, colors.orange, "USING 1 OF {d}", .{card.detected_count});
    } else {
        drawText(panel.x + 16, 346, colors.dim, "ROOT       NOT DETECTED", .{});
        drawText(panel.x + 16, 372, colors.dim, "MENU ROM   UNAVAILABLE", .{});
        drawText(panel.x + 16, 398, colors.dim, "INSTALLED  0", .{});
        drawText(panel.x + 16, 420, colors.orange, "INSERT OR MOUNT A SUMMERCART SD CARD", .{});
    }
}

fn drawUsbPanel(panel: Rect) void {
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    drawText(panel.x + 16, 314, colors.pink, "USB SUMMERCART", .{});
    if (state.device) |device| {
        drawLabelValue(panel.x + 16, 344, "SERIAL", device.serial, colors.white);
        drawLabelValue(panel.x + 16, 370, "PORT", tail(device.port, 42), colors.white);
        drawText(panel.x + 16, 396, colors.dim, "POWER", .{});
        const power_color = switch (device.power) {
            .off => colors.good,
            .on => colors.bad,
            .unknown => colors.orange,
        };
        drawText(panel.x + 184, 396, power_color, "{s}", .{powerLabel(device.power)});
        if (device.library) |library| {
            drawDiff(panel.x + 16, 420, library.titles.len, libraryDiffFor(library.titles));
        } else {
            drawText(panel.x + 16, 420, colors.orange, "INSTALLED LIBRARY UNAVAILABLE", .{});
        }
        if (device.detected_count > 1) drawText(panel.x + panel.w - 146, 314, colors.orange, "USING 1 OF {d}", .{device.detected_count});
    } else {
        drawText(panel.x + 16, 346, colors.dim, "SERIAL     NOT DETECTED", .{});
        drawText(panel.x + 16, 372, colors.dim, "PORT       UNAVAILABLE", .{});
        drawText(panel.x + 16, 398, colors.bad, "POWER      UNAVAILABLE", .{});
        drawText(panel.x + 16, 420, colors.dim, "INSTALLED  0", .{});
    }
}

fn drawDiff(x: f32, y: f32, installed: usize, diff: UiLibraryDiff) void {
    drawText(x, y, colors.dim, "{d} INST", .{installed});
    drawText(x + 80, y, colors.good, "+{d} ADD", .{diff.add});
    drawText(x + 176, y, colors.white, "{d} KEEP", .{diff.keep});
    drawText(x + 272, y, colors.orange, "{d} UPDATE", .{diff.update});
    drawText(x + 384, y, colors.bad, "-{d} HIDE", .{diff.remove});
}

fn drawTitles(width: f32, height: f32) void {
    const top: f32 = 510;
    if (height <= top + 40) return;
    drawText(44, top, colors.white, "SELECTED TITLES", .{});
    drawText(width - 360, top, colors.dim, "SYNC", .{});
    drawText(width - 282, top, colors.dim, "ARTWORK STATUS", .{});
    drawRect(.{ .x = 44, .y = top + 22, .w = width - 88, .h = 2 }, colors.border);
    if (state.scan) |scan| {
        const titles = scan.preview.titles;
        const rows = @max(@as(usize, 1), @as(usize, @intFromFloat((height - top - 48) / 24)));
        const end = @min(titles.len, state.preview_scroll + rows);
        for (titles[state.preview_scroll..end], 0..) |title, row| {
            const y = top + 36 + @as(f32, @floatFromInt(row)) * 24;
            drawText(44, y, colors.yellow, "{s}", .{title.id});
            drawText(100, y, colors.white, "{s}", .{head(title.display_name, 82)});
            const sync_state = titleSyncState(title);
            drawText(width - 360, y, syncStateColor(sync_state), "{s}", .{@tagName(sync_state)});
            drawText(width - 282, y, if (title.artwork_path == null) colors.orange else colors.good, "{s}", .{@tagName(title.artwork_status)});
        }
    } else {
        drawText(44, top + 36, colors.dim, "No resolved N64 titles.", .{});
    }
}

export fn event(event_ptr: [*c]const sapp.Event) void {
    const input = event_ptr.*;
    if (startup.frameAt(state.startup_elapsed).stage != .done) return;
    const scale = ui_scale.metrics(sapp.widthf(), sapp.heightf()).scale;
    switch (input.type) {
        .MOUSE_DOWN => if (input.mouse_button == .LEFT) handleClick(input.mouse_x / scale, input.mouse_y / scale),
        .MOUSE_SCROLL => scrollTitles(input.scroll_y),
        .KEY_DOWN => if (!input.key_repeat) switch (input.key_code) {
            .F5 => runRefresh(),
            .ENTER => runPreferredSync(),
            .ESCAPE => sapp.requestQuit(),
            else => {},
        },
        .FILES_DROPPED => handleDrop(),
        else => {},
    }
}

fn handleClick(x: f32, y: f32) void {
    if (isBusy()) return;
    const width = ui_scale.metrics(sapp.widthf(), sapp.heightf()).width;
    if (contains(layout.refresh(width), x, y)) {
        runRefresh();
    } else if (contains(layout.sdSync(width), x, y)) {
        state.preview_destination = .direct_sd;
        runSync(.direct_sd);
    } else if (contains(layout.usbSync(width), x, y)) {
        state.preview_destination = .usb;
        runSync(.usb);
    }
}

fn handleDrop() void {
    if (isBusy() or sapp.getNumDroppedFiles() <= 0) return;
    const path = sapp.getDroppedFilePath(0);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".lpl")) {
        setStatus(false, "Only a RetroArch .lpl playlist can be used as a fallback.", .{});
        return;
    }
    if (!state.playlist_override.set(path)) {
        setStatus(false, "Dropped playlist path is too long.", .{});
        return;
    }
    setStatus(true, "Saved dropped playlist fallback; refreshing automatic detection first...", .{});
    runRefresh();
}

fn scrollTitles(delta: f32) void {
    const scan = state.scan orelse return;
    if (delta < 0 and state.preview_scroll + 1 < scan.preview.titles.len) state.preview_scroll += 1;
    if (delta > 0 and state.preview_scroll > 0) state.preview_scroll -= 1;
}

fn runRefresh() void {
    if (isBusy()) return;
    const config = DiscoveryConfig{ .playlist_override = state.playlist_override };
    if (!beginWorker()) return;
    state.worker = std.Thread.spawn(.{}, refreshWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start refresh: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Detecting RetroArch and SummerCart...", .{});
}

fn runPreferredSync() void {
    if (state.card != null) {
        runSync(.direct_sd);
    } else {
        runSync(.usb);
    }
}

fn runSync(destination: SyncDestination) void {
    if (isBusy()) return;
    const scan = state.scan orelse {
        setStatus(false, "Sync refused: no RetroArch N64 playlist is ready.", .{});
        return;
    };

    var config = SyncConfig{
        .destination = destination,
        .playlist_path = .{},
        .card_root = .{},
        .deployer_path = .{},
        .port = .{},
    };
    if (!config.playlist_path.set(scan.source.playlist_path)) {
        setStatus(false, "Sync refused: a detected path exceeds the supported path length.", .{});
        return;
    }
    switch (destination) {
        .direct_sd => {
            const card = state.card orelse {
                setStatus(false, "Sync refused: no mounted SummerCart SD card is detected.", .{});
                return;
            };
            if (!config.card_root.set(card.root)) {
                setStatus(false, "Sync refused: the mounted card path is too long.", .{});
                return;
            }
        },
        .usb => {
            const device = state.device orelse {
                setStatus(false, "Sync refused: no USB SummerCart is detected.", .{});
                return;
            };
            switch (device.power) {
                .on => {
                    setStatus(false, "Sync refused: console is powered on. Power it off, then Refresh.", .{});
                    return;
                },
                .unknown => {
                    setStatus(false, "Sync refused: SummerCart power state is unknown. Refresh and retry.", .{});
                    return;
                },
                .off => {},
            }
            if (!config.deployer_path.set(device.deployer_path) or !config.port.set(device.port)) {
                setStatus(false, "Sync refused: a detected USB path exceeds the supported path length.", .{});
                return;
            }
        },
    }
    if (!beginWorker()) return;
    state.worker = std.Thread.spawn(.{}, syncWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start sync: {s}", .{@errorName(err)});
        return;
    };
    switch (destination) {
        .direct_sd => setStatus(true, "Preparing fast direct SD sync...", .{}),
        .usb => setStatus(true, "Checking SummerCart power state...", .{}),
    }
}

fn refreshWorker(config: DiscoveryConfig) void {
    const allocator = std.heap.c_allocator;
    const io = state.threaded.io();
    var result = RefreshResult{};

    result.scan = importer.scanRetroArchLibrary(allocator, io, .{ .environ = state.threaded.environ.process_environ }) catch |auto_err| fallback: {
        if (config.playlist_override.len == 0) {
            result.scan_error = @errorName(auto_err);
            break :fallback null;
        }
        const override_path = config.playlist_override.slice();
        const parent = std.fs.path.dirname(override_path) orelse {
            result.scan_error = "InvalidPlaylistPath";
            break :fallback null;
        };
        const roots = [_][]const u8{parent};
        var fallback_result = importer.scanRetroArchLibrary(allocator, io, .{
            .search_roots = &roots,
            .maximum_search_depth = 0,
            .environ = state.threaded.environ.process_environ,
        }) catch |fallback_err| {
            result.scan_error = @errorName(fallback_err);
            result.override_target_blocked = !std.ascii.eqlIgnoreCase(std.fs.path.basename(override_path), expected_playlist_name);
            break :fallback null;
        };
        if (!std.ascii.eqlIgnoreCase(fallback_result.source.playlist_path, override_path)) {
            fallback_result.deinit(allocator);
            result.scan_error = "ExactPlaylistTargetUnavailable";
            result.override_target_blocked = true;
            break :fallback null;
        }
        result.used_override = true;
        break :fallback fallback_result;
    };

    var card_outcome = discoverCard(allocator, io);
    result.card = card_outcome.card;
    result.card_error = card_outcome.err;
    card_outcome.card = null;
    var device_outcome = discoverDevice(allocator, io);
    result.device = device_outcome.device;
    result.device_error = device_outcome.err;
    device_outcome.device = null;
    finishWorker(.{ .refresh = result });
}

fn discoverCard(allocator: std.mem.Allocator, io: std.Io) CardOutcome {
    var cards = sdcard.detectCards(allocator, io) catch |err| return .{ .err = @errorName(err) };
    defer cards.deinit(allocator);
    if (cards.cards.len == 0) return .{ .err = "NoMountedCardFound" };
    if (cards.cards.len != 1) return .{ .err = "MultipleMountedCardsFound" };

    const detected = cards.cards[0];
    var snapshot = CardSnapshot{
        .root = allocator.dupe(u8, detected.root) catch return .{ .err = "OutOfMemory" },
        .has_menu_rom = detected.has_menu_rom,
        .has_library = detected.has_library,
        .detected_count = cards.cards.len,
    };
    snapshot.library = sdcard.readInstalledLibrary(allocator, io, snapshot.root) catch |err| {
        return .{ .card = snapshot, .err = @errorName(err) };
    };
    return .{ .card = snapshot };
}

fn discoverDevice(allocator: std.mem.Allocator, io: std.Io) DeviceOutcome {
    const deployer_path = deployer.locate(allocator, io, null) catch |err| return .{ .err = @errorName(err) };
    var devices = deployer.detectDevices(allocator, io, deployer_path) catch |err| {
        allocator.free(deployer_path);
        return .{ .err = @errorName(err) };
    };
    defer devices.deinit(allocator);
    if (devices.devices.len == 0) {
        allocator.free(deployer_path);
        return .{ .err = "NoSummerCartFound" };
    }

    const detected = devices.devices[0];
    var snapshot = DeviceSnapshot{
        .deployer_path = deployer_path,
        .serial = allocator.dupe(u8, detected.serial) catch {
            allocator.free(deployer_path);
            return .{ .err = "OutOfMemory" };
        },
        .port = undefined,
        .backend = undefined,
        .detected_count = devices.devices.len,
        .power = .unknown,
    };
    snapshot.port = allocator.dupe(u8, detected.port) catch {
        allocator.free(snapshot.deployer_path);
        allocator.free(snapshot.serial);
        return .{ .err = "OutOfMemory" };
    };
    snapshot.backend = allocator.dupe(u8, detected.backend) catch {
        allocator.free(snapshot.deployer_path);
        allocator.free(snapshot.serial);
        allocator.free(snapshot.port);
        return .{ .err = "OutOfMemory" };
    };

    var info = deployer.probeDevice(allocator, io, snapshot.deployer_path, snapshot.port) catch |err| {
        return .{ .device = snapshot, .err = @errorName(err) };
    };
    defer info.deinit(allocator);
    snapshot.power = if (info.console_powered_on) .on else .off;
    if (snapshot.power == .off) {
        var cleanup_error: ?anyerror = null;
        snapshot.library = deployer.readInstalledLibraryOptions(allocator, io, snapshot.deployer_path, snapshot.port, .{
            .cleanup_error = &cleanup_error,
            .environ = state.threaded.environ.process_environ,
        }) catch |err| {
            return .{ .device = snapshot, .err = @errorName(err) };
        };
        if (cleanup_error) |err| return .{ .device = snapshot, .err = @errorName(err) };
    }
    return .{ .device = snapshot };
}

fn syncWorker(config: SyncConfig) void {
    const allocator = std.heap.c_allocator;
    const io = state.threaded.io();
    var result = SyncResult{ .destination = config.destination };

    if (config.destination == .usb) {
        var info = deployer.probeDevice(allocator, io, config.deployer_path.slice(), config.port.slice()) catch |err| {
            result.err = @errorName(err);
            finishWorker(.{ .sync = result });
            return;
        };
        const powered_on = info.console_powered_on;
        info.deinit(allocator);
        if (powered_on) {
            result.err = "ConsolePoweredOn";
            finishWorker(.{ .sync = result });
            return;
        }
    }

    const staging = createStagingDirectory(allocator, io) catch |err| {
        result.err = @errorName(err);
        finishWorker(.{ .sync = result });
        return;
    };
    defer allocator.free(staging);

    const operation = syncFromStaging(allocator, io, staging, &config);
    if (operation) |_| {} else |err| result.err = @errorName(err);
    std.Io.Dir.cwd().deleteTree(io, staging) catch |err| {
        result.cleanup_error = @errorName(err);
    };
    finishWorker(.{ .sync = result });
}

fn syncFromStaging(
    allocator: std.mem.Allocator,
    io: std.Io,
    staging: []const u8,
    config: *const SyncConfig,
) !void {
    const playlist_path = config.playlist_path.slice();
    const parent = std.fs.path.dirname(playlist_path) orelse return error.InvalidPlaylistPath;
    const roots = [_][]const u8{parent};
    var imported = try importer.importRetroArchLibrary(allocator, io, staging, .{
        .search_roots = &roots,
        .maximum_search_depth = 0,
        .environ = state.threaded.environ.process_environ,
    }, .{ .context = null, .callback = importProgress });
    defer imported.deinit(allocator);
    if (!std.ascii.eqlIgnoreCase(imported.source.playlist_path, playlist_path)) return error.PlaylistChanged;

    const menu_rom = (try findMenuRom(allocator, io)) orelse return error.Sc64MenuNotFound;
    defer allocator.free(menu_rom);
    const staged_rom = try std.fs.path.join(allocator, &.{ staging, "sc64menu.n64" });
    defer allocator.free(staged_rom);
    try std.Io.Dir.copyFileAbsolute(menu_rom, staged_rom, io, .{});
    switch (config.destination) {
        .direct_sd => {
            setStatus(true, "Staging complete; copying directly to mounted SD...", .{});
            try sdcard.syncFromStaging(allocator, io, staging, config.card_root.slice(), .{
                .context = null,
                .callback = sdProgress,
            });
        },
        .usb => {
            setStatus(true, "Staging complete; syncing over USB...", .{});
            try deployer.sync(allocator, io, .{
                .deployer_path = config.deployer_path.slice(),
                .port = config.port.slice(),
                .staging_root = staging,
            }, .{ .context = null, .callback = deployProgress });
        },
    }
}

fn findMenuRom(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const candidates = [_][]const []const u8{
        &.{ executable_dir, "sc64menu.n64" },
        &.{ executable_dir, "..", "..", "..", "..", "sc64menu.n64" },
        &.{"sc64menu.n64"},
    };
    for (candidates) |parts| {
        const path = try std.fs.path.join(allocator, parts);
        if (fileExists(io, path)) return path;
        allocator.free(path);
    }
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn createStagingDirectory(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const temp_root = std.process.Environ.getAlloc(environ, allocator, "TMPDIR") catch
        std.process.Environ.getAlloc(environ, allocator, "TEMP") catch
        std.process.Environ.getAlloc(environ, allocator, "TMP") catch
        try allocator.dupe(u8, if (@import("builtin").os.tag == .windows) "." else "/tmp");
    defer allocator.free(temp_root);

    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random: [12]u8 = undefined;
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(allocator, "m64importer-{s}", .{suffix});
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ temp_root, name });
        std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
    return error.UnableToCreateStagingDirectory;
}

fn importProgress(_: ?*anyopaque, progress_event: importer.ProgressEvent) void {
    setStatus(true, "Staging {d}/{d}: {s}", .{ progress_event.completed, progress_event.total, progress_event.title.display_name });
}

fn deployProgress(_: ?*anyopaque, progress_event: deployer.ProgressEvent) void {
    setStatus(true, "Syncing {d}/{d}: {s}", .{ progress_event.current, progress_event.total, progress_event.path });
}

fn sdProgress(_: ?*anyopaque, progress_event: sdcard.ProgressEvent) void {
    setStatus(true, "Copying {d}/{d}: {s}", .{ progress_event.current, progress_event.total, progress_event.path });
}

fn beginWorker() bool {
    lockWorker();
    defer unlockWorker();
    if (state.worker_busy) return false;
    state.worker_busy = true;
    state.worker_done = false;
    state.worker_result = null;
    return true;
}

fn cancelWorker() void {
    lockWorker();
    defer unlockWorker();
    state.worker_busy = false;
    state.worker_done = false;
}

fn finishWorker(result: WorkerResult) void {
    lockWorker();
    defer unlockWorker();
    state.worker_result = result;
    state.worker_done = true;
}

fn harvestWorker() void {
    lockWorker();
    if (!state.worker_done) {
        unlockWorker();
        return;
    }
    var result = state.worker_result.?;
    state.worker_result = null;
    state.worker_done = false;
    state.worker_busy = false;
    const worker = state.worker;
    state.worker = null;
    unlockWorker();

    if (worker) |thread| thread.join();
    switch (result) {
        .refresh => |*refresh| harvestRefresh(refresh),
        .sync => |sync_result| harvestSync(sync_result),
    }
}

fn harvestRefresh(result: *RefreshResult) void {
    clearScan();
    clearCard();
    clearDevice();
    state.scan = result.scan;
    result.scan = null;
    state.card = result.card;
    result.card = null;
    state.device = result.device;
    result.device = null;
    state.scan_error = result.scan_error;
    state.card_error = result.card_error;
    state.device_error = result.device_error;
    state.source_is_override = result.used_override;
    state.preview_scroll = 0;
    state.preview_destination = if (state.card != null) .direct_sd else .usb;

    if (result.override_target_blocked) {
        setStatus(false, "Playlist fallback failed: core can only target {s}; exact arbitrary .lpl targeting is unavailable.", .{expected_playlist_name});
    } else if (state.scan == null) {
        setStatus(false, "RetroArch detection failed: {s}. SD: {s}; USB: {s}.", .{ state.scan_error orelse "UnknownError", cardSummary(), deviceSummary() });
    } else if (state.card != null) {
        if (state.card_error) |name| {
            setStatus(false, "Mounted SD detected, but its installed library could not be read: {s}.", .{name});
        } else {
            setStatus(true, "Ready for fast direct SD sync of {d} title(s).", .{state.scan.?.preview.titles.len});
        }
    } else if (state.device == null) {
        setStatus(false, "RetroArch library ready; no mounted SD or USB SummerCart detected.", .{});
    } else if (state.device.?.power == .on) {
        setStatus(false, "USB SummerCart detected, but sync is blocked while the console is powered on.", .{});
    } else if (state.device.?.power == .unknown) {
        setStatus(false, "USB SummerCart detected, but power probe failed: {s}.", .{state.device_error orelse "UnknownError"});
    } else if (state.device_error != null) {
        setStatus(false, "USB is available, but its installed library could not be read: {s}.", .{state.device_error.?});
    } else {
        setStatus(true, "Ready to sync {d} title(s) over USB.", .{state.scan.?.preview.titles.len});
    }
}

fn harvestSync(result: SyncResult) void {
    const destination = switch (result.destination) {
        .direct_sd => "Direct SD sync",
        .usb => "USB sync",
    };
    if (result.err) |name| {
        if (std.mem.eql(u8, name, "ConsolePoweredOn")) {
            if (state.device) |*device| device.power = .on;
            setStatus(false, "USB sync refused: console is powered on.", .{});
        } else if (result.cleanup_error) |cleanup_name| {
            setStatus(false, "{s} failed: {s}; staging cleanup also failed: {s}.", .{ destination, name, cleanup_name });
        } else {
            setStatus(false, "{s} failed: {s}.", .{ destination, name });
        }
    } else if (result.cleanup_error) |name| {
        setStatus(false, "{s} completed, but private staging cleanup failed: {s}.", .{ destination, name });
    } else {
        if (!state.shutting_down) {
            setStatus(true, "{s} completed; refreshing installed libraries...", .{destination});
            runRefresh();
        }
    }
}

fn cardSummary() []const u8 {
    if (state.card) |card| return card.root;
    return state.card_error orelse "not detected";
}

fn deviceSummary() []const u8 {
    if (state.device) |device| return powerLabel(device.power);
    return state.device_error orelse "not detected";
}

fn canSyncSd() bool {
    return state.scan != null and state.card != null;
}

fn canSyncUsb() bool {
    return state.scan != null and state.device != null and state.device.?.power == .off;
}

fn titleSyncState(title: importer.Title) TitleSyncState {
    switch (state.preview_destination) {
        .direct_sd => if (state.card) |card| {
            if (card.library) |library| return titleSyncStateFor(title, library.titles);
        },
        .usb => if (state.device) |device| {
            if (device.library) |library| return titleSyncStateFor(title, library.titles);
        },
    }
    return .ADD;
}

fn titleSyncStateFor(title: importer.Title, installed_titles: anytype) TitleSyncState {
    for (installed_titles) |installed| {
        if (!std.mem.eql(u8, &installed.id, &title.id)) continue;
        // Legacy libraries did not have name sidecars, so the deployer falls back
        // to the ID. Matching IDs still mean the ROM is already installed.
        if (std.mem.eql(u8, installed.name, &installed.id) or asciiNameEqual(installed.name, title.display_name)) return .KEEP;
        return .UPDATE;
    }
    return .ADD;
}

fn libraryDiffFor(installed_titles: anytype) UiLibraryDiff {
    var result = UiLibraryDiff{};
    const scan = state.scan orelse return result;
    for (scan.preview.titles) |title| switch (titleSyncStateFor(title, installed_titles)) {
        .ADD => result.add += 1,
        .KEEP => result.keep += 1,
        .UPDATE => result.update += 1,
    };
    for (installed_titles) |installed| {
        var found = false;
        for (scan.preview.titles) |title| if (std.mem.eql(u8, &installed.id, &title.id)) {
            found = true;
            break;
        };
        if (!found) result.remove += 1;
    }
    return result;
}

fn asciiNameEqual(installed: []const u8, desired: []const u8) bool {
    if (installed.len != desired.len) return false;
    for (desired, installed) |source, actual| {
        if (actual != if (source < 0x80) source else '?') return false;
    }
    return true;
}

fn syncStateColor(sync_state: TitleSyncState) Color {
    return switch (sync_state) {
        .ADD => colors.good,
        .KEEP => colors.dim,
        .UPDATE => colors.orange,
    };
}

fn powerLabel(power: PowerState) []const u8 {
    return switch (power) {
        .unknown => "UNKNOWN (SYNC BLOCKED)",
        .off => "OFF (SAFE TO SYNC)",
        .on => "ON (SYNC BLOCKED)",
    };
}

fn artworkCoverage(scan: importer.ScanResult) usize {
    var count: usize = 0;
    for (scan.titles) |title| if (title.artwork_path != null) {
        count += 1;
    };
    return count;
}

fn clearScan() void {
    if (state.scan) |*scan| scan.deinit(std.heap.c_allocator);
    state.scan = null;
}

fn clearCard() void {
    if (state.card) |*card| card.deinit();
    state.card = null;
}

fn clearDevice() void {
    if (state.device) |*device| device.deinit();
    state.device = null;
}

fn lockWorker() void {
    while (!state.worker_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlockWorker() void {
    state.worker_mutex.unlock();
}

fn isBusy() bool {
    lockWorker();
    defer unlockWorker();
    return state.worker_busy;
}

fn setStatus(good: bool, comptime format: []const u8, args: anytype) void {
    lockWorker();
    defer unlockWorker();
    state.status_good = good;
    const rendered = std.fmt.bufPrint(&state.status, format, args) catch "Status message too long";
    state.status_len = rendered.len;
}

fn drawStatus() void {
    lockWorker();
    defer unlockWorker();
    drawText(44, 470, if (state.status_good) colors.good else colors.bad, "{s}", .{state.status[0..state.status_len]});
}

fn drawLabelValue(x: f32, y: f32, label: []const u8, value: []const u8, value_color: Color) void {
    drawText(x, y, colors.dim, "{s}", .{label});
    drawText(x + 168, y, value_color, "{s}", .{value});
}

fn tail(value: []const u8, maximum: usize) []const u8 {
    return if (value.len > maximum) value[value.len - maximum ..] else value;
}

fn head(value: []const u8, maximum: usize) []const u8 {
    return value[0..@min(value.len, maximum)];
}

fn drawRect(rect: Rect, color: Color) void {
    sgl.beginQuads();
    sgl.c3b(color.r, color.g, color.b);
    sgl.v2f(rect.x, rect.y);
    sgl.v2f(rect.x + rect.w, rect.y);
    sgl.v2f(rect.x + rect.w, rect.y + rect.h);
    sgl.v2f(rect.x, rect.y + rect.h);
    sgl.end();
}

fn drawOutline(rect: Rect, color: Color, thickness: f32) void {
    drawRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = thickness }, color);
    drawRect(.{ .x = rect.x, .y = rect.y + rect.h - thickness, .w = rect.w, .h = thickness }, color);
    drawRect(.{ .x = rect.x, .y = rect.y, .w = thickness, .h = rect.h }, color);
    drawRect(.{ .x = rect.x + rect.w - thickness, .y = rect.y, .w = thickness, .h = rect.h }, color);
}

fn drawButton(rect: Rect, color: Color, label: []const u8) void {
    drawRect(rect, color);
    drawText(rect.x + 12, rect.y + 11, colors.background, "{s}", .{label});
}

fn drawText(x: f32, y: f32, color: Color, comptime format: []const u8, args: anytype) void {
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    sdtx.canvas(metrics.width, metrics.height);
    sdtx.font(0);
    sdtx.color3b(color.r, color.g, color.b);
    sdtx.pos(x / 8.0, y / 8.0);
    sdtx.print(format, args);
}

fn contains(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 1120,
        .height = 820,
        .sample_count = 4,
        .high_dpi = true,
        .enable_dragndrop = true,
        .max_dropped_files = 1,
        .max_dropped_file_path_length = 4096,
        .icon = .{ .sokol_default = true },
        .window_title = "m64menu RetroArch Sync",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
