//! Test-only owned regular-image backend for fresh WIM apply.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const host = @import("host_main.zig");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
const app = @import("wim_app.zig");
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingImage;
    const mode = args.next() orelse return error.MissingMode;
    const source_path = args.next() orelse return error.MissingWim;
    const index = try std.fmt.parseInt(u32, args.next() orelse return error.MissingImageIndex, 10);
    const ack = args.next() orelse return error.MissingImageOnlyAcknowledgment;
    const workspace_arg = args.next() orelse return error.MissingWorkspace;
    const workspace = args.next() orelse return error.MissingWorkspace;
    var target_drive: u8 = 'C';
    var verify_scope: app.VerifyScope = .selected;
    var drive_seen = false;
    var scope_seen = false;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--target-drive")) {
            if (drive_seen) return error.InvalidArgument;
            drive_seen = true;
            const drive = args.next() orelse return error.InvalidArgument;
            if (drive.len != 1 or drive[0] < 'A' or drive[0] > 'Z') return error.InvalidTargetDrive;
            target_drive = drive[0];
        } else if (std.mem.startsWith(u8, option, "verify_scope=")) {
            if (scope_seen) return error.InvalidArgument;
            scope_seen = true;
            verify_scope = std.meta.stringToEnum(app.VerifyScope, option[13..]) orelse return error.InvalidArgument;
        } else return error.InvalidArgument;
    }
    if (!std.mem.eql(u8, ack, "--image-only") or !std.mem.eql(u8, workspace_arg, "--workspace")) return error.InvalidArgument;
    try host.validateAbsolute(workspace);
    const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
    defer init.gpa.free(root);
    const real = try host.ownedPath(init.io, init.gpa, root, path);
    defer init.gpa.free(real);
    const source_real = try host.ownedPath(init.io, init.gpa, root, source_path);
    defer init.gpa.free(source_real);
    if (!std.mem.endsWith(u8, real, ".raw") or std.ascii.eqlIgnoreCase(real, source_real)) return error.InvalidArgument;
    if (std.ascii.endsWithIgnoreCase(source_real, ".swm")) return error.UnsupportedSplitWim;
    const kind = std.meta.stringToEnum(partitions.Kind, mode) orelse return error.InvalidArgument;
    var random: [64]u8 = undefined;
    try init.io.randomSecure(&random);
    if (!entropy.healthy(&random)) return error.EntropyUnavailable;
    const ids = try identity.Identifiers.fromEntropy(random);
    var input = try host.open(init.io, source_real, false);
    defer input.file.close(init.io);
    var image = try host.open(init.io, real, true);
    defer image.file.close(init.io);
    if (image.size < 128 * 1024 * 1024 or image.size > 64 * 1024 * 1024 * 1024 or image.size % 512 != 0) return error.InvalidArgument;
    const disk: platform.Disk = .{ .context = &image, .sectors = image.size / 512, .read_fn = host.File.read, .write_fn = host.File.write, .flush_fn = host.File.flush };
    var tracker: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = 12 * 1024 * 1024 };
    var output: host.Output = .{ .io = init.io };
    app.runWithOptions(disk, kind, ids, &tracker, .{ .context = &input, .size = input.size, .read_fn = host.File.read }, index, .{ .target_drive = target_drive, .verify_scope = verify_scope }, .{ .context = &output, .write_fn = host.Output.write, .clock_fn = host.Output.clock }) catch |err| {
        std.debug.print("HOST WIM FAIL error={s} alloc_current={d} alloc_peak={d}\n", .{ @errorName(err), tracker.current, tracker.peak });
        return 1;
    };
    if (tracker.current != 0) return error.AllocationLeak;
    std.debug.print("HOST WIM COMPLETE alloc_current={d} alloc_peak={d}\n", .{ tracker.current, tracker.peak });
    return 0;
}
