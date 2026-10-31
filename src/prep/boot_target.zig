//! Storage capability for the separate UEFI boot client: ESP writes only.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
pub const EspOnly = struct {
    backing: p.Disk,
    first: u64,
    end: u64,
    pub fn init(backing: p.Disk, prepared: wl.Layout) !EspOnly {
        if (prepared.mode != .uefi or !std.meta.eql(prepared, try wl.plan(backing, .uefi))) return error.BootDiskIdentityMismatch;
        const part = prepared.esp orelse return error.BootDiskIdentityMismatch;
        return .{ .backing = backing, .first = part.start_bytes, .end = std.math.add(u64, part.start_bytes, part.size_bytes) catch return error.Bounds };
    }
    pub fn disk(self: *EspOnly) p.Disk {
        return .{ .context = self, .sector_bytes = self.backing.sector_bytes, .sectors = self.backing.sectors, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *EspOnly = @ptrCast(@alignCast(ctx));
        try self.backing.read(at, out);
    }
    fn write(ctx: *anyopaque, at: u64, data: []const u8) p.Error!void {
        const self: *EspOnly = @ptrCast(@alignCast(ctx));
        if (at < self.first or at > self.end or data.len > self.end - at) return error.Bounds;
        try self.backing.write(at, data);
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *EspOnly = @ptrCast(@alignCast(ctx));
        try self.backing.flush();
    }
};
