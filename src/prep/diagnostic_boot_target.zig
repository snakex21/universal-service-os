//! ESP-only capability for the separate, pinned QEMU diagnostic.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std=@import("std");
const p=@import("platform.zig");
const identity=@import("diagnostic_boot_disk.zig");
pub const EspOnly=struct {
    backing:p.Disk,
    pub fn init(backing:p.Disk,a:std.mem.Allocator)!EspOnly {
        try identity.validate(backing,a);
        return .{.backing=backing};
    }
    pub fn disk(self:*EspOnly)p.Disk {
        return .{.context=self,.sector_bytes=self.backing.sector_bytes,.sectors=self.backing.sectors,.read_fn=read,.write_fn=write,.flush_fn=flush};
    }
    fn read(ctx:*anyopaque,at:u64,out:[]u8)p.Error!void {const self:*EspOnly=@ptrCast(@alignCast(ctx));try self.backing.read(at,out);}
    fn write(ctx:*anyopaque,at:u64,data:[]const u8)p.Error!void {
        const self:*EspOnly=@ptrCast(@alignCast(ctx));
        const end=identity.esp.start_bytes+identity.esp.size_bytes;
        if(at<identity.esp.start_bytes or at>end or data.len>end-at)return error.Bounds;
        try self.backing.write(at,data);
    }
    fn flush(ctx:*anyopaque)p.Error!void {const self:*EspOnly=@ptrCast(@alignCast(ctx));try self.backing.flush();}
};
