//! Fragmentation/failure preflight. SPDX-License-Identifier: GPL-3.0-or-later
//! These use the public formatter API and a sparse virtual block device;
//! no host disk, image file, firmware API or external path is opened.
const std = @import("std");
const p = @import("platform.zig");
const ntfs = @import("ntfs.zig");
const r = @import("record.zig");
const partitions = @import("partitions.zig");
const get = r.get;
const put = r.put;
const MiB: u64 = 1024 * 1024;
const GiB: u64 = 1024 * MiB;
const Page = [4096]u8;
const Stream = @TypeOf(@as(ntfs.Ntfs, undefined).bitmap);

/// Nonzero pages only. A write of zeroes to an absent page consumes no
/// memory, so a 12GiB address space never requires a 12GiB host buffer.
const SparseDisk = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    size: u64,
    pages: std.AutoHashMap(u64, *Page),
    peak_pages: usize = 0,
    writes: u64 = 0,
    highest_write: u64 = 0,
    fn init(size: u64) SparseDisk {
        return .{ .size = size, .pages = std.AutoHashMap(u64, *Page).init(std.testing.allocator) };
    }
    fn deinit(self: *SparseDisk) void {
        var values = self.pages.valueIterator();
        while (values.next()) |value| self.allocator.destroy(value.*);
        self.pages.deinit();
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *SparseDisk = @ptrCast(@alignCast(ctx));
        if (offset > self.size or out.len > self.size - offset) return error.Bounds;
        var done: usize = 0;
        while (done < out.len) {
            const index = (offset + done) / 4096;
            const within: usize = @intCast((offset + done) % 4096);
            const count = @min(out.len - done, 4096 - within);
            if (self.pages.get(index)) |page| {
                @memcpy(out[done..][0..count], page[within..][0..count]);
            } else @memset(out[done..][0..count], 0);
            done += count;
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *SparseDisk = @ptrCast(@alignCast(ctx));
        if (offset > self.size or input.len > self.size - offset) return error.Bounds;
        self.writes += 1;
        self.highest_write = @max(self.highest_write, offset + input.len);
        var done: usize = 0;
        while (done < input.len) {
            const index = (offset + done) / 4096;
            const within: usize = @intCast((offset + done) % 4096);
            const count = @min(input.len - done, 4096 - within);
            const chunk = input[done..][0..count];
            if (self.pages.get(index)) |page| {
                @memcpy(page[within..][0..count], chunk);
                if (std.mem.allEqual(u8, page, 0)) {
                    _ = self.pages.remove(index);
                    self.allocator.destroy(page);
                }
            } else if (!std.mem.allEqual(u8, chunk, 0)) {
                const page = self.allocator.create(Page) catch return error.NoSpace;
                page.* = @splat(0);
                @memcpy(page[within..][0..count], chunk);
                self.pages.put(index, page) catch {
                    self.allocator.destroy(page);
                    return error.NoSpace;
                };
                self.peak_pages = @max(self.peak_pages, self.pages.count());
            }
            done += count;
        }
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *SparseDisk) p.Disk {
        return .{ .context = self, .sectors = self.size / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn partition(self: *SparseDisk) partitions.Partition {
        return .{ .start_bytes = MiB, .size_bytes = self.size - MiB };
    }
};

const Fixture = struct {
    size: u64,
    seed: u8,
    dense: bool = false,
    fn source(self: *Fixture) ntfs.Source {
        return .{ .context = self, .size = self.size, .read_fn = read };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (offset > self.size or out.len > self.size - offset) return error.Bounds;
        if (self.dense) {
            for (out, 0..) |*byte, i| {
                const at = offset + i;
                byte.* = self.seed ^ @as(u8, @truncate(at *% 37 +% (at >> 12) *% 11));
            }
        } else {
            @memset(out, 0);
            // Sentinels straddle 32-bit boundaries and EOF. Every other byte
            // is zero and can remain absent in the sparse test backend.
            const starts = [_]u64{ 0, 2 * GiB - 32, 4 * GiB - 32, self.size -| 64 };
            for (starts) |start| {
                const from = @max(offset, start);
                const to = @min(offset + out.len, @min(start + 64, self.size));
                if (from >= to) continue;
                for (@as(usize, @intCast(from - offset))..@as(usize, @intCast(to - offset))) |i| {
                    const at = offset + i;
                    out[i] = self.seed ^ @as(u8, @truncate(at *% 17 +% (at >> 32) *% 53 +% 1));
                }
            }
        }
    }
};

fn name16(out: []u16, number: usize, prefix: u16) []const u16 {
    out[0] = prefix;
    var remaining = number;
    for (0..10) |i| {
        out[10 - i] = '0' + @as(u16, @intCast(remaining % 10));
        remaining /= 10;
    }
    return out[0..11];
}
fn u(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

const RawRun = struct { vcn: u64, lcn: u64, count: u64 };
fn rawRuns(attribute: []const u8, allocator: std.mem.Allocator) !std.ArrayList(RawRun) {
    if (attribute.len < 64 or attribute[8] != 1) return error.Corrupt;
    var out: std.ArrayList(RawRun) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = get(u16, attribute, 32);
    var vcn = get(u64, attribute, 16);
    var lcn: i64 = 0;
    while (pos < attribute.len and attribute[pos] != 0) {
        const sizes = attribute[pos];
        pos += 1;
        const lengths: usize = sizes & 15;
        const offsets: usize = sizes >> 4;
        if (lengths == 0 or lengths > 8 or offsets == 0 or offsets > 8 or pos + lengths + offsets > attribute.len)
            return error.Corrupt;
        var count: u64 = 0;
        var delta_bits: u64 = 0;
        for (0..lengths) |i| count |= @as(u64, attribute[pos + i]) << @intCast(i * 8);
        pos += lengths;
        for (0..offsets) |i| delta_bits |= @as(u64, attribute[pos + i]) << @intCast(i * 8);
        if (offsets < 8 and attribute[pos + offsets - 1] & 0x80 != 0)
            delta_bits |= @as(u64, std.math.maxInt(u64)) << @intCast(offsets * 8);
        pos += offsets;
        if (count == 0) return error.Corrupt;
        lcn = try std.math.add(i64, lcn, @bitCast(delta_bits));
        if (lcn < 0) return error.Corrupt;
        try out.append(allocator, .{ .vcn = vcn, .lcn = @intCast(lcn), .count = count });
        vcn = try std.math.add(u64, vcn, count);
    }
    if (pos >= attribute.len or vcn != get(u64, attribute, 24) + 1) return error.Corrupt;
    return out;
}
fn rawRead(disk: p.Disk, part: partitions.Partition, runs: []const RawRun, offset: u64, out: []u8) !void {
    var done: usize = 0;
    while (done < out.len) {
        const at = offset + done;
        const vcn = at / 4096;
        var found = false;
        for (runs) |run| {
            if (vcn < run.vcn or vcn - run.vcn >= run.count) continue;
            const position = (vcn - run.vcn) * 4096 + at % 4096;
            const count: usize = @intCast(@min(out.len - done, run.count * 4096 - position));
            try disk.read(part.start_bytes + run.lcn * 4096 + position, out[done..][0..count]);
            done += count;
            found = true;
            break;
        }
        if (!found) return error.Corrupt;
    }
}
fn firstMft(disk: p.Disk, part: partitions.Partition, out: *[1024]u8) !void {
    var boot: [512]u8 = undefined;
    try disk.read(part.start_bytes, &boot);
    try std.testing.expectEqualStrings("NTFS    ", boot[3..11]);
    try disk.read(part.start_bytes + get(u64, &boot, 48) * 4096, out);
    try r.unprotect(out);
}

/// Independent disk bootstrap: this never consults Ntfs.mft_runs or its
/// production decoder. Each extension must be reachable before its runlist
/// becomes known. Map memory is proportional only to this bounded fixture.
fn bootstrapCheck(disk: p.Disk, part: partitions.Partition) !std.ArrayList(RawRun) {
    const allocator = std.testing.allocator;
    var base: [1024]u8 = undefined;
    try firstMft(disk, part, &base);
    var map = try rawRuns((try r.find(&base, 0x80, &.{})).?.bytes, allocator);
    errdefer map.deinit(allocator);
    if (try r.find(&base, 0x20, &.{})) |list| {
        var mapping = try rawRuns(list.bytes, allocator);
        defer mapping.deinit(allocator);
        const storage = try allocator.alloc(u8, @intCast(get(u64, list.bytes, 48)));
        defer allocator.free(storage);
        try rawRead(disk, part, mapping.items, 0, storage);
        var cursor: usize = 0;
        while (cursor < storage.len) {
            if (storage.len - cursor < 26) return error.Corrupt;
            const length = get(u16, storage, cursor + 4);
            if (length < 26 or length > storage.len - cursor) return error.Corrupt;
            if (get(u32, storage, cursor) == 0x80 and storage[cursor + 6] == 0 and get(u64, storage, cursor + 8) != 0) {
                const reference = get(u64, storage, cursor + 16);
                const number = reference & 0xffffffffffff;
                // A cached full map would make this test meaningless.
                const last = map.items[map.items.len - 1];
                try std.testing.expect(number * 1024 + 1024 <= (last.vcn + last.count) * 4096);
                try std.testing.expect(number >= 16 and number <= 23);
                var extension: [1024]u8 = undefined;
                try rawRead(disk, part, map.items, number * 1024, &extension);
                try r.unprotect(&extension);
                try std.testing.expectEqual(reference >> 48, @as(u64, get(u16, &extension, 16)));
                const attr = (try r.find(&extension, 0x80, &.{})).?;
                var more = try rawRuns(attr.bytes, allocator);
                defer more.deinit(allocator);
                try std.testing.expectEqual(last.vcn + last.count, more.items[0].vcn);
                try map.appendSlice(allocator, more.items);
            }
            cursor += length;
        }
    }
    const last = map.items[map.items.len - 1];
    const first = (try r.find(&base, 0x80, &.{})).?;
    try std.testing.expectEqual(get(u64, first.bytes, 48), (last.vcn + last.count) * 4096);
    return map;
}
fn bitmapBytes(disk: p.Disk, part: partitions.Partition, map: []const RawRun, out: []u8) !void {
    var record: [1024]u8 = undefined;
    try rawRead(disk, part, map, 6 * 1024, &record);
    try r.unprotect(&record);
    const attr = (try r.find(&record, 0x80, &.{})).?;
    var mapping = try rawRuns(attr.bytes, std.testing.allocator);
    defer mapping.deinit(std.testing.allocator);
    try rawRead(disk, part, mapping.items, 0, out);
}
fn usedCount(bytes: []const u8, bits: u64) u64 {
    var count: u64 = 0;
    for (0..@intCast(bits)) |bit| if (bytes[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0) {
        count += 1;
    };
    return count;
}

test "NoSpace rolls back every partial data run and the unpublished record bitmap" {
    var disk = SparseDisk.init(65 * MiB);
    defer disk.deinit();
    var fs = try ntfs.Ntfs.init(disk.disk(), disk.partition(), std.testing.allocator, 0x88ff);
    defer fs.deinit();
    try fs.format();
    var map = try bootstrapCheck(disk.disk(), disk.partition());
    defer map.deinit(std.testing.allocator);
    try fs.volume_bits.?.flush();
    try fs.record_bits.?.flush();
    var before: [2048]u8 = undefined;
    var after: [2048]u8 = undefined;
    try bitmapBytes(disk.disk(), disk.partition(), map.items, before[0..@intCast(fs.bitmap.bytes)]);
    const used = usedCount(&before, fs.total_clusters);
    var mft: [1024]u8 = undefined;
    try firstMft(disk.disk(), disk.partition(), &mft);
    var record_map = try rawRuns((try r.find(&mft, 0xb0, &.{})).?.bytes, std.testing.allocator);
    defer record_map.deinit(std.testing.allocator);
    var mft_bits_before: [4096]u8 = undefined;
    var mft_bits_after: [4096]u8 = undefined;
    try rawRead(disk.disk(), disk.partition(), record_map.items, 0, &mft_bits_before);
    var too_large: Fixture = .{ .size = (fs.total_clusters - used + 1) * 4096, .seed = 7 };
    try std.testing.expectError(error.NoSpace, fs.writeFile(5, u("NoSpace.bin"), too_large.source(), .{}));
    try std.testing.expect(!fs.failed);
    try fs.volume_bits.?.flush();
    try fs.record_bits.?.flush();
    try bitmapBytes(disk.disk(), disk.partition(), map.items, after[0..@intCast(fs.bitmap.bytes)]);
    try std.testing.expectEqualSlices(u8, before[0..@intCast(fs.bitmap.bytes)], after[0..@intCast(fs.bitmap.bytes)]);
    try rawRead(disk.disk(), disk.partition(), record_map.items, 0, &mft_bits_after);
    try std.testing.expectEqualSlices(u8, &mft_bits_before, &mft_bits_after);
    try std.testing.expectEqual(@as(?u64, null), try fs.lookup(5, u("NoSpace.bin")));
    var small: Fixture = .{ .size = 4096, .seed = 17 };
    _ = try fs.writeFile(5, u("After.bin"), small.source(), .{});
    try fs.finish();
}

test "irreversible source failure prevents clearing the on-disk dirty flag" {
    const Broken = struct {
        fn read(_: *anyopaque, off: u64, out: []u8) p.Error!void {
            if (off != 0) return error.Io;
            @memset(out, 0x5a);
        }
    };
    var disk = SparseDisk.init(65 * MiB);
    defer disk.deinit();
    var fs = try ntfs.Ntfs.init(disk.disk(), disk.partition(), std.testing.allocator, 0x78ff);
    defer fs.deinit();
    try fs.format();
    var context: u8 = 0;
    try std.testing.expectError(error.Io, fs.writeFile(5, u("Interrupted.bin"), .{ .context = &context, .size = MiB, .read_fn = Broken.read }, .{}));
    try std.testing.expect(fs.failed);
    const writes = disk.writes;
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try std.testing.expectEqual(writes, disk.writes);
    var map = try bootstrapCheck(disk.disk(), disk.partition());
    defer map.deinit(std.testing.allocator);
    var volume: [1024]u8 = undefined;
    try rawRead(disk.disk(), disk.partition(), map.items, 3 * 1024, &volume);
    try r.unprotect(&volume);
    const info = try r.value((try r.find(&volume, 0x70, &.{})).?.bytes);
    try std.testing.expect(get(u16, info, 10) & 1 != 0);
}

test "one-cluster holes force bootstrappable MFT and fragmented attribute lists; large delete reuses data" {
    var disk = SparseDisk.init(512 * MiB);
    defer disk.deinit();
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * MiB };
    var fs = try ntfs.Ntfs.init(disk.disk(), disk.partition(), tracked.allocator(), 0x58ff);
    defer fs.deinit();
    try fs.format();
    try fs.volume_bits.?.flush();
    var initial = try bootstrapCheck(disk.disk(), disk.partition());
    defer initial.deinit(std.testing.allocator);
    var guards: [16384]u8 = @splat(0);
    var original: [16384]u8 = @splat(0);
    try bitmapBytes(disk.disk(), disk.partition(), initial.items, original[0..@intCast(fs.bitmap.bytes)]);
    // Synthetic occupied guards exist only during the allocator fixture.
    // They are explicitly removed before finish; no clean volume contains
    // unexplained allocated clusters. Every available hole is one cluster.
    for (0..@intCast(fs.total_clusters)) |bit| {
        const mask = @as(u8, 1) << @intCast(bit % 8);
        if (original[bit / 8] & mask == 0 and bit % 2 == 0) {
            guards[bit / 8] |= mask;
            try fs.volume_bits.?.set(bit, 1, true);
        }
    }
    var empty: Fixture = .{ .size = 0, .seed = 0 };
    var name: [32]u16 = undefined;
    for (0..1500) |i| _ = try fs.writeFile(5, name16(&name, i, 'E'), empty.source(), .{});
    try fs.validateMftBootstrap();
    var map = try bootstrapCheck(disk.disk(), disk.partition());
    defer map.deinit(std.testing.allocator);
    try std.testing.expect(map.items.len > 100);
    var fragment: Fixture = .{ .size = 17000 * 4096, .seed = 29 };
    const file = try fs.writeFile(5, u("ManyRuns.bin"), fragment.source(), .{});
    try std.testing.expect((try fs.fileStats(file)).run_count >= 16000);
    try fs.flushMftRecords(); // Independent on-disk ATTRIBUTE_LIST inspection.
    var record: [1024]u8 = undefined;
    try rawRead(disk.disk(), disk.partition(), map.items, file * 1024, &record);
    try r.unprotect(&record);
    const al = (try r.find(&record, 0x20, &.{})).?;
    var al_map = try rawRuns(al.bytes, std.testing.allocator);
    defer al_map.deinit(std.testing.allocator);
    try std.testing.expect(al_map.items.len >= 2);
    var got: [128]u8 = undefined;
    var expected: [128]u8 = undefined;
    for ([_]u64{ 0, fragment.size / 2, fragment.size - 128 }) |offset| {
        _ = try fs.readFile(file, offset, &got);
        try Fixture.read(&fragment, offset, &expected);
        try std.testing.expectEqualSlices(u8, &expected, &got);
    }
    try fs.removeFile(5, u("ManyRuns.bin"));
    try std.testing.expect(fs.freed_ranges.items.len <= 4096);
    try std.testing.expect(fs.statistics().reuse_accounting_dropped != 0);
    fs.volume_bits.?.hint = 0; // Fixture intentionally consumes the freed runs.
    var block: Fixture = .{ .size = 4096, .seed = 11 };
    for (0..1000) |i| _ = try fs.writeFile(5, name16(&name, i, 'D'), block.source(), .{});
    try fs.volume_bits.?.flush();
    map.deinit(std.testing.allocator);
    map = try bootstrapCheck(disk.disk(), disk.partition());
    var before: [16384]u8 = undefined;
    try bitmapBytes(disk.disk(), disk.partition(), map.items, before[0..@intCast(fs.bitmap.bytes)]);
    for (0..1000) |i| try fs.removeFile(5, name16(&name, i, 'D'));
    fs.volume_bits.?.hint = 0;
    for (0..1000) |i| _ = try fs.writeFile(5, name16(&name, i, 'D'), block.source(), .{});
    try fs.volume_bits.?.flush();
    var after: [16384]u8 = undefined;
    try bitmapBytes(disk.disk(), disk.partition(), map.items, after[0..@intCast(fs.bitmap.bytes)]);
    try std.testing.expectEqual(usedCount(&before, fs.total_clusters), usedCount(&after, fs.total_clusters));
    // Restore only fixture-owned guard bits, preserving all real allocations.
    for (0..@intCast(fs.total_clusters)) |bit| if (guards[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0) try fs.volume_bits.?.set(bit, 1, false);
    try fs.finish();
    try std.testing.expect(tracked.peak <= 16 * MiB);
}

fn fixtureReadStream(disk: p.Disk, part: partitions.Partition, stream: *const Stream, offset: u64, out: []u8) !void {
    var done: usize = 0;
    while (done < out.len) {
        var at = offset + done;
        var found = false;
        for (stream.list.items) |run| {
            if (at >= run.clusters * 4096) {
                at -= run.clusters * 4096;
                continue;
            }
            const n: usize = @intCast(@min(out.len - done, run.clusters * 4096 - at));
            try disk.read(part.start_bytes + run.lcn.? * 4096 + at, out[done..][0..n]);
            done += n;
            found = true;
            break;
        }
        if (!found) return error.Corrupt;
    }
}
fn fragmentedBitmapFixture(fs: *ntfs.Ntfs, count: usize, bytes: u64, guards: *std.ArrayList(u64)) !Stream {
    var stream: Stream = .{ .bytes = bytes };
    errdefer stream.list.deinit(std.testing.allocator);
    for (0..count) |_| {
        const span = try fs.volume_bits.?.allocate(1);
        try stream.list.append(std.testing.allocator, .{ .lcn = span.start, .clusters = 1 });
        const guard = try fs.volume_bits.?.allocate(1);
        try guards.append(std.testing.allocator, guard.start);
    }
    try fs.volume_bits.?.flush();
    return stream;
}
fn copyBitmapFixture(disk: p.Disk, part: partitions.Partition, old: *const Stream, replacement: *const Stream) !void {
    var page: [4096]u8 = undefined;
    for (replacement.list.items, 0..) |run, i| {
        if (i < old.list.items.len or i * 4096 < old.bytes) {
            try fixtureReadStream(disk, part, old, i * 4096, &page);
        } else @memset(&page, 0);
        try disk.write(part.start_bytes + run.lcn.? * 4096, &page);
    }
}
fn publishFixtureStream(disk: p.Disk, part: partitions.Partition, map: []const RawRun, number: u64, kind: u32, name: []const u16, stream: *const Stream) !void {
    var original: [1024]u8 = undefined;
    try rawRead(disk, part, map, number * 1024, &original);
    try r.unprotect(&original);
    // Fresh fixture records have no attribute list. Preserve the on-disk
    // order and rebuild exactly one stream, independent of Ntfs writers.
    try std.testing.expect((try r.find(&original, 0x20, &.{})) == null);
    const target = (try r.find(&original, kind, name)).?;
    var builder = r.Builder.init(number, get(u16, &original, 16), get(u16, &original, 22), get(u16, &original, 18));
    var pos: usize = get(u16, &original, 20);
    while (get(u32, &original, pos) != 0xffffffff) {
        const n: usize = get(u32, &original, pos + 4);
        if (pos == target.offset) {
            var clusters: u64 = 0;
            for (stream.list.items) |run| {
                clusters += run.clusters;
            }
            try builder.nonresidentRuns(kind, name, stream.list.items, 0, clusters * 4096, stream.bytes, stream.bytes);
        } else _ = try builder.copyRaw(original[pos..][0..n]);
        pos += n;
    }
    try r.protect(&builder.b);
    // Initial MFT is one contiguous run in this dedicated fixture.
    try disk.write(part.start_bytes + 4 * 4096 + number * 1024, &builder.b);
    if (number < 4) try disk.write(part.start_bytes + 2 * 4096 + number * 1024, &builder.b);
}

test "fragmented volume MFT and directory bitmaps address independent second pages" {
    var disk = SparseDisk.init(512 * MiB);
    defer disk.deinit();
    var fs = try ntfs.Ntfs.init(disk.disk(), disk.partition(), std.testing.allocator, 0x48ff);
    defer fs.deinit();
    try fs.format();
    _ = try fs.lookup(5, u("$MFT"));
    try fs.volume_bits.?.flush();
    try fs.record_bits.?.flush();
    var map = try bootstrapCheck(disk.disk(), disk.partition());
    defer map.deinit(std.testing.allocator);
    var guards: std.ArrayList(u64) = .empty;
    defer guards.deinit(std.testing.allocator);

    var volume = try fragmentedBitmapFixture(&fs, 4, fs.bitmap.bytes, &guards);
    try copyBitmapFixture(disk.disk(), disk.partition(), &fs.bitmap, &volume);
    try publishFixtureStream(disk.disk(), disk.partition(), map.items, 6, 0x80, &.{}, &volume);
    var old = fs.bitmap;
    fs.bitmap = volume;
    volume = .{};
    fs.volume_bits.?.page_number = null;
    for (old.list.items) |run| try fs.volume_bits.?.set(run.lcn.?, run.clusters, false);
    old.list.deinit(std.testing.allocator);
    // Exercise the actual volume bitmap callback beyond its first4KiB.
    const unused_bit = fs.total_clusters - 17;
    try std.testing.expect(!(try fs.volume_bits.?.get(unused_bit)));
    try fs.volume_bits.?.set(unused_bit, 1, true);
    try fs.volume_bits.?.flush();
    var page: [4096]u8 = undefined;
    try disk.disk().read(disk.partition().start_bytes + fs.bitmap.list.items[3].lcn.? * 4096, &page);
    const relative: usize = @intCast(unused_bit % 32768);
    try std.testing.expect(page[relative / 8] & (@as(u8, 1) << @intCast(relative % 8)) != 0);
    try fs.volume_bits.?.set(unused_bit, 1, false);

    var records = try fragmentedBitmapFixture(&fs, 2, fs.mft_bitmap.bytes, &guards);
    try copyBitmapFixture(disk.disk(), disk.partition(), &fs.mft_bitmap, &records);
    try publishFixtureStream(disk.disk(), disk.partition(), map.items, 0, 0xb0, &.{}, &records);
    old = fs.mft_bitmap;
    fs.mft_bitmap = records;
    records = .{};
    fs.record_bits.?.page_number = null;
    for (old.list.items) |run| try fs.volume_bits.?.set(run.lcn.?, run.clusters, false);
    old.list.deinit(std.testing.allocator);
    var probe = fs.record_bits.?;
    probe.bits = 65536;
    try probe.set(40000, 1, true);
    try probe.flush();
    try disk.disk().read(disk.partition().start_bytes + fs.mft_bitmap.list.items[1].lcn.? * 4096, &page);
    try std.testing.expect(page[(40000 % 32768) / 8] & 1 != 0);
    try probe.set(40000, 1, false);
    try probe.flush();
    fs.record_bits.?.page_number = null;

    var directory = try fragmentedBitmapFixture(&fs, 2, 5008, &guards);
    try copyBitmapFixture(disk.disk(), disk.partition(), &fs.directory.?.bits, &directory);
    old = fs.directory.?.bits;
    fs.directory.?.bits = directory;
    directory = .{};
    for (old.list.items) |run| try fs.volume_bits.?.set(run.lcn.?, run.clusters, false);
    old.list.deinit(std.testing.allocator);
    var remaining: u64 = 40000;
    @memset(&page, 0);
    while (remaining != 0) {
        const span = try fs.volume_bits.?.allocate(remaining);
        try fs.directory.?.data.list.append(std.testing.allocator, .{ .lcn = span.start, .clusters = span.count });
        for (0..@intCast(span.count)) |i| try disk.disk().write(disk.partition().start_bytes + (span.start + i) * 4096, &page);
        remaining -= span.count;
    }
    fs.directory.?.data.bytes = 40008 * 4096;
    fs.directory.?.index_hint = 32768;
    try publishFixtureStream(disk.disk(), disk.partition(), map.items, 5, 0xa0, u("$I30"), &fs.directory.?.data);
    try publishFixtureStream(disk.disk(), disk.partition(), map.items, 5, 0xb0, u("$I30"), &fs.directory.?.bits);
    var empty: Fixture = .{ .size = 0, .seed = 0 };
    var name: [32]u16 = undefined;
    for (0..100) |i| _ = try fs.writeFile(5, name16(&name, i, 'B'), empty.source(), .{});
    try disk.disk().read(disk.partition().start_bytes + fs.directory.?.bits.list.items[1].lcn.? * 4096, &page);
    try std.testing.expect(page[0] != 0); // Actual split allocated VCN32768+.
    _ = try fs.lookup(11, u("$Quota"));
    try std.testing.expect((try fs.lookup(5, name16(&name, 99, 'B'))) != null);
    try std.testing.expect(fs.directory.?.bits.list.items.len == 2);
    for (guards.items) |bit| try fs.volume_bits.?.set(bit, 1, false);
    try fs.finish();
}
