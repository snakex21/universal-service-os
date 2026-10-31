//! Fault, order, overlay and durability tests using self-owned byte fixtures.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const c = @import("writecombine.zig");
const p = @import("platform.zig");
const Event = struct { kind: enum { write, flush }, at: u64 = 0, bytes: usize = 0 };
const Memory = struct {
    bytes: []u8,
    events: [128]Event = undefined,
    used: usize = 0,
    reads: usize = 0,
    fail_write: bool = false,
    fail_read: bool = false,
    fail_flush: bool = false,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        if (self.fail_read) return error.Corrupt;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, at: u64, bytes: []const u8) p.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.events[self.used] = .{ .kind = .write, .at = at, .bytes = bytes.len }; self.used += 1;
        if (self.fail_write) {
            // Real failed storage writes can have partially changed media.
            @memcpy(self.bytes[@intCast(at)..][0..@min(7, bytes.len)], bytes[0..@min(7, bytes.len)]);
            return error.Io;
        }
        @memcpy(self.bytes[@intCast(at)..][0..bytes.len], bytes);
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.events[self.used] = .{ .kind = .flush }; self.used += 1;
        if (self.fail_flush) return error.NoSpace;
    }
    fn disk(self: *@This()) p.Disk { return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush }; }
};
fn makeBytes(n: usize) ![]u8 { const result = try std.testing.allocator.alloc(u8, n); @memset(result, 0); return result; }

test "sixteen sequential64KiB writes produce one aligned1MiB backend write" {
    const data = try makeBytes(2 * c.capacity); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = c.capacity };
    var cache = try c.Cache.init(tracked.allocator(), memory.disk(), .qcow2_file);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(cache.buffer.ptr) % 4096);
    try std.testing.expectEqual(@as(usize, c.capacity), tracked.peak);
    const disk = cache.disk();
    const page = try makeBytes(65536); defer std.testing.allocator.free(page);
    for (0..16) |i| {
        @memset(page, @intCast(i + 1));
        try disk.write(i * page.len, page);
    }
    try std.testing.expectEqual(@as(usize, 1), memory.used);
    try std.testing.expectEqual(@as(usize, c.capacity), memory.events[0].bytes);
    for (0..16) |i| try std.testing.expect(std.mem.allEqual(u8, data[i * page.len..][0..page.len], @intCast(i + 1)));
    try disk.flush();
    try std.testing.expectEqual(Event{ .kind = .flush }, memory.events[1]);
    std.debug.print("WRITE_COMBINE measured_writes=16 upstream_writes={d} bytes={d} capacity={d}\n", .{ cache.stats.upstream_writes, cache.stats.upstream_bytes, cache.buffer.len });
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 0), tracked.current);
}

test "read overlay covers pending bytes and exact upstream prefix suffix without draining" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    for (data, 0..) |*v, i| v.* = @truncate(i *% 3);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .raw_file); defer cache.deinit();
    const disk = cache.disk();
    try disk.write(100, "ABCDEFGHIJ");
    var out: [20]u8 = undefined;
    try disk.read(95, &out);
    try std.testing.expectEqualSlices(u8, data[95..100], out[0..5]);
    try std.testing.expectEqualSlices(u8, "ABCDEFGHIJ", out[5..15]);
    try std.testing.expectEqualSlices(u8, data[110..115], out[15..20]);
    try std.testing.expectEqual(@as(usize, 2), memory.reads);
    try disk.read(102, out[0..4]);
    try std.testing.expectEqualStrings("CDEF", out[0..4]);
    try std.testing.expectEqual(@as(usize, 2), memory.reads);
    try std.testing.expectEqual(@as(usize, 0), memory.used);
    try std.testing.expectEqual(@as(usize, 10), cache.pending);
    try disk.flush();
    try std.testing.expectEqualStrings("ABCDEFGHIJ", data[100..110]);
}

test "overlapping backward random writes and explicit flush preserve publication order" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .raw_file); defer cache.deinit();
    const disk = cache.disk();
    try disk.write(100, "first");
    try disk.write(102, "NEW"); // overlap drains the prior version first
    try disk.write(20, "back");
    try disk.flush();
    try std.testing.expectEqual(Event{ .kind = .write, .at = 100, .bytes = 5 }, memory.events[0]);
    try std.testing.expectEqual(Event{ .kind = .write, .at = 102, .bytes = 3 }, memory.events[1]);
    try std.testing.expectEqual(Event{ .kind = .write, .at = 20, .bytes = 4 }, memory.events[2]);
    try std.testing.expectEqual(Event{ .kind = .flush }, memory.events[3]);
    try std.testing.expectEqualStrings("fiNEW", data[100..105]);
    try std.testing.expectEqualStrings("back", data[20..24]);
}

