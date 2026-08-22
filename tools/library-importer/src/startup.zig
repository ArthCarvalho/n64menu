const std = @import("std");

pub const logo_width: f32 = 168;
pub const logo_height: f32 = 46;
pub const final_scale: f32 = 2;
pub const total_seconds: f64 = 4.4;

pub const Stage = enum { outline, white, color, black, done };

pub const Frame = struct {
    stage: Stage,
    scale: f32 = final_scale,
    intensity: f32 = 1,
};

pub fn frameAt(elapsed: f64) Frame {
    if (elapsed < 1.4) {
        const remaining: f32 = @floatCast(1.0 - elapsed / 1.4);
        return .{ .stage = .outline, .scale = final_scale + 6.0 * remaining * remaining };
    }
    if (elapsed < 2.1) return .{ .stage = .outline };
    if (elapsed < 2.35) return .{ .stage = .white };
    if (elapsed < 3.9) return .{ .stage = .color };
    if (elapsed < 4.3) return .{ .stage = .color, .intensity = @floatCast(1.0 - (elapsed - 3.9) / 0.4) };
    if (elapsed < total_seconds) return .{ .stage = .black };
    return .{ .stage = .done };
}

pub const Run = struct { x: u8, y: u8, width: u8 };

// Horizontal runs from the same 168x46 one-bit masks generated for the ROM.
pub const outer_runs = [_]Run{
    .{ .x = 33, .y = 8, .width = 28 },   .{ .x = 69, .y = 8, .width = 30 },   .{ .x = 106, .y = 8, .width = 9 },   .{ .x = 144, .y = 8, .width = 10 },
    .{ .x = 32, .y = 9, .width = 29 },   .{ .x = 68, .y = 9, .width = 31 },   .{ .x = 105, .y = 9, .width = 10 },  .{ .x = 143, .y = 9, .width = 11 },
    .{ .x = 31, .y = 10, .width = 29 },  .{ .x = 67, .y = 10, .width = 31 },  .{ .x = 104, .y = 10, .width = 10 }, .{ .x = 142, .y = 10, .width = 11 },
    .{ .x = 30, .y = 11, .width = 29 },  .{ .x = 66, .y = 11, .width = 31 },  .{ .x = 103, .y = 11, .width = 10 }, .{ .x = 141, .y = 11, .width = 11 },
    .{ .x = 29, .y = 12, .width = 29 },  .{ .x = 65, .y = 12, .width = 31 },  .{ .x = 102, .y = 12, .width = 28 }, .{ .x = 140, .y = 12, .width = 12 },
    .{ .x = 28, .y = 13, .width = 29 },  .{ .x = 64, .y = 13, .width = 31 },  .{ .x = 101, .y = 13, .width = 31 }, .{ .x = 139, .y = 13, .width = 12 },
    .{ .x = 27, .y = 14, .width = 29 },  .{ .x = 63, .y = 14, .width = 31 },  .{ .x = 100, .y = 14, .width = 34 }, .{ .x = 138, .y = 14, .width = 12 },
    .{ .x = 157, .y = 14, .width = 9 },  .{ .x = 26, .y = 15, .width = 29 },  .{ .x = 62, .y = 15, .width = 31 },  .{ .x = 100, .y = 15, .width = 34 },
    .{ .x = 138, .y = 15, .width = 11 }, .{ .x = 157, .y = 15, .width = 9 },  .{ .x = 25, .y = 16, .width = 8 },   .{ .x = 61, .y = 16, .width = 11 },
    .{ .x = 99, .y = 16, .width = 36 },  .{ .x = 137, .y = 16, .width = 12 }, .{ .x = 157, .y = 16, .width = 9 },  .{ .x = 24, .y = 17, .width = 8 },
    .{ .x = 60, .y = 17, .width = 11 },  .{ .x = 99, .y = 17, .width = 49 },  .{ .x = 157, .y = 17, .width = 9 },  .{ .x = 23, .y = 18, .width = 8 },
    .{ .x = 59, .y = 18, .width = 11 },  .{ .x = 98, .y = 18, .width = 68 },  .{ .x = 22, .y = 19, .width = 10 },  .{ .x = 58, .y = 19, .width = 11 },
    .{ .x = 98, .y = 19, .width = 9 },   .{ .x = 126, .y = 19, .width = 40 }, .{ .x = 21, .y = 20, .width = 29 },  .{ .x = 57, .y = 20, .width = 11 },
    .{ .x = 98, .y = 20, .width = 9 },   .{ .x = 127, .y = 20, .width = 39 }, .{ .x = 20, .y = 21, .width = 29 },  .{ .x = 56, .y = 21, .width = 11 },
    .{ .x = 98, .y = 21, .width = 68 },  .{ .x = 19, .y = 22, .width = 29 },  .{ .x = 55, .y = 22, .width = 11 },  .{ .x = 98, .y = 22, .width = 68 },
    .{ .x = 18, .y = 23, .width = 29 },  .{ .x = 54, .y = 23, .width = 11 },  .{ .x = 99, .y = 23, .width = 67 },  .{ .x = 17, .y = 24, .width = 29 },
    .{ .x = 53, .y = 24, .width = 11 },  .{ .x = 99, .y = 24, .width = 67 },  .{ .x = 16, .y = 25, .width = 29 },  .{ .x = 52, .y = 25, .width = 11 },
    .{ .x = 100, .y = 25, .width = 34 }, .{ .x = 157, .y = 25, .width = 9 },  .{ .x = 16, .y = 26, .width = 28 },  .{ .x = 51, .y = 26, .width = 11 },
    .{ .x = 101, .y = 26, .width = 32 }, .{ .x = 157, .y = 26, .width = 9 },  .{ .x = 35, .y = 27, .width = 8 },   .{ .x = 50, .y = 27, .width = 11 },
    .{ .x = 102, .y = 27, .width = 30 }, .{ .x = 157, .y = 27, .width = 9 },  .{ .x = 34, .y = 28, .width = 8 },   .{ .x = 49, .y = 28, .width = 11 },
    .{ .x = 106, .y = 28, .width = 22 }, .{ .x = 158, .y = 28, .width = 7 },  .{ .x = 33, .y = 29, .width = 8 },   .{ .x = 48, .y = 29, .width = 11 },
    .{ .x = 11, .y = 30, .width = 29 },  .{ .x = 47, .y = 30, .width = 30 },  .{ .x = 10, .y = 31, .width = 29 },  .{ .x = 46, .y = 31, .width = 31 },
    .{ .x = 9, .y = 32, .width = 29 },   .{ .x = 45, .y = 32, .width = 31 },  .{ .x = 8, .y = 33, .width = 29 },   .{ .x = 44, .y = 33, .width = 31 },
    .{ .x = 7, .y = 34, .width = 29 },   .{ .x = 43, .y = 34, .width = 31 },  .{ .x = 6, .y = 35, .width = 29 },   .{ .x = 42, .y = 35, .width = 31 },
    .{ .x = 5, .y = 36, .width = 29 },   .{ .x = 41, .y = 36, .width = 31 },  .{ .x = 4, .y = 37, .width = 29 },   .{ .x = 40, .y = 37, .width = 31 },
};

