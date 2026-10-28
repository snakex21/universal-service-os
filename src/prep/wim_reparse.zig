//! WIM RP_FIX for a fresh Windows volume with an explicit destination letter.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Format/flag references: public wimlib v1.14.5 inode.h/reparse.c,
//! Eric Biggers and contributors (LGPL-2.1-or-later). No C code is linked.
const std = @import("std");
fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn letter(value: u16) bool {
    return (value >= 'A' and value <= 'Z') or (value >= 'a' and value <= 'z');
}
fn pathFix(bytes: []u8, destination: u8, substitute: bool) bool {
    const drive: usize = if (substitute) 4 else 0;
    if (bytes.len < (drive + 3) * 2) return false;
    if (substitute) {
        for ([_]u16{ '\\', '?', '?', '\\' }, 0..) |expected, i|
            if (get(u16, bytes, i * 2) != expected) return false;
    }
    if (!letter(get(u16, bytes, drive * 2)) or get(u16, bytes, (drive + 1) * 2) != ':' or get(u16, bytes, (drive + 2) * 2) != '\\') return false;
    std.mem.writeInt(u16, bytes[drive * 2 ..][0..2], destination, .little);
    return true;
}
/// Hash the original WIM blob before invoking this function. RP_FIX changes
/// only the destination spelling, never the source resource/hash in the WIM.
pub const Result = enum { ignored, fixed, eligible_unmatched };
pub fn fix(raw: []u8, header_flags: u32, entry_flags: u16, destination: u8) !bool {
    return try fixDetailed(raw, header_flags, entry_flags, destination) == .fixed;
}
pub fn fixDetailed(raw: []u8, header_flags: u32, entry_flags: u16, destination: u8) !Result {
    if (destination < 'A' or destination > 'Z') return error.InvalidTargetDrive;
    if (raw.len < 16 or get(u16, raw, 4) != raw.len - 8) return error.CorruptReparseData;
    const tag = get(u32, raw, 0);
    const base: usize = switch (tag) {
        0xa0000003 => 16,
        0xa000000c => 20,
        else => return error.UnsupportedReparsePoint,
    };
    if (raw.len < base) return error.CorruptReparseData;
    var spans: [2][]u8 = undefined;
    for (0..2) |i| {
        const offset = get(u16, raw, 8 + i * 4);
        const length = get(u16, raw, 10 + i * 4);
        if ((offset | length) & 1 != 0 or offset > raw.len - base or length > raw.len - base - offset) return error.CorruptReparseData;
        spans[i] = raw[base + offset ..][0..length];
    }
    if (tag == 0xa000000c) {
        const flags = get(u32, raw, 16);
        if (flags & ~@as(u32, 1) != 0) return error.CorruptReparseData;
        if (flags & 1 != 0) return .ignored; // Relative symlink, never rooted.
    }
    if (header_flags & 0x80 == 0 or entry_flags & 1 != 0) return .ignored;
    // A NOT_FIXED/external path must never be retargeted. Require a canonical
    // DOS-rooted substitute before considering the optional printable name.
    if (!pathFix(spans[0], destination, true)) return .eligible_unmatched;
    _ = pathFix(spans[1], destination, false);
    return .fixed;
}

pub fn substituteUtf8(raw: []const u8, buffer: []u8) ![]const u8 {
    if (raw.len < 16 or get(u16, raw, 4) != raw.len - 8) return error.CorruptReparseData;
    const base: usize = switch (get(u32, raw, 0)) {
        0xa0000003 => 16,
        0xa000000c => 20,
        else => return error.UnsupportedReparsePoint,
    };
    if (raw.len < base) return error.CorruptReparseData;
    const offset = get(u16, raw, 8);
    const length = get(u16, raw, 10);
    var units: [8192]u16 = undefined;
    if ((offset | length) & 1 != 0 or length / 2 > units.len or offset > raw.len - base or length > raw.len - base - offset) return error.CorruptReparseData;
    if (buffer.len < @as(usize, length / 2) * 3) return error.ReparseTextBufferTooSmall;
    for (0..length / 2) |i| units[i] = get(u16, raw, base + offset + i * 2);
    const n = try std.unicode.utf16LeToUtf8(buffer, units[0 .. length / 2]);
    return buffer[0..n];
}

