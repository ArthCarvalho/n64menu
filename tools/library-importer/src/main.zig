const std = @import("std");
const sokol = @import("sokol");
const importer = @import("importer");
const deployer = @import("deployer");
const grid = @import("grid");
const icon = @import("icon.zig");
const launchbox = @import("launchbox");
const registry = @import("registry");
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
const SourceKind = enum { automatic, playlist, directory };
const DropMode = enum { games, registry };
const TitleSyncState = enum { ADD, KEEP, UPDATE };
const UiLibraryDiff = struct { add: usize = 0, keep: usize = 0, update: usize = 0, remove: usize = 0 };

const page_layout = struct {
    const workflow_y: f32 = 142;
    const workflow_height: f32 = 72;
    const status_y: f32 = 226;
    const library_top: f32 = 252;
    const grid_y: f32 = library_top + 38;
    const detail_x: f32 = 616;
    const detail_content_x: f32 = detail_x + 16;
    const mod_first_y: f32 = grid_y + 118;
    const mod_row_height: f32 = 18;
    const mod_button_y: f32 = grid_y + 166;
    const artwork_button_y: f32 = grid_y + 136;
};

const ArtworkTexture = struct {
    title_index: usize = std.math.maxInt(usize),
    failed: bool = false,
    image: sg.Image = .{},
    view: sg.View = .{},
    width: f32 = 0,
    height: f32 = 0,
};

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

const DirectoryScanResult = struct {
    root: []u8,
    preview: importer.ScanResult,

    fn deinit(self: *DirectoryScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.preview.deinit(allocator);
        self.* = undefined;
    }
};

const LibraryScan = union(enum) {
    retroarch: importer.RetroArchScanResult,
    directory: DirectoryScanResult,

    fn deinit(self: *LibraryScan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .retroarch => |*scan| scan.deinit(allocator),
            .directory => |*scan| scan.deinit(allocator),
        }
        self.* = undefined;
    }

    fn preview(self: *const LibraryScan) *const importer.ScanResult {
        return switch (self.*) {
            .retroarch => |*scan| &scan.preview,
            .directory => |*scan| &scan.preview,
        };
    }

    fn sourcePath(self: *const LibraryScan) []const u8 {
        return switch (self.*) {
            .retroarch => |scan| scan.source.playlist_path,
            .directory => |scan| scan.root,
        };
    }
};

const DiscoveryConfig = struct {
    source_kind: SourceKind,
    source_path: FixedText,
};

const SyncConfig = struct {
    destination: SyncDestination,
    source_kind: SourceKind,
    source_path: FixedText,
    source_fingerprint: [32]u8,
    card_root: FixedText,
    deployer_path: FixedText,
    port: FixedText,
};

const ModDownloadConfig = struct {
    registry_index: usize,
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
    scan: ?LibraryScan = null,
    card: ?CardSnapshot = null,
    device: ?DeviceSnapshot = null,
    scan_error: ?[]const u8 = null,
    card_error: ?[]const u8 = null,
    device_error: ?[]const u8 = null,
    source_kind: SourceKind = .automatic,
    override_target_blocked: bool = false,
};

const SyncResult = struct {
    destination: SyncDestination,
    err: ?[]const u8 = null,
    cleanup_error: ?[]const u8 = null,
};

const ModDownloadResult = struct {
    registry_index: usize,
    path: ?[]u8 = null,
    err: ?[]const u8 = null,
};

const WorkerResult = union(enum) {
    refresh: RefreshResult,
    sync: SyncResult,
    mod_download: ModDownloadResult,
};

const state = struct {
    var threaded: std.Io.Threaded = undefined;
    var io_ready = false;
    var pass_action: sg.PassAction = .{};
    var artwork_sampler: sg.Sampler = .{};
    var artwork_textures: [16]ArtworkTexture = @splat(.{});
    var mod_registry: ?registry.Registry = null;
    var registry_is_demo = true;
    var drop_mode: DropMode = .games;
    var selected_mod: usize = 0;
    var scan: ?LibraryScan = null;
    var card: ?CardSnapshot = null;
    var device: ?DeviceSnapshot = null;
    var dropped_source_kind: SourceKind = .automatic;
    var dropped_source_path = FixedText{};
    var active_source_kind: SourceKind = .automatic;
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

    fn addGames() Rect {
        return .{ .x = 188, .y = page_layout.workflow_y + 34, .w = 104, .h = 24 };
    }

    fn loadCatalog(width: f32) Rect {
        const panel_width = width - 88;
        const column_width = (panel_width - 32 - 12 * 3) / 4;
        const catalog_x = 60 + column_width + 12;
        return .{ .x = catalog_x + 112, .y = page_layout.workflow_y + 34, .w = 120, .h = 24 };
    }
};