pub const inner_runs = [_]Run{
    .{ .x = 34, .y = 8, .width = 26 },   .{ .x = 70, .y = 8, .width = 28 },   .{ .x = 107, .y = 8, .width = 7 },   .{ .x = 145, .y = 8, .width = 8 },
    .{ .x = 33, .y = 9, .width = 27 },   .{ .x = 68, .y = 9, .width = 30 },   .{ .x = 106, .y = 9, .width = 8 },   .{ .x = 143, .y = 9, .width = 10 },
    .{ .x = 32, .y = 10, .width = 27 },  .{ .x = 67, .y = 10, .width = 30 },  .{ .x = 105, .y = 10, .width = 8 },  .{ .x = 143, .y = 10, .width = 10 },
    .{ .x = 31, .y = 11, .width = 27 },  .{ .x = 66, .y = 11, .width = 30 },  .{ .x = 104, .y = 11, .width = 9 },  .{ .x = 142, .y = 11, .width = 10 },
    .{ .x = 30, .y = 12, .width = 27 },  .{ .x = 65, .y = 12, .width = 30 },  .{ .x = 103, .y = 12, .width = 26 }, .{ .x = 141, .y = 12, .width = 10 },
    .{ .x = 29, .y = 13, .width = 27 },  .{ .x = 64, .y = 13, .width = 30 },  .{ .x = 102, .y = 13, .width = 29 }, .{ .x = 140, .y = 13, .width = 10 },
    .{ .x = 28, .y = 14, .width = 27 },  .{ .x = 63, .y = 14, .width = 30 },  .{ .x = 101, .y = 14, .width = 32 }, .{ .x = 139, .y = 14, .width = 10 },
    .{ .x = 158, .y = 14, .width = 7 },  .{ .x = 27, .y = 15, .width = 27 },  .{ .x = 62, .y = 15, .width = 30 },  .{ .x = 100, .y = 15, .width = 34 },
    .{ .x = 138, .y = 15, .width = 11 }, .{ .x = 157, .y = 15, .width = 9 },  .{ .x = 26, .y = 16, .width = 7 },   .{ .x = 61, .y = 16, .width = 10 },
    .{ .x = 100, .y = 16, .width = 34 }, .{ .x = 137, .y = 16, .width = 11 }, .{ .x = 157, .y = 16, .width = 9 },  .{ .x = 25, .y = 17, .width = 7 },
    .{ .x = 60, .y = 17, .width = 10 },  .{ .x = 99, .y = 17, .width = 49 },  .{ .x = 157, .y = 17, .width = 9 },  .{ .x = 24, .y = 18, .width = 7 },
    .{ .x = 59, .y = 18, .width = 10 },  .{ .x = 99, .y = 18, .width = 67 },  .{ .x = 23, .y = 19, .width = 8 },   .{ .x = 58, .y = 19, .width = 10 },
    .{ .x = 98, .y = 19, .width = 9 },   .{ .x = 127, .y = 19, .width = 39 }, .{ .x = 22, .y = 20, .width = 27 },  .{ .x = 57, .y = 20, .width = 10 },
    .{ .x = 98, .y = 20, .width = 9 },   .{ .x = 127, .y = 20, .width = 39 }, .{ .x = 21, .y = 21, .width = 27 },  .{ .x = 56, .y = 21, .width = 10 },
    .{ .x = 98, .y = 21, .width = 68 },  .{ .x = 20, .y = 22, .width = 27 },  .{ .x = 55, .y = 22, .width = 10 },  .{ .x = 99, .y = 22, .width = 67 },
    .{ .x = 19, .y = 23, .width = 27 },  .{ .x = 54, .y = 23, .width = 10 },  .{ .x = 99, .y = 23, .width = 67 },  .{ .x = 18, .y = 24, .width = 27 },
    .{ .x = 53, .y = 24, .width = 10 },  .{ .x = 100, .y = 24, .width = 66 }, .{ .x = 17, .y = 25, .width = 27 },  .{ .x = 52, .y = 25, .width = 10 },
    .{ .x = 101, .y = 25, .width = 32 }, .{ .x = 157, .y = 25, .width = 9 },  .{ .x = 17, .y = 26, .width = 26 },  .{ .x = 51, .y = 26, .width = 10 },
    .{ .x = 102, .y = 26, .width = 30 }, .{ .x = 157, .y = 26, .width = 9 },  .{ .x = 35, .y = 27, .width = 7 },   .{ .x = 50, .y = 27, .width = 10 },
    .{ .x = 103, .y = 27, .width = 28 }, .{ .x = 158, .y = 27, .width = 8 },  .{ .x = 34, .y = 28, .width = 7 },   .{ .x = 49, .y = 28, .width = 10 },
    .{ .x = 107, .y = 28, .width = 20 }, .{ .x = 159, .y = 28, .width = 5 },  .{ .x = 33, .y = 29, .width = 7 },   .{ .x = 48, .y = 29, .width = 11 },
    .{ .x = 12, .y = 30, .width = 27 },  .{ .x = 47, .y = 30, .width = 29 },  .{ .x = 11, .y = 31, .width = 27 },  .{ .x = 46, .y = 31, .width = 30 },
    .{ .x = 10, .y = 32, .width = 27 },  .{ .x = 45, .y = 32, .width = 30 },  .{ .x = 9, .y = 33, .width = 27 },   .{ .x = 44, .y = 33, .width = 30 },
    .{ .x = 8, .y = 34, .width = 27 },   .{ .x = 43, .y = 34, .width = 30 },  .{ .x = 7, .y = 35, .width = 27 },   .{ .x = 42, .y = 35, .width = 30 },
    .{ .x = 6, .y = 36, .width = 27 },   .{ .x = 41, .y = 36, .width = 30 },  .{ .x = 5, .y = 37, .width = 27 },   .{ .x = 41, .y = 37, .width = 29 },
};

test "startup follows the ROM phase timing" {
    try std.testing.expectEqual(Stage.outline, frameAt(0).stage);
    try std.testing.expectApproxEqAbs(@as(f32, 8), frameAt(0).scale, 0.0001);
    try std.testing.expectEqual(Stage.outline, frameAt(2.099).stage);
    try std.testing.expectEqual(Stage.white, frameAt(2.1).stage);
    try std.testing.expectEqual(Stage.color, frameAt(2.35).stage);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), frameAt(4.1).intensity, 0.0001);
    try std.testing.expectEqual(Stage.black, frameAt(4.3).stage);
    try std.testing.expectEqual(Stage.done, frameAt(total_seconds).stage);
}
