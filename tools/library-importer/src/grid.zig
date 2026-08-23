const std = @import("std");

pub const minimum_columns: usize = 4;
pub const maximum_columns: usize = 12;
pub const maximum_visible_cards: usize = 64;
pub const source_width: f32 = 256;
pub const source_height: f32 = 179;
pub const reference_card_width: f32 = 124;
pub const reference_gutter: f32 = 16;

pub const Layout = struct {
    columns: usize,
    card_width: f32,
    card_height: f32,
    gutter: f32,
    visible_rows: usize,
};

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn layout(area_width: f32, area_height: f32) Layout {
    const gutter_ratio = reference_gutter / reference_card_width;
    const columns = std.math.clamp(
        @as(usize, @intFromFloat(@ceil((area_width + reference_gutter) / (reference_card_width + reference_gutter)))),
        minimum_columns,
        maximum_columns,
    );
    const card_width = area_width / (@as(f32, @floatFromInt(columns)) + @as(f32, @floatFromInt(columns - 1)) * gutter_ratio);
    const gutter = card_width * gutter_ratio;
    const card_height = card_width * source_height / source_width;
    const rows = @min(
        maximum_visible_cards / columns,
        @max(1, @as(usize, @intFromFloat(@floor((area_height + gutter) / (card_height + gutter))))),
    );
    return .{ .columns = columns, .card_width = card_width, .card_height = card_height, .gutter = gutter, .visible_rows = rows };
}

pub fn firstVisibleRow(selected: usize, title_count: usize, metrics: Layout) usize {
    if (title_count == 0) return 0;
    const row_count = (title_count + metrics.columns - 1) / metrics.columns;
    const selected_row = selected / metrics.columns;
    const centered = selected_row -| (metrics.visible_rows / 2);
    return @min(centered, row_count -| metrics.visible_rows);
}

pub fn cardRect(area_x: f32, area_y: f32, metrics: Layout, first_row: usize, index: usize) Rect {
    const row = index / metrics.columns - first_row;
    const column = index % metrics.columns;
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
    try std.testing.expectEqual(@as(usize, 4), metrics.columns);
    try std.testing.expectEqual(@as(usize, 3), metrics.visible_rows);
}

test "selected row stays centered and clamps at catalog ends" {
    const metrics = layout(544, 293);
    try std.testing.expectEqual(@as(usize, 0), firstVisibleRow(0, 40, metrics));
    try std.testing.expectEqual(@as(usize, 3), firstVisibleRow(17, 40, metrics));
    try std.testing.expectEqual(@as(usize, 7), firstVisibleRow(39, 40, metrics));
}

test "wide areas add columns without stretching cards" {
    const metrics = layout(1244, 600);
    try std.testing.expectEqual(@as(usize, 9), metrics.columns);
    try std.testing.expectApproxEqAbs(@as(f32, 124), metrics.card_width, 0.001);
    try std.testing.expect(metrics.visible_rows >= 5);
}