export fn init() void {
    state.threaded = std.Io.Threaded.init(std.heap.c_allocator, .{ .environ = currentProcessEnviron() });
    state.io_ready = true;
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = slog.func } });
    sgl.setup(.{ .max_vertices = 131_072, .max_commands = 16_384, .logger = .{ .func = slog.func } });
    state.artwork_sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
        .label = "importer-artwork-sampler",
    });
    state.mod_registry = registry.parse(std.heap.c_allocator, registry.bundled_registry) catch null;
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
    clearArtworkTextures();
    if (state.artwork_sampler.id != sg.invalid_id) sg.destroySampler(state.artwork_sampler);
    clearScan();
    clearCard();
    clearDevice();
    if (state.mod_registry) |*catalog| catalog.deinit();
    state.mod_registry = null;
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
        drawSynthwaveBackground(width, height);
        drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = 104 }, colors.panel);
        drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = 6 }, colors.pink);
        drawText(44, 50, colors.yellow, "M64 RETROARCH SYNC", .{});
        drawText(44, 78, colors.dim, "Automatic RetroArch -> SummerCart workflow", .{});

        const busy = isBusy();
        drawButton(layout.refresh(width), if (busy) colors.border else colors.orange, "REFRESH");
        drawButton(layout.sdSync(width), if (canSyncSd() and !busy) colors.yellow else colors.border, "SYNC TO SD (FAST)");
        drawButton(layout.usbSync(width), if (canSyncUsb() and !busy) colors.orange else colors.border, "SYNC OVER USB (SLOW)");

        drawWorkflowStrip(width);
        drawStatus();
        drawTitles(width, height);
    }

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sgl.draw();
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

fn drawSynthwaveBackground(width: f32, height: f32) void {
    const bands: usize = 32;
    const top = Color{ .r = 16, .g = 6, .b = 38 };
    const bottom = Color{ .r = 68, .g = 18, .b = 86 };
    for (0..bands) |index| {
        const t = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(bands - 1));
        const y0 = height * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(bands));
        const y1 = height * @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(bands));
        drawRect(.{ .x = 0, .y = y0, .w = width, .h = y1 - y0 }, .{
            .r = @intFromFloat(@round(@as(f32, @floatFromInt(top.r)) + @as(f32, @floatFromInt(bottom.r - top.r)) * t)),
            .g = @intFromFloat(@round(@as(f32, @floatFromInt(top.g)) + @as(f32, @floatFromInt(bottom.g - top.g)) * t)),
            .b = @intFromFloat(@round(@as(f32, @floatFromInt(top.b)) + @as(f32, @floatFromInt(bottom.b - top.b)) * t)),
        });
    }
    const bar_height: f32 = 80;
    const margin: f32 = 40;
    const span = height + bar_height + margin;
    const travel = @mod(@as(f32, @floatCast(state.startup_elapsed * 60.0)), span);
    const bar_y = height + margin - travel;
    for (0..16) |index| {
        const half: usize = 8;
        const distance = if (index < half) index else 15 - index;
        const alpha = (@as(f32, @floatFromInt(distance)) * 56.0 / @as(f32, @floatFromInt(half))) / 255.0;
        if (alpha <= 0) continue;
        const y = bar_y + @as(f32, @floatFromInt(index)) * 5;
        if (y + 5 <= 0 or y >= height) continue;
        const t = std.math.clamp((y + 2.5) / height, 0, 1);
        const base_r = 16.0 + 52.0 * t;
        const base_g = 6.0 + 12.0 * t;
        const base_b = 38.0 + 48.0 * t;
        drawRect(.{ .x = 0, .y = @max(0, y), .w = width, .h = @min(height, y + 5) - @max(0, y) }, .{
            .r = @intFromFloat(@round(base_r + (168.0 - base_r) * alpha)),
            .g = @intFromFloat(@round(base_g + (132.0 - base_g) * alpha)),
            .b = @intFromFloat(@round(base_b + (220.0 - base_b) * alpha)),
        });
    }
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

fn drawWorkflowStrip(width: f32) void {
    const panel = Rect{ .x = 44, .y = page_layout.workflow_y, .w = width - 88, .h = page_layout.workflow_height };
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    const gap: f32 = 12;
    const column_width = (panel.w - 32 - gap * 3) / 4;
    const library_x = panel.x + 16;
    const catalog_x = library_x + column_width + gap;
    const sd_x = catalog_x + column_width + gap;
    const usb_x = sd_x + column_width + gap;
    drawCompactLibrary(library_x, panel.y + 14);
    drawCompactCatalog(catalog_x, panel.y + 14);
    drawCompactSd(sd_x, panel.y + 14);
    drawCompactUsb(usb_x, panel.y + 14);
}

fn drawCompactLibrary(x: f32, y: f32) void {
    drawText(x, y, colors.pink, "GAME LIBRARY", .{});
    if (state.scan) |scan| {
        const preview = scan.preview();
        const coverage = artworkCoverage(preview.*);
        drawText(x, y + 28, colors.white, "{d} GAMES", .{preview.titles.len});
        drawText(x + 72, y + 28, if (coverage == preview.titles.len) colors.good else colors.orange, "{d} ART", .{coverage});
    } else {
        drawText(x, y + 28, colors.dim, "LOOKING FOR GAMES...", .{});
    }
    drawButton(layout.addGames(), if (state.drop_mode == .games) colors.orange else colors.border, "ADD GAMES");
}

