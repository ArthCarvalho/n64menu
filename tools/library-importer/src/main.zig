const std = @import("std");
const sokol = @import("sokol");
const importer = @import("importer");

const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const sglue = sokol.glue;
const slog = sokol.log;

const Color = struct { r: u8, g: u8, b: u8 };
const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const Field = enum(u8) { output, roms, artwork, retroarch };

const colors = struct {
    const background = Color{ .r = 12, .g = 5, .b = 28 };
    const panel = Color{ .r = 29, .g = 12, .b = 55 };
    const field = Color{ .r = 14, .g = 9, .b = 27 };
    const border = Color{ .r = 91, .g = 54, .b = 129 };
    const pink = Color{ .r = 255, .g = 35, .b = 156 };
    const orange = Color{ .r = 255, .g = 122, .b = 0 };
    const yellow = Color{ .r = 255, .g = 214, .b = 0 };
    const white = Color{ .r = 242, .g = 240, .b = 248 };
    const dim = Color{ .r = 178, .g = 168, .b = 198 };
    const good = Color{ .r = 76, .g = 220, .b = 130 };
    const bad = Color{ .r = 255, .g = 90, .b = 112 };
};

const TextField = struct {
    buffer: [4096]u8 = @splat(0),
    len: usize = 0,

    fn slice(self: *const TextField) []const u8 {
        return self.buffer[0..self.len];
    }

    fn set(self: *TextField, value: []const u8) void {
        self.len = @min(value.len, self.buffer.len - 1);
        @memcpy(self.buffer[0..self.len], value[0..self.len]);
        self.buffer[self.len] = 0;
    }

    fn appendCodepoint(self: *TextField, codepoint: u32) void {
        if (codepoint > std.math.maxInt(u21)) return;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return;
        if (self.len + count >= self.buffer.len) return;
        @memcpy(self.buffer[self.len .. self.len + count], encoded[0..count]);
        self.len += count;
        self.buffer[self.len] = 0;
    }

    fn backspace(self: *TextField) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and (self.buffer[self.len] & 0xC0) == 0x80) self.len -= 1;
        self.buffer[self.len] = 0;
    }
};

const WorkerConfig = struct {
    output: TextField,
    roms: TextField,
    artwork: TextField,
    retroarch: TextField,
    recursive: bool,

    fn importerConfig(self: *const WorkerConfig) importer.Config {
        return .{
            .output_root = self.output.slice(),
            .rom_root = self.roms.slice(),
            .image_root = optionalPath(&self.artwork),
            .retroarch_thumbnail_root = optionalPath(&self.retroarch),
            .recursive = self.recursive,
        };
    }
};

const state = struct {
    var threaded: std.Io.Threaded = undefined;
    var io_ready = false;
    var pass_action: sg.PassAction = .{};
    var output = TextField{};
    var roms = TextField{};
    var artwork = TextField{};
    var retroarch = TextField{};
    var active: Field = .roms;
    var recursive = true;
    var preview: ?importer.ScanResult = null;
    var status: [512]u8 = @splat(0);
    var status_len: usize = 0;
    var status_good = true;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var preview_scroll: usize = 0;
    var worker: ?std.Thread = null;
    var worker_mutex: std.atomic.Mutex = .unlocked;
    var worker_busy = false;
    var worker_done = false;
    var worker_result: ?importer.ScanResult = null;
    var worker_error: ?[]const u8 = null;
};

const layout = struct {
    fn field(index: usize, width: f32) Rect {
        return .{ .x = 44, .y = 136 + @as(f32, @floatFromInt(index)) * 70, .w = width - 88, .h = 40 };
    }
    fn recursive() Rect {
        return .{ .x = 44, .y = 422, .w = 200, .h = 38 };
    }
    fn scan() Rect {
        return .{ .x = 270, .y = 422, .w = 150, .h = 38 };
    }
    fn importButton() Rect {
        return .{ .x = 436, .y = 422, .w = 190, .h = 38 };
    }
};

export fn init() void {
    state.threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
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
    state.output.set(".");
    setStatus(true, "Drop a ROM folder, then scan the library.", .{});
}

export fn cleanup() void {
    if (state.worker) |worker| worker.join();
    clearPreview();
    sdtx.shutdown();
    sgl.shutdown();
    sg.shutdown();
    if (state.io_ready) state.threaded.deinit();
}

