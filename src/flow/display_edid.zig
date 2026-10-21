//! EDID preferred timing (VESA E-EDID 1.3 / 1.4 base block): the first
//! detailed timing descriptor at offset 54 is the monitor's native mode.
//! Pure; shared by the UEFI menu's prep-time reader
//! (src/platform/uefi/display_native.zig) and mirrored for the Windows
//! tools by tools/display_edid.h (same rules, docs/display-policy.md).
const std = @import("std");

pub const Size = struct { width: u16, height: u16 };

const header = [8]u8{ 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0 };

/// The native size, or null for a missing / invalid block or a descriptor
/// that is not a timing. Bounds as tools/display_policy.h (320x200..8192).
pub fn native(edid: []const u8) ?Size {
    if (edid.len < 128) return null;
    if (!std.mem.eql(u8, edid[0..8], &header)) return null;
    var sum: u8 = 0;
    for (edid[0..128]) |b| sum +%= b;
    if (sum != 0) return null;
    if (edid[54] == 0 and edid[55] == 0) return null;
    const w: u32 = @as(u32, edid[56]) | (@as(u32, edid[58] & 0xF0) << 4);
    var h: u32 = @as(u32, edid[59]) | (@as(u32, edid[61] & 0xF0) << 4);
    if (edid[71] & 0x80 != 0) h *= 2;
    if (w < 320 or h < 200 or w > 8192 or h > 8192) return null;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// \EFI\USOS\display-native.txt: one line "WxH\r\n" (tools/display_profile.sh
/// usos_display_native reads it into DISPLAY.TXT as native=WxH).
pub fn record(size: Size, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}x{d}\r\n", .{ size.width, size.height });
}

pub const record_path = "\\EFI\\USOS\\display-native.txt";

fn sample(w: u16, h: u16) [128]u8 {
    var e: [128]u8 = @splat(0);
    @memcpy(e[0..8], &header);
    e[54] = 0x56;
    e[55] = 0x5E;
    e[56] = @truncate(w);
    e[58] = @as(u8, @truncate(w >> 8)) << 4;
    e[59] = @truncate(h);
    e[61] = @as(u8, @truncate(h >> 8)) << 4;
    var sum: u8 = 0;
    for (e[0..127]) |b| sum +%= b;
    e[127] = 0 -% sum;
    return e;
}

test "edid: preferred timing of 1080p, 1440p and 4K monitors" {
    for ([_]Size{ .{ .width = 1920, .height = 1080 }, .{ .width = 2560, .height = 1440 }, .{ .width = 3840, .height = 2160 } }) |s| {
        const e = sample(s.width, s.height);
        try std.testing.expectEqual(s, native(&e).?);
    }
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2560x1440\r\n", try record(.{ .width = 2560, .height = 1440 }, &buffer));
}

test "edid: invalid blocks give no native size" {
    var e = sample(1920, 1080);
    try std.testing.expect(native(e[0..127]) == null);
    e[127] +%= 1;
    try std.testing.expect(native(&e) == null);
    e = sample(1920, 1080);
    e[0] = 1;
    try std.testing.expect(native(&e) == null);
    e = sample(100, 100);
    try std.testing.expect(native(&e) == null);
    e = sample(1920, 1080);
    e[54] = 0;
    e[55] = 0;
    e[127] +%= 0x56 +% 0x5E;
    try std.testing.expect(native(&e) == null);
}
