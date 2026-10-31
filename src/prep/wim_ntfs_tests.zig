//! NTFS features required by WIM apply, independent of WIM parsing/codecs.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const ntfs = @import("ntfs.zig");
const p = @import("platform.zig");
const partitions = @import("partitions.zig");
const r = @import("record.zig");
const runs = @import("runs.zig");
const get = r.get;
const put = r.put;
const ea = @import("ea.zig");
fn featureEa(buffer: []u8, large: bool) []const u8 {
    const name = if (large) "USOS.LARGE" else "USOS.DATA";
    const size: usize = if (large) 768 else 3;
    put(u16, buffer, 0, @intCast(size));
    buffer[2] = @intCast(name.len);buffer[3] = 0;
    @memcpy(buffer[4..][0..name.len], name);buffer[4 + name.len] = 0;
    for (0..size) |i| buffer[5 + name.len + i] = if (large) @truncate(i * 13) else ([_]u8{ 7, 0, 9 })[i];
    return buffer[0 .. 5 + name.len + size];
}

test "DOS 8.3 aliases preserve directories, hardlink counts and index lookups" {
    const bytes = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var memory: Memory = .{ .bytes = bytes };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = bytes.len - 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, std.testing.allocator, 0x21e2c98edaa413bd);
    defer fs.deinit();
    try fs.format();
    const directory = try fs.mkdir(5, u("Long Directory"), .{});
    _ = try fs.setShortName(5, u("Long Directory"), u("LONGDI~1"), directory);
    var pattern: Pattern = .{ .size = 17, .seed = 9 };
    const record = try fs.writeFile(directory, u("Long File Name.txt"), pattern.source(), .{});
    _ = try fs.setShortName(directory, u("Long File Name.txt"), u("LONGFI~1.TXT"), record);
    try fs.linkFile(5, u("Other Long Name.txt"), record);
    try std.testing.expect(!try fs.setShortName(5, u("Other Long Name.txt"), u("OTHERL~1.TXT"), record));
    try std.testing.expectEqual(directory, (try fs.lookup(5, u("LONGDI~1"))).?);
    try std.testing.expectEqual(record, (try fs.lookup(directory, u("LONGFI~1.TXT"))).?);
    try std.testing.expectEqual(@as(?u64, null), try fs.lookup(5, u("OTHERL~1.TXT")));
    try std.testing.expect(!try fs.setShortName(5, u("Other Long Name.txt"), u("LONGDI~1"), record));
    try std.testing.expectError(error.UnsupportedShortNameUnlink, fs.removeFile(directory, u("Long File Name.txt")));
    try fs.finish();
    const raw: Raw = .{ .bytes = bytes, .start = partition.start_bytes, .mft = fs.mft_runs.items };
    const base = try raw.record(record);
    try std.testing.expectEqual(@as(u16, 2), get(u16, &base, 18));
    var attrs = try raw.attributes(record, std.testing.allocator);
    defer freeAttrs(&attrs);
    var win32: usize = 0;
    var dos: usize = 0;
    var posix: usize = 0;
    for (attrs.items) |attr| if (get(u32, attr, 0) == 0x30) {
        const ns = attrValue(attr)[65];
        if (ns == 1) win32 += 1 else if (ns == 2) dos += 1 else if (ns == 0) posix += 1 else return error.Corrupt;
    };
    try std.testing.expectEqual(@as(usize, 1), win32);
    try std.testing.expectEqual(@as(usize, 1), dos);
    try std.testing.expectEqual(@as(usize, 1), posix);
}

test "DOS short-name validation rejects malformed and overlong aliases" {
    for ([_][]const u16{ u(""), u("TOOLONG99.TXT"), u("BASE.LONG"), u(".TXT"), u("BASE."), u("A B.TXT"), u("A+B.TXT"), u("A..B") }) |bad|
        try std.testing.expectError(error.InvalidShortName, ntfs.validateShortName(bad));
    try ntfs.validateShortName(u("LONGFI~1.TXT"));
    try ntfs.validateShortName(u("WINDOWS"));
}