fn drawCompactCatalog(x: f32, y: f32) void {
    drawText(x, y, colors.pink, "MOD CATALOG", .{});
    if (state.mod_registry) |*catalog| {
        drawText(x, y + 28, if (state.registry_is_demo) colors.orange else colors.good, "{d} {s}", .{ catalog.entries().len, if (state.registry_is_demo) "DEMO" else "LOADED" });
    } else {
        drawText(x, y + 28, colors.dim, "NOT LOADED", .{});
    }
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    drawButton(layout.loadCatalog(metrics.width), if (state.drop_mode == .registry) colors.orange else colors.border, "LOAD CATALOG");
}

fn drawCompactSd(x: f32, y: f32) void {
    drawText(x, y, colors.pink, "SD CARD", .{});
    if (state.card) |card| {
        drawText(x, y + 28, colors.good, "READY", .{});
        if (card.library) |library| drawCompactDiff(x + 72, y + 28, libraryDiffFor(library.titles));
    } else {
        drawText(x, y + 28, colors.dim, "NOT CONNECTED", .{});
    }
}

fn drawCompactUsb(x: f32, y: f32) void {
    drawText(x, y, colors.pink, "USB CART", .{});
    if (state.device) |device| {
        const color = switch (device.power) {
            .off => colors.good,
            .on => colors.bad,
            .unknown => colors.orange,
        };
        drawText(x, y + 28, color, "{s}", .{switch (device.power) {
            .off => "READY",
            .on => "POWER OFF CONSOLE",
            .unknown => "CHECK CONNECTION",
        }});
        if (device.power == .off) if (device.library) |library| drawCompactDiff(x + 72, y + 28, libraryDiffFor(library.titles));
    } else {
        drawText(x, y + 28, colors.dim, "NOT CONNECTED", .{});
    }
}

fn drawCompactDiff(x: f32, y: f32, diff: UiLibraryDiff) void {
    var offset: f32 = 0;
    if (diff.add != 0) {
        drawText(x + offset, y, colors.good, "+{d} ADD", .{diff.add});
        offset += 88;
    }
    if (diff.update != 0) {
        drawText(x + offset, y, colors.orange, "{d} UPDATE", .{diff.update});
        offset += 104;
    }
    if (diff.remove != 0) {
        drawText(x + offset, y, colors.bad, "-{d} REMOVE", .{diff.remove});
        offset += 104;
    }
    if (offset == 0) drawText(x, y, colors.dim, "NO CHANGES", .{});
}

fn drawTitles(width: f32, height: f32) void {
    const top: f32 = page_layout.library_top;
    const bottom_margin: f32 = 36;
    if (height <= top + 100) return;
    drawText(44, top, colors.white, "LIBRARY", .{});
    drawRect(.{ .x = 44, .y = top + 22, .w = width - 88, .h = 2 }, colors.border);
    const scan = state.scan orelse {
        drawText(44, top + 42, colors.dim, "No resolved N64 titles.", .{});
        return;
    };
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    state.preview_scroll = @min(state.preview_scroll, titles.len - 1);

    const area_x: f32 = 44;
    const area_y = page_layout.grid_y;
    const area_width: f32 = @min(544, width - 88);
    const area_height = height - area_y - bottom_margin;
    const metrics = grid.layout(area_width, area_height);
    const first_row = grid.firstVisibleRow(state.preview_scroll, titles.len, metrics.visible_rows);
    const first_index = first_row * grid.columns;
    const end_index = @min(titles.len, (first_row + metrics.visible_rows) * grid.columns);
    syncArtworkTextures(titles, first_index, end_index);

    for (titles[first_index..end_index], first_index..) |_, index| {
        if (index == state.preview_scroll) continue;
        const card = fromGridRect(grid.cardRect(area_x, area_y, metrics, first_row, index));
        drawCover(card, textureForTitle(index), titles[index].display_name, false);
    }
    const selected_index = state.preview_scroll;
    if (selected_index >= first_index and selected_index < end_index) {
        const title = titles[selected_index];
        var card = fromGridRect(grid.cardRect(area_x, area_y, metrics, first_row, selected_index));
        const growth = @min(8.0, metrics.card_height * 0.1);
        const scale = (metrics.card_height + growth) / metrics.card_height;
        const grown_width = metrics.card_width * scale;
        card.x -= (grown_width - card.w) * 0.5;
        card.y -= growth * 0.5;
        card.w = grown_width;
        card.h += growth;
        drawCover(card, textureForTitle(selected_index), title.display_name, true);
    }

    drawSelectedTitle(width, area_y, titles[state.preview_scroll]);
}

