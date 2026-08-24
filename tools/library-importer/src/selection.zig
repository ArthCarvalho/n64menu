const std = @import("std");

/// A ROM chosen for the next cart sync.
///
/// Games and local revisions are keyed by their normalized content hash. A
/// registry mod has no ROM until its patch is applied, so it is keyed by a hash
/// of its catalog id instead. Both live in one space so a single set describes
/// everything the cart should hold.
pub const Key = [32]u8;

pub fn modKey(id: []const u8) Key {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("registry-mod\x00");
    hasher.update(id);
    return hasher.finalResult();
}

pub fn containsKey(keys: []const Key, key: Key) bool {
    for (keys) |candidate| if (std.mem.eql(u8, &candidate, &key)) return true;
    return false;
}

/// Whether newly discovered games start selected.
///
/// A ROM folder is swept recursively and can pull in anything, so those imports
/// are opt in. A RetroArch playlist is a list the user already curated, so those
/// imports are opt out.
pub const Default = enum { opt_in, opt_out };

pub const Set = struct {
    keys: std.ArrayList(Key) = .empty,

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
        self.keys = .empty;
    }

    pub fn slice(self: *const Set) []const Key {
        return self.keys.items;
    }

    pub fn count(self: *const Set) usize {
        return self.keys.items.len;
    }

    pub fn has(self: *const Set, key: Key) bool {
        return containsKey(self.keys.items, key);
    }

    pub fn select(self: *Set, allocator: std.mem.Allocator, key: Key) !void {
        if (self.has(key)) return;
        try self.keys.append(allocator, key);
    }

    pub fn deselect(self: *Set, key: Key) void {
        for (self.keys.items, 0..) |candidate, index| {
            if (!std.mem.eql(u8, &candidate, &key)) continue;
            _ = self.keys.swapRemove(index);
            return;
        }
    }

    /// Returns the state the key holds afterwards.
    pub fn toggle(self: *Set, allocator: std.mem.Allocator, key: Key) !bool {
        if (self.has(key)) {
            self.deselect(key);
            return false;
        }
        try self.select(allocator, key);
        return true;
    }

    pub fn clear(self: *Set) void {
        self.keys.clearRetainingCapacity();
    }
};

test "selecting is idempotent and deselect removes only the requested key" {
    const allocator = std.testing.allocator;
    var set = Set{};
    defer set.deinit(allocator);

    const a: Key = @splat(1);
    const b: Key = @splat(2);
    try set.select(allocator, a);
    try set.select(allocator, a);
    try set.select(allocator, b);
    try std.testing.expectEqual(@as(usize, 2), set.count());

    set.deselect(a);
    try std.testing.expect(!set.has(a));
    try std.testing.expect(set.has(b));
    set.deselect(a);
    try std.testing.expectEqual(@as(usize, 1), set.count());
}

test "toggle reports the resulting state" {
    const allocator = std.testing.allocator;
    var set = Set{};
    defer set.deinit(allocator);

    const key: Key = @splat(7);
    try std.testing.expect(try set.toggle(allocator, key));
    try std.testing.expect(set.has(key));
    try std.testing.expect(!(try set.toggle(allocator, key)));
    try std.testing.expect(!set.has(key));
}

test "mod keys are stable per id and distinct across ids" {
    try std.testing.expectEqual(modKey("sm64-green-stars"), modKey("sm64-green-stars"));
    try std.testing.expect(!std.mem.eql(u8, &modKey("a"), &modKey("b")));
}

test "content hashes and mod ids do not collide" {
    const hash: Key = @splat(0);
    try std.testing.expect(!std.mem.eql(u8, &hash, &modKey("")));
}

test "containsKey matches the free-standing list" {
    const a: Key = @splat(3);
    const b: Key = @splat(4);
    try std.testing.expect(containsKey(&.{ a, b }, b));
    try std.testing.expect(!containsKey(&.{a}, b));
    try std.testing.expect(!containsKey(&.{}, a));
}
