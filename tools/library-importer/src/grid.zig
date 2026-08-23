const std = @import("std");

pub const columns: usize = 4;
pub const source_width: f32 = 256;
pub const source_height: f32 = 179;
pub const reference_card_width: f32 = 124;
pub const reference_gutter: f32 = 16;

pub const Layout = struct {
    card_width: f32,
    card_height: f32,
    gutter: f32,
    visible_rows: usize,
};

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn layout(area_width: f32, area_height: f32) Layout {
    const gutter_ratio = reference_gutter / reference_card_width;
    const card_width = area_width / (@as(f32, @floatFromInt(columns)) + @as(f32, @floatFromInt(columns - 1)) * gutter_ratio);
    const gutter = card_width * gutter_ratio;
    const card_height = card_width * source_height / source_width;
    const rows = @min(4, @max(1, @as(usize, @intFromFloat(@floor((area_height + gutter) / (card_height + gutter))))));
    return .{ .card_width = card_width, .card_height = card_height, .gutter = gutter, .visible_rows = rows };
}

pub fn firstVisibleRow(selected: usize, title_count: usize, visible_rows: usize) usize {
    if (title_count == 0) return 0;
    const row_count = (title_count + columns - 1) / columns;
    const selected_row = selected / columns;
    const centered = selected_row -| (visible_rows / 2);
    return @min(centered, row_count -| visible_rows);
}

pub fn cardRect(area_x: f32, area_y: f32, metrics: Layout, first_row: usize, index: usize) Rect {
    const row = index / columns - first_row;
    const column = index % columns;
    return .{
        .x = area_x + @as(f32, @floatFromInt(column)) * (metrics.card_width + metrics.gutter),
        .y = area_y + @as(f32, @floatFromInt(row)) * (metrics.card_height + metrics.gutter),
        .w = metrics.card_width,
        .h = metrics.card_height,
    };
}

test "grid preserves the ROM proportions" {
    const metrics = layout(544, 293);
    try std.testing.expectApproxEqAbs(@as(f32, 124), metrics.card_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 86.703125), metrics.card_height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16), metrics.gutter, 0.001);
    try std.testing.expectEqual(@as(usize, 3), metrics.visible_rows);
}

test "selected row stays centered and clamps at catalog ends" {
    try std.testing.expectEqual(@as(usize, 0), firstVisibleRow(0, 40, 3));
    try std.testing.expectEqual(@as(usize, 3), firstVisibleRow(17, 40, 3));
    try std.testing.expectEqual(@as(usize, 7), firstVisibleRow(39, 40, 3));
}