test "failed partial batch poisons flush but dirty repair writes bypass uncertain cache" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .raw_file); defer cache.deinit();
    const disk = cache.disk();
    try disk.write(100, "unreliable payload");
    memory.fail_write = true;
    try std.testing.expectError(error.Io, disk.flush());
    try std.testing.expectEqual(@as(usize, 0), cache.pending);
    try std.testing.expectEqual(error.Io, cache.first_error.?);
    memory.fail_write = false;
    try disk.write(100, "DIRTY=1");
    try std.testing.expectEqualStrings("DIRTY=1", data[100..107]);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.recovery_writes);
    try std.testing.expectError(error.Io, disk.flush());
    try std.testing.expectEqual(Event{ .kind = .flush }, memory.events[memory.used - 1]);
    try std.testing.expectEqualStrings("DIRTY=1", data[100..107]);
}

test "failed durability barrier preserves its original error after recovery attempts" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .qcow2_file); defer cache.deinit();
    const disk = cache.disk();
    try disk.write(100, "clean=0");
    memory.fail_flush = true;
    try std.testing.expectError(error.NoSpace, disk.flush());
    memory.fail_flush = false;
    try disk.write(100, "dirty=1");
    try std.testing.expectError(error.NoSpace, disk.flush());
    try std.testing.expectEqualStrings("dirty=1", data[100..107]);
}

test "read error discards pending cache and deinit performs no storage IO" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .raw_file);
    const disk = cache.disk();
    try disk.write(100, "pending");
    memory.fail_read = true;
    var out: [1]u8 = undefined;
    try std.testing.expectError(error.Corrupt, disk.read(0, &out));
    try std.testing.expectEqual(@as(usize, 0), cache.pending);
    const before = memory.used;
    cache.deinit();
    try std.testing.expectEqual(before, memory.used);
}

test "bounds and empty operations neither flush pending bytes nor reach the backend" {
    const data = try makeBytes(8192); defer std.testing.allocator.free(data);
    var memory: Memory = .{ .bytes = data };
    var cache = try c.Cache.init(std.testing.allocator, memory.disk(), .raw_file);
    const disk = cache.disk();
    try disk.write(100, "pending");
    var out: [20]u8 = undefined;
    try std.testing.expectError(error.Bounds, disk.write(8190, "bad"));
    try std.testing.expectError(error.Bounds, disk.read(std.math.maxInt(u64), &out));
    try disk.write(8192, &.{}); try disk.read(8192, &.{});
    try std.testing.expectEqual(@as(usize, 0), memory.used);
    try std.testing.expectEqual(@as(usize, 0), memory.reads);
    try std.testing.expectEqual(@as(usize, 7), cache.pending);
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 0), memory.used);
    try std.testing.expect(std.mem.allEqual(u8, data, 0));
}

test "target offsets above4GiB are preserved without allocating a whole disk" {
    const Sparse = struct {
        base: u64 = 5 * 1024 * @as(u64, 1024 * 1024),
        bytes: [4096]u8 = @splat(0),
        last_write: u64 = 0,
        fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at < self.base or at - self.base > self.bytes.len or out.len > self.bytes.len - (at - self.base)) return error.Bounds;
            @memcpy(out, self.bytes[@intCast(at - self.base)..][0..out.len]);
        }
        fn write(ctx: *anyopaque, at: u64, data: []const u8) p.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at < self.base or at - self.base > self.bytes.len or data.len > self.bytes.len - (at - self.base)) return error.Bounds;
            self.last_write = at;
            @memcpy(self.bytes[@intCast(at - self.base)..][0..data.len], data);
        }
        fn flush(_: *anyopaque) p.Error!void {}
    };
    var memory: Sparse = .{};
    const base: p.Disk = .{ .context = &memory, .sectors = (memory.base + memory.bytes.len) / 512,
        .read_fn = Sparse.read, .write_fn = Sparse.write, .flush_fn = Sparse.flush };
    var cache = try c.Cache.init(std.testing.allocator, base, .raw_file); defer cache.deinit();
    const disk = cache.disk();
    try disk.write(memory.base + 777, "large offset");
    var out: [12]u8 = undefined; try disk.read(memory.base + 777, &out);
    try std.testing.expectEqualStrings("large offset", &out);
    try disk.flush();
    try std.testing.expectEqual(memory.base + 777, memory.last_write);
    try std.testing.expectEqualStrings("large offset", memory.bytes[777..789]);
}