fn drawSelectedTitle(width: f32, top: f32, title: importer.Title) void {
    const mod_count = compatibleModCount(title);
    const panel_height: f32 = if (mod_count != 0) 208 else if (title.artwork_path == null) 174 else 112;
    const panel = Rect{ .x = page_layout.detail_x, .y = top, .w = @min(392, @max(0, width - 660)), .h = panel_height };
    if (panel.w < 180) return;
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    drawText(panel.x + 16, panel.y + 18, colors.pink, "SELECTED GAME", .{});
    drawText(panel.x + 16, panel.y + 48, if (title.artwork_path == null) colors.orange else colors.white, "{s}", .{head(title.display_name, 46)});
    const sync_state = titleSyncState(title);
    drawText(panel.x + 16, panel.y + 76, syncStateColor(sync_state), "{s}", .{syncStateDescription(sync_state)});
    drawCompatibleMods(panel, title, mod_count);
    if (title.artwork_path == null and mod_count == 0) {
        drawText(panel.x + 16, panel.y + 102, colors.orange, "ARTWORK NEEDED", .{});
        drawButton(.{ .x = panel.x + 16, .y = panel.y + 136, .w = 168, .h = 26 }, colors.yellow, "FIND ARTWORK");
    }
}

fn compatibleModCount(title: importer.Title) usize {
    const catalog = if (state.mod_registry) |*value| value else return 0;
    var matches: [8]usize = undefined;
    return registry.matching(catalog, title.content_crc32, &title.content_hash, &matches);
}

fn drawCompatibleMods(panel: Rect, title: importer.Title, count: usize) void {
    const catalog = if (state.mod_registry) |*value| value else return;
    var matches: [8]usize = undefined;
    _ = registry.matching(catalog, title.content_crc32, &title.content_hash, &matches);
    if (count == 0) return;
    state.selected_mod = @min(state.selected_mod, @min(count, matches.len) - 1);
    drawText(panel.x + 16, panel.y + 96, colors.pink, "DEMO MOD CATALOG", .{});
    const shown = @min(count, @min(matches.len, 3));
    for (0..shown) |row| {
        const entry = catalog.entries()[matches[row]];
        drawText(panel.x + 16, panel.y + 118 + @as(f32, @floatFromInt(row)) * 18, if (row == state.selected_mod) colors.yellow else colors.white, "{s} {s}", .{ head(entry.name, 28), entry.version });
    }
    const selected = catalog.entries()[matches[state.selected_mod]];
    const cached = isModCached(selected);
    drawButton(.{ .x = panel.x + 16, .y = panel.y + 166, .w = 168, .h = 26 }, if (cached) colors.good else colors.yellow, if (cached) "READY FOR SYNC" else if (selected.patch.archiveMember == null) "DOWNLOAD PATCH" else "DOWNLOAD ARCHIVE");
}

fn isModCached(entry: registry.Entry) bool {
    const cache = registryCachePath(std.heap.c_allocator) catch return false;
    defer std.heap.c_allocator.free(cache);
    const path = registry.cachedArtifactPath(std.heap.c_allocator, entry, cache) catch return false;
    defer std.heap.c_allocator.free(path);
    return registry.cachedArtifactExists(state.threaded.io(), path, entry);
}

fn drawCover(rect: Rect, texture: ?*const ArtworkTexture, display_name: []const u8, selected: bool) void {
    drawRect(rect, colors.background);
    if (texture) |artwork| {
        const scale = @min(rect.w / artwork.width, rect.h / artwork.height);
        const width = artwork.width * scale;
        const height = artwork.height * scale;
        const x = rect.x + (rect.w - width) * 0.5;
        const y = rect.y + (rect.h - height) * 0.5;
        const brightness: u8 = if (selected) 255 else 102;
        sgl.enableTexture();
        sgl.texture(artwork.view, state.artwork_sampler);
        sgl.beginQuads();
        sgl.v2fT2fC3b(x, y, 0, 0, brightness, brightness, brightness);
        sgl.v2fT2fC3b(x + width, y, 1, 0, brightness, brightness, brightness);
        sgl.v2fT2fC3b(x + width, y + height, 1, 1, brightness, brightness, brightness);
        sgl.v2fT2fC3b(x, y + height, 0, 1, brightness, brightness, brightness);
        sgl.end();
        sgl.disableTexture();
    } else {
        drawRect(rect, colors.inset);
        drawCoverName(rect, display_name);
    }
    if (selected) {
        drawOutline(.{ .x = rect.x - 3, .y = rect.y - 3, .w = rect.w + 6, .h = rect.h + 6 }, colors.yellow, 2);
        drawMarker(rect.x - 17, rect.y + rect.h * 0.5 - 6, 11, colors.yellow);
    }
}

fn drawCoverName(rect: Rect, display_name: []const u8) void {
    const maximum = @max(@as(usize, 8), @as(usize, @intFromFloat((rect.w - 20) / 8)));
    var offset: usize = 0;
    var lines: [3][]const u8 = @splat("");
    var count: usize = 0;
    while (offset < display_name.len and count < lines.len) : (count += 1) {
        const remaining = display_name[offset..];
        var length = @min(maximum, remaining.len);
        if (length < remaining.len) {
            if (std.mem.lastIndexOfScalar(u8, remaining[0..length], ' ')) |space| {
                if (space != 0) length = space;
            }
        }
        lines[count] = remaining[0..length];
        offset += length;
        while (offset < display_name.len and display_name[offset] == ' ') offset += 1;
    }
    const visible_count = @min(count, lines.len);
    const first_y = rect.y + (rect.h - @as(f32, @floatFromInt(visible_count)) * 16) * 0.5 + 4;
    for (lines[0..visible_count], 0..) |line, index| {
        const width = @as(f32, @floatFromInt(line.len * 8));
        drawText(rect.x + (rect.w - width) * 0.5, first_y + @as(f32, @floatFromInt(index)) * 16, colors.orange, "{s}", .{line});
    }
}

