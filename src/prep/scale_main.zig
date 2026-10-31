//! Host-only scale fixture, reusing the accepted regular-file path guards.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const host = @import("host_main.zig");
const scale = @import("scale.zig");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const identity = @import("identity.zig");

const IoCounters = struct {
    image: *host.File,
    read_calls: u64 = 0,
    write_calls: u64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    fn read(ctx: *anyopaque, offset: u64, output: []u8) platform.Error!void {
        const self: *IoCounters = @ptrCast(@alignCast(ctx));
        try host.File.read(self.image, offset, output);
        self.read_calls += 1;
        self.read_bytes += output.len;
    }
    fn write(ctx: *anyopaque, offset: u64, data: []const u8) platform.Error!void {
        const self: *IoCounters = @ptrCast(@alignCast(ctx));
        try host.File.write(self.image, offset, data);
        self.write_calls += 1;
        self.write_bytes += data.len;
    }
    fn flush(ctx: *anyopaque) platform.Error!void {
        const self: *IoCounters = @ptrCast(@alignCast(ctx));
        try host.File.flush(self.image);
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingImage;
    const mode = args.next() orelse return error.MissingMode;
    const profile_arg = args.next() orelse return error.MissingProfile;
    const ack = args.next() orelse return error.MissingImageOnlyAcknowledgment;
    const workspace_arg = args.next() orelse return error.MissingWorkspace;
    const workspace = args.next() orelse return error.MissingWorkspace;
    if (args.next() != null or !std.mem.eql(u8, ack, "--image-only") or !std.mem.eql(u8, workspace_arg, "--workspace")) return error.InvalidArgument;
    try host.validateAbsolute(workspace);
    const root_real = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
    defer init.gpa.free(root_real);
    var root_len = root_real.len;
    while (root_len > 0 and (root_real[root_len - 1] == '/' or root_real[root_len - 1] == '\\')) root_len -= 1;
    if (root_len < 3) return error.InvalidArgument;
    const real = try host.ownedPath(init.io, init.gpa, root_real[0..root_len], path);
    defer init.gpa.free(real);
    if (!std.mem.endsWith(u8, real, ".raw")) return error.InvalidArgument;
    const kind = std.meta.stringToEnum(partitions.Kind, mode) orelse return error.InvalidArgument;
    const profile = std.meta.stringToEnum(scale.Profile, profile_arg) orelse return error.InvalidArgument;
    var entropy: [64]u8 = undefined;
    try init.io.randomSecure(&entropy);
    const ids = try identity.Identifiers.fromEntropy(entropy);
    var image = try host.open(init.io, real, true);
    defer image.file.close(init.io);
    if (image.size < 128 * 1024 * 1024 or image.size > 256 * 1024 * 1024 * 1024 or image.size % 512 != 0) return error.InvalidArgument;
    var counters: IoCounters = .{ .image = &image };
    const disk: platform.Disk = .{ .context = &counters, .sectors = image.size / 512, .read_fn = IoCounters.read, .write_fn = IoCounters.write, .flush_fn = IoCounters.flush };
    var tracker: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = 14 * 1024 * 1024 };
    var output: host.Output = .{ .io = init.io };
    std.debug.print("ENTROPY source=host-os-csprng bytes=64 no-fallback\n", .{});
    scale.run(disk, kind, ids, &tracker, profile, .{ .context = &output, .write_fn = host.Output.write, .clock_fn = host.Output.clock }) catch |err| {
        std.debug.print("USOSPREP SCALE ERROR {s} alloc_current={d} alloc_peak={d}\n", .{ @errorName(err), tracker.current, tracker.peak });
        return 1;
    };
    if (tracker.current != 0) return error.AllocationLeak;
    std.debug.print("IO read_calls={d} write_calls={d} read_bytes={d} write_bytes={d}\n", .{ counters.read_calls, counters.write_calls, counters.read_bytes, counters.write_bytes });
    std.debug.print("HOST SCALE complete profile={s} current={d} peak={d}\n", .{ @tagName(profile), tracker.current, tracker.peak });
    return 0;
}
