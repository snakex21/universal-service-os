//! WIM TAG_XATTRS -> on-disk NTFS EA layout (not the query API buffer).
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Format references: public wimlib v1.14.5 xattr.h (Eric Biggers and
//! contributors, LGPL-2.1-or-later), public NTFS-3G layout.h (GPL-2.0-or-later).
const std = @import("std");
fn get(comptime T: type, b: []const u8, at: usize) T { return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little); }
fn sizeWim(raw: []const u8) !usize {
    if (raw.len < 6) return error.CorruptExtendedAttributes;
    const count = 5 + @as(usize, raw[2]) + get(u16, raw, 0);
    if (raw[2] == 0 or raw[3] & ~@as(u8, 0x80) != 0 or count > raw.len or raw[4 + @as(usize, raw[2])] != 0 or std.mem.indexOfScalar(u8, raw[4..][0..raw[2]], 0) != null) return error.CorruptExtendedAttributes;
    return count;
}
pub const Info = struct { packed_size: u16, needed: u16, unpacked_size: u32 };
pub fn validateNative(raw: []const u8) !Info {
    if (raw.len == 0 or raw.len > 65536) return error.UnsupportedExtendedAttributes;
    var at: usize = 0;
    var packed_size: usize = 0;
    var needed: usize = 0;
    while (true) {
        if (at > raw.len or raw.len - at < 9) return error.CorruptExtendedAttributes;
        const size = 9 + @as(usize, raw[at + 5]) + get(u16, raw, at + 6);
        if (raw[at + 5] == 0 or raw[at + 4] & ~@as(u8, 0x80) != 0 or size > raw.len - at or raw[at + 8 + @as(usize, raw[at + 5])] != 0 or std.mem.indexOfScalar(u8, raw[at + 8 ..][0..raw[at + 5]], 0) != null) return error.CorruptExtendedAttributes;
        packed_size += size - 4;
        needed += @intFromBool(raw[at + 4] & 0x80 != 0);
        const next = get(u32, raw, at);
        // Unlike FILE_FULL_EA_INFORMATION returned by Windows, the final
        // on-disk entry keeps its aligned, nonzero next offset (NTFS-3G ea.c).
        if (next % 4 != 0 or next < size or next - size > 3 or next > raw.len - at) return error.CorruptExtendedAttributes;
        if (!std.mem.allEqual(u8, raw[at + size .. at + next], 0)) return error.CorruptExtendedAttributes;
        at += next;
        if (at == raw.len) break;
    }
    if (packed_size > 65535 or needed > 65535) return error.UnsupportedExtendedAttributes;
    return .{ .packed_size = @intCast(packed_size), .needed = @intCast(needed), .unpacked_size = @intCast(raw.len) };
}
pub fn fromWim(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or raw.len > 65535) return error.UnsupportedExtendedAttributes;
    var at: usize = 0;
    var size: usize = 0;
    while (at < raw.len) {
        const n = try sizeWim(raw[at..]);
        at += n;
        size += std.mem.alignForward(usize, n + 4, 4);
        if (size > 65536) return error.UnsupportedExtendedAttributes;
    }
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    @memset(out, 0);
    at = 0;
    var pos: usize = 0;
    while (at < raw.len) {
        const n = try sizeWim(raw[at..]);
        const step = std.mem.alignForward(usize, n + 4, 4);
        std.mem.writeInt(u32, out[pos..][0..4], @intCast(step), .little);
        out[pos + 4] = raw[at + 3];out[pos + 5] = raw[at + 2];
        std.mem.writeInt(u16, out[pos + 6 ..][0..2], get(u16, raw, at), .little);
        @memcpy(out[pos + 8 ..][0 .. n - 4], raw[at + 4 ..][0 .. n - 4]);
        pos += step;at += n;
    }
    _ = try validateNative(out);
    return out;
}
test "EA conversion preserves names binary values flags and packed_size sizes" {
    const source = [_]u8{ 3, 0, 1, 0x80, 'A', 0, 7, 0, 9, 0, 0, 1, 0, 'B', 0 };
    const out = try fromWim(std.testing.allocator, &source);
    defer std.testing.allocator.free(out);
    const info = try validateNative(out);
    try std.testing.expectEqual(@as(u16, source.len), info.packed_size);
    try std.testing.expectEqual(@as(u16, 1), info.needed);
    try std.testing.expectEqual(@as(u32, 28), info.unpacked_size);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 9 }, out[10..13]);
    try std.testing.expectEqual(@as(u32, 16), get(u32, out, 0));
    try std.testing.expectEqual(@as(u32, 12), get(u32, out, 16));
}
test "EA conversion refuses corrupt terminators flags and native continuation" {
    const invalid = [_]u8{ 0, 0, 1, 0, 'A', 1 };
    try std.testing.expectError(error.CorruptExtendedAttributes, fromWim(std.testing.allocator, &invalid));
    var native = [_]u8{ 0, 0, 0, 0, 0x81, 1, 0, 0, 'A', 0 };
    try std.testing.expectError(error.CorruptExtendedAttributes, validateNative(&native));
    native[4] = 0;native[0] = 8;
    try std.testing.expectError(error.CorruptExtendedAttributes, validateNative(&native));
}