export fn frame() void {
    harvestWorker();
    const width = sapp.widthf();
    const height = sapp.heightf();
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.ortho(0, width, height, 0, -1, 1);
    sgl.matrixModeModelview();

    drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = height - 48 }, colors.panel);
    drawRect(.{ .x = 24, .y = 24, .w = width - 48, .h = 6 }, colors.pink);
    drawText(44, 50, colors.yellow, "M64 LIBRARY IMPORTER", .{});
    drawText(44, 78, colors.dim, "ROMs + RetroArch box art -> SummerCart64", .{});

    drawField(.output, 0, "OUTPUT / SD ROOT", width);
    drawField(.roms, 1, "N64 ROM FOLDER", width);
    drawField(.artwork, 2, "OPTIONAL ARTWORK FOLDER", width);
    drawField(.retroarch, 3, "OPTIONAL RETROARCH THUMBNAILS", width);

    drawButton(layout.recursive(), if (state.recursive) colors.pink else colors.border, if (state.recursive) "[x] Recursive" else "[ ] Recursive");
    drawButton(layout.scan(), colors.orange, "SCAN");
    drawButton(layout.importButton(), colors.yellow, if (isBusy()) "IMPORTING..." else "IMPORT TO SD");

    drawStatus();
    drawPreview(width, height);

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sgl.draw();
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

fn drawField(field: Field, index: usize, label: []const u8, width: f32) void {
    const rect = layout.field(index, width);
    drawText(rect.x, rect.y - 22, if (state.active == field) colors.pink else colors.dim, "{s}", .{label});
    drawRect(rect, colors.field);
    drawOutline(rect, if (state.active == field) colors.pink else colors.border, 2);
    const value = fieldPtr(field).slice();
    const visible = if (value.len > 116) value[value.len - 116 ..] else value;
    drawText(rect.x + 12, rect.y + 11, colors.white, "{s}", .{visible});
}

fn drawPreview(width: f32, height: f32) void {
    const top: f32 = 520;
    if (height <= top + 40) return;
    drawText(44, top, colors.white, "PREVIEW", .{});
    if (state.preview) |preview| {
        drawText(138, top, colors.dim, "{d}/{d} titles", .{ preview.titles.len, importer.maximum_titles });
        const rows = @max(@as(usize, 1), @as(usize, @intFromFloat((height - top - 42) / 24)));
        const end = @min(preview.titles.len, state.preview_scroll + rows);
        for (preview.titles[state.preview_scroll..end], 0..) |title, row| {
            const y = top + 32 + @as(f32, @floatFromInt(row)) * 24;
            drawText(44, y, colors.yellow, "{s}", .{title.id});
            drawText(100, y, colors.white, "{s}", .{title.display_name});
            drawText(width - 260, y, if (title.artwork_path == null) colors.orange else colors.good, "{s}", .{@tagName(title.artwork_status)});
        }
    } else {
        drawText(44, top + 32, colors.dim, "No scan yet.", .{});
    }
}

export fn event(event_ptr: [*c]const sapp.Event) void {
    const input = event_ptr.*;
    state.mouse_x = input.mouse_x;
    state.mouse_y = input.mouse_y;
    switch (input.type) {
        .MOUSE_DOWN => if (input.mouse_button == .LEFT) handleClick(input.mouse_x, input.mouse_y),
        .MOUSE_SCROLL => scrollPreview(input.scroll_y),
        .KEY_DOWN => if (!input.key_repeat) handleKey(input),
        .CHAR => if (!isBusy() and input.char_code >= 32 and input.char_code != 127) fieldPtr(state.active).appendCodepoint(input.char_code),
        .FILES_DROPPED => handleDrop(),
        .CLIPBOARD_PASTED => fieldPtr(state.active).set(sapp.getClipboardString()),
        else => {},
    }
}

fn handleClick(x: f32, y: f32) void {
    if (isBusy()) return;
    const width = sapp.widthf();
    for (0..4) |index| if (contains(layout.field(index, width), x, y)) {
        state.active = @enumFromInt(index);
        return;
    };
    if (contains(layout.recursive(), x, y)) state.recursive = !state.recursive else if (contains(layout.scan(), x, y)) runScan() else if (contains(layout.importButton(), x, y)) runImport();
}

fn handleKey(input: sapp.Event) void {
    if (isBusy()) return;
    switch (input.key_code) {
        .TAB => state.active = @enumFromInt((@intFromEnum(state.active) + 1) % 4),
        .BACKSPACE => fieldPtr(state.active).backspace(),
        .V => if ((input.modifiers & (sapp.modifier_ctrl | sapp.modifier_super)) != 0) {
            fieldPtr(state.active).set(sapp.getClipboardString());
        },
        .ENTER => runScan(),
        .ESCAPE => sapp.requestQuit(),
        else => {},
    }
}

fn handleDrop() void {
    if (isBusy()) return;
    if (sapp.getNumDroppedFiles() <= 0) return;
    fieldPtr(state.active).set(sapp.getDroppedFilePath(0));
    setStatus(true, "Assigned dropped path to {s}.", .{@tagName(state.active)});
}

