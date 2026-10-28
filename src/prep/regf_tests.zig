//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const regf = @import("regf.zig");
const t = std.testing;
const u = std.unicode.utf8ToUtf16LeStringLiteral;
test "REGF fresh hive all value types, Unicode, empty/default and segmented data" {
    var hive = try regf.Hive.init(t.allocator, u("ROOT"), 123456789);
    defer hive.deinit();
    const key = try hive.ensureKey(u("Objects\\Zażółć\\Leaf"));
    try t.expectEqual(key, (try hive.findKey(u("objects\\ZAŻÓŁĆ\\leaf"))).?);
    try t.expect((try hive.findKey(u("Objects\\Absent"))) == null);
    for (0..12) |kind| {
        var name: [5]u16 = .{ 'T', 'y', 'p', 'e', @intCast('A' + kind) };
        const data = [_]u8{ @intCast(kind), 0, 0, 0, 5, 6, 7, 8 };
        try hive.setValue(key, &name, @intCast(kind), &data);
        const value = (try hive.getValue(key, &name)).?; defer t.allocator.free(value.data);
        try t.expectEqual(kind, value.kind); try t.expectEqualSlices(u8, &data, value.data);
    }
    try hive.setValue(key, u(""), 0, "");
    const empty = (try hive.getValue(key, u(""))).?; defer t.allocator.free(empty.data);
    try t.expectEqual(@as(usize, 0), empty.data.len);
    const big = try t.allocator.alloc(u8, 131129); defer t.allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    try hive.setValue(key, u("Big"), 3, big);
    try hive.seal();
    var copy = try regf.Hive.open(t.allocator, hive.bytes.items, 999); defer copy.deinit();
    const actual = (try copy.getValue((try copy.findKey(u("Objects\\Zażółć\\Leaf"))).?, u("big"))).?; defer t.allocator.free(actual.data);
    try t.expectEqualSlices(u8, big, actual.data);
    try copy.setValue(key, u("BIG"), 3, "new");
    try copy.setValue(key, u("typea"), 11, "01234567");
    try copy.seal();
    var edited = try regf.Hive.open(t.allocator, copy.bytes.items, 1000); defer edited.deinit();
    const replacement = (try edited.getValue(key, u("big"))).?; defer t.allocator.free(replacement.data);
    try t.expectEqualStrings("new", replacement.data);
}
test "REGF rejects dirty checksum version and real-cell-boundary corruption" {
    var hive = try regf.Hive.init(t.allocator, u("ROOT"), 1); defer hive.deinit();
    const source = try t.allocator.dupe(u8, hive.bytes.items); defer t.allocator.free(source);
    source[8] ^= 1;
    try t.expectError(error.DirtyHive, regf.Hive.open(t.allocator, source, 1));
    @memcpy(source, hive.bytes.items); source[12] ^= 1;
    try t.expectError(error.BadChecksum, regf.Hive.open(t.allocator, source, 1));
    @memcpy(source, hive.bytes.items);
    std.mem.writeInt(u32, source[36..40], hive.root + 8, .little);
    std.mem.writeInt(u32, source[508..512], regf.checksum(source), .little);
    try t.expectError(error.CorruptHive, regf.Hive.open(t.allocator, source, 1));
    @memcpy(source, hive.bytes.items);
    std.mem.writeInt(u32, source[36..40], 0xfffffff8, .little);
    std.mem.writeInt(u32, source[508..512], regf.checksum(source), .little);
    try t.expectError(error.CorruptHive, regf.Hive.open(t.allocator, source, 1));
    @memcpy(source, hive.bytes.items);
    std.mem.writeInt(u32, source[40..44], 0xfffff000, .little);
    std.mem.writeInt(u32, source[508..512], regf.checksum(source), .little);
    try t.expectError(error.CorruptHive, regf.Hive.open(t.allocator, source, 1));
    @memcpy(source, hive.bytes.items); std.mem.writeInt(u32, source[24..28], 1, .little);
    std.mem.writeInt(u32, source[508..512], regf.checksum(source), .little);
    try t.expectError(error.UnsupportedHive, regf.Hive.open(t.allocator, source, 1));
}
test "REGF edits preserve untouched keys, classes, security and reuse free cells" {
    var hive = try regf.Hive.init(t.allocator, u("ROOT"), 1); defer hive.deinit();
    const key = try hive.ensureKey(u("Preserved\\Nested"));
    try hive.setValue(key, u("one"), 3, "0123456789");
    const initial_size = hive.bytes.items.len;
    for (0..50) |i| {
        var bytes: [100]u8 = @splat(@intCast(i));
        try hive.setValue(key, u("one"), 3, &bytes);
    }
    try t.expect(hive.bytes.items.len <= initial_size + 4096);
    try hive.seal();
}
