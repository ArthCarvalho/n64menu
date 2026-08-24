const std = @import("std");
const sokol = @import("sokol");
const importer = @import("importer");
const deployer = @import("deployer");
const grid = @import("grid");
const icon = @import("icon.zig");
const launchbox = @import("launchbox");
const registry = @import("registry");
const sel = @import("selection");
const sdcard = @import("sdcard");
const font = @import("font");
const startup = @import("startup");
const ui_scale = @import("ui_scale");

const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;
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
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    const ribbon = Color{ .r = 113, .g = 48, .b = 183 };
    const ribbon_dim = Color{ .r = 74, .g = 32, .b = 122 };
    const a_dark = Color{ .r = 0, .g = 50, .b = 150 };
    const a_mid = Color{ .r = 0, .g = 104, .b = 230 };
    const a_light = Color{ .r = 62, .g = 160, .b = 255 };
    const b_dark = Color{ .r = 0, .g = 96, .b = 40 };
    const b_mid = Color{ .r = 0, .g = 183, .b = 73 };
    const b_light = Color{ .r = 55, .g = 235, .b = 120 };
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
const PickerKind = enum { games, catalog };
const TitleSyncState = enum { ADD, KEEP, UPDATE, SKIP, REMOVE };
const UiLibraryDiff = struct { add: usize = 0, keep: usize = 0, update: usize = 0, remove: usize = 0 };

const PickerEntry = struct {
    name: [512]u8 = @splat(0),
    len: usize = 0,
    directory: bool = false,
    absolute: bool = false,

    fn setName(self: *PickerEntry, value: []const u8) bool {
        if (value.len >= self.name.len) return false;
        self.len = value.len;
        @memcpy(self.name[0..value.len], value);
        self.name[value.len] = 0;
        return true;
    }

    fn slice(self: *const PickerEntry) []const u8 {
        return self.name[0..self.len];
    }
};

const picker_max_entries = 2048;
const picker_visible_rows = 14;

const text_scale: f32 = 2;
const text_cell: f32 = 16;
const button_height: f32 = 36;

fn buttonWidth(label: []const u8) f32 {
    return font.advance(label.len, text_scale) + 24;
}

fn fitChars(available: f32) usize {
    if (available <= text_cell) return 1;
    return @intFromFloat(available / text_cell);
}

const page_layout = struct {
    const ribbon_top: f32 = 20;
    const ribbon_full: f32 = 76;
    const ribbon_lead: f32 = 68;
    const ribbon_tab: f32 = 76;
    const ribbon_gap: f32 = 6;
    const rule_y: f32 = 100;
    const workflow_y: f32 = 128;
    const workflow_height: f32 = 126;
    const status_y: f32 = 270;
    const library_top: f32 = 302;
    const grid_y: f32 = library_top + 60;
    /// The versions page carries a subtitle under the rule, so its cards start lower.
    const versions_grid_y: f32 = grid_y + 28;
    const grid_x: f32 = 44;
    const detail_width: f32 = 480;
    const detail_gap: f32 = 20;
    const right_margin: f32 = 44;
    const mod_first_y: f32 = grid_y + 150;
    const artwork_plain_y: f32 = grid_y + 120;
    const artwork_versions_y: f32 = grid_y + 200;

    fn detailX(width: f32) f32 {
        return @max(616, width - right_margin - detail_width);
    }

    fn detailContentX(width: f32) f32 {
        return detailX(width) + 16;
    }

    fn gridWidth(width: f32) f32 {
        return @max(544, detailX(width) - detail_gap - grid_x);
    }
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

const AggregateScanResult = struct {
    playlist_path: []u8,
    preview: importer.ScanResult,

    fn deinit(self: *AggregateScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.playlist_path);
        self.preview.deinit(allocator);
        self.* = undefined;
    }
};

const LibraryScan = union(enum) {
    retroarch: importer.RetroArchScanResult,
    directory: DirectoryScanResult,
    aggregate: AggregateScanResult,

    fn deinit(self: *LibraryScan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .retroarch => |*scan| scan.deinit(allocator),
            .directory => |*scan| scan.deinit(allocator),
            .aggregate => |*scan| scan.deinit(allocator),
        }
        self.* = undefined;
    }

    fn preview(self: *const LibraryScan) *const importer.ScanResult {
        return switch (self.*) {
            .retroarch => |*scan| &scan.preview,
            .directory => |*scan| &scan.preview,
            .aggregate => |*scan| &scan.preview,
        };
    }

    fn previewMut(self: *LibraryScan) *importer.ScanResult {
        return switch (self.*) {
            .retroarch => |*scan| &scan.preview,
            .directory => |*scan| &scan.preview,
            .aggregate => |*scan| &scan.preview,
        };
    }

    fn sourcePath(self: *const LibraryScan) []const u8 {
        return switch (self.*) {
            .retroarch => |scan| scan.source.playlist_path,
            .directory => |scan| scan.root,
            .aggregate => |scan| scan.playlist_path,
        };
    }
};

const DiscoveryConfig = struct {
    source_kind: SourceKind,
    source_path: FixedText,
    discover_destinations: bool = true,
    merge_existing: bool = false,
};

const SyncConfig = struct {
    destination: SyncDestination,
    source_kind: SourceKind,
    source_path: FixedText,
    source_fingerprint: [32]u8,
    card_root: FixedText,
    deployer_path: FixedText,
    port: FixedText,
    selection: []const sel.Key = &.{},
};

const ModDownloadConfig = struct {
    registry_index: usize,
};

const ArtworkDownloadConfig = struct {
    title_index: usize,
    display_name: FixedText,
    content_hash: [32]u8,
    advance_after_discovery: bool = false,
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
    destinations_discovered: bool = true,
    merge_existing: bool = false,
};

const SyncResult = struct {
    destination: SyncDestination,
    err: ?[]const u8 = null,
    cleanup_error: ?[]const u8 = null,
    logged: bool = false,
};

const ModDownloadResult = struct {
    registry_index: usize,
    path: ?[]u8 = null,
    err: ?[]const u8 = null,
};

const ModArtworkResult = struct {
    registry_index: usize,
    path: ?[]u8 = null,
    gallery_index: usize = 0,
    gallery_count: usize = 0,
    err: ?[]const u8 = null,
};

const ArtworkDownloadResult = struct {
    title_index: usize,
    content_hash: [32]u8,
    path: ?[]u8 = null,
    gallery_index: usize = 0,
    gallery_count: usize = 0,
    err: ?[]const u8 = null,
};

const ModArtworkSlot = struct {
    registry_index: usize = std.math.maxInt(usize),
    texture: ArtworkTexture = .{},
    loading: bool = false,
    gallery_index: usize = 0,
    gallery_count: usize = 0,
    failed: bool = false,
};

const ModBrowserData = struct {
    catalog: ?*registry.Registry,
    matches: [registry.maximum_variants_per_title]usize,
    local_count: usize,
    registry_count: usize,
    count: usize,
};

const WorkerResult = union(enum) {
    refresh: RefreshResult,
    sync: SyncResult,
    mod_download: ModDownloadResult,
    mod_artwork: ModArtworkResult,
    artwork_download: ArtworkDownloadResult,
};

const state = struct {
    var threaded: std.Io.Threaded = undefined;
    var io_ready = false;
    var pass_action: sg.PassAction = .{};
    var artwork_sampler: sg.Sampler = .{};
    var artwork_textures: [grid.maximum_visible_cards]ArtworkTexture = @splat(.{});
    var mod_artwork_slots: [registry.maximum_variants_per_title]ModArtworkSlot = @splat(.{});
    var mod_registry: ?registry.Registry = null;
    var registry_is_demo = true;
    var drop_mode: DropMode = .games;
    var selected_mod: usize = 0;
    var mod_browser_open = false;
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
    var progressive_scan: ?importer.ScanResult = null;
    var progressive_completed: usize = 0;
    var progressive_total: usize = 0;
    var progressive_base: ?importer.ScanResult = null;
    var shutting_down = false;
    var preview_destination: SyncDestination = .usb;
    var startup_elapsed: f64 = 0;
    var pending_drop_path = FixedText{};
    var pending_drop = false;
    var picker_open = false;
    var picker_kind: PickerKind = .games;
    var picker_path = FixedText{};
    var picker_entries: [picker_max_entries]PickerEntry = @splat(.{});
    var picker_count: usize = 0;
    var picker_scroll: usize = 0;
    var picker_selected: usize = std.math.maxInt(usize);
    var artwork_fetch_index: usize = std.math.maxInt(usize);
    var artwork_worker: ?std.Thread = null;
    var artwork_worker_result: ?ArtworkDownloadResult = null;
    var artwork_worker_done = false;
    var artwork_failed_hashes: [128][32]u8 = @splat(@splat(0));
    var artwork_failed_count: usize = 0;
    /// Guards the held-SPACE bulk select so one hold applies once.
    var space_hold_used = false;
    /// What the next sync should place on the cart.
    var selected: sel.Set = .{};
    /// Every ROM the session has already applied an import default to, so a
    /// rescan never revives a choice the user made.
    var known: sel.Set = .{};
};

const RibbonTab = enum { library, versions };

const labels = struct {
    const refresh = "RESCAN";
    const sd_sync = "SYNC TO SD";
    const usb_sync = "SYNC TO USB";
    const add_games = "ADD GAMES";
    const load_catalog = "LOAD CATALOG";
};

