//! Integrated current-directory cache and bitmap publication gates.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const ntfs = @import("ntfs.zig");
const Memory = @import("mft_cache_tests.zig").Memory;
const u = std.unicode.utf8ToUtf16LeStringLiteral;
const MiB = 1024 * 1024;
const Clock = struct {
    ticks: u64 = 0,
    fn read(ctx: *anyopaque) ?u64 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        self.ticks += 100;
        return self.ticks;
    }
};
const Payload = struct {
    reads: u64 = 0,
    fn read(ctx: *anyopaque, _: u64, output: []u8) p.Error!void {
        const self: *Payload = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        @memset(output, 0x39);
    }
    fn source(self: *Payload) ntfs.Source {
        return .{ .context = self, .size = 64, .read_fn = read };
    }
};

test "integrated prepared inserts reduce actual INDX reads and retain a clean persistent bitmap" {
    var memory = try Memory.init();
    defer memory.deinit();
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * MiB };
    var clock: Clock = .{};
    var profile = p.profiling.Profiler.init(.{ .context = &clock, .read_fn = Clock.read, .frequency_hz = 1000000, .name = "deterministic-test-clock" });
    var target = memory.disk();
    target.profiler = &profile;
    var fs = try ntfs.Ntfs.init(target, memory.partition(), tracked.allocator(), 0x882301);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    const before = fs.statistics();
    const before_calls = memory.reads + memory.writes + memory.flushes;
    const count = 3000;
    for (0..count) |i| {
        var ascii: [12]u8 = undefined;
        var name: [12]u16 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "f{d:0>6}", .{i});
        for (text, 0..) |c, at| name[at] = c;
        _ = try fs.writeFile(5, name[0..text.len], payload.source(), .{});
        if (fs.directory.?.allocation) |bits| try std.testing.expect(!bits.dirty);
    }
    const stats = fs.statistics();
    const prepared = stats.prepared_inserts - before.prepared_inserts;
    std.debug.print("NTFS_INDEX_CACHE files={d} prepared={d} actual_reads={d} actual_writes={d} bitmap_reads={d} bitmap_writes={d} switches={d} tracked_peak={d}\n", .{ count, prepared, memory.index_reads, memory.index_writes, memory.bitmap_reads, memory.bitmap_writes, stats.directory_switches - before.directory_switches, tracked.peak });
    try std.testing.expectEqual(@as(u64, count), prepared);
    try std.testing.expect(memory.index_reads < count / 8);
    try std.testing.expect(memory.bitmap_reads < count / 8);
    try std.testing.expect(memory.index_writes >= count);
    try std.testing.expect(tracked.peak < 16 * MiB);
    const writes = memory.writes;
    for (0..20) |_| try std.testing.expect((try fs.lookup(5, u("f000017"))) != null);
    try std.testing.expectEqual(writes, memory.writes);
    const source_reads = payload.reads;
    const allocated = fs.statistics().allocated_clusters;
    try std.testing.expectError(error.InvalidArgument, fs.writeFile(5, u("f000017"), payload.source(), .{}));
    try std.testing.expectEqual(writes, memory.writes);
    try std.testing.expectEqual(source_reads, payload.reads);
    try std.testing.expectEqual(allocated, fs.statistics().allocated_clusters);
    try std.testing.expect(!fs.failed);
    try fs.finish();
    const target_calls = memory.reads + memory.writes + memory.flushes - before_calls;
    // Includes final MFT/bitmap/mirror durability, not the initial format.
    // The fixed allowance covers MFT/index growth for this actual workload.
    std.debug.print("NTFS_IO_BUDGET files={d} target_calls={d} per_file_limit=8 growth_allowance=1024 includes_finish=true\n", .{ count, target_calls });
    try std.testing.expect(target_calls <= count * 8 + 1024);
    try std.testing.expect(!try memory.dirty());
    const measured = profile.snapshot();
    try std.testing.expectEqual(@as(u64, 0), measured.nesting_errors);
    try std.testing.expectEqual(@as(u64, 0), measured.depth_overflows);
    try std.testing.expectEqual(@as(usize, 0), profile.depth);
    for ([_]p.profiling.Category{ .mft, .index }) |category| {
        const counter = measured.counters[@intFromEnum(category)];
        try std.testing.expect(counter.calls > count);
        try std.testing.expect(counter.exclusive_ticks > 0);
        try std.testing.expect(counter.exclusive_ticks <= counter.inclusive_ticks);
        try std.testing.expectEqual(@as(u64, 0), counter.invalid);
    }
}

test "mkdir preserves parent and cache owner switches cannot alias equal VCNs" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x882302);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    _ = try fs.lookup(5, u("$MFT"));
    const switches = fs.statistics().directory_switches;
    const child = try fs.mkdir(5, u("child"), .{});
    try std.testing.expectEqual(switches, fs.statistics().directory_switches);
    try std.testing.expectEqual(@as(u64, 5), fs.directory.?.number);
    var payload: Payload = .{};
    const root_file = try fs.writeFile(5, u("only-root"), payload.source(), .{});
    const child_file = try fs.writeFile(child, u("only-child"), payload.source(), .{});
    const writes = memory.writes;
    try std.testing.expectEqual(@as(?u64, null), try fs.lookup(child, u("only-root")));
    try std.testing.expectEqual(@as(?u64, root_file), try fs.lookup(5, u("only-root")));
    try std.testing.expectEqual(@as(?u64, null), try fs.lookup(5, u("only-child")));
    try std.testing.expectEqual(@as(?u64, child_file), try fs.lookup(child, u("only-child")));
    try std.testing.expectEqual(writes, memory.writes);
    try fs.finish();
}

test "INDX write failure invalidates cache and cannot clear volume dirty" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x882303);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    var payload: Payload = .{};
    const invalidations = fs.indexCacheStatistics().invalidations;
    memory.fail_index_write = true;
    try std.testing.expectError(error.Io, fs.writeFile(5, u("failed-index"), payload.source(), .{}));
    try std.testing.expect(fs.failed);
    try std.testing.expect(fs.indexCacheStatistics().invalidations > invalidations);
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try std.testing.expect(try memory.dirty());
}

test "persistent directory bitmap flush failure propagates at public mutation boundary" {
    var memory = try Memory.init();
    defer memory.deinit();
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), std.testing.allocator, 0x882304);
    defer fs.deinit();
    try fs.format();
    memory.fs = &fs;
    const child = try fs.mkdir(5, u("child-bitmap"), .{});
    var payload: Payload = .{};
    memory.fail_bitmap_write = true;
    try std.testing.expectError(error.Io, fs.writeFile(child, u("failed-bitmap"), payload.source(), .{}));
    try std.testing.expect(fs.failed);
    try std.testing.expect(memory.bitmap_writes > 0);
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try fs.markIncomplete();
    try std.testing.expect(try memory.dirty());
}
