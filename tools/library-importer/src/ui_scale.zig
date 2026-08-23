const std = @import("std");

pub const base_width: f32 = 1120;
pub const base_height: f32 = 820;

pub const Metrics = struct {
    scale: f32,
    width: f32,
    height: f32,
};

/// Fits the base layout to the framebuffer in quarter-step increments. Sokol's
/// framebuffer dimensions already include DPI scaling, so this responds both to
/// display scaling and to a user enlarging the window. Quarter steps let 1080p
/// and 1440p screens benefit without requiring room for a full 2x layout.
pub fn metrics(framebuffer_width: f32, framebuffer_height: f32) Metrics {
    const fit = @min(framebuffer_width / base_width, framebuffer_height / base_height);
    const scale = @floor(@max(1.0, fit) * 4.0) / 4.0;
    return .{
        .scale = scale,
        .width = framebuffer_width / scale,
        .height = framebuffer_height / scale,
    };
}

test "framebuffer fit grows the UI while preserving the base layout" {
    try std.testing.expectEqual(Metrics{ .scale = 1, .width = 1120, .height = 820 }, metrics(1120, 820));
    try std.testing.expectEqual(Metrics{ .scale = 2, .width = 1120, .height = 820 }, metrics(2240, 1640));
    try std.testing.expectEqual(Metrics{ .scale = 1, .width = 1400, .height = 900 }, metrics(1400, 900));
    try std.testing.expectEqual(Metrics{ .scale = 1.25, .width = 1600, .height = 846.4 }, metrics(2000, 1058));
    try std.testing.expectEqual(Metrics{ .scale = 2.5, .width = 1536, .height = 864 }, metrics(3840, 2160));
}