const layout = struct {
    const columns: usize = 4;
    const column_gap: f32 = 12;

    fn columnWidth(width: f32) f32 {
        return (width - 88 - 32 - column_gap * 3) / @as(f32, @floatFromInt(columns));
    }

    fn columnX(width: f32, index: usize) f32 {
        return 60 + @as(f32, @floatFromInt(index)) * (columnWidth(width) + column_gap);
    }

    fn columnButton(width: f32, index: usize, label: []const u8) Rect {
        return .{ .x = columnX(width, index), .y = page_layout.workflow_y + 80, .w = buttonWidth(label), .h = button_height };
    }

    fn addGames(width: f32) Rect {
        return columnButton(width, 0, labels.add_games);
    }

    fn refresh(_: f32) Rect {
        return .{ .x = 424, .y = 30, .w = buttonWidth(labels.refresh), .h = button_height };
    }

    fn loadCatalog(width: f32) Rect {
        return columnButton(width, 1, labels.load_catalog);
    }

    fn sdSync(width: f32) Rect {
        return columnButton(width, 2, labels.sd_sync);
    }

    fn usbSync(width: f32) Rect {
        return columnButton(width, 3, labels.usb_sync);
    }

    fn ribbonStart(width: f32) f32 {
        return width - 44 - (page_layout.ribbon_tab + page_layout.ribbon_gap) * 2 + page_layout.ribbon_gap;
    }

    fn ribbonTab(width: f32, index: usize) Rect {
        const x = ribbonStart(width) + @as(f32, @floatFromInt(index)) * (page_layout.ribbon_tab + page_layout.ribbon_gap);
        return .{ .x = x - page_layout.ribbon_full, .y = page_layout.ribbon_top, .w = page_layout.ribbon_tab + page_layout.ribbon_full, .h = page_layout.ribbon_full };
    }

    fn modBack(width: f32) Rect {
        const w = buttonWidth("BACK TO GAMES");
        return .{ .x = width - 44 - w, .y = page_layout.library_top - 2, .w = w, .h = button_height };
    }

    fn modPrimary(height: f32) Rect {
        return .{ .x = 44, .y = height - 92, .w = 248, .h = button_height };
    }

    fn modSecondary(height: f32) Rect {
        return .{ .x = 308, .y = height - 92, .w = 232, .h = button_height };
    }

    fn modTertiary(height: f32) Rect {
        return .{ .x = 556, .y = height - 92, .w = 232, .h = button_height };
    }

    fn pickerUp(panel: Rect) Rect {
        return .{ .x = panel.x + 20, .y = panel.y + 90, .w = buttonWidth("UP"), .h = button_height };
    }

    fn pickerAccept(panel: Rect) Rect {
        const previous = pickerUp(panel);
        return .{ .x = previous.x + previous.w + 16, .y = previous.y, .w = buttonWidth(pickerAcceptLabel()), .h = button_height };
    }

    fn pickerCancel(panel: Rect) Rect {
        const w = buttonWidth("CANCEL");
        return .{ .x = panel.x + panel.w - 20 - w, .y = panel.y + 90, .w = w, .h = button_height };
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
    if (state.artwork_worker) |worker| {
        worker.join();
        state.artwork_worker = null;
    }
    harvestVisibleArtworkWorker();
    harvestWorker();
    clearProgressiveScan();
    clearArtworkTextures();
    clearModArtworkSlots();
    if (state.artwork_sampler.id != sg.invalid_id) sg.destroySampler(state.artwork_sampler);
    clearScan();
    clearCard();
    clearDevice();
    if (state.mod_registry) |*catalog| catalog.deinit();
    state.mod_registry = null;
    state.selected.deinit(std.heap.c_allocator);
    state.known.deinit(std.heap.c_allocator);
    sgl.shutdown();
    sg.shutdown();
    if (state.io_ready) state.threaded.deinit();
}

export fn frame() void {
    harvestVisibleArtworkWorker();
    harvestProgressiveScan();
    harvestWorker();
    state.startup_elapsed += sapp.frameDuration();
    if (state.pending_drop and startup.frameAt(state.startup_elapsed).stage == .done and !isBusy()) processPendingDrop();
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const width = metrics.width;
    const height = metrics.height;
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.ortho(0, width, height, 0, -1, 1);
    sgl.matrixModeModelview();

    if (startup.frameAt(state.startup_elapsed).stage != .done) {
        drawStartup(width, height);
    } else if (state.picker_open) {
        drawSynthwaveBackground(width, height);
        drawFilePicker(width, height);
    } else {
        drawSynthwaveBackground(width, height);
        drawHeader(width);
        drawWorkflowStrip(width);
        drawStatus();
        if (state.mod_browser_open) {
            drawModBrowser(width, height);
        } else {
            drawTitles(width, height);
        }
        drawLegends(width, height);
    }

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sgl.draw();
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

fn drawHeader(width: f32) void {
    drawStartupLogo(64, 12, 2, 1);
    drawButton(layout.refresh(width), colors.pink, labels.refresh, !isBusy());

    const selected = selectedRibbonTab();
    const selected_index: usize = if (selected == .library) 0 else 1;
    const tab_x = layout.ribbonStart(width);
    const step = page_layout.ribbon_tab + page_layout.ribbon_gap;
    const rule_end = tab_x + @as(f32, @floatFromInt(selected_index)) * step;
    drawSkewedQuad(64, page_layout.rule_y - 4, @max(420, rule_end), page_layout.rule_y, 4, colors.pink);

    const versions_live = modBrowserAvailable();
    for (0..2) |index| {
        if (index == selected_index) continue;
        const enabled = index == 0 or versions_live;
        drawRibbonTab(tab_x + @as(f32, @floatFromInt(index)) * step, page_layout.ribbon_lead, if (enabled) colors.ribbon else colors.ribbon_dim);
        drawRibbonIcon(tab_x + @as(f32, @floatFromInt(index)) * step, index, false, enabled);
    }
    drawRibbonTab(tab_x + @as(f32, @floatFromInt(selected_index)) * step, page_layout.ribbon_full, colors.pink);
    drawRibbonIcon(tab_x + @as(f32, @floatFromInt(selected_index)) * step, selected_index, true, true);
}

fn selectedRibbonTab() RibbonTab {
    return if (state.mod_browser_open) .versions else .library;
}

fn modBrowserAvailable() bool {
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return false;
    return compatibleModCount(titles[state.preview_scroll]) != 0;
}

fn handleRibbonClick(width: f32, x: f32, y: f32) bool {
    for (0..2) |index| {
        if (!contains(layout.ribbonTab(width, index), x, y)) continue;
        if (index == 0) {
            state.mod_browser_open = false;
            return true;
        }
        if (!modBrowserAvailable()) {
            setStatus(false, "The selected game has no other versions.", .{});
            return true;
        }
        state.selected_mod = 0;
        state.mod_browser_open = true;
        return true;
    }
    return false;
}

fn drawRibbonTab(top_x: f32, height: f32, color: Color) void {
    drawSkewedQuad(top_x - height, page_layout.ribbon_top, top_x + page_layout.ribbon_tab, page_layout.ribbon_top + height, height, color);
}

fn drawSkewedQuad(x1: f32, y1: f32, x2: f32, y2: f32, skew: f32, color: Color) void {
    sgl.beginTriangles();
    sgl.c3b(color.r, color.g, color.b);
    sgl.v2f(x1 + skew, y1);
    sgl.v2f(x2, y1);
    sgl.v2f(x1, y2);
    sgl.v2f(x2, y1);
    sgl.v2f(x2 - skew, y2);
    sgl.v2f(x1, y2);
    sgl.end();
}

fn drawRibbonIcon(top_x: f32, index: usize, selected: bool, enabled: bool) void {
    const size: f32 = 38;
    const x = top_x - size * 0.5;
    const y = page_layout.ribbon_top + (page_layout.ribbon_full - size) * 0.5;
    const fill = if (!enabled) colors.border else if (selected) colors.yellow else colors.white;
    const shade = if (!enabled) colors.ribbon_dim else if (selected) colors.orange else colors.dim;
    if (index == 0) drawGridIcon(x, y, size, fill, shade) else drawStackIcon(x, y, size, fill, shade);
}

fn drawGridIcon(x: f32, y: f32, size: f32, fill: Color, shade: Color) void {
    const cell = size * 0.42;
    const gap = size * 0.16;
    drawRect(.{ .x = x, .y = y, .w = cell, .h = cell }, fill);
    drawRect(.{ .x = x + cell + gap, .y = y, .w = cell, .h = cell }, shade);
    drawRect(.{ .x = x, .y = y + cell + gap, .w = cell, .h = cell }, shade);
    drawRect(.{ .x = x + cell + gap, .y = y + cell + gap, .w = cell, .h = cell }, fill);
}

fn drawStackIcon(x: f32, y: f32, size: f32, fill: Color, shade: Color) void {
    const bar = size * 0.22;
    drawRect(.{ .x = x, .y = y + size * 0.08, .w = size, .h = bar }, shade);
    drawRect(.{ .x = x, .y = y + size * 0.39, .w = size, .h = bar }, fill);
    drawRect(.{ .x = x, .y = y + size * 0.70, .w = size, .h = bar }, shade);
}

const Legend = struct { key: []const u8, action: []const u8, dark: Color, mid: Color, light: Color };

fn currentToggleSelected() bool {
    const title = selectedTitle() orelse return false;
    if (!state.mod_browser_open) return state.selected.has(title.content_hash);
    const data = selectedModBrowserData() orelse return false;
    return variantSelected(title, data, state.selected_mod);
}

fn drawLegends(width: f32, height: f32) void {
    var entries: [5]Legend = undefined;
    var count: usize = 0;
    if (state.mod_browser_open) {
        entries[count] = .{ .key = "BACKSPACE", .action = "GAMES", .dark = colors.b_dark, .mid = colors.b_mid, .light = colors.b_light };
        count += 1;
    }
    if (!isBusy()) {
        if (selectedTitle()) |title| {
            const opens_versions = !state.mod_browser_open and compatibleModCount(title) != 0;
            entries[count] = .{
                .key = "SPACE",
                .action = if (opens_versions) "VERSIONS" else if (currentToggleSelected()) "REMOVE" else "ADD",
                .dark = .{ .r = 150, .g = 10, .b = 80 },
                .mid = colors.pink,
                .light = .{ .r = 255, .g = 130, .b = 195 },
            };
            count += 1;
        }
        if (state.preview_destination == .direct_sd and canSyncSd()) {
            entries[count] = .{ .key = "ENTER", .action = labels.sd_sync, .dark = colors.a_dark, .mid = colors.a_mid, .light = colors.a_light };
            count += 1;
        } else if (canSyncUsb()) {
            entries[count] = .{ .key = "ENTER", .action = labels.usb_sync, .dark = colors.a_dark, .mid = colors.a_mid, .light = colors.a_light };
            count += 1;
        }
        entries[count] = .{ .key = "F5", .action = labels.refresh, .dark = colors.ribbon_dim, .mid = colors.ribbon, .light = colors.dim };
        count += 1;
    }
    if (count == 0) return;

    var total: f32 = 0;
    for (entries[0..count]) |entry| total += legendWidth(entry) + 28;
    var x = width - 44 - total + 28;
    const y = height - 40;
    for (entries[0..count]) |entry| {
        const cap = capWidth(entry.key);
        drawKeyCap(x, y, cap, entry.key, entry.dark, entry.mid, entry.light);
        drawTextSlice(x + cap + 10, y + 8, text_scale, colors.white, entry.action);
        x += legendWidth(entry) + 28;
    }
}

fn capWidth(key: []const u8) f32 {
    return font.advance(key.len, text_scale) + 20;
}

fn legendWidth(entry: Legend) f32 {
    return capWidth(entry.key) + 10 + font.advance(entry.action.len, text_scale);
}

fn drawKeyCap(x: f32, y: f32, w: f32, key: []const u8, dark: Color, mid: Color, light: Color) void {
    const h: f32 = 30;
    drawRect(.{ .x = x + 2, .y = y + 3, .w = w, .h = h }, colors.black);
    drawRect(.{ .x = x, .y = y, .w = w, .h = h }, dark);
    drawRect(.{ .x = x + 2, .y = y + 2, .w = w - 4, .h = h - 6 }, mid);
    drawRect(.{ .x = x + 4, .y = y + 3, .w = w - 8, .h = 3 }, light);
    drawTextSlice(x + 10, y + 7, text_scale, colors.black, key);
}

fn drawWorkflowStrip(width: f32) void {
    const y = page_layout.workflow_y + 6;
    const fit = fitChars(layout.columnWidth(width));
    drawCompactLibrary(width, layout.columnX(width, 0), y, fit);
    drawCompactCatalog(width, layout.columnX(width, 1), y, fit);
    drawCompactSd(width, layout.columnX(width, 2), y, fit);
    drawCompactUsb(width, layout.columnX(width, 3), y, fit);
}

fn drawCompactLibrary(width: f32, x: f32, y: f32, fit: usize) void {
    drawText(x, y, colors.pink, "{s}", .{head("GAME LIBRARY", fit)});
    if (state.scan) |scan| {
        const preview = scan.preview();
        drawText(x, y + 26, colors.white, "{d} GAMES", .{preview.titles.len});
        const chosen = selectedTitleCount();
        drawText(x, y + 50, if (chosen == 0) colors.dim else colors.good, "{d} SELECTED", .{chosen});
    } else {
        drawText(x, y + 26, colors.dim, "{s}", .{head("SCANNING...", fit)});
    }
    drawButton(layout.addGames(width), colors.orange, labels.add_games, !isBusy());
}

fn drawCompactCatalog(width: f32, x: f32, y: f32, fit: usize) void {
    drawText(x, y, colors.pink, "{s}", .{head("MOD CATALOG", fit)});
    if (state.mod_registry) |*catalog| {
        drawText(x, y + 26, if (state.registry_is_demo) colors.orange else colors.good, "{d} {s}", .{ catalog.entries().len, if (state.registry_is_demo) "DEMO" else "LOADED" });
    } else {
        drawText(x, y + 26, colors.dim, "{s}", .{head("NOT LOADED", fit)});
    }
    drawButton(layout.loadCatalog(width), colors.orange, labels.load_catalog, !isBusy());
}

fn drawCompactSd(width: f32, x: f32, y: f32, fit: usize) void {
    drawText(x, y, colors.pink, "{s}", .{head("SD CARD", fit)});
    if (state.card) |card| {
        drawText(x, y + 26, colors.good, "READY", .{});
        if (card.library) |library| drawCompactDiff(x, y + 50, fit, libraryDiffFor(library.titles));
    } else {
        drawText(x, y + 26, colors.dim, "{s}", .{head("NOT CONNECTED", fit)});
    }
    drawButton(layout.sdSync(width), colors.yellow, labels.sd_sync, canSyncSd() and !isBusy());
}

fn drawCompactUsb(width: f32, x: f32, y: f32, fit: usize) void {
    drawText(x, y, colors.pink, "{s}", .{head("USB CART", fit)});
    if (state.device) |device| {
        const color = switch (device.power) {
            .off => colors.good,
            .on => colors.bad,
            .unknown => colors.orange,
        };
        drawText(x, y + 26, color, "{s}", .{head(switch (device.power) {
            .off => "READY",
            .on => "POWER OFF CONSOLE",
            .unknown => "CHECK CONNECTION",
        }, fit)});
        if (device.power == .off) if (device.library) |library| drawCompactDiff(x, y + 50, fit, libraryDiffFor(library.titles));
    } else {
        drawText(x, y + 26, colors.dim, "{s}", .{head("NOT CONNECTED", fit)});
    }
    drawButton(layout.usbSync(width), colors.orange, labels.usb_sync, canSyncUsb() and !isBusy());
}

fn drawCompactDiff(x: f32, y: f32, fit: usize, diff: UiLibraryDiff) void {
    var buffer: [96]u8 = undefined;
    var used: usize = 0;
    if (diff.add != 0) used += (std.fmt.bufPrint(buffer[used..], "+{d} ", .{diff.add}) catch return).len;
    if (diff.update != 0) used += (std.fmt.bufPrint(buffer[used..], "~{d} ", .{diff.update}) catch return).len;
    if (diff.remove != 0) used += (std.fmt.bufPrint(buffer[used..], "-{d}", .{diff.remove}) catch return).len;
    if (used == 0) {
        drawText(x, y, colors.dim, "{s}", .{head("NO CHANGES", fit)});
        return;
    }
    const color = if (diff.remove != 0) colors.bad else if (diff.update != 0) colors.orange else colors.good;
    drawText(x, y, color, "{s}", .{head(buffer[0..used], fit)});
}

fn drawTitles(width: f32, height: f32) void {
    const top: f32 = page_layout.library_top;
    const bottom_margin: f32 = 36;
    if (height <= top + 100) return;
    drawTextSlice(44, top, 4, colors.white, "LIBRARY");
    drawRect(.{ .x = 44, .y = top + 42, .w = width - 88, .h = 2 }, colors.pink);
    const scan = state.scan orelse {
        drawText(44, top + 60, colors.dim, "No resolved N64 titles.", .{});
        return;
    };
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    state.preview_scroll = @min(state.preview_scroll, titles.len - 1);

    const area_x: f32 = page_layout.grid_x;
    const area_y = page_layout.grid_y;
    const area_width = page_layout.gridWidth(width);
    const area_height = height - area_y - bottom_margin;
    const metrics = grid.layout(area_width, area_height);
    const first_row = grid.firstVisibleRow(state.preview_scroll, titles.len, metrics);
    const first_index = first_row * metrics.columns;
    const end_index = @min(titles.len, (first_row + metrics.visible_rows) * metrics.columns);
    syncArtworkTextures(titles, first_index, end_index);
    scheduleVisibleArtwork(titles, first_index, end_index);

    for (titles[first_index..end_index], first_index..) |_, index| {
        if (index == state.preview_scroll) continue;
        const card = fromGridRect(grid.cardRect(area_x, area_y, metrics, first_row, index));
        drawCover(card, textureForTitle(index), titles[index].display_name, false);
        drawModsBadge(card, titles[index]);
        drawSelectionBadge(card, state.selected.has(titles[index].content_hash));
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
        drawModsBadge(card, title);
        drawSelectionBadge(card, state.selected.has(title.content_hash));
    }

    drawSelectedTitle(width, area_y, titles[state.preview_scroll]);
}

/// A filled check means the ROM is queued for the cart; an empty box means it is
/// present in the library but will not be written.
fn drawSelectionBadge(card: Rect, chosen: bool) void {
    const box = Rect{ .x = card.x + 6, .y = card.y + 6, .w = 22, .h = 22 };
    if (!chosen) {
        drawRect(box, colors.background);
        drawOutline(box, colors.dim, 2);
        return;
    }
    drawRect(box, colors.good);
    drawRect(.{ .x = box.x + 4, .y = box.y + 11, .w = 4, .h = 4 }, colors.black);
    drawRect(.{ .x = box.x + 7, .y = box.y + 14, .w = 4, .h = 4 }, colors.black);
    drawRect(.{ .x = box.x + 10, .y = box.y + 10, .w = 4, .h = 5 }, colors.black);
    drawRect(.{ .x = box.x + 13, .y = box.y + 6, .w = 4, .h = 5 }, colors.black);
    drawRect(.{ .x = box.x + 16, .y = box.y + 4, .w = 3, .h = 4 }, colors.black);
}

fn drawModsBadge(card: Rect, title: importer.Title) void {
    const count = compatibleModCount(title);
    if (count == 0) return;
    const badge = Rect{ .x = card.x + card.w - 92, .y = card.y + card.h - 32, .w = 86, .h = 24 };
    drawRect(badge, colors.pink);
    drawText(badge.x + 7, badge.y + 4, colors.background, "{d} MOD", .{count});
}

fn selectedArtworkButton(width: f32, has_versions: bool) Rect {
    const y = if (has_versions) page_layout.artwork_versions_y else page_layout.artwork_plain_y;
    return .{ .x = page_layout.detailContentX(width), .y = y, .w = buttonWidth("NEXT ART"), .h = button_height };
}

fn drawSelectedTitle(width: f32, top: f32, title: importer.Title) void {
    const mod_count = compatibleModCount(title);
    const panel_height: f32 = if (mod_count != 0) 252 else 172;
    const panel = Rect{ .x = page_layout.detailX(width), .y = top, .w = @min(page_layout.detail_width, @max(0, width - page_layout.detailX(width) - page_layout.right_margin)), .h = panel_height };
    if (panel.w < 260) return;
    drawRect(panel, colors.inset);
    drawOutline(panel, colors.border, 2);
    const content_x = panel.x + 16;
    const fit = fitChars(panel.w - 32);
    drawText(content_x, panel.y + 16, colors.pink, "SELECTED GAME", .{});
    drawText(content_x, panel.y + 50, if (title.artwork_path == null) colors.orange else colors.white, "{s}", .{head(title.display_name, fit)});
    const sync_state = titleSyncState(title);
    drawText(content_x, panel.y + 84, syncStateColor(sync_state), "{s}", .{syncStateDescription(sync_state)});
    if (mod_count != 0) {
        drawText(content_x, panel.y + 118, colors.yellow, "{d} VERSION(S)", .{mod_count});
        drawText(content_x, panel.y + 152, colors.dim, "{s}", .{head("SPACE opens them, hold for all.", fit)});
    }
    const artwork_y = if (mod_count == 0) page_layout.artwork_plain_y else page_layout.artwork_versions_y;
    if (title.artwork_path == null) drawText(content_x, artwork_y - 30, colors.orange, "ARTWORK NEEDED", .{});
    drawButton(selectedArtworkButton(width, mod_count != 0), if (title.artwork_path == null) colors.yellow else colors.orange, "NEXT ART", !isBusy());
}

fn drawModBrowser(width: f32, height: f32) void {
    const scan = state.scan orelse return;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return;
    const title = titles[state.preview_scroll];
    const data = selectedModBrowserData() orelse return;
    if (data.count == 0) {
        state.mod_browser_open = false;
        return;
    }
    drawTextSlice(44, page_layout.library_top, 4, colors.white, "VERSIONS");
    drawButton(layout.modBack(width), colors.pink, "BACK TO GAMES", true);
    drawRect(.{ .x = 44, .y = page_layout.library_top + 42, .w = width - 88, .h = 2 }, colors.pink);
    drawText(44, page_layout.library_top + 52, colors.dim, "{s}", .{head(title.display_name, fitChars(width - 88))});

    const cards = data.count + 1;
    const area = Rect{ .x = 44, .y = page_layout.versions_grid_y, .w = width - 88, .h = height - page_layout.versions_grid_y - 130 };
    const columns = std.math.clamp(@as(usize, @intFromFloat(@ceil((area.w + 16) / 220))), 2, 5);
    const gutter: f32 = 16;
    const card_width = (area.w - gutter * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    const card_height = @min(220, card_width * 0.72);
    for (0..cards) |card_index| {
        const row = card_index / columns;
        const column = card_index % columns;
        const rect = Rect{
            .x = area.x + @as(f32, @floatFromInt(column)) * (card_width + gutter),
            .y = area.y + @as(f32, @floatFromInt(row)) * (card_height + gutter),
            .w = card_width,
            .h = card_height,
        };
        const selected = card_index == state.selected_mod;
        const chosen = variantSelected(title, data, card_index);
        if (card_index == 0) {
            drawModBrowserCard(rect, textureForTitle(state.preview_scroll), title.display_name, "LATEST / BASE", selected, chosen);
        } else if (card_index <= data.local_count) {
            const revision = title.local_revisions[card_index - 1];
            drawModBrowserCard(rect, textureForTitle(state.preview_scroll), revision.name, revisionLabel(revision.revision), selected, chosen);
        } else {
            const registry_index = data.matches[card_index - 1 - data.local_count];
            const entry = data.catalog.?.entries()[registry_index];
            syncModArtwork(registry_index);
            drawModBrowserCard(rect, textureForMod(registry_index), entry.name, entry.version, selected, chosen);
        }
    }
    if (state.selected_mod != 0) {
        if (state.selected_mod <= data.local_count) {
            const revision = title.local_revisions[state.selected_mod - 1];
            drawButton(layout.modPrimary(height), colors.good, "READY FOR SYNC", true);
            drawText(layout.modSecondary(height).x, height - 84, colors.dim, "{s} - {s}", .{ head(revision.name, 24), revisionLabel(revision.revision) });
            return;
        }
        const registry_index = data.matches[state.selected_mod - 1 - data.local_count];
        const entry = data.catalog.?.entries()[registry_index];
        const cached = isModCached(entry);
        drawButton(layout.modPrimary(height), if (cached) colors.good else colors.yellow, if (cached) "READY FOR SYNC" else "DOWNLOAD MOD", !isBusy());
        const artwork_slot = modArtworkSlot(registry_index);
        const has_gallery = artwork_slot != null and artwork_slot.?.gallery_count > 1;
        drawButton(layout.modSecondary(height), colors.orange, if (has_gallery) "NEXT ART" else "VIEW MOD PAGE", !isBusy());
        if (has_gallery) drawButton(layout.modTertiary(height), colors.ribbon, "VIEW MOD PAGE", true);
        const text_x = if (has_gallery) layout.modTertiary(height).x + 248 else layout.modTertiary(height).x;
        drawText(text_x, height - 84, colors.dim, "{s} {s}", .{ head(entry.name, 20), entry.version });
    } else {
        drawText(44, height - 84, colors.dim, "Original game", .{});
    }
}

fn revisionLabel(revision: u8) []const u8 {
    return switch (revision) {
        0 => "REV 0",
        1 => "REV A",
        2 => "REV B",
        3 => "REV C",
        else => "OLDER REVISION",
    };
}

fn drawModBrowserCard(rect: Rect, texture: ?*const ArtworkTexture, name: []const u8, version: []const u8, selected: bool, chosen: bool) void {
    drawRect(rect, colors.inset);
    const image_rect = Rect{ .x = rect.x + 8, .y = rect.y + 8, .w = rect.w - 16, .h = rect.h - 62 };
    if (texture) |artwork| {
        drawModArtwork(image_rect, artwork);
    } else {
        drawCoverName(image_rect, name);
    }
    drawText(rect.x + 10, rect.y + rect.h - 42, selectedColor(selected), "{s}", .{head(name, fitChars(rect.w - 20))});
    drawText(rect.x + 10, rect.y + rect.h - 20, colors.dim, "{s}", .{head(version, fitChars(rect.w - 20))});
    drawOutline(rect, if (selected) colors.yellow else colors.border, if (selected) 3 else 1);
    drawSelectionBadge(rect, chosen);
}

fn selectedColor(selected: bool) Color {
    return if (selected) colors.yellow else colors.white;
}

fn compatibleModCount(title: importer.Title) usize {
    const catalog = if (state.mod_registry) |*value| value else return title.local_revisions.len;
    var matches: [8]usize = undefined;
    return title.local_revisions.len + importer.matchingRegistryVariants(title, catalog, &matches);
}

fn drawModArtwork(rect: Rect, artwork: *const ArtworkTexture) void {
    drawRect(rect, colors.background);
    const scale = @min(rect.w / artwork.width, rect.h / artwork.height);
    const width = artwork.width * scale;
    const height = artwork.height * scale;
    const x = rect.x + (rect.w - width) * 0.5;
    const y = rect.y + (rect.h - height) * 0.5;
    sgl.enableTexture();
    sgl.texture(artwork.view, state.artwork_sampler);
    sgl.c3b(255, 255, 255);
    sgl.beginQuads();
    sgl.v2fT2f(x, y, 0, 0);
    sgl.v2fT2f(x + width, y, 1, 0);
    sgl.v2fT2f(x + width, y + height, 1, 1);
    sgl.v2fT2f(x, y + height, 0, 1);
    sgl.end();
    sgl.disableTexture();
    drawOutline(rect, colors.border, 1);
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
    const maximum = @max(@as(usize, 6), fitChars(rect.w - 20));
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
    const first_y = rect.y + (rect.h - @as(f32, @floatFromInt(visible_count)) * (text_cell + 4)) * 0.5 + 4;
    for (lines[0..visible_count], 0..) |line, index| {
        const width = font.advance(line.len, text_scale);
        drawText(rect.x + (rect.w - width) * 0.5, first_y + @as(f32, @floatFromInt(index)) * (text_cell + 4), colors.orange, "{s}", .{line});
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

fn textureForMod(registry_index: usize) ?*const ArtworkTexture {
    for (&state.mod_artwork_slots) |*slot| {
        if (slot.registry_index == registry_index and !slot.texture.failed and slot.texture.title_index != std.math.maxInt(usize)) return &slot.texture;
    }
    return null;
}

fn modArtworkSlot(registry_index: usize) ?*ModArtworkSlot {
    for (&state.mod_artwork_slots) |*slot| if (slot.registry_index == registry_index) return slot;
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
    if (input.type == .FILES_DROPPED) {
        queueDrop();
        return;
    }
    if (startup.frameAt(state.startup_elapsed).stage != .done) return;
    const scale = ui_scale.metrics(sapp.widthf(), sapp.heightf()).scale;
    if (state.picker_open) {
        switch (input.type) {
            .MOUSE_DOWN => if (input.mouse_button == .LEFT) handlePickerClick(input.mouse_x / scale, input.mouse_y / scale),
            .MOUSE_SCROLL => scrollPicker(input.scroll_y),
            .KEY_DOWN => {
                if (!input.key_repeat and input.key_code == .ESCAPE) state.picker_open = false;
            },
            else => {},
        }
        return;
    }
    switch (input.type) {
        .MOUSE_DOWN => if (input.mouse_button == .LEFT) handleClick(input.mouse_x / scale, input.mouse_y / scale),
        .MOUSE_SCROLL => scrollTitles(input.scroll_y),
        .KEY_UP => if (input.key_code == .SPACE) {
            state.space_hold_used = false;
        },
        .KEY_DOWN => if (input.key_code == .SPACE) {
            if (input.key_repeat) handleSpaceHold() else handleSpaceTap();
        } else if (!input.key_repeat) switch (input.key_code) {
            .F5 => runRefresh(),
            .ENTER => if (state.mod_browser_open) activateSelectedMod() else runPreferredSync(),
            .BACKSPACE => if (state.mod_browser_open) {
                state.mod_browser_open = false;
            },
            .LEFT => if (state.mod_browser_open) moveModBrowserSelection(-1) else moveTitleSelection(-1),
            .RIGHT => if (state.mod_browser_open) moveModBrowserSelection(1) else moveTitleSelection(1),
            .UP => if (state.mod_browser_open) moveModBrowserSelection(-@as(isize, @intCast(modBrowserColumns()))) else moveTitleSelection(-@as(isize, @intCast(currentGridLayout().columns))),
            .DOWN => if (state.mod_browser_open) moveModBrowserSelection(@intCast(modBrowserColumns())) else moveTitleSelection(@intCast(currentGridLayout().columns)),
            .ESCAPE => if (state.mod_browser_open) {
                state.mod_browser_open = false;
            } else sapp.requestQuit(),
            else => {},
        },
        else => {},
    }
}

fn scheduleVisibleArtwork(titles: []const importer.Title, first: usize, end: usize) void {
    if (state.artwork_worker != null or state.picker_open) return;
    for (first..end) |index| {
        if (titles[index].artwork_path != null or state.artwork_fetch_index == index or artworkLookupFailed(&titles[index].content_hash)) continue;
        var config = ArtworkDownloadConfig{ .title_index = index, .display_name = .{}, .content_hash = titles[index].content_hash };
        if (!config.display_name.set(titles[index].display_name)) return;
        state.artwork_fetch_index = index;
        state.artwork_worker = std.Thread.spawn(.{}, visibleArtworkWorker, .{config}) catch {
            state.artwork_fetch_index = std.math.maxInt(usize);
            return;
        };
        setStatus(true, "Finding artwork for visible game {s}...", .{titles[index].display_name});
        return;
    }
}

fn visibleArtworkWorker(config: ArtworkDownloadConfig) void {
    const result = downloadArtworkResult(config);
    lockWorker();
    state.artwork_worker_result = result;
    state.artwork_worker_done = true;
    unlockWorker();
}

fn harvestVisibleArtworkWorker() void {
    lockWorker();
    if (!state.artwork_worker_done) {
        unlockWorker();
        return;
    }
    const result = state.artwork_worker_result.?;
    state.artwork_worker_result = null;
    state.artwork_worker_done = false;
    const worker = state.artwork_worker;
    state.artwork_worker = null;
    unlockWorker();
    if (worker) |thread| thread.join();
    harvestArtworkDownload(result);
}

fn artworkLookupFailed(hash: *const [32]u8) bool {
    for (state.artwork_failed_hashes[0..state.artwork_failed_count]) |failed| if (std.mem.eql(u8, &failed, hash)) return true;
    return false;
}

fn rememberArtworkFailure(hash: [32]u8) void {
    if (artworkLookupFailed(&hash)) return;
    if (state.artwork_failed_count == state.artwork_failed_hashes.len) {
        state.artwork_failed_hashes[0] = hash;
        return;
    }
    state.artwork_failed_hashes[state.artwork_failed_count] = hash;
    state.artwork_failed_count += 1;
}

fn clearArtworkFailure(hash: *const [32]u8) void {
    for (state.artwork_failed_hashes[0..state.artwork_failed_count], 0..) |failed, index| if (std.mem.eql(u8, &failed, hash)) {
        state.artwork_failed_count -= 1;
        state.artwork_failed_hashes[index] = state.artwork_failed_hashes[state.artwork_failed_count];
        return;
    };
}

fn modBrowserColumns() usize {
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const area_width = metrics.width - 88;
    return std.math.clamp(@as(usize, @intFromFloat(@ceil((area_width + 16) / 220))), 2, 5);
}

fn moveModBrowserSelection(delta: isize) void {
    const data = selectedModBrowserData() orelse return;
    const maximum: isize = @intCast(data.count);
    state.selected_mod = @intCast(std.math.clamp(@as(isize, @intCast(state.selected_mod)) + delta, 0, maximum));
}

fn activateSelectedMod() void {
    if (state.selected_mod == 0) return;
    const data = selectedModBrowserData() orelse return;
    if (state.selected_mod > data.count or state.selected_mod <= data.local_count) return;
    downloadRegistryIndex(data.matches[state.selected_mod - 1 - data.local_count]);
}

fn selectedTitle() ?importer.Title {
    const scan = state.scan orelse return null;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return null;
    return titles[state.preview_scroll];
}

/// A tap opens the version list when a game has alternates, because choosing
/// between them is the real decision. Games with nothing to choose toggle
/// directly.
fn handleSpaceTap() void {
    if (state.mod_browser_open) {
        toggleSelectedVariant();
        return;
    }
    const title = selectedTitle() orelse return;
    if (compatibleModCount(title) == 0) {
        toggleSelectedTitle();
        return;
    }
    state.selected_mod = 0;
    state.mod_browser_open = true;
    setStatus(true, "{s}: pick versions with SPACE, BACKSPACE to go back.", .{head(title.display_name, 40)});
}

/// Holding takes the whole set, base ROM included, so a game with many versions
/// does not need one press each.
fn handleSpaceHold() void {
    if (state.space_hold_used) return;
    const title = selectedTitle() orelse return;
    if (compatibleModCount(title) == 0) return;
    state.space_hold_used = true;
    selectAllVariants(title);
}

fn selectAllVariants(title: importer.Title) void {
    const allocator = std.heap.c_allocator;
    const data = selectedModBrowserData() orelse return;
    var chosen: usize = 0;
    for (0..data.count + 1) |index| {
        const key = variantKey(title, data, index) orelse continue;
        state.selected.select(allocator, key) catch break;
        chosen += 1;
    }
    setStatus(true, "{s}: {d} version(s) selected.", .{ head(title.display_name, 36), chosen });
}

fn toggleSelectedTitle() void {
    const title = selectedTitle() orelse return;
    const now = state.selected.toggle(std.heap.c_allocator, title.content_hash) catch {
        setStatus(false, "Could not update the selection.", .{});
        return;
    };
    if (!now) deselectVariantsOf(title);
    setStatus(true, "{s}: {s}", .{
        head(title.display_name, 48),
        if (now) "selected for the cart." else "left off the cart.",
    });
}

/// A variant is stored beside its base ROM, so dropping the base drops every
/// alternate version with it.
fn deselectVariantsOf(title: importer.Title) void {
    for (title.local_revisions) |revision| state.selected.deselect(revision.content_hash);
    const catalog = if (state.mod_registry) |*value| value else return;
    var matches: [registry.maximum_variants_per_title]usize = undefined;
    const count = @min(importer.matchingRegistryVariants(title, catalog, &matches), matches.len);
    for (matches[0..count]) |index| state.selected.deselect(sel.modKey(catalog.entries()[index].id));
}

fn variantKey(title: importer.Title, data: ModBrowserData, index: usize) ?sel.Key {
    if (index == 0) return title.content_hash;
    if (index <= data.local_count) return title.local_revisions[index - 1].content_hash;
    const catalog = data.catalog orelse return null;
    if (index > data.count) return null;
    return sel.modKey(catalog.entries()[data.matches[index - 1 - data.local_count]].id);
}

fn variantName(title: importer.Title, data: ModBrowserData, index: usize) []const u8 {
    if (index == 0) return title.display_name;
    if (index <= data.local_count) return title.local_revisions[index - 1].name;
    const catalog = data.catalog orelse return title.display_name;
    if (index > data.count) return title.display_name;
    return catalog.entries()[data.matches[index - 1 - data.local_count]].name;
}

fn variantSelected(title: importer.Title, data: ModBrowserData, index: usize) bool {
    const key = variantKey(title, data, index) orelse return false;
    return state.selected.has(key);
}

fn toggleSelectedVariant() void {
    const title = selectedTitle() orelse return;
    const data = selectedModBrowserData() orelse return;
    const key = variantKey(title, data, state.selected_mod) orelse return;
    const allocator = std.heap.c_allocator;
    const now = state.selected.toggle(allocator, key) catch {
        setStatus(false, "Could not update the selection.", .{});
        return;
    };
    if (state.selected_mod == 0) {
        if (!now) deselectVariantsOf(title);
    } else if (now) {
        // The cart stores a variant under its base title, so the base comes too.
        state.selected.select(allocator, title.content_hash) catch {};
    }
    setStatus(true, "{s}: {s}", .{
        head(variantName(title, data, state.selected_mod), 48),
        if (now) "selected for the cart." else "left off the cart.",
    });
}

fn handleClick(x: f32, y: f32) void {
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const width = metrics.width;
    if (contains(layout.addGames(width), x, y)) {
        openFilePicker(.games);
        return;
    }
    if (contains(layout.loadCatalog(width), x, y)) {
        openFilePicker(.catalog);
        return;
    }
    if (isBusy()) return;
    if (handleRibbonClick(width, x, y)) return;
    if (state.mod_browser_open) {
        handleModBrowserClick(width, metrics.height, x, y);
        return;
    }
    if (advanceSelectedGameArtwork(width, x, y)) return;
    if (selectGridTitle(width, metrics.height, x, y)) return;
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

fn openRegistryEntryPage(selected: registry.Entry) void {
    if (selected.artwork == null) {
        launchbox.openSearch(std.heap.c_allocator, state.threaded.io(), state.threaded.environ.process_environ, selected.name) catch {
            setStatus(false, "Could not open the LaunchBox search.", .{});
            return;
        };
        setStatus(true, "Opened a LaunchBox search for {s}.", .{selected.name});
        return;
    }
    const url = launchbox.attributedUrl(std.heap.c_allocator, selected.projectUrl) catch return;
    defer std.heap.c_allocator.free(url);
    launchbox.openUrl(std.heap.c_allocator, state.threaded.io(), state.threaded.environ.process_environ, url) catch {
        setStatus(false, "Could not open the mod project page.", .{});
        return;
    };
    setStatus(true, "Opened {s}'s project page.", .{selected.name});
}

fn selectedModBrowserData() ?ModBrowserData {
    const scan = state.scan orelse return null;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return null;
    const catalog = if (state.mod_registry) |*value| value else null;
    var matches: [registry.maximum_variants_per_title]usize = undefined;
    const registry_count = if (catalog) |value| @min(importer.matchingRegistryVariants(titles[state.preview_scroll], value, &matches), matches.len) else 0;
    const local_count = @min(titles[state.preview_scroll].local_revisions.len, registry.maximum_variants_per_title);
    return .{ .catalog = catalog, .matches = matches, .local_count = local_count, .registry_count = registry_count, .count = @min(local_count + registry_count, registry.maximum_variants_per_title) };
}

fn downloadRegistryIndex(registry_index: usize) void {
    if (!beginWorker()) return;
    const config = ModDownloadConfig{ .registry_index = registry_index };
    state.worker = std.Thread.spawn(.{}, modDownloadWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start the mod download: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Downloading and verifying mod patch...", .{});
}

fn advanceSelectedGameArtwork(width: f32, x: f32, y: f32) bool {
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return false;
    const title = titles[state.preview_scroll];
    if (width < 840 or !contains(selectedArtworkButton(width, compatibleModCount(title) != 0), x, y)) return false;
    if (state.artwork_worker != null) {
        setStatus(false, "Artwork lookup is already in progress.", .{});
        return true;
    }
    clearArtworkFailure(&title.content_hash);
    var config = ArtworkDownloadConfig{
        .title_index = state.preview_scroll,
        .display_name = .{},
        .content_hash = title.content_hash,
        .advance_after_discovery = true,
    };
    if (!config.display_name.set(title.display_name) or !beginWorker()) return true;
    const spawned = if (title.artwork_options > 1)
        std.Thread.spawn(.{}, artworkCycleWorker, .{config})
    else
        std.Thread.spawn(.{}, artworkDiscoverAndAdvanceWorker, .{config});
    state.worker = spawned catch |err| {
        cancelWorker();
        setStatus(false, "Could not start artwork download: {s}.", .{@errorName(err)});
        return true;
    };
    if (title.artwork_options > 1) {
        setStatus(true, "Switching artwork...", .{});
    } else {
        setStatus(true, "Finding the next artwork option...", .{});
    }
    return true;
}

fn selectGridTitle(width: f32, height: f32, x: f32, y: f32) bool {
    const scan = state.scan orelse return false;
    const titles = scan.preview().titles;
    if (titles.len == 0 or height <= 610) return false;
    const area_x: f32 = page_layout.grid_x;
    const area_y: f32 = page_layout.grid_y;
    const area_width = page_layout.gridWidth(width);
    const area_height = height - area_y - 36;
    const metrics = grid.layout(area_width, area_height);
    const first_row = grid.firstVisibleRow(state.preview_scroll, titles.len, metrics);
    const first_index = first_row * metrics.columns;
    const end_index = @min(titles.len, (first_row + metrics.visible_rows) * metrics.columns);
    for (first_index..end_index) |index| {
        if (contains(fromGridRect(grid.cardRect(area_x, area_y, metrics, first_row, index)), x, y)) {
            if (index == state.preview_scroll and compatibleModCount(titles[index]) != 0) {
                state.mod_browser_open = true;
                state.selected_mod = 0;
                clearModArtworkSlots();
                return true;
            }
            state.preview_scroll = index;
            state.selected_mod = 0;
            return true;
        }
    }
    return false;
}

fn queueDrop() void {
    if (sapp.getNumDroppedFiles() <= 0) return;
    const path = sapp.getDroppedFilePath(0);
    if (!state.pending_drop_path.set(path)) {
        setStatus(false, "Dropped path is too long.", .{});
        return;
    }
    state.pending_drop = true;
    if (isBusy() or startup.frameAt(state.startup_elapsed).stage != .done) {
        setStatus(true, "Drop queued; waiting for current detection to finish...", .{});
    } else processPendingDrop();
}

fn pickerPanel(width: f32, height: f32) Rect {
    const panel_width = @min(940, width - 80);
    const panel_height = @min(720, height - 80);
    return .{ .x = (width - panel_width) * 0.5, .y = (height - panel_height) * 0.5, .w = panel_width, .h = panel_height };
}

fn drawFilePicker(width: f32, height: f32) void {
    drawRect(.{ .x = 0, .y = 0, .w = width, .h = height }, colors.background);
    const panel = pickerPanel(width, height);
    drawRect(panel, colors.panel);
    drawOutline(panel, colors.pink, 3);
    const accept_label = pickerAcceptLabel();
    drawText(panel.x + 20, panel.y + 22, colors.yellow, "{s}", .{if (state.picker_kind == .games) "SELECT ROM FOLDER OR PLAYLIST" else "SELECT MOD CATALOG"});
    const shown_path = if (state.picker_path.len == 0) "Computer" else state.picker_path.slice();
    drawText(panel.x + 20, panel.y + 56, colors.dim, "{s}", .{head(shown_path, fitChars(panel.w - 40))});
    drawButton(layout.pickerUp(panel), colors.orange, "UP", true);
    drawButton(layout.pickerAccept(panel), colors.yellow, accept_label, true);
    drawButton(layout.pickerCancel(panel), colors.ribbon, "CANCEL", true);
    const list = Rect{ .x = panel.x + 20, .y = panel.y + 140, .w = panel.w - 40, .h = panel.h - 160 };
    drawRect(list, colors.inset);
    drawOutline(list, colors.border, 1);
    const end = @min(state.picker_count, state.picker_scroll + picker_visible_rows);
    for (state.picker_scroll..end) |index| {
        const row = pickerRow(list, index);
        const selected = index == state.picker_selected;
        if (selected) drawRect(row, colors.ribbon_dim);
        const entry = state.picker_entries[index];
        drawText(row.x + 8, row.y + 8, if (entry.directory) colors.yellow else colors.white, "{s}{s}", .{ if (entry.directory) "[DIR] " else "", head(entry.slice(), fitChars(row.w - 24) -| 6) });
    }
    if (state.picker_count == 0) drawText(list.x + 12, list.y + 16, colors.dim, "No matching entries in this location.", .{});
    if (state.picker_count == picker_max_entries) drawText(list.x + 12, list.y + list.h - 24, colors.orange, "LIST TRUNCATED", .{});
}

fn pickerAcceptLabel() []const u8 {
    return if (state.picker_kind == .games) "USE THIS FOLDER" else "OPEN SELECTED JSON";
}

fn pickerRow(list: Rect, index: usize) Rect {
    return .{ .x = list.x + 6, .y = list.y + 6 + @as(f32, @floatFromInt(index - state.picker_scroll)) * 36, .w = list.w - 12, .h = 32 };
}

fn openFilePicker(kind: PickerKind) void {
    state.picker_kind = kind;
    state.picker_open = true;
    const owned_start = pickerStartPath(std.heap.c_allocator) catch null;
    defer if (owned_start) |path| std.heap.c_allocator.free(path);
    const start = owned_start orelse ".";
    _ = state.picker_path.set(start);
    refreshPicker();
}

fn pickerStartPath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    return std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME") catch allocator.dupe(u8, ".");
}

fn refreshPicker() void {
    state.picker_count = 0;
    state.picker_scroll = 0;
    state.picker_selected = std.math.maxInt(usize);
    if (state.picker_path.len == 0 and @import("builtin").os.tag == .windows) {
        for ('A'..'Z' + 1) |letter_value| {
            if (state.picker_count == picker_max_entries) break;
            const letter: u8 = @intCast(letter_value);
            var root = [_]u8{ letter, ':', '\\' };
            var dir = std.Io.Dir.cwd().openDir(state.threaded.io(), &root, .{}) catch continue;
            dir.close(state.threaded.io());
            var item = PickerEntry{ .directory = true, .absolute = true };
            if (!item.setName(&root)) continue;
            state.picker_entries[state.picker_count] = item;
            state.picker_count += 1;
        }
        return;
    }
    var dir = std.Io.Dir.cwd().openDir(state.threaded.io(), state.picker_path.slice(), .{ .iterate = true }) catch |err| {
        setStatus(false, "Could not browse folder: {s}.", .{@errorName(err)});
        return;
    };
    defer dir.close(state.threaded.io());
    var iterator = dir.iterate();
    while (iterator.next(state.threaded.io()) catch null) |entry| {
        if (state.picker_count == picker_max_entries) break;
        const kind = if (entry.kind == .unknown) blk: {
            const path = std.fs.path.join(std.heap.c_allocator, &.{ state.picker_path.slice(), entry.name }) catch continue;
            defer std.heap.c_allocator.free(path);
            break :blk (std.Io.Dir.cwd().statFile(state.threaded.io(), path, .{}) catch continue).kind;
        } else entry.kind;
        const directory = kind == .directory;
        if (!directory and (kind != .file or !pickerFileAccepted(entry.name))) continue;
        var item = PickerEntry{ .directory = directory };
        if (!item.setName(entry.name)) continue;
        state.picker_entries[state.picker_count] = item;
        state.picker_count += 1;
    }
    std.mem.sort(PickerEntry, state.picker_entries[0..state.picker_count], {}, pickerEntryLessThan);
}

fn pickerFileAccepted(name: []const u8) bool {
    const expected = if (state.picker_kind == .games) ".lpl" else ".json";
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), expected);
}

fn pickerEntryLessThan(_: void, a: PickerEntry, b: PickerEntry) bool {
    if (a.directory != b.directory) return a.directory;
    return std.ascii.lessThanIgnoreCase(a.slice(), b.slice());
}

fn scrollPicker(delta: f32) void {
    const maximum = state.picker_count -| picker_visible_rows;
    if (delta < 0) state.picker_scroll = @min(maximum, state.picker_scroll + 3);
    if (delta > 0) state.picker_scroll -|= @min(state.picker_scroll, 3);
}

fn handlePickerClick(x: f32, y: f32) void {
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    const panel = pickerPanel(metrics.width, metrics.height);
    if (contains(layout.pickerCancel(panel), x, y)) {
        state.picker_open = false;
        return;
    }
    if (contains(layout.pickerUp(panel), x, y)) {
        pickerGoUp();
        return;
    }
    if (contains(layout.pickerAccept(panel), x, y)) {
        if (state.picker_kind == .games) {
            const selected = if (state.picker_selected < state.picker_count) state.picker_entries[state.picker_selected] else PickerEntry{};
            if (selected.len != 0 and !selected.directory) {
                pickerUseEntry(selected);
            } else pickerChoosePath(state.picker_path.slice());
        } else if (state.picker_selected < state.picker_count and !state.picker_entries[state.picker_selected].directory) {
            pickerUseEntry(state.picker_entries[state.picker_selected]);
        }
        return;
    }
    const list = Rect{ .x = panel.x + 20, .y = panel.y + 140, .w = panel.w - 40, .h = panel.h - 160 };
    if (!contains(list, x, y)) return;
    const row_index: usize = @intFromFloat(@max(0, @floor((y - list.y - 6) / 36)));
    const index = state.picker_scroll + row_index;
    if (index >= state.picker_count) return;
    const entry = state.picker_entries[index];
    if (entry.directory) {
        pickerUseEntry(entry);
    } else if (state.picker_selected == index) {
        pickerUseEntry(entry);
    } else state.picker_selected = index;
}

fn pickerUseEntry(entry: PickerEntry) void {
    const path = if (entry.absolute)
        std.heap.c_allocator.dupe(u8, entry.slice()) catch return
    else
        std.fs.path.join(std.heap.c_allocator, &.{ state.picker_path.slice(), entry.slice() }) catch return;
    defer std.heap.c_allocator.free(path);
    if (entry.directory) {
        _ = state.picker_path.set(path);
        refreshPicker();
    } else pickerChoosePath(path);
}

fn pickerChoosePath(path: []const u8) void {
    state.picker_open = false;
    if (isBusy()) {
        if (!state.pending_drop_path.set(path)) {
            setStatus(false, "Selected path is too long.", .{});
            return;
        }
        state.pending_drop = true;
        setStatus(true, "Selection queued; waiting for current detection to finish...", .{});
    } else handleDropPath(path);
}

fn pickerGoUp() void {
    const current = state.picker_path.slice();
    if (@import("builtin").os.tag == .windows and current.len == 3 and current[1] == ':' and (current[2] == '\\' or current[2] == '/')) {
        state.picker_path.len = 0;
        state.picker_path.buffer[0] = 0;
        refreshPicker();
        return;
    }
    const parent = std.fs.path.dirname(current) orelse {
        if (@import("builtin").os.tag == .windows) {
            state.picker_path.len = 0;
            state.picker_path.buffer[0] = 0;
            refreshPicker();
        }
        return;
    };
    if (parent.len == 0 or std.mem.eql(u8, parent, current)) {
        if (@import("builtin").os.tag == .windows) {
            state.picker_path.len = 0;
            state.picker_path.buffer[0] = 0;
            refreshPicker();
        }
        return;
    }
    state.picker_path.len = parent.len;
    state.picker_path.buffer[parent.len] = 0;
    refreshPicker();
}

fn processPendingDrop() void {
    if (!state.pending_drop or isBusy()) return;
    state.pending_drop = false;
    handleDropPath(state.pending_drop_path.slice());
}

fn handleDropPath(path: []const u8) void {
    if (isArtworkPath(path)) {
        installDroppedArtwork(path);
        return;
    }
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".json")) {
        loadRegistry(path);
        return;
    }
    const kind = classifyDroppedSource(state.threaded.io(), path) catch |err| {
        setStatus(false, "Could not inspect dropped path: {s}.", .{@errorName(err)});
        return;
    } orelse {
        setStatus(false, "Drop a ROM directory or a RetroArch .lpl playlist.", .{});
        return;
    };
    if (!state.dropped_source_path.set(path)) unreachable;
    state.dropped_source_kind = kind;
    state.drop_mode = .games;
    switch (kind) {
        .directory => setStatus(true, "Scanning dropped directory recursively...", .{}),
        .playlist => setStatus(true, "Loading dropped RetroArch playlist...", .{}),
        .automatic => unreachable,
    }
    runSourceRefresh(kind == .directory);
}

fn classifyDroppedSource(io: std.Io, path: []const u8) !?SourceKind {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind == .directory) return .directory;
    if (stat.kind == .file and std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".lpl")) return .playlist;
    return null;
}

