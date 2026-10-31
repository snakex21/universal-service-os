//! NTFS on-disk records, written field by field without native ABI structs.
//! Format references: Linux-NTFS Documentation 0.6 and ntfs-3g layout.h
//! (GPL-2.0-or-later, Tuxera/Linux-NTFS contributors). This implementation
//! is independently structured Zig; no Microsoft source code is used.
const std = @import("std");
const runs = @import("runs.zig");
pub const Error = error{ NoSpace, Corrupt, InvalidArgument };
pub fn get(comptime T: type, b: []const u8, p: usize) T {
    return std.mem.readInt(T, b[p..][0..@sizeOf(T)], .little);
}
pub fn put(comptime T: type, b: []u8, p: usize, v: T) void {
    std.mem.writeInt(T, b[p..][0..@sizeOf(T)], v, .little);
}
pub fn aligned(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}
pub fn utf16(out: []u8, input: []const u16) void {
    for (input, 0..) |c, i| put(u16, out, i * 2, c);
}
pub fn protect(b: []u8) Error!void {
    if (b.len % 512 != 0 or b.len < 512) return error.Corrupt;
    const offset = get(u16, b, 4);
    const count = get(u16, b, 6);
    if (count != b.len / 512 + 1 or offset + @as(usize, count) * 2 > 510) return error.Corrupt;
    var usn = get(u16, b, offset) +% 1;
    if (usn == 0 or usn == 0xffff) usn = 1;
    put(u16, b, offset, usn);
    for (1..count) |i| {
        const end = i * 512 - 2;
        put(u16, b, offset + i * 2, get(u16, b, end));
        put(u16, b, end, usn);
    }
}
pub fn unprotect(b: []u8) Error!void {
    if (b.len % 512 != 0 or b.len < 512) return error.Corrupt;
    const offset = get(u16, b, 4);
    const count = get(u16, b, 6);
    if (count != b.len / 512 + 1 or offset + @as(usize, count) * 2 > 510) return error.Corrupt;
    const usn = get(u16, b, offset);
    for (1..count) |i| {
        const end = i * 512 - 2;
        if (get(u16, b, end) != usn) return error.Corrupt;
        put(u16, b, end, get(u16, b, offset + i * 2));
    }
}
pub const Builder = struct {
    b: [1024]u8 = @splat(0),
    pos: usize = 56,
    next_id: u16 = 0,
    pub fn init(number: u64, sequence: u16, flags: u16, links: u16) Builder {
        var self: Builder = .{};
        @memcpy(self.b[0..4], "FILE");
        put(u16, &self.b, 4, 48);
        put(u16, &self.b, 6, 3);
        put(u16, &self.b, 16, sequence);
        put(u16, &self.b, 18, links);
        put(u16, &self.b, 20, 56);
        put(u16, &self.b, 22, flags);
        put(u32, &self.b, 28, 1024);
        put(u32, &self.b, 44, @intCast(number));
        self.finish();
        return self;
    }
    pub fn finish(self: *Builder) void {
        put(u32, &self.b, self.pos, 0xffffffff);
        put(u32, &self.b, 24, @intCast(self.pos + 8));
        put(u16, &self.b, 40, self.next_id);
    }
    fn head(self: *Builder, kind: u32, name: []const u16, size: usize, is_nonresident: bool) Error![]u8 {
        if (name.len > 255 or self.pos + size + 8 > self.b.len) return error.NoSpace;
        const attr = self.b[self.pos..][0..size];
        @memset(attr, 0);
        put(u32, attr, 0, kind);
        put(u32, attr, 4, @intCast(size));
        attr[8] = @intFromBool(is_nonresident);
        attr[9] = @intCast(name.len);
        if (name.len > 0) put(u16, attr, 10, if (is_nonresident) 64 else 24);
        put(u16, attr, 14, self.next_id);
        self.next_id += 1;
        self.pos += size;
        self.finish();
        return attr;
    }
    pub fn resident(self: *Builder, kind: u32, name: []const u16, payload: []const u8, indexed: bool) Error!void {
        const vo = aligned(24 + name.len * 2);
        const a = try self.head(kind, name, aligned(vo + payload.len), false);
        put(u32, a, 16, @intCast(payload.len));
        put(u16, a, 20, @intCast(vo));
        a[22] = @intFromBool(indexed);
        utf16(a[24..], name);
        @memcpy(a[vo..][0..payload.len], payload);
    }
    pub fn nonresident(self: *Builder, kind: u32, name: []const u16, lcn: ?u64, clusters: u64, data_bytes: u64, initialized_bytes: u64) Error!void {
        var pairs: [24]u8 = undefined;
        const length = try runlist(&pairs, lcn, clusters);
        const ro = aligned(64 + name.len * 2);
        const a = try self.head(kind, name, aligned(ro + length), true);
        put(u64, a, 24, if (clusters == 0) 0 else clusters - 1);
        put(u16, a, 32, @intCast(ro));
        put(u64, a, 40, if (lcn == null) 0 else clusters * 4096);
        put(u64, a, 48, data_bytes);
        put(u64, a, 56, initialized_bytes);
        utf16(a[64..], name);
        @memcpy(a[ro..][0..length], pairs[0..length]);
    }
    pub fn copyRaw(self: *Builder, source: []const u8) Error!u16 {
        if (source.len < 24 or source.len % 8 != 0 or get(u32, source, 4) != source.len or self.pos + source.len + 8 > self.b.len) return error.NoSpace;
        const id = self.next_id;
        @memcpy(self.b[self.pos..][0..source.len], source);
        put(u16, &self.b, self.pos + 14, id);
        self.next_id += 1;
        self.pos += source.len;
        self.finish();
        return id;
    }
    pub fn nonresidentRuns(self: *Builder, kind: u32, name: []const u16, list: []const runs.Run, lowest_vcn: u64, allocated_bytes: u64, data_bytes: u64, initialized_bytes: u64) Error!void {
        return self.nonresidentRunsFlags(kind, name, list, lowest_vcn, allocated_bytes, data_bytes, initialized_bytes, 0, 0);
    }
    /// Sparse/compressed NTFS uses the 72-byte header and unit=4, including
    /// physically full (uncompressed) 16-cluster compression units.
    pub fn nonresidentRunsFlags(self: *Builder, kind: u32, name: []const u16, list: []const runs.Run, lowest_vcn: u64, allocated_bytes: u64, data_bytes: u64, initialized_bytes: u64, flags: u16, physical_bytes: u64) Error!void {
        var pairs: [896]u8 = undefined;
        const length = runs.encode(&pairs, list) catch |err| return switch (err) {
            error.NoSpace => error.NoSpace,
            error.InvalidArgument => error.InvalidArgument,
            else => error.Corrupt,
        };
        const count = runs.totalClusters(list) catch return error.Corrupt;
        const header: usize = if (flags & 0x8001 != 0) 72 else 64;
        const ro = aligned(header + name.len * 2);
        const a = try self.head(kind, name, aligned(ro + length), true);
        put(u64, a, 16, lowest_vcn);
        put(u64, a, 24, if (count == 0) std.math.maxInt(u64) else std.math.add(u64, lowest_vcn, count - 1) catch return error.Corrupt);
        put(u16, a, 32, @intCast(ro));
        put(u16, a, 12, flags);
        if (header == 72) {
            a[34] = 4;
            put(u64, a, 64, physical_bytes);
        }
        put(u64, a, 40, allocated_bytes);
        put(u64, a, 48, data_bytes);
        put(u64, a, 56, initialized_bytes);
        if (name.len != 0) put(u16, a, 10, @intCast(header));
        utf16(a[header..], name);
        @memcpy(a[ro..][0..length], pairs[0..length]);
    }
};
pub fn runlist(out: []u8, lcn: ?u64, clusters: u64) Error!usize {
    if (clusters == 0) {
        out[0] = 0;
        return 1;
    }
    // Mapping-pair lengths are positive signed values too. In particular,
    // 0x8001 clusters needs 01 80 00; omitting the sign byte passes a naive
    // unsigned reader but the independent NTFS driver rejects the run.
    const n: usize = @max(1, (65 - @clz(clusters) + 7) / 8);
    const k: usize = if (lcn) |p| @max(1, (65 - @clz(p) + 7) / 8) else 0;
    if (n > 8 or k > 8 or out.len < n + k + 2) return error.InvalidArgument;
    out[0] = @as(u8, @intCast(k << 4 | n));
    for (0..n) |i| out[i + 1] = @truncate(clusters >> @intCast(i * 8));
    if (lcn) |p| for (0..k) |i| {
        out[n + i + 1] = @truncate(p >> @intCast(i * 8));
    };
    out[n + k + 1] = 0;
    return n + k + 2;
}
pub const Attribute = struct { offset: usize, bytes: []u8 };
pub fn find(b: []u8, kind: u32, name: []const u16) Error!?Attribute {
    var pos: usize = get(u16, b, 20);
    while (pos + 8 <= b.len) {
        const t = get(u32, b, pos);
        if (t == 0xffffffff) return null;
        const n = get(u32, b, pos + 4);
        if (n < 24 or n % 8 != 0 or pos + n > b.len) return error.Corrupt;
        const a = b[pos..][0..n];
        if (t == kind and a[9] == name.len) {
            const off: usize = get(u16, a, 10);
            if (off + name.len * 2 > n) return error.Corrupt;
            var equal = true;
            for (name, 0..) |c, i| if (get(u16, a, off + i * 2) != c) {
                equal = false;
            };
            if (equal) return .{ .offset = pos, .bytes = a };
        }
        pos += n;
    }
    return error.Corrupt;
}
pub fn value(a: []u8) Error![]u8 {
    if (a[8] != 0) return error.Corrupt;
    const off = get(u16, a, 20);
    const len = get(u32, a, 16);
    if (@as(u64, off) + len > a.len) return error.Corrupt;
    return a[off..][0..len];
}

