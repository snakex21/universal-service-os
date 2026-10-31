//! Current-directory index cache integration. SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const index = @import("index.zig");
const cached = @import("index_cache.zig");
const r = @import("record.zig");

const Store = struct {
    pages: std.ArrayList([4096]u8) = .empty,
    live: std.ArrayList(bool) = .empty,
    reusable: std.ArrayList(u64) = .empty,
    root: u64 = 0,
    reads: usize = 0,
    writes: usize = 0,
    fail_read: bool = false,
    fail_write: bool = false,
    fail_alloc: bool = false,
    fail_free: bool = false,
    fail_root: bool = false,
    fn backend(self: *Store) index.Backend {
        return .{ .context = self, .read_node = read, .write_node = write,
            .alloc_node = allocate, .free_node = free, .set_root = setRoot };
    }
    fn deinit(self: *Store) void {
        self.pages.deinit(std.testing.allocator);
        self.live.deinit(std.testing.allocator);
        self.reusable.deinit(std.testing.allocator);
    }
    fn read(ctx: *anyopaque, vcn: u64, out: *[4096]u8) !void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.fail_read) return error.Io;
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        out.* = self.pages.items[@intCast(vcn)];
        self.reads += 1;
    }
    fn write(ctx: *anyopaque, vcn: u64, data: *const [4096]u8) !void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.fail_write) return error.Io;
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        self.pages.items[@intCast(vcn)] = data.*;
        self.writes += 1;
    }
    fn allocate(ctx: *anyopaque) !u64 {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.fail_alloc) return error.NoSpace;
        if (self.reusable.pop()) |vcn| {
            self.live.items[@intCast(vcn)] = true;
            return vcn;
        }
        const vcn = self.pages.items.len;
        try self.pages.append(std.testing.allocator, @splat(0));
        try self.live.append(std.testing.allocator, true);
        return @intCast(vcn);
    }
    fn free(ctx: *anyopaque, vcn: u64) !void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.fail_free) return error.Io;
        if (vcn >= self.live.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        try self.reusable.append(std.testing.allocator, vcn);
        self.live.items[@intCast(vcn)] = false;
    }
    fn setRoot(ctx: *anyopaque, vcn: u64) !void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.fail_root) return error.Io;
        self.root = vcn;
    }
};

const Key = struct {
    bytes: [576]u8 = @splat(0),
    len: usize,
    name: [255]u16,
    name_len: usize,
    reference: u64,
    fn make(number: usize, long: bool) Key {
        var result: Key = .{ .len = undefined, .name = undefined, .name_len = if (long) 255 else 16,
            .reference = 0x1000000000000 | @as(u64, @intCast(number)) };
        result.len = 66 + result.name_len * 2;
        result.bytes[64] = @intCast(result.name_len);
        for (0..result.name_len) |i| result.name[i] = if (i < 10) '0' else 'x';
        var value = number;
        for (0..10) |i| {
            result.name[9 - i] = @as(u16, @intCast(value % 10)) + '0';
            value /= 10;
        }
        for (result.name[0..result.name_len], 0..) |unit, i| r.put(u16, &result.bytes, 66 + i * 2, unit);
        return result;
    }
    fn data(self: *const Key) []const u8 { return self.bytes[0..self.len]; }
    fn text(self: *const Key) []const u16 { return self.name[0..self.name_len]; }
};

fn upcase() ![]u16 {
    const table = try std.testing.allocator.alloc(u16, 65536);
    @import("unicode_upper.zig").build(table);
    return table;
}

