//! The same workload runs on firmware and host-file backends.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const ntfs = @import("ntfs.zig");
const identity = @import("identity.zig");

pub const Logger = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) void,
    clock_fn: *const fn (*anyopaque) u64,
    telemetry_fn: ?*const fn (*anyopaque) platform.Telemetry = null,
    profiler: ?*platform.profiling.Profiler = null,
    // Optional QEMU diagnostic boundary. Never a completion/PASS indication.
    progress_fn: ?*const fn (*anyopaque, []const u8, platform.ProgressUpdate) void = null,
    pub fn say(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch "LOG LINE TOO LONG\n";
        self.write_fn(self.context, text);
    }
    pub fn now(self: Logger) u64 { return self.clock_fn(self.context); }
    pub fn telemetry(self: Logger) platform.Telemetry {
        return if (self.telemetry_fn) |snapshot| snapshot(self.context) else .{};
    }
};

pub const Fixtures = struct { small: ntfs.Source, large: ntfs.Source };

fn milestone(log: Logger, tracker: *platform.TrackedAllocator, name: []const u8, start: u64) void {
    const now = log.now();
    log.say("STEP {s} OK seconds={d} alloc_current={d} alloc_peak={d}\n", .{ name, now -| start, tracker.current, tracker.peak });
}

fn sourceHash(source: ntfs.Source) ![32]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source.size) {
        const n: usize = @intCast(@min(buffer.len, source.size - offset));
        try source.read_fn(source.context, offset, buffer[0..n]);
        sha.update(buffer[0..n]);
        offset += n;
    }
    return sha.finalResult();
}

fn copy(fs: *ntfs.Ntfs, parent: u64, name: []const u16, source: ntfs.Source, expected: [32]u8, label: []const u8, log: Logger) !void {
    const record = try fs.writeFile(parent, name, source, .{});
    const actual = try fs.hashFile(record);
    if (!std.mem.eql(u8, &actual, &expected)) return error.Corrupt;
    log.say("FILE {s} bytes={d} sha256={s} OK\n", .{ label, source.size, std.fmt.bytesToHex(actual, .lower) });
}

pub fn run(disk: platform.Disk, kind: partitions.Kind, ids: identity.Identifiers, tracker: *platform.TrackedAllocator, fixtures: Fixtures, log: Logger) !void {
    try ids.validate();
    if (fixtures.small.size != 64 or fixtures.large.size <= 100 * 1024 * 1024) return error.InvalidArgument;
    const total_start = log.now();
    log.say("USOSPREP 1a mode={s} disk_bytes={d} sector_bytes={d}\n", .{ @tagName(kind), try disk.bytes(), disk.sector_bytes });
    log.say("BUFFERS hash=65536 partition_entries=16384; allocator_limit={d}; firmware memory excluded\n", .{tracker.limit});
    log.say("IDENTITIES disk_guid={s} partition_guid={s} mbr_signature={x:0>8} ntfs_serial={x:0>16}\n", .{std.fmt.bytesToHex(ids.disk_guid, .lower),std.fmt.bytesToHex(ids.partition_guid, .lower),ids.mbr_signature,ids.ntfs_serial});
    var start = log.now();
    const small_hash = try sourceHash(fixtures.small);
    const large_hash = try sourceHash(fixtures.large);
    log.say("SOURCE small bytes={d} sha256={s}\nSOURCE large bytes={d} sha256={s}\n", .{ fixtures.small.size, std.fmt.bytesToHex(small_hash, .lower), fixtures.large.size, std.fmt.bytesToHex(large_hash, .lower) });
    milestone(log, tracker, "source-read", start);
    start = log.now();
    const partition = try partitions.create(disk, kind, ids);
    milestone(log, tracker, "partitions", start);
    start = log.now();
    var fs = try ntfs.Ntfs.init(disk, partition, tracker.allocator(), ids.ntfs_serial);
    defer fs.deinit();
    milestone(log, tracker, "core-init", start);
    try fs.format();
    milestone(log, tracker, "format-ntfs", start);
    start = log.now();
    const dir = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("Fixtures"), .{});
    const nested = try fs.mkdir(dir, std.unicode.utf8ToUtf16LeStringLiteral("Nested"), .{});
    const unicode = try fs.mkdir(nested, std.unicode.utf8ToUtf16LeStringLiteral("Zażółć-世界"), .{});
    for (0..1000) |n| {
        var name_bytes: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_bytes, "item-{d:0>4}.txt", .{n});
        var name16: [32]u16 = undefined;
        const count = try std.unicode.utf8ToUtf16Le(&name16, name);
        try copy(&fs, dir, name16[0..count], fixtures.small, small_hash, name, log);
    }
    milestone(log, tracker, "1000-directory-entries", start);
    start = log.now();
    try copy(&fs, unicode, std.unicode.utf8ToUtf16LeStringLiteral("Zażółć-gęślą-世界.txt"), fixtures.small, small_hash, "Nested/Unicode", log);
    var long_name: [255]u16 = @splat('L');
    @memcpy(long_name[251..255], &[_]u16{ '.', 't', 'x', 't' });
    try copy(&fs, nested, &long_name, fixtures.small, small_hash, "Nested/255-utf16-name", log);
    var empty_source = fixtures.small;
    empty_source.size = 0;
    try copy(&fs, nested, std.unicode.utf8ToUtf16LeStringLiteral("empty.bin"), empty_source, try sourceHash(empty_source), "Nested/empty.bin", log);
    try copy(&fs, nested, std.unicode.utf8ToUtf16LeStringLiteral("large.bin"), fixtures.large, large_hash, "Nested/large.bin", log);
    // Self-relative SD: a single allow ACE for Everyone (S-1-1-0). This is
    // generated format data, not copied from any operating system source.
    const supplied_sd = [_]u8{
        1, 0, 4, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0,
        2, 0, 28, 0, 1, 0, 0, 0, 0, 0, 20, 0, 255, 1, 31, 0,
        1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
    };
    const secured = try fs.writeFile(nested, std.unicode.utf8ToUtf16LeStringLiteral("supplied-security.bin"), fixtures.small, .{ .security_descriptor = &supplied_sd });
    const secured_hash = try fs.hashFile(secured);
    if (!std.mem.eql(u8, &secured_hash, &small_hash)) return error.Corrupt;
    log.say("FILE Nested/supplied-security.bin bytes=64 sha256={s} OK descriptor_bytes=48\n", .{std.fmt.bytesToHex(secured_hash, .lower)});
    try fs.finish();
    try disk.flush();
    milestone(log, tracker, "nested-long-unicode-large-files", start);
    milestone(log, tracker, "ALL", total_start);
    log.say("USOSPREP PASS; host read-only filesystem validation remains required\n", .{});
}
