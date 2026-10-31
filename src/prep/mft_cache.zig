//! Bounded single-writer cache of logical (MST-unprotected) MFT records.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Publication barriers belong to Ntfs, not to this storage-independent cache.
const std = @import("std");

pub const record_bytes = 1024;
pub const set_count = 256;
pub const ways = 4;
pub const capacity = set_count * ways;
const invalid = std.math.maxInt(u64);
const Entry = struct {
    data: [record_bytes]u8 = undefined,
    number: u64 = invalid,
    age: u8 = 0,
    dirty: bool = false,
};
pub const allocated_bytes = @sizeOf(Entry) * capacity;
pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u64, *[record_bytes]u8) anyerror!void,
    // May update the logical record's USA state after a successful MST write.
    write: *const fn (*anyopaque, u64, *[record_bytes]u8) anyerror!void,
};
pub const Statistics = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    stores: u64 = 0,
    writebacks: u64 = 0,
    dirty_evictions: u64 = 0,
};
pub const Cache = struct {
    entries: []Entry,
    statistics: Statistics = .{},

    pub fn init(allocator: std.mem.Allocator) !Cache {
        const entries = try allocator.alloc(Entry, capacity);
        for (entries) |*entry| entry.* = .{};
        return .{ .entries = entries };
    }
    /// Deliberately never flush: failure/abandonment must not publish data.
    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }
    fn set(self: *Cache, number: u64) []Entry {
        const bucket: usize = @intCast(number & (set_count - 1));
        return self.entries[bucket * ways ..][0..ways];
    }
    fn find(self: *Cache, number: u64) ?*Entry {
        for (self.set(number)) |*entry| if (entry.number == number) return entry;
        return null;
    }
    fn touch(self: *Cache, number: u64, chosen: *Entry) void {
        for (self.set(number)) |*entry| {
            if (entry == chosen) entry.age = 0 else entry.age = @min(ways - 1, entry.age + 1);
        }
    }
    fn flushEntry(self: *Cache, backend: Backend, entry: *Entry) !void {
        if (!entry.dirty) return;
        // On failure preserve both the tag and dirty data for diagnosis;
        // the owning filesystem poisons itself and must not retry finish.
        try backend.write(backend.context, entry.number, &entry.data);
        entry.dirty = false;
        self.statistics.writebacks +|= 1;
    }
    fn victim(self: *Cache, backend: Backend, number: u64) !*Entry {
        const candidates = self.set(number);
        var oldest = &candidates[0];
        for (candidates) |*entry| {
            if (entry.number == invalid) return entry;
            if (entry.age > oldest.age) oldest = entry;
        }
        const dirty = oldest.dirty;
        try self.flushEntry(backend, oldest);
        if (dirty) self.statistics.dirty_evictions +|= 1;
        return oldest;
    }
    pub fn read(self: *Cache, backend: Backend, number: u64, out: *[record_bytes]u8) !void {
        return self.readImpl(backend, number, out, false);
    }
    /// Allocation is already a mutation: it may evict a dirty slot to retain
    /// the free record's sequence for subsequent in-memory construction.
    pub fn readForMutation(self: *Cache, backend: Backend, number: u64, out: *[record_bytes]u8) !void {
        return self.readImpl(backend, number, out, true);
    }
    fn readImpl(self: *Cache, backend: Backend, number: u64, out: *[record_bytes]u8, mutating: bool) !void {
        if (self.find(number)) |entry| {
            self.statistics.hits +|= 1;
            out.* = entry.data;
            self.touch(number, entry);
            return;
        }
        self.statistics.misses +|= 1;
        // Do not destroy a valid victim if the incoming disk record is bad.
        var incoming: [record_bytes]u8 = undefined;
        try backend.read(backend.context, number, &incoming);
        const entry = if (mutating) try self.victim(backend, number) else blk: {
            var clean: ?*Entry = null;
            for (self.set(number)) |*candidate| {
                if (candidate.number == invalid) break :blk candidate;
                if (!candidate.dirty and (clean == null or candidate.age > clean.?.age)) clean = candidate;
            }
            // A read-only lookup must not turn a cold read into a writeback.
            // Bypass retention when every way contains pending dirty data.
            break :blk clean orelse {
                out.* = incoming;
                return;
            };
        };
        entry.* = .{ .number = number, .data = incoming };
        self.touch(number, entry);
        out.* = incoming;
    }
    pub fn store(self: *Cache, backend: Backend, number: u64, data: *const [record_bytes]u8) !void {
        const entry = self.find(number) orelse try self.victim(backend, number);
        entry.* = .{ .number = number, .data = data.*, .dirty = true };
        self.touch(number, entry);
        self.statistics.stores +|= 1;
    }
    pub fn flushRecord(self: *Cache, backend: Backend, number: u64) !void {
        if (self.find(number)) |entry| try self.flushEntry(backend, entry);
    }
    pub fn flush(self: *Cache, backend: Backend) !void {
        for (self.entries) |*entry| try self.flushEntry(backend, entry);
    }
};