test "object IDs retain all 64 bytes and a populated ULONGS ObjId index" {
    const bytes = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var memory: Memory = .{ .bytes = bytes };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = bytes.len - 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, std.testing.allocator, 0x21e2c98edaa413bd);
    defer fs.deinit();
    try fs.format();
    var pattern: Pattern = .{ .size = 17, .seed = 9 };
    const record = try fs.writeFile(5, u("object.bin"), pattern.source(), .{});
    const other = try fs.writeFile(5, u("other.bin"), pattern.source(), .{});
    var object: [64]u8 = undefined;
    for (&object, 0..) |*b, i| b.* = @truncate(i + 1);
    try fs.setObjectId(record, &object);
    try std.testing.expectError(error.DuplicateObjectId, fs.setObjectId(other, &object));
    try fs.finish();
    const raw: Raw = .{ .bytes = bytes, .start = partition.start_bytes, .mft = fs.mft_runs.items };
    var attrs = try raw.attributes(record, std.testing.allocator);
    defer freeAttrs(&attrs);
    var found = false;
    for (attrs.items) |attr| if (get(u32, attr, 0) == 0x40) {
        try std.testing.expectEqualSlices(u8, object[0..16], attrValue(attr)); found = true;
    };
    try std.testing.expect(found);
    const index_record = try raw.record(25);
    const root = (try r.find(@constCast(&index_record), 0x90, u("$O"))).?;
    try std.testing.expectEqual(@as(u32, 0x13), get(u32, try r.value(root.bytes), 4));
    try std.testing.expect((try r.find(@constCast(&index_record), 0xa0, u("$O"))) != null);
}
fn u(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
pub const FeatureResult = struct { original: u64, survivor: u64, sparse: u64, compressed: u64, dense_sparse: u64, empty: u64, junction: u64, symlink: u64, security_count: u32 };
pub const times: ntfs.FileTimes = .{ .created = 132537600000000001, .modified = 132537600100000002, .changed = 132537600200000003, .accessed = 132537600300000004 };
pub const Pattern = struct {
    size: u64,
    seed: u8,
    sparse: bool = false,
    pub fn source(self: *Pattern) ntfs.Source {
        return .{ .context = self, .size = self.size, .read_fn = read };
    }
    pub fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Pattern = @ptrCast(@alignCast(ctx));
        if (offset > self.size or out.len > self.size - offset) return error.Bounds;
        for (out, 0..) |*byte, i| {
            const at = offset + i;
            byte.* = if (!self.sparse or at < 4096 or at >= self.size -| 4096) self.seed ^ @as(u8, @truncate(at *% 37 +% (at >> 12) *% 11)) else 0;
        }
    }
};
pub fn securityDescriptor(rid: u32) [48]u8 {
    var sd: [48]u8 = @splat(0);
    sd[0] = 1;
    put(u16, &sd, 2, 0x8000);
    put(u32, &sd, 4, 20);
    put(u32, &sd, 8, 32);
    sd[20] = 1;
    sd[21] = 1;
    sd[27] = 5;
    put(u32, &sd, 28, rid);
    sd[32] = 1;
    sd[33] = 2;
    sd[39] = 5;
    put(u32, &sd, 40, 32);
    put(u32, &sd, 44, 544);
    return sd;
}
pub fn reparseBuffer(out: []u8, tag: u32, substitute: []const u16, print: []const u16, relative: bool) []const u8 {
    const prefix: usize = if (tag == 0xa000000c) 20 else 16;
    const count = prefix + (substitute.len + print.len + 2) * 2;
    @memset(out[0..count], 0);
    put(u32, out, 0, tag);
    put(u16, out, 4, @intCast(count - 8));
    put(u16, out, 10, @intCast(substitute.len * 2));
    put(u16, out, 12, @intCast((substitute.len + 1) * 2));
    put(u16, out, 14, @intCast(print.len * 2));
    if (tag == 0xa000000c) put(u32, out, 16, @intFromBool(relative));
    r.utf16(out[prefix..], substitute);
    r.utf16(out[prefix + (substitute.len + 1) * 2 ..], print);
    return out[0..count];
}
/// Deterministic, independently enumerable fixture. No host paths, disk API or
/// allocator globals are used, so final host/firmware entrypoints can reuse it.
pub fn populate(fs: *ntfs.Ntfs) !FeatureResult {
    const security_dir = try fs.mkdir(5, u("Security"), .{});
    _ = try fs.setShortName(5, u("Security"), u("SECURI~1"), security_dir);
    const links = try fs.mkdir(5, u("Links"), .{});
    const streams = try fs.mkdir(5, u("Streams"), .{});
    const reparse = try fs.mkdir(5, u("Reparse"), .{});
    _ = try fs.mkdir(links, u("Target"), .{});
    var empty: Pattern = .{ .size = 0, .seed = 0 };
    for (0..5000) |i| {
        const sd = securityDescriptor(@intCast(1000 + i));
        const id = try fs.registerSecurity(&sd);
        if (try fs.registerSecurity(&sd) != id) return error.Corrupt;
        var name: [16]u16 = @splat(0);
        name[0] = 's';
        for (0..4) |digit| name[1 + digit] = @as(u16, @intCast((i / std.math.pow(usize, 10, @intCast(3 - digit))) % 10)) + '0';
        _ = try fs.writeFile(security_dir, name[0..5], empty.source(), .{ .security_id = id });
    }
    var original: Pattern = .{ .size = 8193, .seed = 0x71 };
    const inode = try fs.writeFile(links, u("original.bin"), original.source(), .{ .times = times, .attributes = 0x27 });
    try fs.linkFile(streams, u("survivor.bin"), inode);
    try fs.linkFile(links, u("third.bin"), inode);
    try fs.removeFile(links, u("original.bin"));
    try std.testing.expect(try fs.setShortName(links, u("third.bin"), u("THIRD~1.BIN"), inode));
    try std.testing.expect(!try fs.setShortName(streams, u("survivor.bin"), u("SURVIV~1.BIN"), inode));
    const metadata: ntfs.FileOptions = .{ .times = times, .attributes = 0x27, .security_id = 257 };
    try fs.setMetadata(inode, metadata);
    var small_ads: Pattern = .{ .size = 37, .seed = 0x32 };
    try fs.writeStream(inode, u("Zone.Identifier"), small_ads.source(), .{});
    var large_ads: Pattern = .{ .size = 196609, .seed = 0xa5 };
    try fs.writeStream(inode, u("large-世界"), large_ads.source(), .{ .max_run_clusters = 1 });
    var sparse: Pattern = .{ .size = 1048576 + 37, .seed = 0x53, .sparse = true };
    const sparse_inode = try fs.writeFile(streams, u("sparse.bin"), sparse.source(), .{ .sparse = true });
    var dense: Pattern = .{ .size = 32769, .seed = 0xb8 };
    const compressed = try fs.writeFile(streams, u("compressed.bin"), dense.source(), .{ .compressed = true });
    var object_id: [64]u8 = undefined;
    for (&object_id, 0..) |*byte, i| byte.* = @intCast(i + 1);
    try fs.setObjectId(compressed, &object_id);
    const dense_sparse = try fs.writeFile(streams, u("dense-sparse.bin"), dense.source(), .{ .sparse = true });
    _ = try fs.setShortName(streams, u("dense-sparse.bin"), u("DENSES~1.BIN"), dense_sparse);
    const zero = try fs.writeFile(streams, u("zero.bin"), empty.source(), .{ .sparse = true, .times = times });
    var buffer: [1024]u8 = undefined;
    for ([_]bool{ false, true }) |large| {
        const native = try ea.fromWim(fs.allocator, featureEa(&buffer, large));
        defer fs.allocator.free(native);
        try fs.setExtendedAttributes(if (large) zero else dense_sparse, native);
    }
    const junction = try fs.mkdir(reparse, u("junction"), .{});
    try fs.setReparse(junction, reparseBuffer(&buffer, 0xa0000003, u("\\??\\C:\\Links\\Target"), u("C:\\Links\\Target"), false));
    const symlink = try fs.writeFile(reparse, u("symlink"), empty.source(), .{});
    try fs.setReparse(symlink, reparseBuffer(&buffer, 0xa000000c, u("..\\Links\\third.bin"), u("..\\Links\\third.bin"), true));
    try fs.setMetadata(junction, .{ .times = times, .attributes = 0x10 });
    return .{ .original = inode, .survivor = inode, .sparse = sparse_inode, .compressed = compressed, .dense_sparse = dense_sparse, .empty = zero, .junction = junction, .symlink = symlink, .security_count = 5001 };
}
const Memory = struct {
    bytes: []u8,
    writes: u64 = 0,
    fail_write: bool = false,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (self.fail_write) return error.Io;
        @memcpy(self.bytes[@intCast(offset)..][0..input.len], input);
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *@This()) p.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};
fn attrValue(raw: []const u8) []const u8 {
    return raw[get(u16, raw, 20)..][0..get(u32, raw, 16)];
}
fn readRuns(bytes: []const u8, start: u64, list: []const runs.Run, offset: u64, out: []u8) !void {
    var done: usize = 0;
    while (done < out.len) {
        const location = try runs.locate(list, (offset + done) / 4096);
        const intra: usize = @intCast((offset + done) % 4096);
        const n: usize = @intCast(@min(out.len - done, location.available * 4096 - intra));
        if (location.lcn) |lcn| @memcpy(out[done..][0..n], bytes[@intCast(start + lcn * 4096 + intra)..][0..n]) else @memset(out[done..][0..n], 0);
        done += n;
    }
}
const Raw = struct {
    bytes: []const u8,
    start: u64,
    mft: []const runs.Run,
    fn record(self: Raw, number: u64) ![1024]u8 {
        var out: [1024]u8 = undefined;
        try readRuns(self.bytes, self.start, self.mft, number * 1024, &out);
        try r.unprotect(&out);
        return out;
    }
    fn attributes(self: Raw, number: u64, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
        var output: std.ArrayList([]u8) = .empty;
        errdefer {
            for (output.items) |v| allocator.free(v);
            output.deinit(allocator);
        }
        var base = try self.record(number);
        if (try r.find(&base, 0x20, &.{})) |list_attr| {
            var decoded: [1024]runs.Run = undefined;
            var count: usize = 0;
            var decoder: runs.Decoder = .{ .bytes = list_attr.bytes[get(u16, list_attr.bytes, 32)..] };
            while (try decoder.next()) |run| {
                decoded[count] = run;
                count += 1;
            }
            const storage = try allocator.alloc(u8, @intCast(get(u64, list_attr.bytes, 48)));
            defer allocator.free(storage);
            try readRuns(self.bytes, self.start, decoded[0..count], 0, storage);
            var pos: usize = 0;
            while (pos < storage.len) {
                const length = get(u16, storage, pos + 4);
                var target = try self.record(get(u64, storage, pos + 16) & 0xffffffffffff);
                var at: usize = get(u16, &target, 20);
                while (at + 8 < target.len and get(u32, &target, at) != 0xffffffff) {
                    const size = get(u32, &target, at + 4);
                    if (get(u16, &target, at + 14) == get(u16, storage, pos + 24) and get(u32, &target, at) == get(u32, storage, pos)) {
                        try output.append(allocator, try allocator.dupe(u8, target[at..][0..size]));
                        break;
                    }
                    at += size;
                }
                pos += length;
            }
        } else {
            var pos: usize = get(u16, &base, 20);
            while (get(u32, &base, pos) != 0xffffffff) {
                const length = get(u32, &base, pos + 4);
                try output.append(allocator, try allocator.dupe(u8, base[pos..][0..length]));
                pos += length;
            }
        }
        return output;
    }
};
fn freeAttrs(attrs: *std.ArrayList([]u8)) void {
    for (attrs.items) |v| std.testing.allocator.free(v);
    attrs.deinit(std.testing.allocator);
}
test "WIM NTFS: hardlinks ADS sparse compression times reparse and 5000 unique Secure descriptors" {
    const data = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var memory: Memory = .{ .bytes = data };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = data.len - 1024 * 1024 };
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, tracker.allocator(), 0x21e2c98edaa413bd);
    defer fs.deinit();
    try fs.format();
    const result = try populate(&fs);
    var expected: [5000]u8 = undefined;
    var actual: [5000]u8 = undefined;
    var pattern: Pattern = .{ .size = 1048576 + 37, .seed = 0x53, .sparse = true };
    for ([_]u64{ 0, 4090, 32700, 1048576 - 4100 }) |at| {
        const count: usize = @intCast(@min(expected.len, pattern.size - at));
        try Pattern.read(&pattern, at, expected[0..count]);
        try std.testing.expectEqual(count, try fs.readFile(result.sparse, at, actual[0..count]));
        try std.testing.expectEqualSlices(u8, expected[0..count], actual[0..count]);
    }
    var ads: Pattern = .{ .size = 196609, .seed = 0xa5 };
    try Pattern.read(&ads, 196609 - 5000, &expected);
    try std.testing.expectEqual(actual.len, try fs.readStream(result.survivor, u("large-世界"), 196609 - 5000, &actual));
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try fs.finish();
    const raw: Raw = .{ .bytes = data, .start = partition.start_bytes, .mft = fs.mft_runs.items };
    var links = try raw.attributes(result.original, std.testing.allocator);
    defer freeAttrs(&links);
    var fn_count: usize = 0;
    var namespaces = [_]u8{0} ** 4;
    var data_names: usize = 0;
    for (links.items) |attr| {
        if (get(u32, attr, 0) == 0x80) {
            const expected_name = switch (data_names) {
                0 => u(""),
                1 => u("large-世界"),
                2 => u("Zone.Identifier"),
                else => return error.Corrupt,
            };
            try std.testing.expectEqual(expected_name.len, attr[9]);
            for (expected_name, 0..) |unit, i| try std.testing.expectEqual(unit, get(u16, attr, get(u16, attr, 10) + i * 2));
            data_names += 1;
        }
        if (get(u32, attr, 0) == 0x30) {
            fn_count += 1;
            const ns = attrValue(attr)[65];
            try std.testing.expect(ns < 3);
            namespaces[ns] += 1;
        }
        if (get(u32, attr, 0) == 0x10) {
            const value = attrValue(attr);
            try std.testing.expectEqual(times.created, get(u64, value, 0));
            try std.testing.expectEqual(times.modified, get(u64, value, 8));
            try std.testing.expectEqual(times.changed, get(u64, value, 16));
            try std.testing.expectEqual(times.accessed, get(u64, value, 24));
            try std.testing.expectEqual(@as(u32, 257), get(u32, value, 52));
        }
    }
    try std.testing.expectEqual(@as(usize, 3), fn_count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 0 }, &namespaces);
    try std.testing.expectEqual(@as(usize, 3), data_names);
    const record = try raw.record(result.original);
    try std.testing.expectEqual(@as(u16, 2), get(u16, &record, 18));
    var sparse = try raw.attributes(result.sparse, std.testing.allocator);
    defer freeAttrs(&sparse);
    var compressed = try raw.attributes(result.compressed, std.testing.allocator);
    defer freeAttrs(&compressed);
    for (sparse.items) |attr| if (get(u32, attr, 0) == 0x80) {
        try std.testing.expectEqual(@as(u16, 0x8000), get(u16, attr, 12));
        try std.testing.expectEqual(@as(u8, 4), attr[34]);
        try std.testing.expect(get(u64, attr, 64) < get(u64, attr, 40));
    };
    for (compressed.items) |attr| if (get(u32, attr, 0) == 0x80) {
        try std.testing.expectEqual(@as(u16, 1), get(u16, attr, 12));
        try std.testing.expectEqual(@as(u64, 65536), get(u64, attr, 64));
    };
    var secure = try raw.attributes(9, std.testing.allocator);
    defer freeAttrs(&secure);
    var roots: usize = 0;
    for (secure.items) |attr| if (get(u32, attr, 0) == 0x90) {
        roots += 1;
        try std.testing.expectEqual(@as(u8, 1), attrValue(attr)[28]);
    };
    try std.testing.expectEqual(@as(usize, 2), roots);
    try std.testing.expectEqual(@as(usize, 5001), fs.security_entries.items.len);
    for (fs.security_entries.items) |entry| {
        var primary: [68]u8 = undefined;
        var duplicate: [68]u8 = undefined;
        // Default descriptor is124B rather than48; compare every header and
        // all custom descriptors using the independently mapped SDS stream.
        try readRuns(data, partition.start_bytes, fs.secure_stream.list.items, entry.offset, &primary);
        try readRuns(data, partition.start_bytes, fs.secure_stream.list.items, entry.offset + 0x40000, &duplicate);
        try std.testing.expectEqualSlices(u8, &primary, &duplicate);
        try std.testing.expectEqual(entry.offset, get(u64, &primary, 8));
        try std.testing.expectEqual(entry.id, get(u32, &primary, 4));
        try std.testing.expect((entry.offset & 0x3ffff) + entry.length <= 0x40000);
    }
    try std.testing.expect(tracker.peak < 16 * 1024 * 1024);
}
test "WIM NTFS: invalid reparse rejected before writes" {
    var bytes: [1024]u8 = undefined;
    const raw = reparseBuffer(&bytes, 0xa000000c, u("..\\target"), u("..\\target"), true);
    try ntfs.validateReparse(raw);
    put(u16, &bytes, 8, 0xffff);
    try std.testing.expectError(error.InvalidArgument, ntfs.validateReparse(raw));
}
test "WIM NTFS: root metadata is applied and a failed data write cannot finish clean" {
    const data = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var memory: Memory = .{ .bytes = data };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = data.len - 1024 * 1024 };
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, tracker.allocator(), 0xd86c40583c7d4189);
    defer fs.deinit();
    try fs.format();
    const descriptor = securityDescriptor(717);
    const id = try fs.registerSecurity(&descriptor);
    try fs.setMetadata(5, .{ .times = times, .attributes = 0x12, .security_id = id });
    const raw: Raw = .{ .bytes = data, .start = partition.start_bytes, .mft = fs.mft_runs.items };
    var root = try raw.record(5);
    const si = attrValue((try r.find(&root, 0x10, &.{})).?.bytes);
    try std.testing.expectEqual(times.created, get(u64, si, 0));
    try std.testing.expectEqual(times.changed, get(u64, si, 16));
    try std.testing.expectEqual(@as(u32, 6), get(u32, si, 32));
    try std.testing.expectEqual(id, get(u32, si, 52));
    const filename = attrValue((try r.find(&root, 0x30, &.{})).?.bytes);
    try std.testing.expectEqual(@as(u8, 3), filename[65]);
    try std.testing.expectEqual(@as(u32, 0x10000006), get(u32, filename, 56));
    try std.testing.expectEqual(@as(u64, 5), (try fs.lookup(5, u("."))).?);
    try std.testing.expectError(error.InvalidArgument, fs.setMetadata(0, .{}));
    var source: Pattern = .{ .size = 65537, .seed = 0x7c };
    memory.fail_write = true;
    try std.testing.expectError(error.Io, fs.writeFile(5, u("must-not-complete"), source.source(), .{}));
    memory.fail_write = false;
    const before = memory.writes;
    try std.testing.expect(fs.failed);
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try std.testing.expectEqual(before, memory.writes);
    var volume = try raw.record(3);
    try std.testing.expect(get(u16, attrValue((try r.find(&volume, 0x70, &.{})).?.bytes), 10) & 1 != 0);
}
test "WIM NTFS: root retains reserved SI and FILE_NAME flags without altering ordinary files" {
    const data = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var memory: Memory = .{ .bytes = data };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = data.len - 1024 * 1024 };
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, tracker.allocator(), 0x61ad4a3e0de9b682);
    defer fs.deinit();
    try fs.format();
    const descriptor = securityDescriptor(991);
    const id = try fs.registerSecurity(&descriptor);
    // This is the real-WIM root case that the earlier generic metadata test
    // missed: WIM has no HIDDEN/SYSTEM flags, but the NTFS volume root must
    // retain them in both SI and FN. Ordinary file attributes remain exact.
    try fs.setMetadata(5, .{ .times = times, .attributes = 0x10, .security_id = id });
    var empty: Pattern = .{ .size = 0, .seed = 0 };
    const child = try fs.writeFile(5, u("ordinary"), empty.source(), .{ .attributes = 0 });
    try fs.setMetadata(child, .{ .times = times, .attributes = 0 });
    try fs.finish();
    const raw: Raw = .{ .bytes = data, .start = partition.start_bytes, .mft = fs.mft_runs.items };
    var root = try raw.record(5);
    const si = attrValue((try r.find(&root, 0x10, &.{})).?.bytes);
    const filename = attrValue((try r.find(&root, 0x30, &.{})).?.bytes);
    try std.testing.expectEqual(@as(u32, 6), get(u32, si, 32));
    try std.testing.expectEqual(id, get(u32, si, 52));
    try std.testing.expectEqual(@as(u32, 0x10000006), get(u32, filename, 56));
    try std.testing.expectEqual(@as(u64, 0x0005000000000005), get(u64, filename, 0));
    try std.testing.expectEqual(@as(u16, 5), get(u16, &root, 16));
    try std.testing.expectEqual(@as(u8, 3), filename[65]);
    try std.testing.expectEqualSlices(u8, si[0..32], filename[8..40]);
    try std.testing.expectEqual(times.created, get(u64, si, 0));
    try std.testing.expectEqual(times.modified, get(u64, si, 8));
    try std.testing.expectEqual(times.changed, get(u64, si, 16));
    try std.testing.expectEqual(times.accessed, get(u64, si, 24));
    try std.testing.expectEqual(@as(u64, 5), (try fs.lookup(5, u("."))).?);
    var ordinary = try raw.record(child);
    try std.testing.expectEqual(@as(u32, 0), get(u32, attrValue((try r.find(&ordinary, 0x10, &.{})).?.bytes), 32));
    try std.testing.expectEqual(@as(u32, 0), get(u32, attrValue((try r.find(&ordinary, 0x30, &.{})).?.bytes), 56));
}
test "WIM NTFS: allocator exhaustion in an unpublished DATA resource poisons finish" {
    const data = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(data);
    @memset(data, 0);
    var memory: Memory = .{ .bytes = data };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = data.len - 1024 * 1024 };
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 16 * 1024 * 1024 };
    var fs = try ntfs.Ntfs.init(memory.disk(), partition, tracker.allocator(), 0x2143e08a33f05599);
    defer fs.deinit();
    try fs.format();
    // Load the root before fault injection: an allocation failure while merely
    // loading a directory has not started publishing a DATA resource.
    _ = try fs.lookup(5, u("absent"));
    tracker.limit = tracker.current;
    var source: Pattern = .{ .size = 65537, .seed = 0x5c };
    try std.testing.expectError(error.OutOfMemory, fs.writeFile(5, u("must-not-complete"), source.source(), .{}));
    try std.testing.expect(fs.failed);
    const before = memory.writes;
    try std.testing.expectError(error.PoisonedVolume, fs.finish());
    try std.testing.expectEqual(before, memory.writes);
}
