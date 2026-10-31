//! Stage 1b-1 integration gates. SPDX-License-Identifier: GPL-3.0-or-later
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
fn checkMirror(disk: p.Disk, part: partitions.Partition) !void {
    var mft: [1024]u8 = undefined;
    try firstMft(disk, part, &mft);
    const data = (try r.find(&mft, 0x80, &.{})) orelse return error.Corrupt;
    var runs = try rawRuns(data.bytes, std.testing.allocator);
    defer runs.deinit(std.testing.allocator);
    var boot: [512]u8 = undefined;
    try disk.read(part.start_bytes, &boot);
    var primary: [4096]u8 = undefined;
    var mirror: [4096]u8 = undefined;
    try rawRead(disk, part, runs.items, 0, &primary);
    try disk.read(part.start_bytes + get(u64, &boot, 56) * 4096, &mirror);
    try std.testing.expectEqualSlices(u8, &primary, &mirror);
}

fn checkResidentEmptyDirectory(disk: p.Disk, part: partitions.Partition, number: u64) !void {
    var mft: [1024]u8 = undefined;
    try firstMft(disk, part, &mft);
    const data = (try r.find(&mft, 0x80, &.{})) orelse return error.Corrupt;
    var runs = try rawRuns(data.bytes, std.testing.allocator);
    defer runs.deinit(std.testing.allocator);
    var directory: [1024]u8 = undefined;
    try rawRead(disk, part, runs.items, number * 1024, &directory);
    try r.unprotect(&directory);
    const root_attr = (try r.find(&directory, 0x90, u("$I30"))) orelse return error.Corrupt;
    try std.testing.expectEqual(@as(u8, 0), root_attr.bytes[8]);
    const root = try r.value(root_attr.bytes);
    try std.testing.expectEqual(@as(usize, 48), root.len);
    try std.testing.expectEqual(@as(u8, 0), root[28]);
    const entry: usize = 16 + get(u32, root, 16);
    try std.testing.expectEqual(@as(u16, 2), get(u16, root, entry + 12));
    try std.testing.expectEqual(@as(u16, 0), get(u16, root, entry + 10));
    try std.testing.expectEqual(root.len, entry + get(u16, root, entry + 8));
    try std.testing.expect((try r.find(&directory, 0xa0, u("$I30"))) == null);
    try std.testing.expect((try r.find(&directory, 0xb0, u("$I30"))) == null);
}

/// Read a real promoted separator from the on-disk directory root, so the
/// integration deletion cannot accidentally cover leaf-only removal.
fn promotedName(disk: p.Disk, part: partitions.Partition, number: u64, out: *[255]u16) ![]const u16 {
    var mft: [1024]u8 = undefined;
    try firstMft(disk, part, &mft);
    const data = (try r.find(&mft, 0x80, &.{})) orelse return error.Corrupt;
    var mft_runs = try rawRuns(data.bytes, std.testing.allocator);
    defer mft_runs.deinit(std.testing.allocator);
    var directory: [1024]u8 = undefined;
    try rawRead(disk, part, mft_runs.items, number * 1024, &directory);
    try r.unprotect(&directory);
    const root_attr = (try r.find(&directory, 0x90, u("$I30"))) orelse return error.Corrupt;
    const root = try r.value(root_attr.bytes);
    if (root.len != 56 or root[28] != 1) return error.Corrupt;
    const alloc_attr = (try r.find(&directory, 0xa0, u("$I30"))) orelse return error.Corrupt;
    var runs = try rawRuns(alloc_attr.bytes, std.testing.allocator);
    defer runs.deinit(std.testing.allocator);
    var node: [4096]u8 = undefined;
    try rawRead(disk, part, runs.items, get(u64, root, 48) * 4096, &node);
    try r.unprotect(&node);
    if (node[36] != 1) return error.Corrupt;
    const entry: usize = 24 + get(u32, &node, 24);
    if (get(u16, &node, entry + 12) != 1) return error.Corrupt;
    const key = node[entry + 16 ..][0..get(u16, &node, entry + 10)];
    const count: usize = key[64];
    for (0..count) |i| out[i] = get(u16, key, 66 + i * 2);
    return out[0..count];
}