fn isArtworkPath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for ([_][]const u8{ ".bmp", ".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff" }) |candidate| if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    return false;
}

fn installDroppedArtwork(path: []const u8) void {
    if (state.artwork_worker != null) {
        setStatus(false, "Wait for the current artwork lookup to finish, then retry.", .{});
        return;
    }
    const allocator = std.heap.c_allocator;
    var decoded = importer.decodeArtwork(allocator, state.threaded.io(), path) catch |err| {
        setStatus(false, "Could not decode dropped artwork: {s}.", .{@errorName(err)});
        return;
    };
    decoded.deinit(allocator);
    const cache = artworkCachePath(allocator) catch return;
    defer allocator.free(cache);
    if (state.mod_browser_open and state.selected_mod != 0) {
        const data = selectedModBrowserData() orelse return;
        if (state.selected_mod <= data.local_count) {
            setStatus(false, "Revision artwork uses the base game's selected artwork.", .{});
            return;
        }
        const registry_index = data.matches[state.selected_mod - 1 - data.local_count];
        const entry = data.catalog.?.entries()[registry_index];
        const selection = launchbox.installCustomArtwork(allocator, state.threaded.io(), path, entry.id, cache) catch |err| {
            setStatus(false, "Could not use dropped artwork: {s}.", .{@errorName(err)});
            return;
        };
        harvestModArtwork(.{ .registry_index = registry_index, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count });
        setStatus(true, "Set dropped artwork for {s}.", .{entry.name});
        return;
    }
    const scan = if (state.scan) |*value| value else return;
    const titles = scan.previewMut().titles;
    if (titles.len == 0 or state.preview_scroll >= titles.len) return;
    const title = &titles[state.preview_scroll];
    const key = std.fmt.bytesToHex(title.content_hash, .lower);
    const selection = launchbox.installCustomArtwork(allocator, state.threaded.io(), path, &key, cache) catch |err| {
        setStatus(false, "Could not use dropped artwork: {s}.", .{@errorName(err)});
        return;
    };
    defer allocator.free(selection.path);
    const replacement = allocator.dupe(u8, selection.path) catch return;
    if (title.artwork_path) |old_path| allocator.free(old_path);
    title.artwork_path = replacement;
    title.artwork_status = .downloaded;
    title.artwork_options = selection.count;
    for (&state.artwork_textures) |*texture| if (texture.title_index == state.preview_scroll) destroyArtworkTexture(texture);
    setStatus(true, "Set dropped artwork for {s}; it will be included in the next sync.", .{title.display_name});
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
    state.mod_browser_open = false;
    clearModArtworkSlots();
    state.drop_mode = .games;
    setStatus(true, "Loaded {d} mod catalog entries. Use ADD GAMES or drop another folder to continue.", .{parsed.entries().len});
}

