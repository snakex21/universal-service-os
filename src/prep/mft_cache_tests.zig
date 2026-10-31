//! MFT cache integration tests against a byte-addressed target, not mock IO counts.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const ntfs = @import("ntfs.zig");
const r = @import("record.zig");
const partitions = @import("partitions.zig");
const cache = @import("mft_cache.zig");
const MiB = 1024 * 1024;
const u = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Memory = struct {
    bytes: []u8,
    fs: ?*ntfs.Ntfs = null,
    reads: u64 = 0,
    writes: u64 = 0,
    flushes: u64 = 0,
    ordinary_reads: u64 = 0,
    ordinary_writes: u64 = 0,
    fail_ordinary_write: bool = false,
    fail_flush_at: u64 = 0,
    index_reads: u64 = 0,
    index_writes: u64 = 0,
    bitmap_reads: u64 = 0,
    bitmap_writes: u64 = 0,
    fail_index_write: bool = false,
    fail_bitmap_write: bool = false,
    fn directoryRange(self: *Memory, offset: u64, len: usize, bitmap: bool) bool {
        if (len != 4096) return false;
        const fs = self.fs orelse return false;
        const dir = fs.directory orelse return false;
        if (offset < fs.partition.start_bytes) return false;
        const physical = offset - fs.partition.start_bytes;
        const stream = if (bitmap) dir.bits.list.items else dir.data.list.items;
        for (stream) |run| {
            const start = (run.lcn orelse return false) * 4096;
            if (physical >= start and physical - start < run.clusters * 4096) return true;
        }
        return false;
    }
    pub fn init() !Memory {
        const bytes = try std.testing.allocator.alloc(u8, 65 * MiB);
        @memset(bytes, 0);
        return .{ .bytes = bytes };
    }
    pub fn deinit(self: *Memory) void {
        std.testing.allocator.free(self.bytes);
    }
    fn recordNumber(self: *Memory, offset: u64, len: usize) ?u64 {
        if (len != 1024) return null;
        const fs = self.fs orelse return null;
        if (offset < fs.partition.start_bytes) return null;
        const physical = offset - fs.partition.start_bytes;
        var logical: u64 = 0;
        for (fs.mft_runs.items) |run| {
            const start = (run.lcn orelse return null) * 4096;
            if (physical >= start and physical - start < run.clusters * 4096) {
                const at = logical + physical - start;
                if (at % 1024 != 0) return null;
                return at / 1024;
            }
            logical += run.clusters * 4096;
        }
        return null;
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Bounds;
        self.reads += 1;
        if (self.directoryRange(offset, out.len, false)) self.index_reads += 1;
        if (self.directoryRange(offset, out.len, true)) self.bitmap_reads += 1;
        if (self.recordNumber(offset, out.len)) |number| if (number >= 27) {
            self.ordinary_reads += 1;
        };
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (offset > self.bytes.len or input.len > self.bytes.len - offset) return error.Bounds;
        self.writes += 1;
        if (self.directoryRange(offset, input.len, false)) {
            self.index_writes += 1;
            if (self.fail_index_write) return error.Io;
        }
        if (self.directoryRange(offset, input.len, true)) {
            self.bitmap_writes += 1;
            if (self.fail_bitmap_write) return error.Io;
        }
        if (self.recordNumber(offset, input.len)) |number| if (number >= 27) {
            self.ordinary_writes += 1;
            if (self.fail_ordinary_write) return error.Io;
        };
        @memcpy(self.bytes[@intCast(offset)..][0..input.len], input);
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.flushes += 1;
        if (self.flushes == self.fail_flush_at) return error.Io;
    }
    pub fn disk(self: *Memory) p.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    pub fn partition(_: *Memory) partitions.Partition {
        return .{ .start_bytes = MiB, .size_bytes = 64 * MiB };
    }
    fn rawRecord(self: *Memory, number: u64, out: *[1024]u8) !void {
        const fs = self.fs.?;
        var at = number * 1024;
        for (fs.mft_runs.items) |run| {
            if (at < run.clusters * 4096) {
                const position = fs.partition.start_bytes + run.lcn.? * 4096 + at;
                @memcpy(out, self.bytes[@intCast(position)..][0..1024]);
                try r.unprotect(out);
                try std.testing.expectEqual(number, @as(u64, r.get(u32, out, 44)));
                return;
            }
            at -= run.clusters * 4096;
        }
        return error.Corrupt;
    }
    pub fn dirty(self: *Memory) !bool {
        var volume: [1024]u8 = undefined;
        try self.rawRecord(3, &volume);
        return r.get(u16, try r.value((try r.find(&volume, 0x70, &.{})).?.bytes), 10) & 1 != 0;
    }
};
const Payload = struct {
    value: u8 = 0x91,
    fn read(ctx: *anyopaque, _: u64, out: []u8) p.Error!void {
        const self: *Payload = @ptrCast(@alignCast(ctx));
        @memset(out, self.value);
    }
    fn source(self: *Payload) ntfs.Source {
        return .{ .context = self, .size = 32, .read_fn = read };
    }
};