const TestBackend = struct {
    reads: usize = 0,
    writes: usize = 0,
    fail_write: bool = false,
    last_number: u64 = invalid,
    last: [record_bytes]u8 = @splat(0),
    fn read(ctx: *anyopaque, number: u64, out: *[record_bytes]u8) !void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        @memset(out, @truncate(number));
    }
    fn write(ctx: *anyopaque, number: u64, data: *[record_bytes]u8) !void {
        const self: *TestBackend = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (self.fail_write) return error.Io;
        self.last_number = number;
        self.last = data.*;
    }
    fn backend(self: *TestBackend) Backend {
        return .{ .context = self, .read = read, .write = write };
    }
};
test "MFT cache coalesces writes and serves latest logical bytes without IO" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    var disk: TestBackend = .{};
    var data: [record_bytes]u8 = @splat(17);
    try cache.store(disk.backend(), 27, &data);
    data[511] = 91;
    try cache.store(disk.backend(), 27, &data);
    var actual: [record_bytes]u8 = undefined;
    try cache.read(disk.backend(), 27, &actual);
    try std.testing.expectEqualSlices(u8, &data, &actual);
    try std.testing.expectEqual(@as(usize, 0), disk.reads + disk.writes);
    try cache.flush(disk.backend());
    try std.testing.expectEqual(@as(usize, 1), disk.writes);
    try cache.flush(disk.backend());
    try std.testing.expectEqual(@as(usize, 1), disk.writes);
    try std.testing.expect(allocated_bytes < 1100 * 1024);
}
test "MFT cache collision flush failure preserves dirty victim and newer input stays unpublished" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    var disk: TestBackend = .{};
    var data: [record_bytes]u8 = @splat(33);
    for (0..ways) |i| try cache.store(disk.backend(), 27 + i * set_count, &data);
    disk.fail_write = true;
    try std.testing.expectError(error.Io, cache.store(disk.backend(), 27 + ways * set_count, &data));
    try std.testing.expect(cache.find(27) != null);
    try std.testing.expect(cache.find(27).?.dirty);
    try std.testing.expect(cache.find(27 + ways * set_count) == null);
    disk.fail_write = false;
    try cache.flushRecord(disk.backend(), 27);
    try std.testing.expectEqual(@as(u64, 27), disk.last_number);
    try std.testing.expectEqualSlices(u8, &data, &disk.last);
}
test "MFT cache clean read hit and abandonment perform no extra write" {
    var disk: TestBackend = .{};
    var cache = try Cache.init(std.testing.allocator);
    var actual: [record_bytes]u8 = undefined;
    try cache.read(disk.backend(), 301, &actual);
    try cache.read(disk.backend(), 301, &actual);
    try std.testing.expectEqual(@as(usize, 1), disk.reads);
    try cache.store(disk.backend(), 301, &actual);
    cache.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), disk.writes);
}

test "read-only miss with all dirty ways does not evict or write" {
    var cache = try Cache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);
    var disk: TestBackend = .{};
    var data: [record_bytes]u8 = @splat(27);
    for (0..ways) |i| try cache.store(disk.backend(), 27 + i * set_count, &data);
    var actual: [record_bytes]u8 = undefined;
    try cache.read(disk.backend(), 27 + ways * set_count, &actual);
    try std.testing.expectEqual(@as(usize, 0), disk.writes);
    try std.testing.expectEqual(@as(usize, 1), disk.reads);
    for (0..ways) |i| try std.testing.expect(cache.find(27 + i * set_count).?.dirty);
    try cache.readForMutation(disk.backend(), 27 + ways * set_count, &actual);
    try std.testing.expectEqual(@as(usize, 1), disk.writes);
    try std.testing.expect(cache.find(27 + ways * set_count) != null);
}