test "NTFS integration: >8192 fragmented MFT, real internal separator deletion, reuse and mirror" {
    var memory = SparseDisk.init(512 * MiB);
    defer memory.deinit();
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracker.allocator(), 0x9b91e602e0c18cd9);
    defer fs.deinit();
    try fs.format();
    var source: Fixture = .{ .size = 31, .seed = 0x41 };
    var wide: [255]u16 = undefined;
    for (0..9000) |i| _ = try fs.writeFile(5, name16(&wide, i, 'f'), source.source(), .{});
    try std.testing.expect(fs.statistics().mft_records > 8192);
    try std.testing.expect(fs.statistics().mft_runs > 1);
    const actual_separator = try promotedName(memory.disk(), memory.partition(), 5, &wide);
    const removed = (try fs.lookup(5, actual_separator)).?;
    try fs.removeFile(5, actual_separator);
    try std.testing.expect((try fs.lookup(5, actual_separator)) == null);
    const before = fs.statistics();
    const replacement = try fs.writeFile(5, u("replacement.bin"), source.source(), .{});
    const after = fs.statistics();
    try std.testing.expect(after.record_reuses > before.record_reuses);
    try std.testing.expectEqual(removed, replacement);
    try fs.finish();
    try checkMirror(memory.disk(), memory.partition());
    // Reopen the MFT's actual mapping pairs instead of trusting statistics.
    var record_zero: [1024]u8 = undefined;
    try firstMft(memory.disk(), memory.partition(), &record_zero);
    const data = (try r.find(&record_zero, 0x80, &.{})).?;
    var runs = try rawRuns(data.bytes, std.testing.allocator);
    defer runs.deinit(std.testing.allocator);
    try std.testing.expect(runs.items.len > 1);
    try std.testing.expect(get(u64, data.bytes, 48) > 8192 * 1024);
    try std.testing.expect(tracker.peak <= 16 * 1024 * 1024);
}

test "NTFS integration: canonical resident empty directories, read-only lookup, reinsertion and cluster reuse" {
    var memory = SparseDisk.init(128 * MiB);
    defer memory.deinit();
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracker.allocator(), 0x7ada276a4e8cd001);
    defer fs.deinit();
    try fs.format();
    const directory = try fs.mkdir(5, u("canonical-empty"), .{});
    try fs.flushMftRecords(); // Independent raw reader requires publication.
    try checkResidentEmptyDirectory(memory.disk(), memory.partition(), directory);
    var writes = memory.writes;
    try std.testing.expect((try fs.lookup(directory, u("missing"))) == null);
    try std.testing.expectEqual(writes, memory.writes);
    try checkResidentEmptyDirectory(memory.disk(), memory.partition(), directory);

    var fixture: Fixture = .{ .size = 31, .seed = 0x7d };
    var name: [32]u16 = undefined;
    const before_create = fs.statistics();
    for (0..10) |i| _ = try fs.writeFile(directory, name16(&name, i, 'e'), fixture.source(), .{});
    for (0..10) |i| try fs.removeFile(directory, name16(&name, i, 'e'));
    try std.testing.expect(fs.statistics().freed_clusters > before_create.freed_clusters);
    try checkResidentEmptyDirectory(memory.disk(), memory.partition(), directory);
    writes = memory.writes;
    try std.testing.expect((try fs.lookup(directory, u("missing"))) == null);
    try std.testing.expectEqual(writes, memory.writes);

    const before_reinsert = fs.statistics();
    fs.volume_bits.?.hint = 0; // Controlled reuse assertion, not production policy.
    const replacement = try fs.writeFile(directory, u("replacement"), fixture.source(), .{});
    try std.testing.expectEqual(replacement, (try fs.lookup(directory, u("replacement"))).?);
    try std.testing.expect(fs.statistics().reused_clusters > before_reinsert.reused_clusters);
    try fs.removeFile(directory, u("replacement"));
    try checkResidentEmptyDirectory(memory.disk(), memory.partition(), directory);
    try fs.finish();
    try checkResidentEmptyDirectory(memory.disk(), memory.partition(), directory);
    writes = memory.writes;
    try std.testing.expect((try fs.lookup(directory, u("replacement"))) == null);
    try std.testing.expectEqual(writes, memory.writes);
    try std.testing.expect(tracker.peak <= 16 * 1024 * 1024);
}

