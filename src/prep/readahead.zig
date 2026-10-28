//! Bounded read-only source cache for sequential firmware image reads.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");

pub const capacity = 1024 * 1024;
pub const sequential_threshold = 64 * 1024;
pub const Input = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) p.Error!void,
};
pub const Stats = struct {
    requests: u64 = 0,
    upstream_reads: u64 = 0,
    upstream_bytes: u64 = 0,
    hits: u64 = 0,
};
pub const Cache = struct {
    input: Input,
    allocator: std.mem.Allocator,
    bytes: []u8,
    start: u64 = 0,
    valid: usize = 0,
    next: u64 = std.math.maxInt(u64),
    consecutive: usize = 0,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, input: Input) !Cache {
        // The object itself never contains a large by-value firmware buffer.
        return .{ .input = input, .allocator = allocator, .bytes = try allocator.alloc(u8, @intCast(@min(input.size, capacity))) };
    }
    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
    pub fn reader(self: *Cache) Input {
        return .{ .context = self, .size = self.input.size, .read_fn = readCallback };
    }
    fn readCallback(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.read(at, out);
    }
    pub fn read(self: *Cache, offset: u64, out: []u8) p.Error!void {
        // Subtraction avoids an overflowing offset+length, including on i486.
        if (offset > self.input.size or out.len > self.input.size - offset) return error.Bounds;
        if (out.len == 0) return;
        self.stats.requests +|= 1;
        if (offset != self.next) self.consecutive = 0;
        const prefetch = self.consecutive >= sequential_threshold;
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            if (self.valid == 0 or at < self.start or at - self.start >= self.valid) {
                const wanted = if (prefetch) self.bytes.len else @min(self.bytes.len, out.len - done);
                const count: usize = @intCast(@min(wanted, self.input.size - at));
                // A failed, partially completed read must not publish stale data.
                self.valid = 0;
                self.stats.upstream_reads +|= 1;
                self.input.read_fn(self.input.context, at, self.bytes[0..count]) catch |err| {
                    self.next = std.math.maxInt(u64);
                    self.consecutive = 0;
                    return err;
                };
                self.stats.upstream_bytes +|= count;
                self.start = at;
                self.valid = count;
            } else {
                self.stats.hits +|= 1;
            }
            const within: usize = @intCast(at - self.start);
            const n = @min(out.len - done, self.valid - within);
            @memcpy(out[done..][0..n], self.bytes[within..][0..n]);
            done += n;
        }
        self.next = offset + out.len;
        self.consecutive = @min(sequential_threshold, self.consecutive +| out.len);
    }
};

const Pattern = struct {
    size: u64,
    calls: usize = 0,
    bytes: u64 = 0,
    failed: bool = false,
    fn byte(at: u64) u8 { return @truncate((at *% 37) ^ (at >> 11) ^ (at >> 32)); }
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Pattern = @ptrCast(@alignCast(ctx));
        if (at > self.size or out.len > self.size - at) return error.Bounds;
        self.calls += 1;
        if (self.failed) {
            @memset(out, 0xff);
            return error.Io;
        }
        self.bytes += out.len;
        for (out, 0..) |*v, i| v.* = byte(at + i);
    }
    fn input(self: *Pattern) Input { return .{ .context = self, .size = self.size, .read_fn = read }; }
    fn expect(at: u64, data: []const u8) !void { for (data, 0..) |v, i| try std.testing.expectEqual(byte(at + i), v); }
};

test "one MiB cache cuts sequential tiny reads and returns exact source bytes" {
    var source: Pattern = .{ .size = 3 * capacity + 123 };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    var out: [1024]u8 = undefined;
    var at: u64 = 0;
    var requests: usize = 0;
    while (at < source.size) {
        const n: usize = @intCast(@min(out.len, source.size - at));
        try cache.read(at, out[0..n]);
        try Pattern.expect(at, out[0..n]);
        at += n;
        requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 3073), requests);
    try std.testing.expectEqual(@as(usize, 67), source.calls);
    try std.testing.expectEqual(source.size, source.bytes);
    try std.testing.expectEqual(@as(u64, 67), cache.stats.upstream_reads);
    try std.testing.expectEqual(@as(usize, capacity), cache.bytes.len);
    try std.testing.expect(@sizeOf(Cache) < 256);
    std.debug.print("SOURCE_READAHEAD measured_requests={d} upstream_reads={d} upstream_bytes={d} cache_bytes={d}\n", .{ requests, source.calls, source.bytes, cache.bytes.len });
}

