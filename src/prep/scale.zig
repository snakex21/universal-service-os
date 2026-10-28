//! Stage1b-1 generated workloads. The formatter and sources stay streaming;
//! no WIM reader, installation flow or firmware-owned storage is used here.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const ntfs = @import("ntfs.zig");
const identity = @import("identity.zig");
const Logger = @import("app.zig").Logger;

pub const Profile = enum { firmware, tree150k, single50k, fragment5g };
pub const block_bytes = 4096;
pub const large_file_bytes: u64 = 5 * 1024 * 1024 * 1024;

/// The first8bytes of every4096-byte block encode the file's seed in LE.
/// Remaining bytes are (block_position*37+11) mod256. An independent host
/// generator uses the same documented fixture format, not this code.
pub const Generated = struct {
    block: [block_bytes]u8 = undefined,
    bytes: u64 = 0,
    pub fn init(bytes: u64, seed: u64) Generated {
        var self: Generated = .{ .bytes = bytes };
        for (&self.block, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
        self.setSeed(seed);
        return self;
    }
    pub fn setSeed(self: *Generated, seed: u64) void {
        std.mem.writeInt(u64, self.block[0..8], seed, .little);
    }
    pub fn read(ctx: *anyopaque, offset: u64, output: []u8) platform.Error!void {
        const self: *Generated = @ptrCast(@alignCast(ctx));
        if (offset > self.bytes or output.len > self.bytes - offset) return error.Bounds;
        var done: usize = 0;
        while (done < output.len) {
            const position: usize = @intCast((offset + done) % block_bytes);
            const count = @min(output.len - done, block_bytes - position);
            @memcpy(output[done..][0..count], self.block[position..][0..count]);
            done += count;
        }
    }
    pub fn source(self: *Generated) ntfs.Source {
        return .{ .context = self, .size = self.bytes, .read_fn = read };
    }
};

fn name16(output: []u16, bytes: []u8, comptime format: []const u8, args: anytype) ![]const u16 {
    const text = try std.fmt.bufPrint(bytes, format, args);
    const count = try std.unicode.utf8ToUtf16Le(output, text);
    return output[0..count];
}

fn putFile(fs: *ntfs.Ntfs, parent: u64, name: []const u16, generated: *Generated, seed: u64) !u64 {
    generated.setSeed(seed);
    return fs.writeFile(parent, name, generated.source(), .{});
}

/// Deliberately creates real holes between live files. Merely splitting a
/// contiguous runlist into adjacent runs would not test fragmentation.
fn fragmented(fs: *ntfs.Ntfs, parent: u64, large: bool, log: Logger) !void {
    const pairs: usize = if (large) 1024 else 256;
    var fixture = Generated.init(64 * 1024, 0);
    var bytes: [64]u8 = undefined;
    var wide: [64]u16 = undefined;
    for (0..pairs) |i| {
        _ = try putFile(fs, parent, try name16(&wide, &bytes, "hole-{d:0>5}.bin", .{i}), &fixture, 0x10000000 + i);
        _ = try putFile(fs, parent, try name16(&wide, &bytes, "keep-{d:0>5}.bin", .{i}), &fixture, 0x20000000 + i);
    }
    for (0..pairs) |i| try fs.removeFile(parent, try name16(&wide, &bytes, "hole-{d:0>5}.bin", .{i}));
    fixture.bytes = if (large) large_file_bytes else pairs * 64 * 1024;
    const file = try putFile(fs, parent, std.unicode.utf8ToUtf16LeStringLiteral("fragmented.bin"), &fixture, 0x30000000);
    const details = try fs.fileStats(file);
    if (details.run_count < 100 or details.attribute_list_records == 0) return error.Corrupt;
    log.say("FRAGMENT bytes={d} runs={d} attribute_list_records={d} actual_holes={d}\n", .{ details.size, details.run_count, details.attribute_list_records, pairs });
    var expected = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < fixture.bytes) {
        const count: usize = @intCast(@min(buffer.len, fixture.bytes - offset));
        try Generated.read(&fixture, offset, buffer[0..count]);
        expected.update(buffer[0..count]);
        offset += count;
    }
    const actual = try fs.hashFile(file);
    const expected_hash = expected.finalResult();
    if (!std.mem.eql(u8, &actual, &expected_hash)) return error.Corrupt;
    log.say("FRAGMENT READBACK sha256={s} OK\n", .{std.fmt.bytesToHex(actual, .lower)});
}

