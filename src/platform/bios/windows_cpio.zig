const std = @import("std");

pub const Error = error{ArchiveTooLarge, InvalidArchiveName, ArchiveBufferTooSmall};

pub fn entrySize(name: []const u8, size: u32) Error!u32 {
    if (name.len == 0 or name.len > 255 or std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidArchiveName;
    const total = @as(u64, 110) + name.len + 1 + 3 + size + 3;
    if (total > std.math.maxInt(u32)) return error.ArchiveTooLarge;
    return std.mem.alignForward(u32, @as(u32, @intCast(111 + name.len)), 4) + std.mem.alignForward(u32, size, 4);
}

pub const Writer = struct {
    bytes: []u8,
    position: usize = 0,
    inode: u32 = 1,

    pub fn reserve(self: *Writer, name: []const u8, size: u32) Error![]u8 {
        const total = try entrySize(name, size);
        if (self.position > self.bytes.len or total > self.bytes.len - self.position) return error.ArchiveBufferTooSmall;
        const entry = self.bytes[self.position..][0..total];
        const data_start = std.mem.alignForward(usize, 111 + name.len, 4);
        @memset(entry[0..data_start], 0);
        @memset(entry[data_start + size..], 0);
        @memcpy(entry[0..6], "070701");
        const fields = [_]u32{ self.inode, 0x81a4, 0, 0, 1, 0, size, 0, 0, 0, 0, @intCast(name.len + 1), 0 };
        for (fields, 0..) |field, i| hex(entry[6 + 8 * i..][0..8], field);
        @memcpy(entry[110..][0..name.len], name);
        self.position += total;
        self.inode +%= 1;
        return entry[data_start..][0..size];
    }

    pub fn add(self: *Writer, name: []const u8, bytes: []const u8) Error!void {
        if (bytes.len > std.math.maxInt(u32)) return error.ArchiveTooLarge;
        @memcpy(try self.reserve(name, @intCast(bytes.len)), bytes);
    }

    pub fn finish(self: *Writer) Error!void {
        _ = try self.reserve("TRAILER!!!", 0);
    }
};

fn hex(out: []u8, number: u32) void {
    const digits = "0123456789abcdef";
    for (0..8) |i| out[i] = digits[(number >> @as(u5, @intCast((7 - i) * 4))) & 15];
}

test "CPIO packs exact file contents and pads each header and body" {
    var bytes: [512]u8 = undefined;
    var writer = Writer{ .bytes = &bytes };
    try writer.add("boot.wim", "abcde");
    try std.testing.expectEqualStrings("070701", bytes[0..6]);
    try std.testing.expectEqualStrings("00000005", bytes[54..62]);
    try std.testing.expectEqualStrings("boot.wim\x00\x00", bytes[110..120]);
    try std.testing.expectEqualStrings("abcde\x00\x00\x00", bytes[120..128]);
    try writer.finish();
    try std.testing.expectEqualStrings("TRAILER!!!\x00", bytes[238..249]);
    try std.testing.expectEqual(@as(usize, 252), writer.position);
}

test "CPIO rejects overflow, path names and short buffers before writing" {
    var bytes = [_]u8{0xaa} ** 120;
    var writer = Writer{ .bytes = &bytes };
    try std.testing.expectError(error.ArchiveBufferTooSmall, writer.add("boot.wim", "abc"));
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectError(error.InvalidArchiveName, entrySize("../boot.wim", 1));
    try std.testing.expectError(error.ArchiveTooLarge, entrySize("boot.wim", 0xffffffff));
}
