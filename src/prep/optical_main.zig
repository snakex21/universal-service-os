//! Host-only regular-image harness; optical core has no host dependencies.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const host = @import("host_main.zig");
const o = @import("optical.zig");
const on = @import("optical_ntfs.zig");
const p = @import("platform.zig");
const optical_wim = @import("optical_wim.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
const ntfs_writer = @import("ntfs.zig");
fn manifest(v: *const o.Volume, allocator: std.mem.Allocator, emit: bool) !void {
    var walker = try o.Walker.init(v, allocator);
    defer walker.deinit();
    const buffer = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buffer);
    var entry: o.Entry = undefined;
    while (try walker.next(&entry)) {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        if (!entry.node.directory) {
            var offset: u64 = 0;
            while (offset < entry.node.size) {
                const count: usize = @intCast(@min(buffer.len, entry.node.size - offset));
                try entry.node.read(v.input, offset, buffer[0..count]);
                hash.update(buffer[0..count]);
                offset += count;
            }
        }
        var sha: [32]u8 = undefined;
        hash.final(&sha);
        if (emit) {
            const text = try std.json.Stringify.valueAlloc(allocator, .{ .path = walker.path(), .directory = entry.node.directory, .size = if (entry.node.directory) @as(u64, 0) else entry.node.size, .sha256 = if (entry.node.directory) @as(?[64]u8, null) else std.fmt.bytesToHex(sha, .lower) }, .{});
            defer allocator.free(text);
            std.debug.print("ENTRY {s}\n", .{text});
        }
    }
    if (emit) std.debug.print("OPTICAL_MANIFEST_COMPLETE entries={d} skipped_symlink={d} skipped_stream={d} skipped_nameless={d} skipped_other={d}\n", .{ walker.entries, walker.skipped.symbolic_links, walker.skipped.streams, walker.skipped.nameless, walker.skipped.other });
}
const FuzzMemory = struct {
    bytes: []const u8,
    fuel: usize = 1024,
    byte_fuel: usize = 4 * 1024 * 1024,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *FuzzMemory = @ptrCast(@alignCast(ctx));
        if (self.fuel == 0 or out.len > self.byte_fuel) return error.Corrupt;
        self.fuel -= 1;
        self.byte_fuel -= out.len;
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
};
fn fuzz(input: o.Input, allocator: std.mem.Allocator) !void {
    if (input.size < 17 * 2048 or input.size > 2 * 1024 * 1024) return error.FuzzFixtureTooLarge;
    const original = try allocator.alloc(u8, @intCast(input.size));
    defer allocator.free(original);
    const bytes = try allocator.alloc(u8, original.len);
    defer allocator.free(bytes);
    try input.read(0, original);
    var random = std.Random.DefaultPrng.init(0xc11cd119);
    var rejected: usize = 0;
    for (0..1024) |i| {
        @memcpy(bytes, original);
        const at = if (i < 512) random.random().intRangeLessThan(usize, 16 * 2048, @min(bytes.len, 160 * 2048)) else random.random().uintLessThan(usize, bytes.len);
        bytes[at] ^= random.random().int(u8) | 1;
        var memory: FuzzMemory = .{ .bytes = bytes };
        const source: o.Input = .{ .context = &memory, .size = bytes.len, .read_fn = FuzzMemory.read };
        var volume = o.Volume.open(source) catch {
            rejected += 1;
            continue;
        };
        manifest(&volume, allocator, false) catch {
            rejected += 1;
            continue;
        };
    }
    std.debug.print("OPTICAL_FUZZ_COMPLETE seed=c11cd119 cases=1024 refused={d} unchanged_or_accepted={d}\n", .{ rejected, 1024 - rejected });
}
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const path = args.next() orelse return error.MissingSource;
    // Every host input is a canonical regular file. No physical paths.
    try host.validateAbsolute(path);
    const real = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, path, init.gpa);
    defer init.gpa.free(real);
    var file = try host.open(init.io, real, false);
    defer file.file.close(init.io);
    var input: o.Input = .{ .context = &file, .size = file.size, .read_fn = host.File.read };
    var tracker: p.TrackedAllocator = .{ .backing = init.gpa, .limit = 16 * 1024 * 1024 };
    if (std.mem.eql(u8, mode, "fuzz")) {
        if (args.next() != null) return error.InvalidArgument;
        try fuzz(input, tracker.allocator());
        if (tracker.current != 0) return error.AllocationLeak;
        return 0;
    }
    var ntfs_source: on.Source = undefined;
    var ntfs_open = false;
    defer if (ntfs_open) ntfs_source.deinit();
    if (std.mem.eql(u8, mode, "ntfs-manifest") or std.mem.eql(u8, mode, "ntfs-apply")) {
        const start = try std.fmt.parseInt(u64, args.next() orelse return error.MissingPartition, 10);
        const size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingPartition, 10);
        const iso_name = args.next() orelse return error.MissingIsoName;
        var name: [255]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&name, iso_name);
        ntfs_source = try on.Source.open(input, start, size, &.{name[0..n]}, tracker.allocator());
        ntfs_open = true;
        std.debug.print("NTFS_ISO_SOURCE size={d} runs={d} attribute_extents={d}\n", .{ ntfs_source.file.size(), ntfs_source.file.runCount(), ntfs_source.file.attribute_extents });
        input = ntfs_source.reader();
    }
    var disk: p.Disk = .{ .context = &file, .sectors = file.size / 2048, .sector_bytes = 2048, .read_fn = host.File.read, .write_fn = readonly, .flush_fn = noflush };
    if (std.mem.eql(u8, mode, "block-manifest")) input = try o.Input.fromDisk(&disk);
    var volume = o.Volume.open(input) catch |err| {
        std.debug.print("OPTICAL_REFUSE {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("OPTICAL kind={s} revision={x} input_bytes={d} volume_bytes={d} node_bytes={d} volume_state_bytes={d}\n", .{ @tagName(volume.kind), volume.udf_state.revision, input.size, volume.input.size, @sizeOf(o.Node), @sizeOf(o.Volume) });
    if (std.mem.eql(u8, mode, "pack-ntfs")) {
        const target = args.next() orelse return error.MissingTarget;
        const ack = args.next() orelse return error.MissingAcknowledgment;
        const workspace = args.next() orelse return error.MissingWorkspace;
        if (args.next() != null or !std.mem.eql(u8, ack, "--image-only")) return error.InvalidArgument;
        try host.validateAbsolute(workspace);
        const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
        defer init.gpa.free(root);
        const target_real = try host.ownedPath(init.io, init.gpa, root, target);
        defer init.gpa.free(target_real);
        if (!std.mem.endsWith(u8, target_real, ".raw") or std.ascii.eqlIgnoreCase(real, target_real)) return error.InvalidArgument;
        var random: [64]u8 = undefined;
        try init.io.randomSecure(&random);
        if (!entropy.healthy(&random)) return error.EntropyUnavailable;
        const ids = try identity.Identifiers.fromEntropy(random);
        var target_file = try openTarget(init.io, target_real);
        defer target_file.file.close(init.io);
        if (target_file.size < 128 * 1024 * 1024 or target_file.size > 64 * 1024 * 1024 * 1024 or target_file.size % 512 != 0) return error.InvalidArgument;
        const target_disk: p.Disk = .{ .context = &target_file, .sectors = target_file.size / 512, .read_fn = host.File.read, .write_fn = host.File.write, .flush_fn = host.File.flush };
        const partition = try partitions.create(target_disk, .gpt, ids);
        var fs = try ntfs_writer.Ntfs.init(target_disk, partition, tracker.allocator(), ids.ntfs_serial);
        defer fs.deinit();
        try fs.format();
        _ = try fs.writeFile(5, std.unicode.utf8ToUtf16LeStringLiteral("INSTALL.ISO"), .{ .context = &file, .size = file.size, .read_fn = host.File.read }, .{});
        try fs.finish();
        try target_disk.flush();
        std.debug.print("ISO_ON_NTFS_COMPLETE start={d} bytes={d} file=INSTALL.ISO size={d}\n", .{ partition.start_bytes, partition.size_bytes, file.size });
        return 0;
    } else if (std.mem.eql(u8, mode, "probe")) {
        const requested = args.next() orelse return error.MissingPath;
        const offset = try std.fmt.parseInt(u64, args.next() orelse return error.MissingOffset, 10);
        if (args.next() != null) return error.InvalidArgument;
        const node = try volume.find(requested);
        var sample: [32]u8 = undefined;
        const n: usize = @intCast(@min(sample.len, node.size -| offset));
        try node.read(volume.input, offset, sample[0..n]);
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(sample[0..n], &sha, .{});
        std.debug.print("OPTICAL_PROBE size={d} offset={d} bytes={d} sha256={s}\n", .{ node.size, offset, n, std.fmt.bytesToHex(sha, .lower) });
    } else if (std.mem.eql(u8, mode, "manifest") or std.mem.eql(u8, mode, "ntfs-manifest") or std.mem.eql(u8, mode, "block-manifest")) {
        if (args.next() != null) return error.InvalidArgument;
        manifest(&volume, tracker.allocator(), true) catch |err| {
            std.debug.print("OPTICAL_REFUSE {s}\n", .{@errorName(err)});
            return 1;
        };
    } else if (std.mem.eql(u8, mode, "apply") or std.mem.eql(u8, mode, "ntfs-apply")) {
        const target = args.next() orelse return error.MissingTarget;
        const index = try std.fmt.parseInt(u32, args.next() orelse return error.MissingIndex, 10);
        const ack = args.next() orelse return error.MissingAcknowledgment;
        const workspace = args.next() orelse return error.MissingWorkspace;
        if (!std.mem.eql(u8, ack, "--image-only") or args.next() != null) return error.InvalidArgument;
        try host.validateAbsolute(workspace);
        const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
        defer init.gpa.free(root);
        const target_real = try host.ownedPath(init.io, init.gpa, root, target);
        defer init.gpa.free(target_real);
        if (!std.mem.endsWith(u8, target_real, ".raw") or std.ascii.eqlIgnoreCase(real, target_real)) return error.InvalidArgument;
        var random: [64]u8 = undefined;
        try init.io.randomSecure(&random);
        if (!entropy.healthy(&random)) return error.EntropyUnavailable;
        const ids = try identity.Identifiers.fromEntropy(random);
        var target_file = try openTarget(init.io, target_real);
        defer target_file.file.close(init.io);
        if (target_file.size < 128 * 1024 * 1024 or target_file.size > 64 * 1024 * 1024 * 1024 or target_file.size % 512 != 0) return error.InvalidArgument;
        const target_disk: p.Disk = .{ .context = &target_file, .sectors = target_file.size / 512, .read_fn = host.File.read, .write_fn = host.File.write, .flush_fn = host.File.flush };
        var output: host.Output = .{ .io = init.io };
        optical_wim.runVolume(target_disk, partitions.Kind.gpt, ids, &tracker, &volume, index, .{}, .{ .context = &output, .write_fn = host.Output.write, .clock_fn = host.Output.clock }) catch |err| {
            std.debug.print("ISO_WIM_REFUSE {s}\n", .{@errorName(err)});
            return 1;
        };
    } else return error.InvalidArgument;
    if (ntfs_open) {
        ntfs_source.deinit();
        ntfs_open = false;
    }
    if (tracker.current != 0) return error.AllocationLeak;
    std.debug.print("OPTICAL_COMPLETE heap_peak={d} heap_current=0\n", .{tracker.peak});
    return 0;
}
/// A canonical pathname does not identify a file: two hardlink names can name
/// the same source. Refuse multiply linked destinations on the opened handle
/// before formatting, even when source and target path strings differ.
fn openTarget(io: std.Io, path: []const u8) !host.File {
    var target = try host.open(io, path, true);
    errdefer target.file.close(io);
    const stat = try target.file.stat(io);
    if (stat.nlink != 1) return error.LinkedTargetNotAllowed;
    return target;
}
fn readonly(_: *anyopaque, _: u64, _: []const u8) p.Error!void {
    return error.Unsupported;
}
fn noflush(_: *anyopaque) p.Error!void {
    return error.Unsupported;
}