fn scrollTitles(delta: f32) void {
    const scan = state.scan orelse return;
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    const metrics = currentGridLayout();
    if (delta < 0) state.preview_scroll = @min(titles.len - 1, state.preview_scroll + metrics.columns);
    if (delta > 0) state.preview_scroll -|= @min(state.preview_scroll, metrics.columns);
}

fn moveTitleSelection(delta: isize) void {
    const scan = state.scan orelse return;
    const titles = scan.preview().titles;
    if (titles.len == 0) return;
    const current: isize = @intCast(state.preview_scroll);
    state.preview_scroll = @intCast(std.math.clamp(current + delta, 0, @as(isize, @intCast(titles.len - 1))));
    state.selected_mod = 0;
    state.mod_browser_open = false;
    clearModArtworkSlots();
}

fn currentGridLayout() grid.Layout {
    const metrics = ui_scale.metrics(sapp.widthf(), sapp.heightf());
    return grid.layout(page_layout.gridWidth(metrics.width), metrics.height - page_layout.grid_y - 36);
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

fn runSourceRefresh(merge_existing: bool) void {
    if (isBusy()) return;
    const config = DiscoveryConfig{
        .source_kind = state.dropped_source_kind,
        .source_path = state.dropped_source_path,
        .discover_destinations = false,
        .merge_existing = merge_existing,
    };
    clearProgressiveScan();
    if (merge_existing) if (state.scan) |scan| {
        state.progressive_base = importer.cloneScanResult(std.heap.c_allocator, scan.preview().titles) catch null;
    };
    if (!beginWorker()) return;
    state.worker = std.Thread.spawn(.{}, refreshWorker, .{config}) catch |err| {
        cancelWorker();
        setStatus(false, "Could not start import: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Importing dropped game source recursively...", .{});
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

fn artworkDiscoverAndAdvanceWorker(config: ArtworkDownloadConfig) void {
    finishWorker(.{ .artwork_download = downloadArtworkResult(config) });
}

fn downloadArtworkResult(config: ArtworkDownloadConfig) ArtworkDownloadResult {
    const allocator = std.heap.c_allocator;
    const cache = artworkCachePath(allocator) catch |err| {
        return .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) };
    };
    defer allocator.free(cache);
    const key = std.fmt.bytesToHex(config.content_hash, .lower);
    const existing = launchbox.cachedSelection(allocator, state.threaded.io(), &key, cache) catch null;
    defer if (existing) |selection| allocator.free(selection.path);
    if (existing == null) if (importer.findRetroArchArtwork(allocator, state.threaded.io(), state.threaded.environ.process_environ, config.display_name.slice()) catch null) |retro_path| {
        defer allocator.free(retro_path);
        const selection = launchbox.seedArtwork(allocator, state.threaded.io(), retro_path, &key, cache) catch |err| {
            return .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) };
        };
        allocator.free(selection.path);
    };
    var selection = launchbox.downloadArtwork(allocator, state.threaded.io(), config.display_name.slice(), &key, cache) catch |err| {
        return .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) };
    };
    if (config.advance_after_discovery and selection.count > 1) {
        allocator.free(selection.path);
        selection = launchbox.cycleArtwork(allocator, state.threaded.io(), &key, cache) catch |err| {
            return .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) };
        };
    }
    return .{ .title_index = config.title_index, .content_hash = config.content_hash, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count };
}