fn syncArtworkTextures(titles: []const importer.Title, first: usize, end: usize) void {
    for (&state.artwork_textures) |*texture| {
        if (texture.title_index == std.math.maxInt(usize)) continue;
        if (texture.title_index < first or texture.title_index >= end or titles[texture.title_index].artwork_path == null) destroyArtworkTexture(texture);
    }
    for (first..end) |index| {
        const path = titles[index].artwork_path orelse continue;
        if (textureForTitle(index) != null) continue;
        var slot: ?*ArtworkTexture = null;
        for (&state.artwork_textures) |*texture| if (texture.title_index == std.math.maxInt(usize)) {
            slot = texture;
            break;
        };
        const texture = slot orelse return;
        texture.title_index = index;
        var decoded = importer.decodeArtwork(std.heap.c_allocator, state.threaded.io(), path) catch {
            texture.failed = true;
            continue;
        };
        defer decoded.deinit(std.heap.c_allocator);
        var mip_levels: [sg.max_mipmaps]sg.Range = @splat(.{});
        mip_levels[0] = .{ .ptr = decoded.pixels.ptr, .size = decoded.pixels.len };
        const image = sg.makeImage(.{
            .width = @intCast(decoded.width),
            .height = @intCast(decoded.height),
            .pixel_format = .RGBA8,
            .data = .{ .mip_levels = mip_levels },
            .label = "importer-artwork",
        });
        if (sg.queryImageState(image) != .VALID) {
            sg.destroyImage(image);
            texture.failed = true;
            continue;
        }
        const view = sg.makeView(.{ .texture = .{ .image = image }, .label = "importer-artwork-view" });
        if (sg.queryViewState(view) != .VALID) {
            sg.destroyView(view);
            sg.destroyImage(image);
            texture.failed = true;
            continue;
        }
        texture.* = .{
            .title_index = index,
            .image = image,
            .view = view,
            .width = @floatFromInt(decoded.width),
            .height = @floatFromInt(decoded.height),
        };
    }
}

fn textureForTitle(index: usize) ?*const ArtworkTexture {
    for (&state.artwork_textures) |*texture| if (texture.title_index == index) return if (texture.failed) null else texture;
    return null;
}

fn clearArtworkTextures() void {
    for (&state.artwork_textures) |*texture| destroyArtworkTexture(texture);
}

fn destroyArtworkTexture(texture: *ArtworkTexture) void {
    if (texture.title_index == std.math.maxInt(usize)) return;
    if (texture.view.id != sg.invalid_id) sg.destroyView(texture.view);
    if (texture.image.id != sg.invalid_id) sg.destroyImage(texture.image);
    texture.* = .{};
}

fn fromGridRect(rect: grid.Rect) Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
}

fn drawMarker(x: f32, y: f32, size: f32, color: Color) void {
    sgl.beginTriangles();
    sgl.c3b(color.r, color.g, color.b);
    sgl.v2f(x, y);
    sgl.v2f(x + size, y + size * 0.5);
    sgl.v2f(x, y + size);
    sgl.end();
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
            .LEFT => moveTitleSelection(-1),
            .RIGHT => moveTitleSelection(1),
            .UP => moveTitleSelection(-@as(isize, @intCast(grid.columns))),
            .DOWN => moveTitleSelection(@intCast(grid.columns)),
            .ESCAPE => sapp.requestQuit(),
            else => {},
        },
        .FILES_DROPPED => handleDrop(),
        else => {},
    }
}

fn handleClick(x: f32, y: f32) void {
    if (isBusy()) return;
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const width = metrics.width;
    if (downloadSelectedMod(width, x, y)) return;
    if (selectCompatibleMod(width, x, y)) return;
    if (searchMissingArtwork(width, x, y)) return;
    if (selectGridTitle(width, metrics.height, x, y)) return;
    if (contains(layout.refresh(width), x, y)) {
        runRefresh();
    } else if (contains(layout.addGames(), x, y)) {
        state.drop_mode = .games;
        setStatus(true, "Drop a ROM folder or RetroArch .lpl playlist anywhere on this window.", .{});
    } else if (contains(layout.loadCatalog(width), x, y)) {
        state.drop_mode = .registry;
        setStatus(true, "Drop a registry JSON file anywhere on this window.", .{});
    } else if (contains(layout.sdSync(width), x, y)) {
        state.preview_destination = .direct_sd;
        runSync(.direct_sd);
    } else if (contains(layout.usbSync(width), x, y)) {
        state.preview_destination = .usb;
        runSync(.usb);
    }
}