test "fixups preserve sector ends and detect torn writes" {
    var b = Builder.init(7, 1, 1, 1);
    put(u16, &b.b, 510, 0x5a31);
    put(u16, &b.b, 1022, 0xaa82);
    try protect(&b.b);
    const protected = b.b;
    try unprotect(&b.b);
    try std.testing.expectEqual(@as(u16, 0x5a31), get(u16, &b.b, 510));
    try std.testing.expectEqual(@as(u16, 0xaa82), get(u16, &b.b, 1022));
    b.b = protected;
    b.b[1022] ^= 1;
    try std.testing.expectError(error.Corrupt, unprotect(&b.b));
}
test "runlist sign padding and resident bounds" {
    var b = Builder.init(27, 1, 1, 1);
    try b.resident(0x80, &.{}, "small", false);
    const attr = (try find(&b.b, 0x80, &.{})).?;
    try std.testing.expectEqualStrings("small", try value(attr.bytes));
    var run: [24]u8 = undefined;
    const n = try runlist(&run, 0x80, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0x21, 1, 0x80, 0, 0 }, run[0..n]);
    const long_n = try runlist(&run, 4, 0x8001);
    try std.testing.expectEqualSlices(u8, &.{ 0x13, 1, 0x80, 0, 4, 0 }, run[0..long_n]);
}
