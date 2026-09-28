//! Minimal newc (SVR4, no CRC) cpio writer for the per-boot archive that is
//! appended to a distro initramfs (docs/design/linux-iso-boot.md section 3).
//! Deterministic: mtime 0, uid/gid 0, inode numbers from a counter.
//!
//! Never write a directory entry for a path that may be a symlink in the
//! distro initramfs (lib, bin, sbin, lib64): the kernel's unpacker replaces
//! an existing entry of another type. Callers only write under usos/ and the
//! single root file preseed.cfg.
const std = @import("std");

pub const Error = error{NoSpaceLeft};

pub const Writer = struct {
    out: []u8,
    len: usize = 0,
    inode: u32 = 0x5553_0000,

    pub fn directory(self: *Writer, path: []const u8) Error!void {
        try self.entry(path, 0o040755, "");
    }

    pub fn file(self: *Writer, path: []const u8, mode: u32, data: []const u8) Error!void {
        try self.entry(path, 0o100000 | (mode & 0o7777), data);
    }

    /// The trailer, then zero padding to a 4-byte boundary (the next archive
    /// appended after this one must start aligned).
    pub fn finish(self: *Writer) Error![]const u8 {
        try self.entry("TRAILER!!!", 0, "");
        try self.pad(4);
        return self.out[0..self.len];
    }

    fn entry(self: *Writer, path: []const u8, mode: u32, data: []const u8) Error!void {
        self.inode += 1;
        const nlink: u32 = if (mode & 0o170000 == 0o040000) 2 else 1;
        // No std.fmt: the i386 BIOS Core links this and pays for every byte.
        // ino mode uid gid nlink mtime filesize devmajor devminor rdevmajor rdevminor namesize check
        const fields = [13]u32{ if (mode == 0) 0 else self.inode, mode, 0, 0, nlink, 0, @intCast(data.len), 0, 0, 0, 0, @intCast(path.len + 1), 0 };
        try self.put("070701");
        for (fields) |value| {
            var hex: [8]u8 = undefined;
            for (0..8) |d| hex[d] = "0123456789abcdef"[@as(usize, @intCast((value >> @intCast(28 - d * 4)) & 0xf))];
            try self.put(&hex);
        }
        try self.put(path);
        try self.put(&.{0});
        try self.pad(4);
        try self.put(data);
        try self.pad(4);
    }

    fn put(self: *Writer, bytes: []const u8) Error!void {
        if (self.out.len - self.len < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.out[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn pad(self: *Writer, alignment: usize) Error!void {
        while (self.len % alignment != 0) try self.put(&.{0});
    }
};

/// Bytes of zero padding that bring `len` to a 4-byte boundary.
pub fn padding(len: u64) u64 {
    return (4 - len % 4) % 4;
}

test "newc archive layout: header, aligned name and data, trailer, 4-byte end" {
    var buffer: [1024]u8 = undefined;
    var writer = Writer{ .out = &buffer };
    try writer.directory("usos");
    try writer.file("usos/iso.map", 0o644, "abc");
    const archive = try writer.finish();
    try std.testing.expect(std.mem.startsWith(u8, archive, "070701"));
    try std.testing.expectEqual(@as(usize, 0), archive.len % 4);
    // second header starts 4-aligned after "usos\0" (110 + 5 -> 116)
    try std.testing.expect(std.mem.eql(u8, archive[116..122], "070701"));
    try std.testing.expect(std.mem.indexOf(u8, archive, "usos/iso.map\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "TRAILER!!!\x00") != null);
    // data "abc" is padded to 4
    const at = std.mem.indexOf(u8, archive, "abc").?;
    try std.testing.expectEqual(@as(usize, 0), at % 4);
    try std.testing.expectEqual(@as(u64, 3), padding(5));
    try std.testing.expectEqual(@as(u64, 0), padding(8));
}