test "source cache random seeks cross windows and preserve 64 bit offsets" {
    var source: Pattern = .{ .size = 5 * 1024 * @as(u64, 1024 * 1024) + 77 };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    var out: [4117]u8 = undefined;
    const reader = cache.reader();
    for ([_]u64{ 0, 300, capacity - 20, 4 * 1024 * @as(u64, 1024 * 1024) - 13, 1, source.size - out.len, 2 * capacity }) |at| {
        try reader.read_fn(reader.context, at, &out);
        try Pattern.expect(at, &out);
    }
    try std.testing.expect(source.calls < 12);
    try std.testing.expect(source.bytes < 9 * capacity);
}

test "source cache refuses bounds before IO and does not read past final byte" {
    var source: Pattern = .{ .size = 5000 };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    var out: [50]u8 = undefined;
    try std.testing.expectError(error.Bounds, cache.read(4999, &out));
    try std.testing.expectError(error.Bounds, cache.read(std.math.maxInt(u64), &out));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try cache.read(source.size, &.{});
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try cache.read(4950, &out);
    try Pattern.expect(4950, &out);
    try std.testing.expectEqual(@as(u64, 50), source.bytes);
    try std.testing.expectEqual(@as(usize, 5000), cache.bytes.len);
}

test "failed read preserves original IO error and cannot expose partially filled cache" {
    var source: Pattern = .{ .size = 3 * capacity };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    var out: [100]u8 = undefined;
    try cache.read(1, &out);
    source.failed = true;
    try std.testing.expectError(error.Io, cache.read(2 * capacity, &out));
    try std.testing.expectEqual(@as(usize, 0), cache.valid);
    source.failed = false;
    try cache.read(1, &out);
    try Pattern.expect(1, &out);
    try std.testing.expectEqual(@as(usize, 3), source.calls);
}

test "empty input needs no source IO or positive allocation" {
    var source: Pattern = .{ .size = 0 };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    try cache.read(0, &.{});
    try std.testing.expectError(error.Bounds, cache.read(1, &.{}));
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes.len);
}

test "random tiny lookup misses have no read amplification after cache warmup" {
    var source: Pattern = .{ .size = 16 * capacity };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    var out: [64]u8 = undefined;
    for (0..2048) |i| {
        const at = @as(u64, i) * 65537 % (source.size - out.len);
        try cache.read(at, &out);
        try Pattern.expect(at, &out);
    }
    try std.testing.expectEqual(@as(usize, 2048), source.calls);
    try std.testing.expectEqual(@as(u64, 2048 * 64), source.bytes);
    std.debug.print("SOURCE_READAHEAD_RANDOM measured_requests=2048 upstream_reads={d} requested_bytes=131072 upstream_bytes={d}\n", .{ source.calls, source.bytes });
}

test "mixed lookup and payload seeks remain exact while in-window seeks retain cache" {
    var source: Pattern = .{ .size = 64 * capacity };
    var cache = try Cache.init(std.testing.allocator, source.input());
    defer cache.deinit();
    const out = try std.testing.allocator.alloc(u8, sequential_threshold);
    defer std.testing.allocator.free(out);
    for (0..64) |i| {
        const lookup = @as(u64, i % 4) * sequential_threshold;
        const payload = 4 * capacity + @as(u64, i) * 3 * sequential_threshold;
        try cache.read(lookup, out);
        try Pattern.expect(lookup, out);
        try cache.read(payload, out[0..32768]);
        try Pattern.expect(payload, out[0..32768]);
    }
    try std.testing.expectEqual(@as(u64, 64 * (65536 + 32768)), source.bytes);
    try std.testing.expectEqual(@as(usize, 128), source.calls);
    // A fresh contiguous sequence warms up before prefetching. Random reads
    // inside that valid window reset the streak without discarding its bytes.
    try cache.read(32 * capacity, out);
    try std.testing.expectEqual(out.len, cache.valid);
    try cache.read(32 * capacity + out.len, out);
    try std.testing.expectEqual(@as(usize, capacity), cache.valid);
    const calls = source.calls;
    const cached_start = cache.start;
    try cache.read(cached_start + 5, out[0..20]);
    try Pattern.expect(cached_start + 5, out[0..20]);
    try std.testing.expectEqual(calls, source.calls);
    try std.testing.expectEqual(@as(usize, capacity), cache.valid);
    try cache.read(48 * capacity, out[0..20]);
    try std.testing.expectEqual(@as(usize, 20), cache.valid);
    try std.testing.expectEqual(@as(usize, 20), cache.consecutive);
}