fn artworkCycleWorker(config: ArtworkDownloadConfig) void {
    const allocator = std.heap.c_allocator;
    const cache = artworkCachePath(allocator) catch |err| {
        finishWorker(.{ .artwork_download = .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) } });
        return;
    };
    defer allocator.free(cache);
    const key = std.fmt.bytesToHex(config.content_hash, .lower);
    const selection = launchbox.cycleArtwork(allocator, state.threaded.io(), &key, cache) catch |err| {
        finishWorker(.{ .artwork_download = .{ .title_index = config.title_index, .content_hash = config.content_hash, .err = @errorName(err) } });
        return;
    };
    finishWorker(.{ .artwork_download = .{ .title_index = config.title_index, .content_hash = config.content_hash, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count } });
}

fn syncModArtwork(registry_index: usize) void {
    var empty: ?*ModArtworkSlot = null;
    for (&state.mod_artwork_slots) |*slot| {
        if (slot.registry_index == registry_index) return;
        if (slot.registry_index == std.math.maxInt(usize) and empty == null) empty = slot;
    }
    const slot = empty orelse return;
    slot.registry_index = registry_index;
    if (isBusy()) {
        slot.registry_index = std.math.maxInt(usize);
        return;
    }
    if (!beginWorker()) {
        slot.registry_index = std.math.maxInt(usize);
        return;
    }
    slot.loading = true;
    state.worker = std.Thread.spawn(.{}, modArtworkWorker, .{registry_index}) catch {
        slot.* = .{};
        cancelWorker();
        return;
    };
}