test "prepared cached insert preserves exact protected tree and removes repeated backend reads" {
    const upper = try upcase(); defer std.testing.allocator.free(upper);
    var ordinary: Store = .{}; defer ordinary.deinit();
    var backing: Store = .{}; defer backing.deinit();
    var cache = try cached.Cache.init(std.testing.allocator, backing.backend()); defer cache.deinit();
    cache.switchOwner(5);
    var original = try index.Tree.create(ordinary.backend(), upper);
    var tree = try index.Tree.create(cache.backend(), upper);
    for (0..50000) |i| {
        const key = Key.make(i, false);
        try std.testing.expect((try original.lookup(key.text())) == null);
        try original.insert(key.reference, key.data());
        var hint: index.InsertHint = undefined;
        try tree.prepareInsert(key.text(), &hint);
        try std.testing.expect(try tree.insertPrepared(key.reference, key.data(), &hint));
    }
    try std.testing.expectEqual(ordinary.root, backing.root);
    try std.testing.expectEqual(ordinary.pages.items.len, backing.pages.items.len);
    for (ordinary.pages.items, backing.pages.items) |a, b| try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expectEqual(ordinary.writes, backing.writes);
    try std.testing.expect(backing.reads < ordinary.reads / 4);
    try std.testing.expect(cache.stats.read_hits > 50000);
    std.debug.print("\nindex-cache50k original_reads={d} cached_reads={d} writes={d} hits={d} fixed_bytes={d}\n", .{
        ordinary.reads, backing.reads, backing.writes, cache.stats.read_hits,
        cached.payload_bytes + @sizeOf(cached.Cache) + @sizeOf(index.InsertHint) + @sizeOf(@import("bitmap.zig").Bitmap),
    });
    for (0..50000) |i| {
        const key = Key.make(i, false);
        try std.testing.expectEqual(key.reference, (try tree.lookup(key.text())).?);
    }
    const duplicate = Key.make(100, false);
    var hint: index.InsertHint = undefined;
    const writes_before = backing.writes;
    try std.testing.expectError(error.InvalidArgument, tree.prepareInsert(duplicate.text(), &hint));
    try std.testing.expectEqual(writes_before, backing.writes);
}

test "prepared hints reject changed root revision owner backend name and repeated use" {
    const upper = try upcase(); defer std.testing.allocator.free(upper);
    var store: Store = .{}; defer store.deinit();
    var cache = try cached.Cache.init(std.testing.allocator, store.backend()); defer cache.deinit();
    cache.switchOwner(5);
    var tree = try index.Tree.create(cache.backend(), upper);
    const reserved = Key.make(9000, false);
    var hint: index.InsertHint = undefined;
    try tree.prepareInsert(reserved.text(), &hint);
    for (0..300) |i| {
        const key = Key.make(i, i % 3 == 0);
        try tree.insert(key.reference, key.data());
    }
    try std.testing.expect(!try tree.insertPrepared(reserved.reference, reserved.data(), &hint));
    try std.testing.expectError(error.InvalidArgument, tree.insertPrepared(reserved.reference, reserved.data(), &hint));
    const switched = Key.make(9001, false);
    try tree.prepareInsert(switched.text(), &hint);
    cache.switchOwner(11);
    try std.testing.expect(!try tree.insertPrepared(switched.reference, switched.data(), &hint));
    const original_name = Key.make(9002, false);
    const changed_name = Key.make(9003, false);
    try tree.prepareInsert(original_name.text(), &hint);
    try std.testing.expect(!try tree.insertPrepared(changed_name.reference, changed_name.data(), &hint));
    try std.testing.expect((try tree.lookup(original_name.text())) == null);
    try std.testing.expectEqual(changed_name.reference, (try tree.lookup(changed_name.text())).?);
    const changed_context = Key.make(9004, false);
    try tree.prepareInsert(changed_context.text(), &hint);
    var other_cache = try cached.Cache.init(std.testing.allocator, store.backend()); defer other_cache.deinit();
    other_cache.switchOwner(11);
    var other = index.Tree.open(other_cache.backend(), upper, tree.root_vcn);
    try std.testing.expect(!try other.insertPrepared(changed_context.reference, changed_context.data(), &hint));
}

test "cached prepared index scales to150000 permuted variable keys with remove and reuse" {
    const upper = try upcase(); defer std.testing.allocator.free(upper);
    var store: Store = .{}; defer store.deinit();
    var cache = try cached.Cache.init(std.testing.allocator, store.backend()); defer cache.deinit();
    cache.switchOwner(55);
    var tree = try index.Tree.create(cache.backend(), upper);
    const count = 150000;
    for (0..count) |i| {
        const number = (i * 7919) % count;
        const key = Key.make(number, number % 31 == 0);
        var hint: index.InsertHint = undefined;
        try tree.prepareInsert(key.text(), &hint);
        try std.testing.expect(try tree.insertPrepared(key.reference, key.data(), &hint));
    }
    try std.testing.expect(store.reads < count * 8);
    for (0..count) |i| {
        const key = Key.make(i, i % 31 == 0);
        try std.testing.expectEqual(key.reference, (try tree.lookup(key.text())).?);
    }
    const allocated_before = store.pages.items.len;
    for (0..1024) |i| {
        const number = (i * 7919) % count;
        const key = Key.make(number, number % 31 == 0);
        try std.testing.expect(try tree.remove(key.text()));
        try std.testing.expect((try tree.lookup(key.text())) == null);
    }
    for (0..1024) |i| {
        const number = (i * 7919) % count;
        const key = Key.make(number, number % 31 == 0);
        var hint: index.InsertHint = undefined;
        try tree.prepareInsert(key.text(), &hint);
        try std.testing.expect(try tree.insertPrepared(key.reference, key.data(), &hint));
        try std.testing.expectEqual(key.reference, (try tree.lookup(key.text())).?);
    }
    if (store.pages.items.len > allocated_before) try std.testing.expectEqual(@as(usize, 0), store.reusable.items.len);
}

