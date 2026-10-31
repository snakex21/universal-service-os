//! Offline bulk metadata indexes for NTFS $Secure and $Reparse.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Layout adapted from public ntfs-3g layout.h, commit
//! 7f0f841fc52cf719106c5c93bafe465004e36816, GPL-2.0-or-later,
//! Anton Altaparmakov, Yura Pakhuchiy, Szabolcs Szakacsits and contributors.
//! This is a Zig builder, not a linked C implementation. Promoted separators
//! occur once, and every leaf has the same depth. No descriptor payload or
//! complete index image is buffered here; only one node per recursion level.
const std = @import("std");
const r = @import("record.zig");
const put = r.put;
const get = r.get;
pub const SecurityEntry = struct { offset: u64, hash: u32, id: u32, length: u32 };
pub const ReparseEntry = struct { reference: u64, tag: u32 };
pub const ObjectIdEntry = struct { reference: u64, value: [64]u8 };
pub const Items = union(enum) {
    sii: []const SecurityEntry,
    sdh: []const SecurityEntry,
    reparse: []const ReparseEntry,
    object_id: []const ObjectIdEntry,
    fn len(self: Items) usize {
        return switch (self) {
            inline else => |items| items.len,
        };
    }
    fn leafBytes(self: Items) usize {
        return switch (self) {
            .sii => 40,
            .sdh => 48,
            .reparse => 32,
            .object_id => 88,
        };
    }
    fn keyBytes(self: Items) u16 {
        return switch (self) {
            .sii => 4,
            .sdh => 8,
            .reparse => 12,
            .object_id => 16,
        };
    }
    fn collation(self: Items) u32 {
        return switch (self) {
            .sii => 0x10,
            .sdh => 0x12,
            .reparse => 0x13,
            .object_id => 0x13,
        };
    }
    fn less(self: Items, a: usize, b: usize) bool {
        return switch (self) {
            .sii => |items| items[a].id < items[b].id,
            .sdh => |items| securityHashLess({}, items[a], items[b]),
            .reparse => |items| reparseLess({}, items[a], items[b]),
            .object_id => |items| objectIdLess({}, items[a], items[b]),
        };
    }
    fn encode(self: Items, number: usize, output: []u8, child: ?u64) usize {
        const length = self.leafBytes() + @as(usize, if (child != null) 8 else 0);
        @memset(output[0..length], 0);
        put(u16, output, 8, @intCast(length));
        put(u16, output, 10, self.keyBytes());
        put(u16, output, 12, @intFromBool(child != null));
        switch (self) {
            .sii, .sdh => |items| {
                const entry = items[number];
                const data: usize = if (self == .sii) 20 else 24;
                put(u16, output, 0, @intCast(data));
                put(u16, output, 2, 20);
                if (self == .sii) put(u32, output, 16, entry.id) else {
                    put(u32, output, 16, entry.hash);
                    put(u32, output, 20, entry.id);
                    put(u32, output, 44, 0x00490049);
                }
                put(u32, output, data, entry.hash);
                put(u32, output, data + 4, entry.id);
                put(u64, output, data + 8, entry.offset);
                put(u32, output, data + 16, entry.length);
            },
            .reparse => |items| {
                put(u32, output, 16, items[number].tag);
                put(u64, output, 20, items[number].reference);
            },
            .object_id => |items| {
                const entry = items[number];
                put(u16, output, 0, 32);
                put(u16, output, 2, 56);
                @memcpy(output[16..32], entry.value[0..16]);
                put(u64, output, 32, entry.reference);
                @memcpy(output[40..88], entry.value[16..64]);
            },
        }
        if (child) |vcn| put(u64, output, length - 8, vcn);
        return length;
    }
};
pub fn securityIdLess(_: void, a: SecurityEntry, b: SecurityEntry) bool {
    return a.id < b.id;
}
pub fn securityHashLess(_: void, a: SecurityEntry, b: SecurityEntry) bool {
    return if (a.hash != b.hash) a.hash < b.hash else a.id < b.id;
}
pub fn reparseLess(_: void, a: ReparseEntry, b: ReparseEntry) bool {
    if (a.tag != b.tag) return a.tag < b.tag;
    const low_a: u32 = @truncate(a.reference);
    const low_b: u32 = @truncate(b.reference);
    return if (low_a != low_b) low_a < low_b else (a.reference >> 32) < (b.reference >> 32);
}
pub fn objectIdLess(_: void, a: ObjectIdEntry, b: ObjectIdEntry) bool {
    for (0..4) |i| {
        const left = get(u32, &a.value, i * 4);
        const right = get(u32, &b.value, i * 4);
        if (left != right) return left < right;
    }
    return false;
}
test "object ID keys use ULONG collation and retain extended index data" {
    var a: ObjectIdEntry = .{ .reference = 0x100000000001b, .value = @splat(7) };
    var b = a;
    put(u32, &a.value, 0, 0xff);
    put(u32, &b.value, 0, 0x100);
    try std.testing.expect(objectIdLess({}, a, b));
    try std.testing.expect(!objectIdLess({}, b, a));
    const items: Items = .{ .object_id = &.{a} };
    var encoded: [96]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 88), items.encode(0, &encoded, null));
    try std.testing.expectEqual(@as(u16, 32), get(u16, &encoded, 0));
    try std.testing.expectEqual(@as(u16, 56), get(u16, &encoded, 2));
    try std.testing.expectEqual(@as(u16, 16), get(u16, &encoded, 10));
    try std.testing.expectEqualSlices(u8, a.value[0..16], encoded[16..32]);
    try std.testing.expectEqual(a.reference, get(u64, &encoded, 32));
    try std.testing.expectEqualSlices(u8, a.value[16..64], encoded[40..88]);
}
pub const Sink = struct {
    context: *anyopaque,
    write_node: *const fn (*anyopaque, u64, *const [4096]u8) anyerror!void,
};
pub const Root = struct { bytes: [56]u8, length: usize, node_count: u64, height: u8 };
const Builder = struct {
    items: Items,
    sink: Sink,
    cursor: usize = 0,
    next_vcn: u64 = 0,
    fn capacity(self: *const Builder, height: u8) usize {
        const leaf = (4096 - 64 - 16) / self.items.leafBytes();
        const internal = (4096 - 64 - 24) / (self.items.leafBytes() + 8);
        var result = leaf;
        for (1..height) |_| result = std.math.add(usize, internal, std.math.mul(usize, internal + 1, result) catch return std.math.maxInt(usize)) catch return std.math.maxInt(usize);
        return result;
    }
    fn node(self: *Builder, count: usize, height: u8) anyerror!u64 {
        var page: [4096]u8 = @splat(0);
        @memcpy(page[0..4], "INDX");
        put(u16, &page, 4, 40);
        put(u16, &page, 6, 9);
        put(u32, &page, 24, 40);
        put(u32, &page, 32, 4096 - 24);
        page[36] = @intFromBool(height > 1);
        var pos: usize = 64;
        if (height == 1) {
            for (0..count) |_| {
                pos += self.items.encode(self.cursor, page[pos..], null);
                self.cursor += 1;
            }
            pos += end(page[pos..], null);
        } else {
            const child_capacity = self.capacity(height - 1);
            const children = (count + 1 + child_capacity) / (child_capacity + 1);
            if (children < 2) return error.Corrupt;
            const total_child_keys = count - (children - 1);
            for (0..children) |i| {
                const child_count = total_child_keys / children + @as(usize, @intFromBool(i < total_child_keys % children));
                const child = try self.node(child_count, height - 1);
                if (i + 1 == children) pos += end(page[pos..], child) else {
                    pos += self.items.encode(self.cursor, page[pos..], child);
                    self.cursor += 1;
                }
            }
        }
        if (pos > page.len) return error.Corrupt;
        const vcn = self.next_vcn;
        self.next_vcn += 1;
        put(u64, &page, 16, vcn);
        put(u32, &page, 28, @intCast(pos - 24));
        try r.protect(&page);
        try self.sink.write_node(self.sink.context, vcn, &page);
        return vcn;
    }
};
fn end(output: []u8, child: ?u64) usize {
    const length: usize = if (child != null) 24 else 16;
    @memset(output[0..length], 0);
    put(u16, output, 8, @intCast(length));
    put(u16, output, 12, if (child != null) 3 else 2);
    if (child) |vcn| put(u64, output, 16, vcn);
    return length;
}
pub fn build(items: Items, sink: Sink) !Root {
    if (items.len() > 65536) return error.NoSpace;
    if (items.len() > 1) for (1..items.len()) |i| if (!items.less(i - 1, i)) return error.InvalidArgument;
    var result: Root = .{ .bytes = @splat(0), .length = 48, .node_count = 0, .height = 0 };
    put(u32, &result.bytes, 4, items.collation());
    put(u32, &result.bytes, 8, 4096);
    result.bytes[12] = 1;
    put(u32, &result.bytes, 16, 16);
    if (items.len() == 0) {
        put(u32, &result.bytes, 20, 32);
        put(u32, &result.bytes, 24, 32);
        _ = end(result.bytes[32..], null);
        return result;
    }
    var builder: Builder = .{ .items = items, .sink = sink };
    var height: u8 = 1;
    while (builder.capacity(height) < items.len()) : (height += 1) if (height >= 8) return error.NoSpace;
    const root = try builder.node(items.len(), height);
    if (builder.cursor != items.len()) return error.Corrupt;
    put(u32, &result.bytes, 20, 40);
    put(u32, &result.bytes, 24, 40);
    result.bytes[28] = 1;
    _ = end(result.bytes[32..], root);
    result.length = 56;
    result.node_count = builder.next_vcn;
    result.height = height;
    return result;
}