fn makeHoles(fs: *ntfs.Ntfs, parent: u64, count: usize) !void {
    var fixture: Fixture = .{ .size = 64 * 1024, .seed = 0, .dense = true };
    var name: [32]u16 = undefined;
    for (0..count) |i| {
        fixture.seed = @truncate(i * 17 + 0x21);
        _ = try fs.writeFile(parent, name16(&name, i, 'h'), fixture.source(), .{});
        fixture.seed = @truncate(i * 29 + 0x53);
        _ = try fs.writeFile(parent, name16(&name, i, 'k'), fixture.source(), .{});
    }
    for (0..count) |i| try fs.removeFile(parent, name16(&name, i, 'h'));
    // Deliberately select the newly freed holes; production keeps its forward
    // cursor until wrap to avoid rescanning the allocated prefix per file.
    fs.volume_bits.?.hint = 0;
}
fn descriptor48() [48]u8 {
    var sd: [48]u8 = @splat(0);
    sd[0] = 1;
    put(u16, &sd, 2, 0x8000);
    put(u32, &sd, 4, 20);
    put(u32, &sd, 8, 32);
    sd[20] = 1;
    sd[21] = 1;
    sd[27] = 5;
    put(u32, &sd, 28, 18);
    sd[32] = 1;
    sd[33] = 2;
    sd[39] = 5;
    put(u32, &sd, 40, 32);
    put(u32, &sd, 44, 544);
    return sd;
}
fn checkFixtureHash(fs: *ntfs.Ntfs, number: u64, fixture: *Fixture) !void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var done: u64 = 0;
    while (done < fixture.size) {
        const count: usize = @intCast(@min(buffer.len, fixture.size - done));
        try Fixture.read(fixture, done, buffer[0..count]);
        hash.update(buffer[0..count]);
        done += count;
    }
    try std.testing.expectEqualSlices(u8, &hash.finalResult(), &try fs.hashFile(number));
}

test "NTFS integration: true holes, >100 runs, ATTRIBUTE_LIST, 255UTF16 name and 48-byte SD" {
    var memory = SparseDisk.init(256 * MiB);
    defer memory.deinit();
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracker.allocator(), 0x5b58e5153ed20a37);
    defer fs.deinit();
    try fs.format();
    const directory = try fs.mkdir(5, u("fragmentation"), .{});
    try makeHoles(&fs, directory, 320);
    var long_name: [255]u16 = @splat(0x0105);
    long_name[254] = '7';
    const descriptor = descriptor48();
    var fixture: Fixture = .{ .size = 320 * 64 * 1024 + 123, .seed = 0xc7, .dense = true };
    const before = fs.statistics();
    const number = try fs.writeFile(directory, &long_name, fixture.source(), .{ .security_descriptor = &descriptor });
    const details = try fs.fileStats(number);
    try std.testing.expectEqual(fixture.size, details.size);
    try std.testing.expect(details.run_count > 100);
    try std.testing.expect(details.attribute_list_records > 0);
    try std.testing.expect(fs.statistics().reused_clusters > before.reused_clusters);
    try std.testing.expectEqual(number, (try fs.lookup(directory, &long_name)).?);
    try checkFixtureHash(&fs, number, &fixture);
    try fs.finish();
    try checkMirror(memory.disk(), memory.partition());
    try std.testing.expect(tracker.peak <= 16 * 1024 * 1024);
}

test "NTFS integration: 5GiB fragmented stream, 64-bit boundaries, bounded sparse backend" {
    var memory = SparseDisk.init(12 * GiB);
    defer memory.deinit();
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), memory.partition(), tracker.allocator(), 0x50320e2b7cf1009b);
    defer fs.deinit();
    try fs.format();
    const directory = try fs.mkdir(5, u("large"), .{});
    try makeHoles(&fs, directory, 256);
    var fixture: Fixture = .{ .size = 5 * GiB + 37, .seed = 0xb9 };
    const number = try fs.writeFile(directory, u("five-gib-plus-37.bin"), fixture.source(), .{});
    const details = try fs.fileStats(number);
    try std.testing.expectEqual(fixture.size, details.size);
    try std.testing.expect(details.run_count > 100);
    try std.testing.expect(details.attribute_list_records > 0);
    const positions = [_]u64{ 0, 4090, 2 * GiB - 40, 4 * GiB - 40, 4 * GiB + 4093, fixture.size - 80 };
    var expected: [80]u8 = undefined;
    var actual: [80]u8 = undefined;
    for (positions) |position| {
        try Fixture.read(&fixture, position, &expected);
        try std.testing.expectEqual(actual.len, try fs.readFile(number, position, &actual));
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
    try std.testing.expectEqual(@as(usize, 0), try fs.readFile(number, fixture.size, &actual));
    try fs.finish();
    try checkMirror(memory.disk(), memory.partition());
    try std.testing.expect(tracker.peak <= 16 * 1024 * 1024);
    // Includes dense keep-files and NTFS metadata; excludes unallocated
    // zero pages of the >5GiB file. This is backend memory, not app memory.
    try std.testing.expect(memory.peak_pages < 16384);
    try std.testing.expect(memory.highest_write > 5 * GiB);
}
