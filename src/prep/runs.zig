//! Signed NTFS mapping pairs and bounded stream address translation.
//! Format: public Linux-NTFS attribute/runlist documentation; no OS code copied.
const std = @import("std");
pub const Run = struct { lcn: ?u64, clusters: u64 };
pub const Error = error{ Corrupt, Bounds, NoSpace, InvalidArgument };

fn signedBytes(value: i64) usize {
    var count: usize = 1;
    var rest = value >> 7;
    while (rest != 0 and rest != -1) : (count += 1) rest >>= 8;
    return count;
}
pub fn encodedSize(list: []const Run) Error!usize {
    var previous: i64 = 0;
    var size: usize = 1;
    for (list) |run| {
        if (run.clusters == 0 or run.clusters > std.math.maxInt(i64)) return error.InvalidArgument;
        const length: i64 = @intCast(run.clusters);
        var delta: i64 = 0;
        if (run.lcn) |lcn| {
            const current = std.math.cast(i64, lcn) orelse return error.Bounds;
            delta = std.math.sub(i64, current, previous) catch return error.Bounds;
            previous = current;
        }
        size = std.math.add(usize, size, 1 + signedBytes(length) + (if (run.lcn != null) signedBytes(delta) else 0)) catch return error.Bounds;
    }
    return size;
}
pub fn encode(out: []u8, list: []const Run) Error!usize {
    const size = try encodedSize(list);
    if (size > out.len) return error.NoSpace;
    var pos: usize = 0;
    var previous: i64 = 0;
    for (list) |run| {
        const n = signedBytes(@intCast(run.clusters));
        var delta: i64 = 0;
        if (run.lcn) |lcn| {
            const current: i64 = @intCast(lcn);
            delta = current - previous;
            previous = current;
        }
        const k: usize = if (run.lcn != null) signedBytes(delta) else 0;
        out[pos] = @intCast(n | (k << 4));
        pos += 1;
        for (0..n) |i| {
            out[pos] = @truncate(run.clusters >> @intCast(i * 8));
            pos += 1;
        }
        const bits: u64 = @bitCast(delta);
        for (0..k) |i| {
            out[pos] = @truncate(bits >> @intCast(i * 8));
            pos += 1;
        }
    }
    out[pos] = 0;
    return pos + 1;
}
pub const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    previous: i64 = 0,
    vcn: u64 = 0,
    ended: bool = false,
    pub fn next(self: *Decoder) Error!?Run {
        if (self.ended) return null;
        if (self.pos >= self.bytes.len) return error.Corrupt;
        const head = self.bytes[self.pos];
        self.pos += 1;
        if (head == 0) {
            self.ended = true;
            return null;
        }
        const n: usize = head & 15;
        const k: usize = head >> 4;
        if (n == 0 or n > 8 or k > 8 or self.pos + n + k > self.bytes.len) return error.Corrupt;
        var clusters: u64 = 0;
        for (0..n) |i| clusters |= @as(u64, self.bytes[self.pos + i]) << @intCast(i * 8);
        if (clusters == 0 or self.bytes[self.pos + n - 1] & 0x80 != 0) return error.Corrupt;
        self.pos += n;
        var lcn: ?u64 = null;
        if (k != 0) {
            var raw: u64 = 0;
            for (0..k) |i| raw |= @as(u64, self.bytes[self.pos + i]) << @intCast(i * 8);
            if (k < 8 and self.bytes[self.pos + k - 1] & 0x80 != 0) raw |= @as(u64, std.math.maxInt(u64)) << @intCast(k * 8);
            self.previous = std.math.add(i64, self.previous, @as(i64, @bitCast(raw))) catch return error.Corrupt;
            if (self.previous < 0) return error.Corrupt;
            lcn = @intCast(self.previous);
        }
        self.pos += k;
        self.vcn = std.math.add(u64, self.vcn, clusters) catch return error.Corrupt;
        return .{ .lcn = lcn, .clusters = clusters };
    }
};
pub const Location = struct { lcn: ?u64, available: u64 };
pub fn locate(list: []const Run, vcn: u64) Error!Location {
    var cursor = vcn;
    for (list) |run| {
        if (cursor < run.clusters) return .{ .lcn = if (run.lcn) |lcn| std.math.add(u64, lcn, cursor) catch return error.Bounds else null, .available = run.clusters - cursor };
        cursor -= run.clusters;
    }
    return error.Bounds;
}
pub fn totalClusters(list: []const Run) Error!u64 {
    var count: u64 = 0;
    for (list) |run| count = std.math.add(u64, count, run.clusters) catch return error.Bounds;
    return count;
}

test "mapping pairs signed forward/backward offsets, >4GiB and sparse" {
    const original = [_]Run{ .{ .lcn = 0x8000, .clusters = 0x8001 }, .{ .lcn = 3, .clusters = 2 }, .{ .lcn = null, .clusters = 7 }, .{ .lcn = 0x123456, .clusters = 5 * 1024 * 1024 * 1024 / 4096 } };
    var buffer: [128]u8 = undefined;
    const size = try encode(&buffer, &original);
    var decoder: Decoder = .{ .bytes = buffer[0..size] };
    for (original) |expected| try std.testing.expectEqualDeep(expected, (try decoder.next()).?);
    try std.testing.expectEqual(@as(?Run, null), try decoder.next());
    const loc = try locate(&original, 0x8001);
    try std.testing.expectEqual(@as(?u64, 3), loc.lcn);
    try std.testing.expectError(error.Bounds, locate(&original, 99999999));
}
test "mapping pairs reject truncation, negative length and negative physical position" {
    var bad: Decoder = .{ .bytes = &.{ 0x11, 1, 0xff, 0 } };
    try std.testing.expectError(error.Corrupt, bad.next());
    bad = .{ .bytes = &.{ 0x12, 1, 0x80, 4, 0 } };
    try std.testing.expectError(error.Corrupt, bad.next());
    bad = .{ .bytes = &.{ 0x11, 1 } };
    try std.testing.expectError(error.Corrupt, bad.next());
    var output: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpace, encode(&output, &.{.{ .lcn = 1, .clusters = 1 }}));
}