test "bulk SII/SDH metadata indexes retain every promoted key once and balanced leaves" {
    const Memory = struct {
        nodes: std.ArrayList([4096]u8) = .empty,
        fn write(ctx: *anyopaque, vcn: u64, page: *const [4096]u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(self.nodes.items.len, vcn);
            try self.nodes.append(std.testing.allocator, page.*);
        }
        fn visit(self: *@This(), items: Items, vcn: u64, remaining_height: u8, cursor: *usize) !void {
            try std.testing.expect(vcn < self.nodes.items.len);
            var page = self.nodes.items[@intCast(vcn)];
            try r.unprotect(&page);
            try std.testing.expectEqual(@intFromBool(remaining_height > 1), page[36]);
            var pos: usize = 64;
            const used = get(u32, &page, 28) + 24;
            while (pos < used) {
                const length = get(u16, &page, pos + 8);
                const flags = get(u16, &page, pos + 12);
                if (remaining_height > 1) try self.visit(items, get(u64, &page, pos + length - 8), remaining_height - 1, cursor);
                if (flags & 2 != 0) {
                    try std.testing.expectEqual(pos + length, used);
                    return;
                }
                var expected: [56]u8 = undefined;
                const n = items.encode(cursor.*, &expected, if (remaining_height > 1) get(u64, &page, pos + length - 8) else null);
                try std.testing.expectEqualSlices(u8, expected[0..n], page[pos..][0..n]);
                cursor.* += 1;
                pos += length;
            }
            return error.Corrupt;
        }
    };
    const entries = try std.testing.allocator.alloc(SecurityEntry, 12000);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*entry, i| entry.* = .{ .offset = i * 144, .hash = @truncate(i *% 0x9e3779b1), .id = @intCast(256 + i), .length = 144 };
    inline for (.{ .sii, .sdh }) |kind| {
        if (kind == .sdh) std.mem.sort(SecurityEntry, entries, {}, securityHashLess);
        var memory: Memory = .{};
        defer memory.nodes.deinit(std.testing.allocator);
        const items: Items = @unionInit(Items, @tagName(kind), entries);
        const root = try build(items, .{ .context = &memory, .write_node = Memory.write });
        try std.testing.expect(root.height >= 3);
        var cursor: usize = 0;
        try memory.visit(items, get(u64, &root.bytes, 48), root.height, &cursor);
        try std.testing.expectEqual(entries.len, cursor);
        try std.testing.expectEqual(memory.nodes.items.len, root.node_count);
    }
}
