//! Owned regular-image host fixture: always new format, never open NTFS.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const host = @import("host_main.zig");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
const ntfs = @import("ntfs.zig");
const features = @import("wim_ntfs_tests.zig");
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingImage;
    const mode = args.next() orelse return error.MissingMode;
    const ack = args.next() orelse return error.MissingImageOnlyAcknowledgment;
    const workspace_arg = args.next() orelse return error.MissingWorkspace;
    const workspace = args.next() orelse return error.MissingWorkspace;
    if (args.next() != null or !std.mem.eql(u8, ack, "--image-only") or !std.mem.eql(u8, workspace_arg, "--workspace")) return error.InvalidArgument;
    try host.validateAbsolute(workspace);
    const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
    defer init.gpa.free(root);
    const real = try host.ownedPath(init.io, init.gpa, root, path);
    defer init.gpa.free(real);
    if (!std.mem.endsWith(u8, real, ".raw")) return error.InvalidArgument;
    const kind = std.meta.stringToEnum(partitions.Kind, mode) orelse return error.InvalidArgument;
    var random: [64]u8 = undefined;
    try init.io.randomSecure(&random);
    if (!entropy.healthy(&random)) return error.EntropyUnavailable;
    const ids = try identity.Identifiers.fromEntropy(random);
    var image = try host.open(init.io, real, true);
    defer image.file.close(init.io);
    if (image.size < 128 * 1024 * 1024 or image.size > 4 * 1024 * 1024 * 1024 or image.size % 512 != 0) return error.InvalidArgument;
    const disk: platform.Disk = .{ .context = &image, .sectors = image.size / 512, .read_fn = host.File.read, .write_fn = host.File.write, .flush_fn = host.File.flush };
    var tracker: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = 12 * 1024 * 1024 };
    const start = std.Io.Clock.awake.now(init.io);
    const partition = try partitions.create(disk, kind, ids);
    var fs = try ntfs.Ntfs.init(disk, partition, tracker.allocator(), ids.ntfs_serial);
    {
        defer fs.deinit();
        try fs.format();
        const result = try features.populate(&fs);
        try fs.finish();
        try disk.flush();
        std.debug.print("FEATURES security={d} link_inode={d} sparse={d} compressed={d} empty={d} junction={d} symlink={d}\n", .{ result.security_count, result.original, result.sparse, result.compressed, result.empty, result.junction, result.symlink });
    }
    if (tracker.current != 0) return error.AllocationLeak;
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start.nanoseconds;
    std.debug.print("HOST NTFS_FEATURES PASS mode={s} fresh_format=true elapsed_ns={d} alloc_current={d} alloc_peak={d}\n", .{ mode, elapsed, tracker.current, tracker.peak });
    return 0;
}