fn scrollPreview(delta: f32) void {
    const preview = state.preview orelse return;
    if (delta < 0 and state.preview_scroll + 1 < preview.titles.len) state.preview_scroll += 1;
    if (delta > 0 and state.preview_scroll > 0) state.preview_scroll -= 1;
}

fn runScan() void {
    if (isBusy()) return;
    clearPreview();
    state.preview_scroll = 0;
    state.preview = importer.scanLibrary(std.heap.c_allocator, state.threaded.io(), config()) catch |err| {
        setStatus(false, "Scan failed: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Found {d} title(s). Review the preview, then import.", .{state.preview.?.titles.len});
}

fn runImport() void {
    if (isBusy()) return;
    clearPreview();
    state.preview_scroll = 0;
    const worker_config = WorkerConfig{
        .output = state.output,
        .roms = state.roms,
        .artwork = state.artwork,
        .retroarch = state.retroarch,
        .recursive = state.recursive,
    };
    lockWorker();
    state.worker_busy = true;
    state.worker_done = false;
    state.worker_error = null;
    unlockWorker();
    state.worker = std.Thread.spawn(.{}, importWorker, .{worker_config}) catch |err| {
        lockWorker();
        state.worker_busy = false;
        unlockWorker();
        setStatus(false, "Could not start import: {s}", .{@errorName(err)});
        return;
    };
    setStatus(true, "Starting import...", .{});
}

fn progress(_: ?*anyopaque, progress_event: importer.ProgressEvent) void {
    lockWorker();
    defer unlockWorker();
    setStatusUnlocked(true, "Importing {d}/{d}: {s}", .{ progress_event.completed, progress_event.total, progress_event.title.display_name });
}

fn importWorker(worker_config: WorkerConfig) void {
    const result = importer.importLibrary(std.heap.c_allocator, state.threaded.io(), worker_config.importerConfig(), .{
        .context = null,
        .callback = progress,
    });
    lockWorker();
    defer unlockWorker();
    if (result) |scan| {
        state.worker_result = scan;
    } else |err| {
        state.worker_error = @errorName(err);
    }
    state.worker_done = true;
}

fn harvestWorker() void {
    lockWorker();
    if (!state.worker_done) {
        unlockWorker();
        return;
    }
    const result = state.worker_result;
    const worker_error = state.worker_error;
    state.worker_result = null;
    state.worker_error = null;
    state.worker_done = false;
    state.worker_busy = false;
    const worker = state.worker;
    state.worker = null;
    unlockWorker();

    if (worker) |thread| thread.join();
    if (result) |scan| {
        state.preview = scan;
        setStatus(true, "Imported {d} title(s) to {s}.", .{ scan.titles.len, state.output.slice() });
    } else if (worker_error) |name| {
        setStatus(false, "Import failed: {s}", .{name});
    }
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

fn drawStatus() void {
    lockWorker();
    defer unlockWorker();
    const status_color = if (state.status_good) colors.good else colors.bad;
    drawText(44, 482, status_color, "{s}", .{state.status[0..state.status_len]});
}

fn config() importer.Config {
    return .{
        .output_root = state.output.slice(),
        .rom_root = state.roms.slice(),
        .image_root = optionalPath(&state.artwork),
        .retroarch_thumbnail_root = optionalPath(&state.retroarch),
        .recursive = state.recursive,
    };
}

fn optionalPath(field: *const TextField) ?[]const u8 {
    return if (field.len == 0) null else field.slice();
}

fn clearPreview() void {
    if (state.preview) |*preview| preview.deinit(std.heap.c_allocator);
    state.preview = null;
}

fn fieldPtr(field: Field) *TextField {
    return switch (field) {
        .output => &state.output,
        .roms => &state.roms,
        .artwork => &state.artwork,
        .retroarch => &state.retroarch,
    };
}

fn setStatus(good: bool, comptime format: []const u8, args: anytype) void {
    lockWorker();
    defer unlockWorker();
    setStatusUnlocked(good, format, args);
}

fn setStatusUnlocked(good: bool, comptime format: []const u8, args: anytype) void {
    state.status_good = good;
    const rendered = std.fmt.bufPrint(&state.status, format, args) catch "Status message too long";
    state.status_len = rendered.len;
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
    sdtx.canvas(sapp.widthf(), sapp.heightf());
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
        .height = 760,
        .sample_count = 4,
        .high_dpi = true,
        .enable_clipboard = true,
        .clipboard_size = 8192,
        .enable_dragndrop = true,
        .max_dropped_files = 8,
        .max_dropped_file_path_length = 4096,
        .icon = .{ .sokol_default = true },
        .window_title = "m64menu Library Importer",
        .logger = .{ .func = slog.func },
        .win32 = .{ .console_attach = true },
    });
}