fn fixture(buffer: []u8, tag: u32) []u8 {
    @memset(buffer, 0);
    const base: usize = if (tag == 0xa000000c) 20 else 16;
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("\\??\\D:\\Users");
    const print = std.unicode.utf8ToUtf16LeStringLiteral("D:\\Users");
    const size = base + (sub.len + print.len + 2) * 2;
    const out = buffer[0..size];
    std.mem.writeInt(u32, out[0..4], tag, .little);
    std.mem.writeInt(u16, out[4..6], @intCast(size - 8), .little);
    std.mem.writeInt(u16, out[10..12], @intCast(sub.len * 2), .little);
    std.mem.writeInt(u16, out[12..14], @intCast((sub.len + 1) * 2), .little);
    std.mem.writeInt(u16, out[14..16], @intCast(print.len * 2), .little);
    for (sub, 0..) |c, i| std.mem.writeInt(u16, out[base + i * 2 ..][0..2], c, .little);
    for (print, 0..) |c, i| std.mem.writeInt(u16, out[base + (sub.len + 1 + i) * 2 ..][0..2], c, .little);
    return out;
}
test "RP_FIX rewrites both absolute names to the explicit destination" {
    var bytes: [128]u8 = undefined;
    for ([_]u32{ 0xa0000003, 0xa000000c }) |tag| {
        const raw = fixture(&bytes, tag);
        try std.testing.expect(try fix(raw, 0x80, 0, 'C'));
        const base: usize = if (tag == 0xa000000c) 20 else 16;
        try std.testing.expectEqual(@as(u16, 'C'), get(u16, raw, base + 8));
        try std.testing.expectEqual(@as(u16, 'C'), get(u16, raw, base + get(u16, raw, 12)));
    }
}
test "NOT_FIXED, missing RP_FIX and relative links preserve every byte" {
    var bytes: [128]u8 = undefined;
    var before: [128]u8 = undefined;
    for ([_]u8{ 0, 1, 2 }) |mode| {
        const raw = fixture(&bytes, 0xa000000c);
        if (mode == 2) std.mem.writeInt(u32, raw[16..20], 1, .little);
        @memcpy(before[0..raw.len], raw);
        try std.testing.expect(!try fix(raw, if (mode == 0) 0 else 0x80, if (mode == 1) 1 else 0, 'E'));
        try std.testing.expectEqualSlices(u8, before[0..raw.len], raw);
    }
}
test "malformed reparse paths and invalid destination are rejected" {
    var bytes: [128]u8 = undefined;
    const raw = fixture(&bytes, 0xa0000003);
    try std.testing.expectError(error.InvalidTargetDrive, fix(raw, 0x80, 0, '1'));
    std.mem.writeInt(u16, raw[8..10], 0xffff, .little);
    try std.testing.expectError(error.CorruptReparseData, fix(raw, 0x80, 0, 'C'));
}

test "RP_FIX eligible volume GUID and drive-less targets are counted unmatched" {
    var bytes: [256]u8 = undefined;
    for ([_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("\\??\\Volume{12345678-1234-1234-1234-123456789abc}\\Users"), std.unicode.utf8ToUtf16LeStringLiteral("\\Users") }) |target| {
        @memset(&bytes, 0);
        const raw = bytes[0 .. 16 + target.len * 2];
        std.mem.writeInt(u32, raw[0..4], 0xa0000003, .little);
        std.mem.writeInt(u16, raw[4..6], @intCast(raw.len - 8), .little);
        std.mem.writeInt(u16, raw[10..12], @intCast(target.len * 2), .little);
        for (target, 0..) |c, i| std.mem.writeInt(u16, raw[16 + i * 2 ..][0..2], c, .little);
        try std.testing.expectEqual(Result.eligible_unmatched, try fixDetailed(raw, 0x80, 0, 'C'));
        try std.testing.expectEqual(Result.ignored, try fixDetailed(raw, 0x80, 1, 'C'));
        var text: [256]u8 = undefined;
        try std.testing.expect((try substituteUtf8(raw, &text)).len != 0);
    }
}
test "reparse target logging rejects malformed input and an undersized output buffer" {
    var bytes: [128]u8 = undefined;
    const raw = fixture(&bytes, 0xa0000003);
    var text: [128]u8 = undefined;
    try std.testing.expectError(error.CorruptReparseData, substituteUtf8(raw[0..3], &text));
    try std.testing.expectError(error.ReparseTextBufferTooSmall, substituteUtf8(raw, text[0..1]));
    std.mem.writeInt(u16, raw[10..12], 3, .little);
    try std.testing.expectError(error.CorruptReparseData, substituteUtf8(raw, &text));
}