fn selectCompatibleMod(width: f32, x: f32, y: f32) bool {
    if (width < 840 or x < page_layout.detail_content_x or x > width - 44) return false;
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return false;
    const catalog = if (state.mod_registry) |*value| value else return false;
    var matches: [8]usize = undefined;
    const count = registry.matching(catalog, titles[state.preview_scroll].content_crc32, &titles[state.preview_scroll].content_hash, &matches);
    const shown = @min(count, @min(matches.len, 3));
    for (0..shown) |row| {
        const row_y = page_layout.mod_first_y + @as(f32, @floatFromInt(row)) * page_layout.mod_row_height;
        if (y >= row_y - 8 and y <= row_y + 12) {
            state.selected_mod = row;
            return true;
        }
    }
    return false;
}

fn downloadSelectedMod(width: f32, x: f32, y: f32) bool {
    if (width < 840 or !contains(.{ .x = page_layout.detail_content_x, .y = page_layout.mod_button_y, .w = 196, .h = 30 }, x, y)) return false;
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return false;
    const catalog = if (state.mod_registry) |*value| value else return false;
    var matches: [8]usize = undefined;
    const count = registry.matching(catalog, titles[state.preview_scroll].content_crc32, &titles[state.preview_scroll].content_hash, &matches);
    if (count == 0) return false;
    const shown = @min(count, matches.len);
    state.selected_mod = @min(state.selected_mod, shown - 1);
    if (!beginWorker()) return true;
    const config = ModDownloadConfig{ .registry_index = matches[state.selected_mod] };
    state.worker = std.Thread.spawn(.{}, modDownloadWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start the mod download: {s}", .{@errorName(err)});
        return true;
    };
    setStatus(true, "Downloading and verifying mod patch...", .{});
    return true;
}

fn searchMissingArtwork(width: f32, x: f32, y: f32) bool {
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return false;
    const title = titles[state.preview_scroll];
    if (title.artwork_path != null) return false;
    const button = Rect{ .x = page_layout.detail_content_x, .y = page_layout.artwork_button_y, .w = 196, .h = 30 };
    if (width < 840 or !contains(button, x, y)) return false;
    launchbox.openSearch(std.heap.c_allocator, state.threaded.io(), state.threaded.environ.process_environ, title.display_name) catch |err| {
        setStatus(false, "Could not open LaunchBox search: {s}.", .{@errorName(err)});
        return true;
    };
    setStatus(true, "Opened LaunchBox search for {s}.", .{title.display_name});
    return true;
}

fn selectGridTitle(width: f32, height: f32, x: f32, y: f32) bool {
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or height <= 610) return false;
    const area_x: f32 = 44;
    const area_y: f32 = page_layout.grid_y;
    const area_width: f32 = @min(544, width - 88);
    const area_height = height - area_y - 36;
    const metrics = grid.layout(area_width, area_height);
    const first_row = grid.firstVisibleRow(state.preview_scroll, titles.len, metrics.visible_rows);
    const first_index = first_row * grid.columns;
    const end_index = @min(titles.len, (first_row + metrics.visible_rows) * grid.columns);
    for (first_index..end_index) |index| {
        if (contains(fromGridRect(grid.cardRect(area_x, area_y, metrics, first_row, index)), x, y)) {
            state.preview_scroll = index;
            return true;
        }
    }
    return false;
}

fn handleDrop() void {
    if (isBusy() or sapp.getNumDroppedFiles() <= 0) return;
    const path = sapp.getDroppedFilePath(0);
    if (state.drop_mode == .registry or std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".json")) {
        loadRegistry(path);
        return;
    }
    const kind: SourceKind = blk: {
        const stat = std.Io.Dir.cwd().statFile(state.threaded.io(), path, .{}) catch |err| {
            setStatus(false, "Could not inspect dropped path: {s}.", .{@errorName(err)});
            return;
        };
        if (stat.kind == .directory) break :blk .directory;
        if (stat.kind == .file and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".lpl")) break :blk .playlist;
        setStatus(false, "Drop a ROM directory or a RetroArch .lpl playlist.", .{});
        return;
    };
    if (!state.dropped_source_path.set(path)) {
        setStatus(false, "Dropped source path is too long.", .{});
        return;
    }
    state.dropped_source_kind = kind;
    switch (kind) {
        .directory => setStatus(true, "Scanning dropped directory recursively...", .{}),
        .playlist => setStatus(true, "Saved dropped playlist fallback; refreshing automatic detection first...", .{}),
        .automatic => unreachable,
    }
    runRefresh();
}

fn loadRegistry(path: []const u8) void {
    const allocator = std.heap.c_allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(state.threaded.io(), path, allocator, .limited(registry.maximum_registry_size)) catch |err| {
        setStatus(false, "Could not read that mod catalog: {s}.", .{@errorName(err)});
        return;
    };
    defer allocator.free(bytes);
    var parsed = registry.parse(allocator, bytes) catch {
        setStatus(false, "That file is not a valid m64menu mod catalog.", .{});
        return;
    };
    if (state.mod_registry) |*existing| existing.deinit();
    state.mod_registry = parsed;
    state.registry_is_demo = false;
    state.selected_mod = 0;
    state.drop_mode = .games;
    setStatus(true, "Loaded {d} mod catalog entries. Use ADD GAMES or drop another folder to continue.", .{parsed.entries().len});
}

