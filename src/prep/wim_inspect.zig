//! Read-only host fixture for the actual Zig WIM parser, never a host writer.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const wim = @import("wim.zig");
const meta = @import("wim_metadata.zig");
const platform = @import("platform.zig");
const File = struct {
    io: std.Io,
    file: std.Io.File,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if ((self.file.readPositionalAll(self.io, out, at) catch return error.Io) != out.len) return error.Io;
    }
};
const Counts = struct {
    metadata: *meta.Metadata,
    archive: *wim.Archive,
    files: u64 = 0,
    directories: u64 = 0,
    reparses: u64 = 0,
    ads: u64 = 0,
    short_names: u64 = 0,
    bytes: u64 = 0,
    fn enter(ctx: *anyopaque, _: u64, item: *const meta.Entry) !u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (item.isDirectory()) self.directories += 1 else self.files += 1;
        if (item.isReparse()) self.reparses += 1;
        if (item.short_name_bytes != 0) self.short_names += 1;
        var streams = meta.StreamIterator.init(self.metadata, item.*);
        while (try streams.next()) |stream| {
            if (stream.kind == .named_data) self.ads += 1;
            if (!std.mem.allEqual(u8, &stream.hash, 0)) {
                const entry = try self.archive.find(stream.hash);
                if (stream.kind == .data) self.bytes += entry.descriptor.size;
            }
        }
        return 5;
    }
    fn leave(_: *anyopaque, _: u64, _: *const meta.Entry) !void {}
};
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingWim;
    const index = try std.fmt.parseInt(u32, args.next() orelse return error.MissingIndex, 10);
    const mode = args.next() orelse return error.MissingMode;
    if (args.next() != null or !std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//") or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidArgument;
    const verify = std.mem.eql(u8, mode, "--verify");
    if (!verify and !std.mem.eql(u8, mode, "--inspect")) return error.InvalidArgument;
    var file: File = .{ .io = init.io, .file = try std.Io.Dir.openFileAbsolute(init.io, path, .{ .mode = .read_only }) };
    defer file.file.close(init.io);
    const stat = try file.file.stat(init.io);
    if (stat.kind != .file) return error.InvalidArgument;
    var tracker: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = 12 * 1024 * 1024 };
    const start = std.Io.Clock.awake.now(init.io);
    var archive = try wim.Archive.open(tracker.allocator(), .{ .context = &file, .size = stat.size, .read_fn = File.read }, index);
    defer archive.deinit();
    const integrity = try archive.verifyIntegrity();
    var metadata = try archive.openMetadata();
    defer metadata.deinit();
    try metadata.verify();
    var tree = try meta.Metadata.open(tracker.allocator(), &metadata);
    defer tree.deinit();
    var counts: Counts = .{ .metadata = &tree, .archive = &archive };
    try tree.walk(&counts, Counts.enter, Counts.leave);
    std.debug.print("TREE files={d} dirs={d} reparse={d} ads={d} short_8_3={d} security={d} data_bytes={d}\n", .{ counts.files, counts.directories, counts.reparses, counts.ads, counts.short_names, tree.securityCount(), counts.bytes });
    std.debug.print("WIM images={d} selected={d} compression={s} chunk={d} resources={d} metadata_bytes={d} metadata_sha1=PASS raw_integrity={any}\n", .{ archive.header.images, index, if (archive.header.compression) |kind| @tagName(kind) else "none", archive.header.chunk_size, archive.resource_count, metadata.descriptor.size, integrity });
    if (verify) archive.verifyAll() catch |err| {
        const failed = try archive.entry(@intCast(archive.hashes_verified));
        std.debug.print("RESOURCE_FAIL index={d} chunk={d} offset={d} stored={d} size={d} flags={x} sha1={s} error={s}\n", .{ archive.hashes_verified, archive.failed_chunk, failed.descriptor.offset, failed.descriptor.stored, failed.descriptor.size, failed.descriptor.flags, std.fmt.bytesToHex(failed.sha1, .lower), @errorName(err) });
        return err;
    };
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start.nanoseconds;
    std.debug.print("WIM_READONLY PASS verified_blob_sha1={d} elapsed_ns={d} alloc_current={d} alloc_peak={d}\n", .{ archive.hashes_verified, elapsed, tracker.current, tracker.peak });
    return 0;
}
