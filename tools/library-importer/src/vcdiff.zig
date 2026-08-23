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

    fn integer(self: *Reader) !u64 {
        var result: u64 = 0;
        var count: usize = 0;
        while (true) {
            if (count == 10) return error.IntegerOverflow;
            const value = try self.byte();
            if (result > std.math.maxInt(u64) >> 7) return error.IntegerOverflow;
            result = (result << 7) | (value & 0x7f);
            count += 1;
            if (value & 0x80 == 0) return result;
        }
    }

    fn skip(self: *Reader, length: u64) !void {
        if (length > self.bytes.len -| self.offset) return error.UnexpectedEnd;
        self.offset += @intCast(length);
    }
};

const InstructionType = enum(u8) { noop, add, run, copy };
const Instruction = struct { kind: InstructionType = .noop, size: u8 = 0, mode: u8 = 0 };
const Code = struct { first: Instruction = .{}, second: Instruction = .{} };

const AddressCache = struct {
    near: [4]u64 = @splat(0),
    same: [3 * 256]u64 = @splat(0),
    next_near: usize = 0,

    fn update(self: *AddressCache, address: u64) void {
        self.near[self.next_near] = address;
        self.next_near = (self.next_near + 1) % self.near.len;
        self.same[address % self.same.len] = address;
    }
};

const Sections = struct {
    patch: []const u8,
    data: []const u8,
    instructions: []const u8,
    addresses: []const u8,
    data_position: usize = 0,
    instruction_position: usize = 0,
    address_position: usize = 0,

    fn readData(self: *Sections, output: []u8) !void {
        if (output.len > self.data.len -| self.data_position) return error.SectionOverflow;
        @memcpy(output, self.data[self.data_position..][0..output.len]);
        self.data_position += output.len;
    }

    fn instructionByte(self: *Sections) !u8 {
        if (self.instruction_position >= self.instructions.len) return error.SectionOverflow;
        defer self.instruction_position += 1;
        return self.instructions[self.instruction_position];
    }

    fn addressByte(self: *Sections) !u8 {
        if (self.address_position >= self.addresses.len) return error.SectionOverflow;
        defer self.address_position += 1;
        return self.addresses[self.address_position];
    }

    fn instructionInteger(self: *Sections) !u64 {
        return sectionInteger(self, true);
    }

    fn addressInteger(self: *Sections) !u64 {
        return sectionInteger(self, false);
    }

    fn sectionInteger(self: *Sections, instruction: bool) !u64 {
        var result: u64 = 0;
        var count: usize = 0;
        while (true) {
            if (count == 10) return error.IntegerOverflow;
            const value = if (instruction) try self.instructionByte() else try self.addressByte();
            if (result > std.math.maxInt(u64) >> 7) return error.IntegerOverflow;
            result = (result << 7) | (value & 0x7f);
            count += 1;
            if (value & 0x80 == 0) return result;
        }
    }
};

pub fn apply(allocator: std.mem.Allocator, source: []const u8, patch: []const u8) ![]u8 {
    const size = try targetSize(patch);
    if (size == 0 or size > maximum_output_size) return error.TargetSizeInvalid;
    const target = try allocator.alloc(u8, size);
    errdefer allocator.free(target);
    try decode(source, patch, target);
    return target;
}

pub fn targetSize(patch: []const u8) !usize {
    var stream = try header(patch);
    var total: u64 = 0;
    while (stream.offset < patch.len) {
        const window_indicator = try stream.byte();
        if (window_indicator & ~@as(u8, 0x07) != 0 or window_indicator & 0x03 == 0x03) return error.UnsupportedFeature;
        if (window_indicator & 0x03 != 0) {
            _ = try stream.integer();
            _ = try stream.integer();
        }
        const delta_length = try stream.integer();
        const delta_start = stream.offset;
        const target_length = try stream.integer();
        total = std.math.add(u64, total, target_length) catch return error.IntegerOverflow;
        if (total > maximum_output_size) return error.TargetSizeInvalid;
        try stream.skip(delta_length -| (stream.offset - delta_start));
        if (stream.offset - delta_start != delta_length) return error.InvalidWindow;
    }
    return @intCast(total);
}

