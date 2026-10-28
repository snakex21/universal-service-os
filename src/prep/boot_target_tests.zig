//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
const target = @import("boot_target.zig");
const Probe = struct {
    reads: usize = 0,
    writes: usize = 0,
    flushes: usize = 0,
    fn read(ctx: *anyopaque, _: u64, out: []u8) p.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        @memset(out, 0);
    }
    fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.writes += 1;
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.flushes += 1;
    }
};
test "UEFI boot capability permits all reads but only exact ESP write boundaries" {
    var probe: Probe = .{};
    const base: p.Disk = .{ .context = &probe, .sectors = wl.mib, .read_fn = Probe.read, .write_fn = Probe.write, .flush_fn = Probe.flush };
    const layout = try wl.plan(base, .uefi);
    var guard = try target.EspOnly.init(base, layout);
    const disk = guard.disk();
    const first = layout.esp.?.start_bytes;
    const end = first + layout.esp.?.size_bytes;
    try disk.write(first, &.{1});
    try disk.write(end - 1, &.{2});
    try disk.write(end - 2, &.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 3), probe.writes);
    try std.testing.expectError(error.Bounds, disk.write(0, &.{1}));
    try std.testing.expectError(error.Bounds, disk.write(first - 1, &.{ 1, 2 }));
    try std.testing.expectError(error.Bounds, disk.write(end - 1, &.{ 1, 2 }));
    try std.testing.expectError(error.Bounds, disk.write(end, &.{1}));
    try std.testing.expectError(error.Bounds, disk.write(layout.windows.start_bytes, &.{1}));
    try std.testing.expectError(error.Bounds, disk.write(std.math.maxInt(u64), &.{ 1, 2 }));
    try std.testing.expectEqual(@as(usize, 3), probe.writes);
    var byte: [1]u8 = undefined;
    try disk.read(0, &byte);
    try disk.read(layout.windows.start_bytes, &byte);
    try disk.flush();
    try std.testing.expectEqual(@as(usize, 2), probe.reads);
    try std.testing.expectEqual(@as(usize, 1), probe.flushes);
    var wrong = layout;
    wrong.esp.?.size_bytes += 512;
    try std.testing.expectError(error.BootDiskIdentityMismatch, target.EspOnly.init(base, wrong));
}