pub fn run(disk: platform.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *platform.TrackedAllocator, profile: Profile, log: Logger) !void {
    try ids.validate();
    const started = log.now();
    log.say("USOSPREP 1b-1 profile={s} mode={s} disk_bytes={d} sector_bytes={d}\n", .{ @tagName(profile), @tagName(kind), try disk.bytes(), disk.sector_bytes });
    const partition = try partitions.create(disk, kind, ids);
    var fs = try ntfs.Ntfs.init(disk, partition, tracker.allocator(), ids.ntfs_serial);
    defer fs.deinit();
    try fs.format();
    var bytes: [64]u8 = undefined;
    var wide: [64]u16 = undefined;
    var fixture = Generated.init(switch (profile) {
        .tree150k => 65536,
        .single50k => 4096,
        else => 64,
    }, 0);
    const count: usize = switch (profile) {
        .firmware => 10000,
        .tree150k => 150000,
        .single50k => 50000,
        .fragment5g => 0,
    };
    var written: usize = 0;
    if (profile == .firmware or profile == .single50k) {
        const dir = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("Wide"), .{});
        const single: usize = if (profile == .firmware) 5000 else 50000;
        // A permutation inserts in non-sorted order and exercises both sides
        // of directory nodes. 7919 is coprime to both5000 and50000.
        for (0..single) |step| {
            const i = (step * 7919) % single;
            _ = try putFile(&fs, dir, try name16(&wide, &bytes, "file-{d:0>5}.bin", .{i}), &fixture, i);
            written += 1;
            if (written == 10000 or written == 25000) log.say("WIDE checkpoint={d} seconds={d} alloc_peak={d}\n", .{ written, log.now() -| started, tracker.peak });
        }
        log.say("WIDE files={d} seconds={d} alloc_peak={d}\n", .{ single, log.now() -| started, tracker.peak });
    }
    if (profile == .firmware or profile == .tree150k) {
        const tree = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("Tree"), .{});
        const directories: usize = if (profile == .firmware) 100 else 300;
        const per_directory: usize = if (profile == .firmware) 50 else 500;
        for (0..directories) |d| {
            const dir = try fs.mkdir(tree, try name16(&wide, &bytes, "dir-{d:0>3}", .{d}), .{});
            for (0..per_directory) |step| {
                const i = (step * 37) % per_directory;
                const seed = (if (profile == .firmware) @as(u64, 5000) else @as(u64, 0)) + d * per_directory + i;
                _ = try putFile(&fs, dir, try name16(&wide, &bytes, "file-{d:0>5}.bin", .{i}), &fixture, seed);
                written += 1;
            }
        }
        log.say("TREE files={d} directories={d} bytes={d} seconds={d} alloc_peak={d}\n", .{ directories * per_directory, directories, @as(u64, directories * per_directory) * fixture.bytes, log.now() -| started, tracker.peak });
    }
    if (written != count) return error.Corrupt;
    if (profile == .firmware or profile == .fragment5g) {
        const frag = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("Frag"), .{});
        try fragmented(&fs, frag, profile == .fragment5g, log);
    }
    if (profile == .firmware) {
        // Also leave a genuinely empty directory after a complete tree
        // collapse; Windows must accept that index, not just a half-full one.
        const scratch_dir = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("Scratch"), .{});
        fixture.bytes = 64;
        for (0..64) |i| _ = try putFile(&fs, scratch_dir, try name16(&wide, &bytes, "scratch-{d:0>3}.tmp", .{i}), &fixture, 0x40000000 + i);
        for (0..64) |i| try fs.removeFile(scratch_dir, try name16(&wide, &bytes, "scratch-{d:0>3}.tmp", .{i}));
        log.say("EMPTY-INDEX delete-all files=64 directory=Scratch OK\n", .{});
    }
    try fs.finish();
    try disk.flush();
    const stats = fs.statistics();
    if ((profile == .firmware or profile == .tree150k or profile == .single50k) and (stats.mft_records <= 8192 or stats.mft_runs < 2)) return error.Corrupt;
    if ((profile == .firmware or profile == .fragment5g) and (stats.reused_clusters == 0 or stats.record_reuses == 0)) return error.Corrupt;
    log.say("MFT records={d} runs={d} reused_clusters={d} record_reuses={d}\n", .{ stats.mft_records, stats.mft_runs, stats.reused_clusters, stats.record_reuses });
    log.say("USOSPREP SCALE PASS profile={s} base_files={d} seconds={d} alloc_current={d} alloc_peak={d}; independent readonly checks required\n", .{ @tagName(profile), written, log.now() -| started, tracker.current, tracker.peak });
}

test "generated fixture reads preserve seed and wrap across4096byte boundaries" {
    var fixture = Generated.init(8193, 0x123456789abcdef0);
    var bytes: [9]u8 = undefined;
    try Generated.read(&fixture, 4092, &bytes);
    try std.testing.expectEqualSlices(u8, fixture.block[4092..], bytes[0..4]);
    try std.testing.expectEqualSlices(u8, fixture.block[0..5], bytes[4..]);
    try std.testing.expectError(error.Bounds, Generated.read(&fixture, 8190, &bytes));
    var seed: [8]u8 = undefined;
    try Generated.read(&fixture, 4096, &seed);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), std.mem.readInt(u64, &seed, .little));
}