test "uncached providers safely rescan and maintain duplicate and Unicode contracts" {
    const upper = try upcase(); defer std.testing.allocator.free(upper);
    var store: Store = .{}; defer store.deinit();
    var tree = try index.Tree.create(store.backend(), upper);
    var key = Key.make(1, false);
    key.name[0] = 0x0105; r.put(u16, &key.bytes, 66, key.name[0]);
    var hint: index.InsertHint = undefined;
    try tree.prepareInsert(key.text(), &hint);
    try std.testing.expect(!try tree.insertPrepared(key.reference, key.data(), &hint));
    key.name[0] = 0x0104;
    try std.testing.expectError(error.InvalidArgument, tree.prepareInsert(key.text(), &hint));
    try std.testing.expectEqual(key.reference, (try tree.lookup(key.text())).?);
}

test "cache eviction free reuse and errors cannot resurrect stale protected pages" {
    var store: Store = .{}; defer store.deinit();
    var cache = try cached.Cache.init(std.testing.allocator, store.backend()); defer cache.deinit();
    cache.switchOwner(5);
    const io = cache.backend();
    var data: [4096]u8 = @splat(0);
    var out: [4096]u8 = undefined;
    for (0..80) |i| {
        const vcn = try io.alloc_node(io.context);
        r.put(u64, &data, 0, i);
        try io.write_node(io.context, vcn, &data);
    }
    const writes_before_read = store.writes;
    for (0..80) |i| {
        try io.read_node(io.context, i, &out);
        try std.testing.expectEqual(@as(u64, @intCast(i)), r.get(u64, &out, 0));
    }
    try std.testing.expectEqual(writes_before_read, store.writes);
    try io.free_node(io.context, 79);
    const reused = try io.alloc_node(io.context);
    try std.testing.expectEqual(@as(u64, 79), reused);
    store.pages.items[79] = @splat(0xaa);
    try io.read_node(io.context, 79, &out);
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xaa));
    const previous = cache.revision;
    store.fail_write = true;
    try std.testing.expectError(error.Io, io.write_node(io.context, 79, &data));
    try std.testing.expect(cache.revision != previous);
    store.fail_write = false;
    store.fail_read = true;
    try std.testing.expectError(error.Io, io.read_node(io.context, 79, &out));
    store.fail_read = false;
    try io.read_node(io.context, 79, &out);
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xaa));
    store.fail_alloc = true;
    try std.testing.expectError(error.NoSpace, io.alloc_node(io.context));
    store.fail_alloc = false;
    store.fail_free = true;
    try std.testing.expectError(error.Io, io.free_node(io.context, 79));
    store.fail_free = false;
    store.fail_root = true;
    try std.testing.expectError(error.Io, io.set_root(io.context, 79));
    store.fail_root = false;
    store.pages.items[79] = @splat(0xbb);
    try io.read_node(io.context, 79, &out);
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xbb));
    cache.switchOwner(99);
    store.pages.items[79] = @splat(0xcc);
    try io.read_node(io.context, 79, &out);
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xcc));
}

test "MST corruption invalidates cache and fixed cache plus hint plus bitmap fit144KiB" {
    const upper = try upcase(); defer std.testing.allocator.free(upper);
    var store: Store = .{}; defer store.deinit();
    var cache = try cached.Cache.init(std.testing.allocator, store.backend()); defer cache.deinit();
    cache.switchOwner(5);
    var tree = try index.Tree.create(cache.backend(), upper);
    const key = Key.make(1, false);
    try tree.insert(key.reference, key.data());
    cache.invalidateAll();
    store.pages.items[@intCast(tree.root_vcn)][510] ^= 1;
    const revision = cache.revision;
    try std.testing.expectError(error.Corrupt, tree.lookup(key.text()));
    try std.testing.expect(cache.revision != revision);
    try std.testing.expect(cached.payload_bytes + @sizeOf(cached.Cache) + @sizeOf(index.InsertHint) + @sizeOf(@import("bitmap.zig").Bitmap) <= 144 * 1024);
}