fn decode(source: []const u8, patch: []const u8, target: []u8) !void {
    var stream = try header(patch);
    var target_position: usize = 0;
    while (stream.offset < patch.len) {
        const window_indicator = try stream.byte();
        if (window_indicator & ~@as(u8, 0x07) != 0 or window_indicator & 0x03 == 0x03) return error.UnsupportedFeature;
        var source_length: u64 = 0;
        var source_position: u64 = 0;
        if (window_indicator & 0x03 != 0) {
            source_length = try stream.integer();
            source_position = try stream.integer();
        }
        if (window_indicator & 0x01 != 0 and (source_position > source.len or source_length > source.len - source_position)) return error.InvalidWindow;
        if (window_indicator & 0x02 != 0 and (source_position > target_position or source_length > target_position - source_position)) return error.InvalidWindow;
        const delta_length = try stream.integer();
        const delta_start = stream.offset;
        const target_length_u64 = try stream.integer();
        if (target_length_u64 == 0 or target_length_u64 > target.len - target_position) return error.TargetOverflow;
        const target_length: usize = @intCast(target_length_u64);
        if (try stream.byte() != 0) return error.UnsupportedFeature;
        const data_length = try stream.integer();
        const instruction_length = try stream.integer();
        const address_length = try stream.integer();
        var expected_adler: ?u32 = null;
        if (window_indicator & 0x04 != 0) {
            if (stream.offset + 4 > patch.len) return error.UnexpectedEnd;
            expected_adler = std.mem.readInt(u32, patch[stream.offset..][0..4], .big);
            stream.offset += 4;
        }
        const sections_length = std.math.add(u64, std.math.add(u64, data_length, instruction_length) catch return error.IntegerOverflow, address_length) catch return error.IntegerOverflow;
        if (sections_length > patch.len - stream.offset) return error.UnexpectedEnd;
        const data_end = stream.offset + @as(usize, @intCast(data_length));
        const instruction_end = data_end + @as(usize, @intCast(instruction_length));
        const address_end = instruction_end + @as(usize, @intCast(address_length));
        var sections = Sections{
            .patch = patch,
            .data = patch[stream.offset..data_end],
            .instructions = patch[data_end..instruction_end],
            .addresses = patch[instruction_end..address_end],
        };
        var cache = AddressCache{};
        var produced: usize = 0;
        const window = target[target_position..][0..target_length];
        while (sections.instruction_position < sections.instructions.len) {
            const code = defaultCode(try sections.instructionByte());
            try execute(code.first, source, target, target_position, source_position, source_length, window, &produced, &sections, &cache, window_indicator);
            try execute(code.second, source, target, target_position, source_position, source_length, window, &produced, &sections, &cache, window_indicator);
        }
        if (produced != target_length or sections.data_position != sections.data.len or sections.address_position != sections.addresses.len) return error.InvalidWindow;
        if (expected_adler) |checksum| if (adler32(window) != checksum) return error.ChecksumMismatch;
        target_position += target_length;
        stream.offset = address_end;
        if (stream.offset - delta_start != delta_length) return error.InvalidWindow;
    }
    if (target_position != target.len) return error.TargetOverflow;
}

fn header(patch: []const u8) !Reader {
    if (patch.len < 5 or !std.mem.eql(u8, patch[0..4], &.{ 0xd6, 0xc3, 0xc4, 0x00 })) return error.InvalidHeader;
    var stream = Reader{ .bytes = patch, .offset = 4 };
    const indicator = try stream.byte();
    if (indicator & 0x03 != 0) return error.UnsupportedFeature;
    if (indicator & 0x04 != 0) try stream.skip(try stream.integer());
    return stream;
}