fn scrollTitles(delta: f32) void {
    const scan = state.scan orelse return;
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    if (delta < 0) state.preview_scroll = @min(titles.len - 1, state.preview_scroll + grid.columns);
    if (delta > 0) state.preview_scroll -|= @min(state.preview_scroll, grid.columns);
}

fn moveTitleSelection(delta: isize) void {
    const scan = state.scan orelse return;
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    const current: isize = @intCast(state.preview_scroll);
    state.preview_scroll = @intCast(std.math.clamp(current + delta, 0, @as(isize, @intCast(titles.len - 1))));
    state.selected_mod = 0;
}

fn runRefresh() void {
    if (isBusy()) return;
    const config = DiscoveryConfig{ .source_kind = state.dropped_source_kind, .source_path = state.dropped_source_path };
    if (!beginWorker()) return;
    state.worker = std.Thread.spawn(.{}, refreshWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start refresh: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Detecting RetroArch and SummerCart...", .{});
}

fn modDownloadWorker(config: ModDownloadConfig) void {
    const allocator = std.heap.c_allocator;
    const catalog = &(state.mod_registry orelse {
        finishWorker(.{ .mod_download = .{ .registry_index = config.registry_index, .err = "RegistryUnavailable" } });
        return;
    });
    const cache = registryCachePath(allocator) catch |err| {
        finishWorker(.{ .mod_download = .{ .registry_index = config.registry_index, .err = @errorName(err) } });
        return;
    };
    defer allocator.free(cache);
    const path = registry.download(allocator, state.threaded.io(), catalog.entries()[config.registry_index], cache) catch |err| {
        finishWorker(.{ .mod_download = .{ .registry_index = config.registry_index, .err = @errorName(err) } });
        return;
    };
    finishWorker(.{ .mod_download = .{ .registry_index = config.registry_index, .path = path } });
}

fn registryCachePath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "m64menu", "patches" });
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
        setStatus(false, "Sync refused: no N64 library is ready.", .{});
        return;
    };

    var config = SyncConfig{
        .destination = destination,
        .source_kind = state.active_source_kind,
        .source_path = .{},
        .source_fingerprint = libraryFingerprint(scan.preview().titles),
        .card_root = .{},
        .deployer_path = .{},
        .port = .{},
    };
    if (!config.source_path.set(scan.sourcePath())) {
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

    result.scan = switch (config.source_kind) {
        .directory => directory: {
            const root = config.source_path.slice();
            const preview = importer.scanLibrary(allocator, io, .{ .rom_root = root, .recursive = true }) catch |err| {
                result.scan_error = @errorName(err);
                break :directory null;
            };
            result.source_kind = .directory;
            break :directory .{ .directory = .{
                .root = allocator.dupe(u8, root) catch {
                    var owned_preview = preview;
                    owned_preview.deinit(allocator);
                    result.scan_error = "OutOfMemory";
                    break :directory null;
                },
                .preview = preview,
            } };
        },
        .automatic, .playlist => retroarch: {
            const detected = importer.scanRetroArchLibrary(allocator, io, .{ .environ = state.threaded.environ.process_environ }) catch |auto_err| fallback: {
                if (config.source_kind != .playlist or config.source_path.len == 0) {
                    result.scan_error = @errorName(auto_err);
                    break :fallback null;
                }
                const override_path = config.source_path.slice();
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
                result.source_kind = .playlist;
                break :fallback fallback_result;
            };
            break :retroarch if (detected) |scan| LibraryScan{ .retroarch = scan } else null;
        },
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
    var imported_titles: []const importer.Title = &.{};
    switch (config.source_kind) {
        .directory => {
            var imported = try importer.importLibrary(allocator, io, .{
                .output_root = staging,
                .rom_root = config.source_path.slice(),
                .recursive = true,
            }, .{ .context = null, .callback = importProgress });
            defer imported.deinit(allocator);
            if (!std.mem.eql(u8, &libraryFingerprint(imported.titles), &config.source_fingerprint)) return error.SourceChanged;
            imported_titles = imported.titles;
            try stageCachedMods(allocator, io, staging, imported_titles);
        },
        .automatic, .playlist => {
            const playlist_path = config.source_path.slice();
            const parent = std.fs.path.dirname(playlist_path) orelse return error.InvalidPlaylistPath;
            const roots = [_][]const u8{parent};
            var imported = try importer.importRetroArchLibrary(allocator, io, staging, .{
                .search_roots = &roots,
                .maximum_search_depth = 0,
                .environ = state.threaded.environ.process_environ,
            }, .{ .context = null, .callback = importProgress });
            defer imported.deinit(allocator);
            if (!std.ascii.eqlIgnoreCase(imported.source.playlist_path, playlist_path)) return error.PlaylistChanged;
            if (!std.mem.eql(u8, &libraryFingerprint(imported.preview.titles), &config.source_fingerprint)) return error.SourceChanged;
            imported_titles = imported.preview.titles;
            try stageCachedMods(allocator, io, staging, imported_titles);
        },
    }

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

fn stageCachedMods(allocator: std.mem.Allocator, io: std.Io, staging: []const u8, titles: []const importer.Title) !void {
    const catalog = &(state.mod_registry orelse return);
    const cache = try registryCachePath(allocator);
    defer allocator.free(cache);
    const count = try importer.stageCachedVariants(allocator, io, staging, titles, catalog, cache);
    if (count != 0) setStatus(true, "Staged {d} downloaded mod(s).", .{count});
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
        .mod_download => |download_result| harvestModDownload(download_result),
    }
}

fn harvestModDownload(result: ModDownloadResult) void {
    defer if (result.path) |path| std.heap.c_allocator.free(path);
    if (result.err) |_| {
        setStatus(false, "The mod patch could not be downloaded or verified.", .{});
        return;
    }
    const catalog = if (state.mod_registry) |*value| value else return;
    if (result.registry_index >= catalog.entries().len) return;
    const entry = catalog.entries()[result.registry_index];
    if (entry.patch.archiveMember != null) {
        setStatus(true, "Downloaded and verified {s}. Safe archive extraction is the next step.", .{entry.name});
    } else {
        setStatus(true, "Downloaded and verified {s}. Ready for patch application.", .{entry.name});
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
    state.active_source_kind = result.source_kind;
    state.preview_scroll = 0;
    state.preview_destination = if (state.card != null) .direct_sd else .usb;

    if (result.override_target_blocked) {
        setStatus(false, "That playlist could not be used. Drop {s} or a ROM folder instead.", .{expected_playlist_name});
    } else if (state.scan == null) {
        setStatus(false, "No Nintendo 64 games found. Drop a ROM folder or RetroArch playlist to continue.", .{});
    } else if (state.card != null) {
        if (state.card_error) |name| {
            setStatus(false, "Mounted SD detected, but its installed library could not be read: {s}.", .{name});
        } else {
            setStatus(true, "Ready to sync {d} games directly to the SD card.", .{state.scan.?.preview().titles.len});
        }
    } else if (state.device == null) {
        setStatus(false, "N64 library ready; no mounted SD or USB SummerCart detected.", .{});
    } else if (state.device.?.power == .on) {
        setStatus(false, "USB SummerCart detected, but sync is blocked while the console is powered on.", .{});
    } else if (state.device.?.power == .unknown) {
        setStatus(false, "USB cart found, but its power state could not be checked. Reconnect it and Refresh.", .{});
    } else if (state.device_error != null) {
        setStatus(false, "USB is available, but its installed library could not be read: {s}.", .{state.device_error.?});
    } else {
        setStatus(true, "Ready to sync {d} games over USB.", .{state.scan.?.preview().titles.len});
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
        if (!std.mem.eql(u8, installed.idSlice(), importer.titleIdSlice(&title.id))) continue;
        // Legacy libraries did not have name sidecars, so the deployer falls back
        // to the ID. Matching IDs still mean the ROM is already installed.
        if (std.mem.eql(u8, installed.name, installed.idSlice()) or asciiNameEqual(installed.name, title.display_name)) return .KEEP;
        return .UPDATE;
    }
    return .ADD;
}

fn libraryDiffFor(installed_titles: anytype) UiLibraryDiff {
    var result = UiLibraryDiff{};
    const scan = state.scan orelse return result;
    for (scan.preview().titles) |title| switch (titleSyncStateFor(title, installed_titles)) {
        .ADD => result.add += 1,
        .KEEP => result.keep += 1,
        .UPDATE => result.update += 1,
    };
    for (installed_titles) |installed| {
        var found = false;
        for (scan.preview().titles) |title| if (std.mem.eql(u8, installed.idSlice(), importer.titleIdSlice(&title.id))) {
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

fn syncStateDescription(sync_state: TitleSyncState) []const u8 {
    return switch (sync_state) {
        .ADD => "WILL BE ADDED",
        .KEEP => "ALREADY ON CART",
        .UPDATE => "WILL BE UPDATED",
    };
}

fn artworkCoverage(scan: importer.ScanResult) usize {
    var count: usize = 0;
    for (scan.titles) |title| if (title.artwork_path != null) {
        count += 1;
    };
    return count;
}

fn libraryFingerprint(titles: []const importer.Title) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (titles) |title| {
        hash.update(importer.titleIdSlice(&title.id));
        hash.update("\x00");
        hash.update(title.display_name);
        hash.update("\x00");
    }
    return hash.finalResult();
}

fn clearScan() void {
    clearArtworkTextures();
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
    drawText(44, page_layout.status_y, if (state.status_good) colors.good else colors.bad, "{s}", .{state.status[0..state.status_len]});
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
        .icon = icon.desc(),
        .window_title = "m64menu RetroArch Sync",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