fn handleModBrowserClick(width: f32, height: f32, x: f32, y: f32) void {
    if (contains(layout.modBack(width), x, y)) {
        state.mod_browser_open = false;
        return;
    }
    const selected = selectedModBrowserData() orelse return;
    const cards = selected.count + 1;
    const area = Rect{ .x = 44, .y = page_layout.versions_grid_y, .w = width - 88, .h = height - page_layout.versions_grid_y - 130 };
    const columns = std.math.clamp(@as(usize, @intFromFloat(@ceil((area.w + 16) / 220))), 2, 5);
    const gutter: f32 = 16;
    const card_width = (area.w - gutter * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    const card_height = @min(220, card_width * 0.72);
    for (0..cards) |card_index| {
        const row = card_index / columns;
        const column = card_index % columns;
        const rect = Rect{
            .x = area.x + @as(f32, @floatFromInt(column)) * (card_width + gutter),
            .y = area.y + @as(f32, @floatFromInt(row)) * (card_height + gutter),
            .w = card_width,
            .h = card_height,
        };
        if (contains(rect, x, y)) {
            state.selected_mod = card_index;
            return;
        }
    }
    if (state.selected_mod == 0) return;
    if (state.selected_mod <= selected.local_count) return;
    if (contains(layout.modPrimary(height), x, y)) {
        downloadRegistryIndex(selected.matches[state.selected_mod - 1 - selected.local_count]);
    } else if (contains(layout.modSecondary(height), x, y)) {
        const registry_index = selected.matches[state.selected_mod - 1 - selected.local_count];
        const slot = modArtworkSlot(registry_index);
        if (slot != null and slot.?.gallery_count > 1) {
            cycleModArtwork(registry_index);
        } else openRegistryEntryPage(selected.catalog.?.entries()[registry_index]);
    } else if (contains(layout.modTertiary(height), x, y)) {
        const registry_index = selected.matches[state.selected_mod - 1 - selected.local_count];
        const slot = modArtworkSlot(registry_index);
        if (slot != null and slot.?.gallery_count > 1) openRegistryEntryPage(selected.catalog.?.entries()[registry_index]);
    }
}

fn cycleModArtwork(registry_index: usize) void {
    if (!beginWorker()) return;
    state.worker = std.Thread.spawn(.{}, modArtworkCycleWorker, .{registry_index}) catch {
        cancelWorker();
        return;
    };
    setStatus(true, "Switching mod artwork...", .{});
}

fn modArtworkCycleWorker(registry_index: usize) void {
    const allocator = std.heap.c_allocator;
    const catalog = &(state.mod_registry orelse return);
    const cache = artworkCachePath(allocator) catch |err| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
        return;
    };
    defer allocator.free(cache);
    const selection = launchbox.cycleArtwork(allocator, state.threaded.io(), catalog.entries()[registry_index].id, cache) catch |err| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
        return;
    };
    finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count } });
}

fn clearModArtworkSlots() void {
    for (&state.mod_artwork_slots) |*slot| {
        destroyArtworkTexture(&slot.texture);
        slot.* = .{};
    }
}

fn modArtworkWorker(registry_index: usize) void {
    const allocator = std.heap.c_allocator;
    const catalog = &(state.mod_registry orelse {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = "RegistryUnavailable" } });
        return;
    });
    const cache = artworkCachePath(allocator) catch |err| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
        return;
    };
    defer allocator.free(cache);
    const entry = catalog.entries()[registry_index];
    if (launchbox.customArtworkExists(allocator, state.threaded.io(), entry.id, cache)) if (tryCachedModArtwork(allocator, state.threaded.io(), entry.id, cache)) |selection| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count } });
        return;
    };
    if (entry.artwork) |_| {
        const registry_cache = registryCachePath(allocator) catch |err| {
            finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
            return;
        };
        defer allocator.free(registry_cache);
        const path = (registry.downloadArtwork(allocator, state.threaded.io(), entry, registry_cache) catch |err| {
            finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
            return;
        }) orelse return;
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .path = path } });
        return;
    }
    if (tryCachedModArtwork(allocator, state.threaded.io(), entry.id, cache)) |selection| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count } });
        return;
    }
    const selection = launchbox.downloadArtwork(allocator, state.threaded.io(), entry.name, entry.id, cache) catch |err| {
        finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .err = @errorName(err) } });
        return;
    };
    finishWorker(.{ .mod_artwork = .{ .registry_index = registry_index, .path = selection.path, .gallery_index = selection.index, .gallery_count = selection.count } });
}

fn tryCachedModArtwork(allocator: std.mem.Allocator, io: std.Io, key: []const u8, cache: []const u8) ?launchbox.GallerySelection {
    return launchbox.cachedSelection(allocator, io, key, cache) catch null;
}

fn registryCachePath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "m64menu", "patches" });
}

fn artworkCachePath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "m64menu", "artwork" });
}

/// Card writes are slow in ways throughput alone does not explain, so each
/// file's filesystem phases are recorded and flushed to a log the user can read
/// after a sync, successful or not.
const sync_log = struct {
    var buffer: [128 * 1024]u8 = @splat(0);
    var len: usize = 0;
    var truncated = false;

    fn reset() void {
        len = 0;
        truncated = false;
    }

    fn append(comptime format: []const u8, args: anytype) void {
        if (truncated) return;
        const written = std.fmt.bufPrint(buffer[len..], format, args) catch {
            truncated = true;
            return;
        };
        len += written.len;
    }

    fn slice() []const u8 {
        return buffer[0..len];
    }
};

fn microseconds(nanoseconds: u64) u64 {
    return nanoseconds / 1000;
}

fn syncTrace(_: ?*anyopaque, entry: sdcard.TraceEvent) void {
    switch (entry.phase) {
        .begin => sync_log.append("BEGIN {s}\n", .{entry.path}),
        .done => sync_log.append(
            "DONE  {s} bytes={d} total={d}us mkdir={d}us open={d}us write={d}us commit={d}us\n",
            .{
                entry.path,
                entry.bytes,
                microseconds(entry.total_ns),
                microseconds(entry.mkdir_ns),
                microseconds(entry.open_ns),
                microseconds(entry.write_ns),
                microseconds(entry.commit_ns),
            },
        ),
    }
}

fn syncLogPath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "m64menu", "sd-sync.log" });
}

fn writeSyncLog(allocator: std.mem.Allocator, io: std.Io, failure: ?[]const u8) ?[]u8 {
    if (failure) |name| sync_log.append("FAILED {s}\n", .{name});
    if (sync_log.truncated) sync_log.append("(log truncated)\n", .{});
    const path = syncLogPath(allocator) catch return null;
    if (std.fs.path.dirname(path)) |parent| std.Io.Dir.cwd().createDirPath(io, parent) catch {
        allocator.free(path);
        return null;
    };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = sync_log.slice() }) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn cartLibraryCachePath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "m64menu", "cart-library" });
}

fn mirrorConnectedCart(
    allocator: std.mem.Allocator,
    io: std.Io,
    card: ?CardSnapshot,
    device: ?DeviceSnapshot,
) !?[]u8 {
    const cache = try cartLibraryCachePath(allocator);
    defer allocator.free(cache);
    try std.Io.Dir.cwd().createDirPath(io, cache);
    var card_error: ?anyerror = null;
    if (card) |mounted| {
        if (mirrorMountedCart(allocator, io, cache, mounted)) |playlist| return playlist else |err| card_error = err;
    }
    if (device) |usb| if (usb.power == .off and usb.library != null) {
        return try mirrorUsbCart(allocator, io, cache, usb);
    };
    if (card_error) |err| return err;
    return null;
}

fn mirrorMountedCart(allocator: std.mem.Allocator, io: std.Io, cache: []const u8, mounted: CardSnapshot) ![]u8 {
    const library = mounted.library orelse return error.CartLibraryUnavailable;
    if (library.titles.len == 0) return error.NoRomsFound;
    const source_root = try std.fs.path.join(allocator, &.{ cache, "mounted-sd" });
    defer allocator.free(source_root);
    const playlist = try std.fs.path.join(allocator, &.{ source_root, expected_playlist_name });
    errdefer allocator.free(playlist);
    const boxarts = try std.fs.path.join(allocator, &.{ source_root, "thumbnails", "Nintendo - Nintendo 64", "Named_Boxarts" });
    defer allocator.free(boxarts);
    try std.Io.Dir.cwd().createDirPath(io, boxarts);
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    for (library.titles) |title| {
        const id = title.idSlice();
        const filename = try std.fmt.allocPrint(allocator, "{s}_e.z64", .{id});
        defer allocator.free(filename);
        const rom = try std.fs.path.join(allocator, &.{ mounted.root, "menu", "title", id, filename });
        defer allocator.free(rom);
        if (!usableRomFile(io, rom)) return error.IncompleteCartLibrary;
        try appendPlaylistEntry(allocator, &contents, rom, title.name);
        const sprite_name = try std.fmt.allocPrint(allocator, "{s}_e.sprite", .{id});
        defer allocator.free(sprite_name);
        const sprite = try std.fs.path.join(allocator, &.{ mounted.root, "menu", "title", id, sprite_name });
        defer allocator.free(sprite);
        try cacheInstalledArtwork(allocator, io, sprite, boxarts, title.name);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = playlist, .data = contents.items });
    return playlist;
}