fn execute(
    instruction: Instruction,
    source: []const u8,
    target: []u8,
    target_position: usize,
    source_position: u64,
    source_length: u64,
    window: []u8,
    produced: *usize,
    sections: *Sections,
    cache: *AddressCache,
    indicator: u8,
) !void {
    if (instruction.kind == .noop) return;
    const size_u64 = if (instruction.size == 0) try sections.instructionInteger() else instruction.size;
    if (size_u64 == 0 or size_u64 > window.len -| produced.*) return error.InvalidInstruction;
    const size: usize = @intCast(size_u64);
    switch (instruction.kind) {
        .noop => unreachable,
        .add => try sections.readData(window[produced.*..][0..size]),
        .run => {
            var value: [1]u8 = undefined;
            try sections.readData(&value);
            @memset(window[produced.*..][0..size], value[0]);
        },
        .copy => {
            const here = source_length + produced.*;
            const address = try decodeAddress(cache, sections, here, instruction.mode);
            if (address < source_length) {
                if (size_u64 > source_length - address) return error.InvalidAddress;
                const absolute = source_position + address;
                if (indicator & 0x01 != 0) {
                    if (absolute > source.len or size > source.len - absolute) return error.InvalidAddress;
                    @memcpy(window[produced.*..][0..size], source[@intCast(absolute)..][0..size]);
                } else if (indicator & 0x02 != 0) {
                    if (absolute > target_position or size > target_position - absolute) return error.InvalidAddress;
                    @memcpy(window[produced.*..][0..size], target[@intCast(absolute)..][0..size]);
                } else return error.InvalidAddress;
            } else {
                const from_start = address - source_length;
                if (from_start >= produced.*) return error.InvalidAddress;
                for (0..size) |index| {
                    const from = from_start + index;
                    if (from >= produced.* + index) return error.InvalidAddress;
                    window[produced.* + index] = window[from];
                }
            }
        },
    }
    produced.* += size;
}

fn decodeAddress(cache: *AddressCache, sections: *Sections, here: u64, mode: u8) !u64 {
    const address = switch (mode) {
        0 => try sections.addressInteger(),
        1 => blk: {
            const distance = try sections.addressInteger();
            if (distance > here) return error.InvalidAddress;
            break :blk here - distance;
        },
        2...5 => |near_mode| std.math.add(u64, cache.near[near_mode - 2], try sections.addressInteger()) catch return error.IntegerOverflow,
        6...8 => |same_mode| cache.same[@as(usize, same_mode - 6) * 256 + try sections.addressByte()],
        else => return error.InvalidAddress,
    };
    if (address >= here) return error.InvalidAddress;
    cache.update(address);
    return address;
}

fn defaultCode(index: u8) Code {
    if (index == 0) return .{ .first = .{ .kind = .run } };
    if (index <= 18) return .{ .first = .{ .kind = .add, .size = index - 1 } };
    if (index <= 162) {
        const relative = index - 19;
        return .{ .first = .{ .kind = .copy, .size = if (relative % 16 == 0) 0 else 3 + relative % 16, .mode = relative / 16 } };
    }
    if (index <= 234) {
        const relative = index - 163;
        return .{ .first = .{ .kind = .add, .size = 1 + (relative % 12) / 3 }, .second = .{ .kind = .copy, .size = 4 + relative % 3, .mode = relative / 12 } };
    }
    if (index <= 246) {
        const relative = index - 235;
        return .{ .first = .{ .kind = .add, .size = 1 + relative % 4 }, .second = .{ .kind = .copy, .size = 4, .mode = 6 + relative / 4 } };
    }
    return .{ .first = .{ .kind = .copy, .size = 4, .mode = index - 247 }, .second = .{ .kind = .add, .size = 1 } };
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |value| {
        a = (a + value) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

test "decodes checksummed ADD-only window" {
    const expected = "modded";
    const checksum = adler32(expected);
    const patch = [_]u8{
        0xd6,                      0xc3,                      0xc4,                     0x00,                0x00, 0x05, 0x01, 0x00, 0x11, 0x06, 0x00, 0x06, 0x02, 0x00,
        @truncate(checksum >> 24), @truncate(checksum >> 16), @truncate(checksum >> 8), @truncate(checksum), 'm',  'o',  'd',  'd',  'e',  'd',  0x01, 0x06,
    };
    const output = try apply(std.testing.allocator, "x", &patch);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}
