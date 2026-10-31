//! Read-only ISO-on-NTFS adapter; no writable Disk or NTFS writer needed.
//! SPDX-License-Identifier: GPL-3.0-or-later
const ntfs = @import("ntfs_ro");
const o = @import("optical.zig");
const p = @import("platform.zig");
const std = @import("std");
pub const Source = struct {
    input: o.Input,
    fs: ntfs.FileSystem,
    file: ntfs.LargeFile,
    last_error: ?anyerror = null,
    pub fn open(input: o.Input, start: u64, bytes: u64, path: []const []const u16, allocator: std.mem.Allocator) !Source {
        var result: Source = undefined;
        try openInto(input,start,bytes,path,allocator,&result);
        return result;
    }
    pub fn openInto(input: o.Input, start: u64, bytes: u64, path: []const []const u16, allocator: std.mem.Allocator, out: *Source) !void {
        out.* = .{ .input = input, .fs = undefined, .file = undefined };
        // The mount/open calls are synchronous; subsequent reads use the
        // retained input and resolved runlist, without storing this temporary.
        out.fs = try ntfs.mountAllocated(.{ .context = &out.input, .read_fn = readDisk },.{ .start_bytes = start, .size_bytes = bytes }, allocator);
        errdefer out.fs.deinit();
        try ntfs.openLargeFile(&out.fs,.{ .context = &out.input, .read_fn = readDisk },path,allocator,&out.file);
    }
    pub fn deinit(self: *Source) void { self.file.deinit(); self.fs.deinit(); }
    fn readDisk(ctx: *anyopaque, offset: u64, out: []u8) error{Io,OutOfBounds}!void {
        const input: *o.Input = @ptrCast(@alignCast(ctx));
        input.read(offset,out) catch return error.Io;
    }
    fn readFile(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Source = @ptrCast(@alignCast(ctx));
        self.file.readAt(&self.fs,.{ .context = &self.input, .read_fn = readDisk },offset,out) catch |err| {
            self.last_error = err;
            return if (err == error.Io) error.Io else if (err == error.OutOfBounds) error.Bounds else error.Corrupt;
        };
    }
    pub fn reader(self: *Source) o.Input { return .{ .context = self, .size = self.file.size(), .read_fn = readFile }; }
};