fn mirrorUsbCart(allocator: std.mem.Allocator, io: std.Io, cache: []const u8, usb: DeviceSnapshot) ![]u8 {
    const library = usb.library orelse return error.CartLibraryUnavailable;
    if (library.titles.len == 0) return error.NoRomsFound;
    const serial = try safePathComponent(allocator, usb.serial);
    defer allocator.free(serial);
    const source_root = try std.fs.path.join(allocator, &.{ cache, serial });
    defer allocator.free(source_root);
    const rom_root = try std.fs.path.join(allocator, &.{ source_root, "roms" });
    defer allocator.free(rom_root);
    const boxarts = try std.fs.path.join(allocator, &.{ source_root, "thumbnails", "Nintendo - Nintendo 64", "Named_Boxarts" });
    defer allocator.free(boxarts);
    const playlist = try std.fs.path.join(allocator, &.{ source_root, expected_playlist_name });
    errdefer allocator.free(playlist);
    try std.Io.Dir.cwd().createDirPath(io, rom_root);
    try std.Io.Dir.cwd().createDirPath(io, boxarts);
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    for (library.titles) |title| {
        const id = title.idSlice();
        const filename = try std.fmt.allocPrint(allocator, "{s}.z64", .{id});
        defer allocator.free(filename);
        const local = try std.fs.path.join(allocator, &.{ rom_root, filename });
        defer allocator.free(local);
        if (!usableRomFile(io, local)) {
            std.Io.Dir.cwd().deleteFile(io, local) catch {};
            const remote = try std.fmt.allocPrint(allocator, "/menu/title/{s}/{s}_e.z64", .{ id, id });
            defer allocator.free(remote);
            try downloadCartFileAtomic(allocator, io, usb, remote, local);
        }
        if (!usableRomFile(io, local)) return error.IncompleteCartLibrary;
        try appendPlaylistEntry(allocator, &contents, local, title.name);
        const sprite_name = try std.fmt.allocPrint(allocator, "{s}.sprite", .{id});
        defer allocator.free(sprite_name);
        const sprite = try std.fs.path.join(allocator, &.{ rom_root, sprite_name });
        defer allocator.free(sprite);
        const remote_sprite = try std.fmt.allocPrint(allocator, "/menu/title/{s}/{s}_e.sprite", .{ id, id });
        defer allocator.free(remote_sprite);
        downloadCartFileAtomic(allocator, io, usb, remote_sprite, sprite) catch {};
        try cacheInstalledArtwork(allocator, io, sprite, boxarts, title.name);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = playlist, .data = contents.items });
    return playlist;
}

fn downloadCartFileAtomic(allocator: std.mem.Allocator, io: std.Io, usb: DeviceSnapshot, remote: []const u8, local: []const u8) !void {
    var random: [8]u8 = undefined;
    io.random(&random);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}.download", .{ local, std.fmt.bytesToHex(random, .lower) });
    defer allocator.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try deployer.downloadFile(allocator, io, usb.deployer_path, usb.port, remote, temporary);
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), local, io);
}

fn cacheInstalledArtwork(allocator: std.mem.Allocator, io: std.Io, sprite: []const u8, boxarts: []const u8, title: []const u8) !void {
    if (!fileExists(io, sprite)) return;
    const safe_name = try importer.retroArchThumbnailName(allocator, title);
    defer allocator.free(safe_name);
    const filename = try std.fmt.allocPrint(allocator, "{s}.bmp", .{safe_name});
    defer allocator.free(filename);
    const destination = try std.fs.path.join(allocator, &.{ boxarts, filename });
    defer allocator.free(destination);
    importer.convertMenuSpriteToBmp(allocator, io, sprite, destination) catch {};
}

fn appendPlaylistEntry(allocator: std.mem.Allocator, output: *std.ArrayList(u8), rom_path: []const u8, title: []const u8) !void {
    try output.appendSlice(allocator, rom_path);
    try output.append(allocator, '\n');
    for (title) |byte| try output.append(allocator, if (byte == '\r' or byte == '\n') ' ' else byte);
    try output.appendSlice(allocator, "\nDETECT\nDETECT\nDETECT\nNintendo - Nintendo 64.lpl\n");
}

fn safePathComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, @max(value.len, 1));
    if (value.len == 0) {
        result[0] = '_';
        return result;
    }
    for (value, 0..) |byte, index| result[index] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') byte else '_';
    return result;
}

