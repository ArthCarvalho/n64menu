const std = @import("std");

pub const maximum_output_size = 78 * 1024 * 1024;

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.offset >= self.bytes.len) return error.UnexpectedEnd;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    fn number(self: *Reader) !u64 {
        var data: u64 = 0;
        var shift: u64 = 1;
        var count: usize = 0;
        while (true) {
            if (count == 10) return error.IntegerOverflow;
            const value = try self.byte();
            data = std.math.add(u64, data, std.math.mul(u64, value & 0x7f, shift) catch return error.IntegerOverflow) catch return error.IntegerOverflow;
            if (value & 0x80 != 0) return data;
            if (shift > std.math.maxInt(u64) >> 7) return error.IntegerOverflow;
            shift <<= 7;
            data = std.math.add(u64, data, shift) catch return error.IntegerOverflow;
            count += 1;
        }
    }

    fn signed(self: *Reader) !i64 {
        const encoded = try self.number();
        const magnitude: i64 = @intCast(encoded >> 1);
        return if (encoded & 1 != 0) -magnitude else magnitude;
    }

    fn skip(self: *Reader, length: u64) !void {
        if (length > self.bytes.len -| self.offset) return error.UnexpectedEnd;
        self.offset += @intCast(length);
    }
};

pub fn apply(allocator: std.mem.Allocator, source: []const u8, patch: []const u8) ![]u8 {
    if (patch.len < 16 or !std.mem.eql(u8, patch[0..4], "BPS1")) return error.InvalidPatch;
    const footer = patch.len - 12;
    const source_crc = std.mem.readInt(u32, patch[footer..][0..4], .little);
    const target_crc = std.mem.readInt(u32, patch[footer + 4 ..][0..4], .little);
    const patch_crc = std.mem.readInt(u32, patch[footer + 8 ..][0..4], .little);
    if (std.hash.crc.Crc32.hash(source) != source_crc) return error.SourceChecksumMismatch;
    if (std.hash.crc.Crc32.hash(patch[0 .. patch.len - 4]) != patch_crc) return error.PatchChecksumMismatch;

    var reader = Reader{ .bytes = patch, .offset = 4 };
    const source_size = try reader.number();
    const target_size = try reader.number();
    const metadata_size = try reader.number();
    if (source_size != source.len) return error.SourceSizeMismatch;
    if (target_size == 0 or target_size > maximum_output_size) return error.TargetSizeInvalid;
    try reader.skip(metadata_size);

    const target = try allocator.alloc(u8, @intCast(target_size));
    errdefer allocator.free(target);
    var output_offset: usize = 0;
    var source_relative: i64 = 0;
    var target_relative: i64 = 0;
    while (output_offset < target.len) {
        if (reader.offset >= footer) return error.UnexpectedEnd;
        const action = try reader.number();
        const length_u64 = (action >> 2) + 1;
        if (length_u64 > target.len - output_offset) return error.TargetOverflow;
        const length: usize = @intCast(length_u64);
        switch (action & 3) {
            0 => {
                if (output_offset + length > source.len) return error.SourceOverflow;
                @memcpy(target[output_offset..][0..length], source[output_offset..][0..length]);
            },
            1 => {
                if (length > footer -| reader.offset) return error.UnexpectedEnd;
                @memcpy(target[output_offset..][0..length], patch[reader.offset..][0..length]);
                reader.offset += length;
            },
            2 => {
                source_relative = std.math.add(i64, source_relative, try reader.signed()) catch return error.IntegerOverflow;
                if (source_relative < 0 or source_relative > source.len or length > source.len - @as(usize, @intCast(source_relative))) return error.SourceOverflow;
                @memcpy(target[output_offset..][0..length], source[@intCast(source_relative)..][0..length]);
                source_relative += @intCast(length);
            },
            3 => {
                target_relative = std.math.add(i64, target_relative, try reader.signed()) catch return error.IntegerOverflow;
                if (target_relative < 0 or target_relative >= output_offset) return error.TargetCopyInvalid;
                for (0..length) |index| {
                    const from = @as(usize, @intCast(target_relative)) + index;
                    if (from >= output_offset + index) return error.TargetCopyInvalid;
                    target[output_offset + index] = target[from];
                }
                target_relative += @intCast(length);
            },
            else => unreachable,
        }
        output_offset += length;
    }
    if (reader.offset != footer) return error.TrailingPatchData;
    if (std.hash.crc.Crc32.hash(target) != target_crc) return error.TargetChecksumMismatch;
    return target;
}

fn encodeNumber(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: u64) !void {
    var value = input;
    while (true) {
        const next = value >> 7;
        var byte: u8 = @truncate(value & 0x7f);
        if (next == 0) {
            byte |= 0x80;
            try output.append(allocator, byte);
            return;
        }
        try output.append(allocator, byte);
        value = next - 1;
    }
}

test "applies target-read BPS patch and verifies footer" {
    const allocator = std.testing.allocator;
    const source = "base";
    const expected = "modded";
    var patch: std.ArrayList(u8) = .empty;
    defer patch.deinit(allocator);
    try patch.appendSlice(allocator, "BPS1");
    try encodeNumber(&patch, allocator, source.len);
    try encodeNumber(&patch, allocator, expected.len);
    try encodeNumber(&patch, allocator, 0);
    try encodeNumber(&patch, allocator, ((expected.len - 1) << 2) | 1);
    try patch.appendSlice(allocator, expected);
    var footer: [12]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], std.hash.crc.Crc32.hash(source), .little);
    std.mem.writeInt(u32, footer[4..8], std.hash.crc.Crc32.hash(expected), .little);
    try patch.appendSlice(allocator, footer[0..8]);
    std.mem.writeInt(u32, footer[8..12], std.hash.crc.Crc32.hash(patch.items), .little);
    try patch.appendSlice(allocator, footer[8..12]);
    const result = try apply(allocator, source, patch.items);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "rejects the wrong source" {
    const patch = "BPS1\x84\x84\x80\x8cbase" ++ "\x00" ** 12;
    try std.testing.expectError(error.SourceChecksumMismatch, apply(std.testing.allocator, "nope", patch));
}