test "real small-file MFT call budget across eviction and growth with raw final records" {
    var memory = try Memory.init();
    defer memory.deinit();
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * MiB };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracked.allocator(), 0x123456);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    try std.testing.expect(try memory.dirty());
    var payload: Payload = .{};
    const count = 2100; // More than twice the bounded cache, and six MFT growths.
    for (0..count) |i| {
        var name: [12]u16 = undefined;
        var ascii: [12]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "f{d:0>6}", .{i});
        for (text, 0..) |c, at| name[at] = c;
        _ = try fs.writeFile(5, name[0..text.len], payload.source(), .{});
    }
    try fs.finish();
    // These counters are incremented only by actual backend1024-byte IO in
    // physical MFT runs, excluding bulk zero-initialization and special0..26.
    std.debug.print("MFT_CACHE_CALLS files={d} reads={d} writes={d} hits={d} evictions={d} allocated={d} tracked_peak={d}\n", .{ count, memory.ordinary_reads, memory.ordinary_writes, fs.mftCacheStatistics().hits, fs.mftCacheStatistics().dirty_evictions, cache.allocated_bytes, tracked.peak });
    try std.testing.expectEqual(@as(u64, count), memory.ordinary_writes);
    try std.testing.expectEqual(@as(u64, count), memory.ordinary_reads);
    try std.testing.expect(fs.mftCacheStatistics().hits >= count * 2);
    try std.testing.expect(fs.mftCacheStatistics().dirty_evictions > 0);
    try std.testing.expect(tracked.peak < 16 * MiB);
    try std.testing.expect(!try memory.dirty());
    for ([_]u64{ 27, 1027, 2126 }) |number| {
        var actual: [1024]u8 = undefined;
        try memory.rawRecord(number, &actual);
        try std.testing.expectEqual(@as(u16, 1), r.get(u16, &actual, 22));
        const data = try r.value((try r.find(&actual, 0x80, &.{})).?.bytes);
        try std.testing.expectEqual(@as(usize, 32), data.len);
        try std.testing.expect(std.mem.allEqual(u8, data, payload.value));
    }
    // Mirror is physically byte-identical, including MST protection.
    try std.testing.expectEqualSlices(u8, memory.bytes[MiB + 4 * 4096 ..][0..4096], memory.bytes[MiB + 2 * 4096 ..][0..4096]);
}
test "dirty MFT flush error poisons finish and markIncomplete persists through bypass" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x123457);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    _ = try fs.writeFile(5, u("pending.bin"), payload.source(), .{});
    try std.testing.expectEqual(@as(u64, 0), memory.ordinary_writes);
    memory.fail_ordinary_write = true;
    try std.testing.expectError(error.Io, fs.flushMftRecords());
    try std.testing.expect(fs.failed);
    const before = memory.writes;
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try std.testing.expectEqual(before, memory.writes);
    // The ordinary record remains dirty in cache; the special3 write must
    // not try to drain it or become only another deferred cache operation.
    try fs.markIncomplete();
    try std.testing.expect(try memory.dirty());
}
test "failed final flush after clean write is explicitly redirtied on disk" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x123458);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    _ = try fs.writeFile(5, u("last-flush.bin"), payload.source(), .{});
    memory.fail_flush_at = memory.flushes + 2;
    try std.testing.expectError(error.Io, fs.finish());
    try std.testing.expect(!try memory.dirty()); // clean write reached target
    try fs.markIncomplete();
    try std.testing.expect(try memory.dirty());
}
test "unflushed create delete reuse keeps new sequence and cannot replay old dirty bytes" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x123459);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    const old = try fs.writeFile(5, u("old.bin"), payload.source(), .{});
    try fs.removeFile(5, u("old.bin"));
    payload.value = 0x37;
    const new = try fs.writeFile(5, u("new.bin"), payload.source(), .{});
    try std.testing.expectEqual(old, new);
    try std.testing.expectEqual(@as(?u64, null), try fs.lookup(5, u("old.bin")));
    try std.testing.expectEqual(@as(?u64, new), try fs.lookup(5, u("new.bin")));
    try fs.finish();
    var actual: [1024]u8 = undefined;
    try memory.rawRecord(new, &actual);
    try std.testing.expectEqual(@as(u16, 2), r.get(u16, &actual, 16));
    try std.testing.expect(std.mem.allEqual(u8, try r.value((try r.find(&actual, 0x80, &.{})).?.bytes), 0x37));
}
test "Ntfs deinit abandons dirty cache without any implicit read write or flush" {
    var memory = try Memory.init();
    defer memory.deinit();
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * MiB };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracked.allocator(), 0x123460);
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    _ = try fs.writeFile(5, u("abandoned.bin"), payload.source(), .{});
    const before = .{ memory.reads, memory.writes, memory.flushes };
    fs.deinit();
    try std.testing.expectEqual(before, .{ memory.reads, memory.writes, memory.flushes });
    try std.testing.expectEqual(@as(usize, 0), tracked.current);
    try std.testing.expect(cache.allocated_bytes < 1100 * 1024);
}

test {
    _ = @import("scale_tests.zig");
    _ = @import("preflight_tests.zig");
    _ = @import("wim_ntfs_tests.zig");
}