fn usableRomFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.size >= 4 and stat.size <= importer.maximum_rom_size;
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
    if (selectedTitleCount() == 0) {
        setStatus(false, "Sync refused: no games are selected. Press SPACE on a game to select it.", .{});
        return;
    }

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
    config.selection = selectionForCurrentLibrary(std.heap.c_allocator) catch {
        cancelWorker();
        setStatus(false, "Sync refused: the selection could not be captured.", .{});
        return;
    };
    state.worker = std.Thread.spawn(.{}, syncWorker, .{config}) catch |err| {
        std.heap.c_allocator.free(config.selection);
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
    result.destinations_discovered = config.discover_destinations;
    result.merge_existing = config.merge_existing;
    const artwork_cache = artworkCachePath(allocator) catch null;
    defer if (artwork_cache) |path| allocator.free(path);

    if (config.discover_destinations) {
        var card_outcome = discoverCard(allocator, io);
        result.card = card_outcome.card;
        result.card_error = card_outcome.err;
        card_outcome.card = null;
        var device_outcome = discoverDevice(allocator, io);
        result.device = device_outcome.device;
        result.device_error = device_outcome.err;
        device_outcome.device = null;
    }

    result.scan = switch (config.source_kind) {
        .directory => directory: {
            const root = config.source_path.slice();
            const preview = importer.scanLibrary(allocator, io, .{ .rom_root = root, .recursive = true, .artwork_cache_root = artwork_cache, .preview_progress = .{ .callback = scanPreviewProgress } }) catch |err| {
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
            if (config.source_kind == .playlist and config.source_path.len != 0) {
                const override_path = config.source_path.slice();
                const exact = importer.scanRetroArchPlaylistPath(allocator, io, override_path, .{
                    .environ = state.threaded.environ.process_environ,
                    .artwork_cache_root = artwork_cache,
                    .preview_progress = .{ .callback = scanPreviewProgress },
                }) catch |err| {
                    result.scan_error = @errorName(err);
                    result.override_target_blocked = true;
                    break :retroarch null;
                };
                result.source_kind = .playlist;
                break :retroarch LibraryScan{ .retroarch = exact };
            }
            if (config.source_kind == .automatic) {
                const cart_playlist = mirrorConnectedCart(allocator, io, result.card, result.device) catch |err| blk: {
                    result.scan_error = @errorName(err);
                    break :blk null;
                };
                if (cart_playlist) |playlist_path| {
                    defer allocator.free(playlist_path);
                    const parent = std.fs.path.dirname(playlist_path) orelse break :retroarch null;
                    const roots = [_][]const u8{parent};
                    const detected = importer.scanRetroArchLibrary(allocator, io, .{
                        .search_roots = &roots,
                        .maximum_search_depth = 0,
                        .environ = state.threaded.environ.process_environ,
                        .artwork_cache_root = artwork_cache,
                        .preview_progress = .{ .callback = scanPreviewProgress },
                    }) catch null;
                    if (detected) |scan| {
                        result.source_kind = .playlist;
                        break :retroarch LibraryScan{ .retroarch = scan };
                    }
                }
            }
            const detected = importer.scanRetroArchLibrary(allocator, io, .{ .environ = state.threaded.environ.process_environ, .artwork_cache_root = artwork_cache, .preview_progress = .{ .callback = scanPreviewProgress } }) catch |auto_err| fallback: {
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
                    .artwork_cache_root = artwork_cache,
                    .preview_progress = .{ .callback = scanPreviewProgress },
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
    if (result.scan) |*scan| if (artwork_cache) |cache| seedLocalArtwork(allocator, io, scan.previewMut().titles, cache);
    finishWorker(.{ .refresh = result });
}

fn seedLocalArtwork(allocator: std.mem.Allocator, io: std.Io, titles: []importer.Title, cache: []const u8) void {
    for (titles) |*title| {
        const source = title.artwork_path orelse continue;
        if (title.artwork_status == .downloaded) continue;
        const key = std.fmt.bytesToHex(title.content_hash, .lower);
        const selection = launchbox.seedArtwork(allocator, io, source, &key, cache) catch continue;
        defer allocator.free(selection.path);
        const replacement = allocator.dupe(u8, selection.path) catch continue;
        allocator.free(source);
        title.artwork_path = replacement;
        title.artwork_status = .downloaded;
        title.artwork_options = selection.count;
    }
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
    defer allocator.free(config.selection);
    const io = state.threaded.io();
    var result = SyncResult{ .destination = config.destination };
    sync_log.reset();

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
    if (config.destination == .direct_sd) {
        if (writeSyncLog(allocator, io, result.err)) |path| {
            allocator.free(path);
            result.logged = true;
        }
    }
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
    const artwork_cache = try artworkCachePath(allocator);
    defer allocator.free(artwork_cache);
    var imported_titles: []const importer.Title = &.{};
    switch (config.source_kind) {
        .directory => {
            var imported = try importer.importLibrary(allocator, io, .{
                .output_root = staging,
                .rom_root = config.source_path.slice(),
                .recursive = true,
                .artwork_cache_root = artwork_cache,
                .selection = config.selection,
            }, .{ .context = null, .callback = importProgress });
            defer imported.deinit(allocator);
            if (!std.mem.eql(u8, &libraryFingerprint(imported.titles), &config.source_fingerprint)) return error.SourceChanged;
            imported_titles = imported.titles;
            try stageCachedMods(allocator, io, staging, imported_titles, config.selection);
        },
        .automatic, .playlist => {
            const playlist_path = config.source_path.slice();
            var imported = try importer.importRetroArchPlaylistPath(allocator, io, staging, playlist_path, .{
                .environ = state.threaded.environ.process_environ,
                .artwork_cache_root = artwork_cache,
                .selection = config.selection,
            }, .{ .context = null, .callback = importProgress });
            defer imported.deinit(allocator);
            if (!std.mem.eql(u8, &libraryFingerprint(imported.preview.titles), &config.source_fingerprint)) return error.SourceChanged;
            imported_titles = imported.preview.titles;
            try stageCachedMods(allocator, io, staging, imported_titles, config.selection);
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
            }, .{ .context = null, .callback = syncTrace });
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

fn stageCachedMods(allocator: std.mem.Allocator, io: std.Io, staging: []const u8, titles: []const importer.Title, selection: []const sel.Key) !void {
    const revisions = try importer.stageLocalRevisions(allocator, io, staging, titles, selection);
    const catalog = &(state.mod_registry orelse return);
    const cache = try registryCachePath(allocator);
    defer allocator.free(cache);
    const artwork_cache = try artworkCachePath(allocator);
    defer allocator.free(artwork_cache);
    const count = try importer.stageCachedVariants(allocator, io, staging, titles, catalog, cache, artwork_cache, selection);
    if (count + revisions != 0) setStatus(true, "Staged {d} alternate version(s).", .{count + revisions});
}

fn findMenuRom(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const candidates = [_][]const []const u8{
        &.{ executable_dir, "sc64menu.n64" },
        // Native menu builds land here. Prefer it to the legacy repository-root
        // copy, which may be stale after `zig build menu`.
        &.{ executable_dir, "..", "..", "..", "..", "zig-out", "bin", "sc64menu.n64" },
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

fn aggregateLibraryPath(allocator: std.mem.Allocator) ![]u8 {
    const environ = state.threaded.environ.process_environ;
    const root = std.process.Environ.getAlloc(environ, allocator, if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME") catch
        std.process.Environ.getAlloc(environ, allocator, "HOME") catch
        try allocator.dupe(u8, ".");
    defer allocator.free(root);
    const directory = try std.fs.path.join(allocator, &.{ root, "m64menu", "aggregate-library" });
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(state.threaded.io(), directory);
    return std.fs.path.join(allocator, &.{ directory, expected_playlist_name });
}

fn writeAggregatePlaylist(allocator: std.mem.Allocator, titles: []const importer.Title) ![]u8 {
    const path = try aggregateLibraryPath(allocator);
    errdefer allocator.free(path);
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    for (titles) |title| {
        try appendPlaylistEntry(allocator, &contents, title.rom_path, title.display_name);
        for (title.local_revisions) |revision| try appendPlaylistEntry(allocator, &contents, revision.rom_path, revision.name);
    }
    try std.Io.Dir.cwd().writeFile(state.threaded.io(), .{ .sub_path = path, .data = contents.items });
    return path;
}

fn scanPreviewProgress(_: ?*anyopaque, progress_event: importer.ScanProgressEvent) void {
    if (progress_event.completed != progress_event.total and progress_event.completed % 4 != 0) return;
    const snapshot = if (state.progressive_base) |base|
        importer.mergeScanResults(std.heap.c_allocator, base.titles, progress_event.titles) catch return
    else
        importer.cloneScanResult(std.heap.c_allocator, progress_event.titles) catch return;
    lockWorker();
    if (state.worker_done) {
        unlockWorker();
        var discarded = snapshot;
        discarded.deinit(std.heap.c_allocator);
        return;
    }
    if (state.progressive_scan) |*previous| previous.deinit(std.heap.c_allocator);
    state.progressive_scan = snapshot;
    state.progressive_completed = progress_event.completed;
    state.progressive_total = progress_event.total;
    unlockWorker();
}

fn harvestProgressiveScan() void {
    lockWorker();
    var snapshot = state.progressive_scan;
    if (snapshot == null) {
        unlockWorker();
        return;
    }
    state.progressive_scan = null;
    const completed = state.progressive_completed;
    const total = state.progressive_total;
    unlockWorker();

    clearArtworkTextures();
    if (state.scan) |*scan| {
        switch (scan.*) {
            .retroarch => |*retroarch| {
                retroarch.preview.deinit(std.heap.c_allocator);
                retroarch.preview = snapshot.?;
            },
            .directory => |*directory| {
                directory.preview.deinit(std.heap.c_allocator);
                directory.preview = snapshot.?;
            },
            .aggregate => |*aggregate| {
                aggregate.preview.deinit(std.heap.c_allocator);
                aggregate.preview = snapshot.?;
            },
        }
    } else {
        const root = std.heap.c_allocator.dupe(u8, state.dropped_source_path.slice()) catch {
            snapshot.?.deinit(std.heap.c_allocator);
            return;
        };
        state.scan = .{ .directory = .{ .root = root, .preview = snapshot.? } };
    }
    const count = state.scan.?.preview().titles.len;
    if (count != 0) state.preview_scroll = @min(state.preview_scroll, count - 1);
    setStatus(true, "Found {d} game(s); scanning {d}/{d}...", .{ count, completed, total });
}

fn clearProgressiveScan() void {
    lockWorker();
    defer unlockWorker();
    if (state.progressive_scan) |*scan| scan.deinit(std.heap.c_allocator);
    state.progressive_scan = null;
    if (state.progressive_base) |*scan| scan.deinit(std.heap.c_allocator);
    state.progressive_base = null;
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
    if (state.progressive_scan) |*scan| scan.deinit(std.heap.c_allocator);
    state.progressive_scan = null;
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
        .mod_artwork => |artwork_result| harvestModArtwork(artwork_result),
        .artwork_download => |artwork_result| harvestArtworkDownload(artwork_result),
    }
}

fn harvestArtworkDownload(result: ArtworkDownloadResult) void {
    state.artwork_fetch_index = std.math.maxInt(usize);
    defer if (result.path) |path| std.heap.c_allocator.free(path);
    if (result.err) |name| {
        rememberArtworkFailure(result.content_hash);
        setStatus(false, "Automatic artwork lookup failed: {s}.", .{name});
        return;
    }
    const path = result.path orelse return;
    const scan = if (state.scan) |*value| value else return;
    const titles = scan.previewMut().titles;
    if (result.title_index >= titles.len or !std.mem.eql(u8, &titles[result.title_index].content_hash, &result.content_hash)) return;
    const title = &titles[result.title_index];
    const replacement = std.heap.c_allocator.dupe(u8, path) catch return;
    if (title.artwork_path) |old_path| std.heap.c_allocator.free(old_path);
    title.artwork_path = replacement;
    title.artwork_status = .downloaded;
    title.artwork_options = result.gallery_count;
    for (&state.artwork_textures) |*texture| if (texture.title_index == result.title_index) destroyArtworkTexture(texture);
    setStatus(true, "Using artwork {d}/{d} for {s}. It will be included in the next sync.", .{ result.gallery_index + 1, @max(result.gallery_count, 1), title.display_name });
}

fn harvestModArtwork(result: ModArtworkResult) void {
    defer if (result.path) |path| std.heap.c_allocator.free(path);
    var slot: ?*ModArtworkSlot = null;
    for (&state.mod_artwork_slots) |*candidate| if (candidate.registry_index == result.registry_index) {
        slot = candidate;
        break;
    };
    const artwork_slot = slot orelse return;
    artwork_slot.loading = false;
    if (result.err != null) {
        artwork_slot.failed = true;
        return;
    }
    artwork_slot.gallery_index = result.gallery_index;
    artwork_slot.gallery_count = result.gallery_count;
    const path = result.path orelse return;
    destroyArtworkTexture(&artwork_slot.texture);
    var decoded = importer.decodeArtwork(std.heap.c_allocator, state.threaded.io(), path) catch return;
    defer decoded.deinit(std.heap.c_allocator);
    var mip_levels: [sg.max_mipmaps]sg.Range = @splat(.{});
    mip_levels[0] = .{ .ptr = decoded.pixels.ptr, .size = decoded.pixels.len };
    const image = sg.makeImage(.{
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .pixel_format = .RGBA8,
        .data = .{ .mip_levels = mip_levels },
        .label = "mod-artwork",
    });
    if (sg.queryImageState(image) != .VALID) return;
    const view = sg.makeView(.{ .texture = .{ .image = image }, .label = "mod-artwork-view" });
    if (sg.queryViewState(view) != .VALID) {
        sg.destroyImage(image);
        return;
    }
    artwork_slot.texture = .{
        .title_index = result.registry_index,
        .image = image,
        .view = view,
        .width = @floatFromInt(decoded.width),
        .height = @floatFromInt(decoded.height),
    };
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
    // The merged library reports itself as a playlist, so the import that
    // produced the new titles decides their default, not the aggregate.
    const incoming_kind = result.source_kind;
    if (result.merge_existing and result.scan == null) {
        if (state.progressive_base) |base| if (state.scan) |*scan| {
            const restored = importer.cloneScanResult(std.heap.c_allocator, base.titles) catch null;
            if (restored) |preview| {
                clearArtworkTextures();
                scan.previewMut().deinit(std.heap.c_allocator);
                scan.previewMut().* = preview;
            }
        };
        clearProgressiveScan();
        state.scan_error = result.scan_error;
        setStatus(false, "Folder import failed; existing library was kept.", .{});
        return;
    }
    if (result.merge_existing and state.progressive_base != null and result.scan != null) {
        var merged = importer.mergeScanResults(std.heap.c_allocator, state.progressive_base.?.titles, result.scan.?.preview().titles) catch null;
        if (merged) |*preview| {
            const playlist = writeAggregatePlaylist(std.heap.c_allocator, preview.titles) catch null;
            if (playlist) |path| {
                clearScan();
                state.scan = .{ .aggregate = .{ .playlist_path = path, .preview = preview.* } };
                merged = null;
                state.active_source_kind = .playlist;
                state.dropped_source_kind = .playlist;
                _ = state.dropped_source_path.set(path);
            }
        }
        if (merged) |*preview| preview.deinit(std.heap.c_allocator);
        result.scan.?.deinit(std.heap.c_allocator);
        result.scan = null;
    } else {
        clearScan();
        state.scan = result.scan;
        result.scan = null;
        state.active_source_kind = result.source_kind;
    }
    clearProgressiveScan();
    if (result.destinations_discovered) {
        clearCard();
        clearDevice();
        state.card = result.card;
        result.card = null;
        state.device = result.device;
        result.device = null;
    }
    state.scan_error = result.scan_error;
    if (result.destinations_discovered) {
        state.card_error = result.card_error;
        state.device_error = result.device_error;
    }
    state.preview_scroll = 0;
    state.mod_browser_open = false;
    clearModArtworkSlots();
    state.preview_destination = if (state.card != null) .direct_sd else .usb;
    seedSelection(incoming_kind);

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
        } else if (result.logged) {
            setStatus(false, "{s} failed: {s}. Details in %LOCALAPPDATA%\\m64menu\\sd-sync.log", .{ destination, name });
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
    return if (state.selected.has(title.content_hash)) .ADD else .SKIP;
}

fn titleSyncStateFor(title: importer.Title, installed_titles: anytype) TitleSyncState {
    const selected = state.selected.has(title.content_hash);
    for (installed_titles) |installed| {
        if (!std.mem.eql(u8, installed.idSlice(), importer.titleIdSlice(&title.id))) continue;
        if (!selected) return .REMOVE;
        // Legacy libraries did not have name sidecars, so the deployer falls back
        // to the ID. Matching IDs still mean the ROM is already installed.
        if (std.mem.eql(u8, installed.name, installed.idSlice()) or asciiNameEqual(installed.name, title.display_name)) return .KEEP;
        return .UPDATE;
    }
    return if (selected) .ADD else .SKIP;
}

fn libraryDiffFor(installed_titles: anytype) UiLibraryDiff {
    var result = UiLibraryDiff{};
    const scan = state.scan orelse return result;
    for (scan.preview().titles) |title| switch (titleSyncStateFor(title, installed_titles)) {
        .ADD => result.add += 1,
        .KEEP => result.keep += 1,
        .UPDATE => result.update += 1,
        .REMOVE => result.remove += 1,
        .SKIP => {},
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

fn installedOnTarget(title: importer.Title) bool {
    if (state.card) |card| if (card.library) |library| {
        for (library.titles) |installed| if (std.mem.eql(u8, installed.idSlice(), importer.titleIdSlice(&title.id))) return true;
    };
    if (state.device) |device| if (device.library) |library| {
        for (library.titles) |installed| if (std.mem.eql(u8, installed.idSlice(), importer.titleIdSlice(&title.id))) return true;
    };
    return false;
}

/// Folder imports are opt in and playlist imports are opt out, so a recursive
/// sweep never silently queues everything it found. Anything already on the cart
/// starts selected so a sync cannot quietly delete it.
fn seedSelection(kind: SourceKind) void {
    const scan = state.scan orelse return;
    const allocator = std.heap.c_allocator;
    const opt_out = kind != .directory;
    for (scan.preview().titles) |title| {
        if (state.known.has(title.content_hash)) continue;
        state.known.select(allocator, title.content_hash) catch return;
        if (opt_out or installedOnTarget(title)) state.selected.select(allocator, title.content_hash) catch return;
    }
}

fn selectedTitleCount() usize {
    const scan = state.scan orelse return 0;
    var count: usize = 0;
    for (scan.preview().titles) |title| {
        if (state.selected.has(title.content_hash)) count += 1;
    }
    return count;
}

fn selectionForCurrentLibrary(allocator: std.mem.Allocator) ![]sel.Key {
    var keys: std.ArrayList(sel.Key) = .empty;
    errdefer keys.deinit(allocator);
    const scan = state.scan orelse return keys.toOwnedSlice(allocator);
    const catalog = if (state.mod_registry) |*value| value else null;
    for (scan.preview().titles) |title| {
        if (!state.selected.has(title.content_hash)) continue;
        try keys.append(allocator, title.content_hash);
        for (title.local_revisions) |revision| {
            if (state.selected.has(revision.content_hash)) try keys.append(allocator, revision.content_hash);
        }
        if (catalog) |value| {
            var matches: [registry.maximum_variants_per_title]usize = undefined;
            const count = @min(importer.matchingRegistryVariants(title, value, &matches), matches.len);
            for (matches[0..count]) |index| {
                const key = sel.modKey(value.entries()[index].id);
                if (state.selected.has(key)) try keys.append(allocator, key);
            }
        }
    }
    return keys.toOwnedSlice(allocator);
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
        .SKIP => colors.dim,
        .REMOVE => colors.bad,
    };
}

fn syncStateDescription(sync_state: TitleSyncState) []const u8 {
    return switch (sync_state) {
        .ADD => "WILL BE ADDED",
        .KEEP => "ALREADY ON CART",
        .UPDATE => "WILL BE UPDATED",
        .SKIP => "NOT SELECTED",
        .REMOVE => "WILL BE REMOVED",
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
        for (title.local_revisions) |revision| {
            hash.update(&revision.content_hash);
            hash.update(revision.name);
            hash.update("\x00");
        }
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
    const width = ui_scale.metrics(sapp.widthf(), sapp.heightf()).width;
    lockWorker();
    defer unlockWorker();
    drawText(44, page_layout.status_y, if (state.status_good) colors.good else colors.bad, "{s}", .{head(state.status[0..state.status_len], fitChars(width - 88))});
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

fn drawButton(rect: Rect, color: Color, label: []const u8, enabled: bool) void {
    const body = Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h - 4 };
    const text_x = rect.x + (rect.w - font.advance(label.len, text_scale)) * 0.5;
    const text_y = body.y + (body.h - text_cell) * 0.5;
    if (!enabled) {
        drawRect(body, colors.inset);
        drawOutline(body, colors.border, 2);
        drawTextSlice(text_x, text_y, text_scale, colors.dim, label);
        return;
    }
    drawPill(rect, color);
    drawTextSlice(text_x, text_y, text_scale, colors.black, label);
}

fn drawPill(rect: Rect, color: Color) void {
    drawRect(.{ .x = rect.x + 2, .y = rect.y + 4, .w = rect.w, .h = rect.h - 4 }, colors.black);
    drawRect(.{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h - 2 }, colors.yellow);
    drawRect(.{ .x = rect.x + 2, .y = rect.y, .w = rect.w - 4, .h = rect.h - 4 }, color);
}

fn drawText(x: f32, y: f32, color: Color, comptime format: []const u8, args: anytype) void {
    var buffer: [768]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    drawTextSlice(x, y, text_scale, color, text);
}

fn drawTextSlice(x: f32, y: f32, scale: f32, color: Color, text: []const u8) void {
    const cell = @as(f32, @floatFromInt(font.cell)) * scale;
    sgl.beginQuads();
    sgl.c3b(color.r, color.g, color.b);
    for (text, 0..) |code, index| {
        const origin_x = x + @as(f32, @floatFromInt(index)) * cell;
        for (font.glyph(code)) |run| {
            const left = origin_x + @as(f32, @floatFromInt(run.x)) * scale;
            const top = y + @as(f32, @floatFromInt(run.y)) * scale;
            const right = left + @as(f32, @floatFromInt(run.width)) * scale;
            const bottom = top + scale;
            sgl.v2f(left, top);
            sgl.v2f(right, top);
            sgl.v2f(right, bottom);
            sgl.v2f(left, bottom);
        }
    }
    sgl.end();
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
        .width = 1440,
        .height = 900,
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
