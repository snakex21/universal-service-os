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


// GOP mode choice for UEFI paths that must set one mode for an OS without
// its own GPU driver (Win7 x64 UefiSeven: tools/windows7_native_mode.zig).
// Same policy as USOSRES: the EDID native size, else the largest usable mode.

/// One GOP mode as the caller saw it through QueryMode.
pub const Candidate = struct {
    width: u32,
    height: u32,
    /// 32 bpp RGB/BGR (PixelRedGreenBlueReserved8BitPerColor or
    /// PixelBlueGreenRedReserved8BitPerColor) and any caller-specific limit.
    usable: bool,
};

pub const Reason = enum {
    /// The GOP mode with the EDID preferred timing's size.
    edid_native,
    /// No EDID (or an invalid one): the largest usable mode.
    largest_no_edid,
    /// EDID present, but no usable mode with its size: the largest usable mode.
    largest_no_match,
};

pub const Pick = struct {
    index: usize,
    reason: Reason,
};

/// Index of the mode to use, or null when no candidate is usable.
pub fn pickMode(candidates: []const Candidate, preferred: ?Size) ?Pick {
    if (preferred) |want| {
        for (candidates, 0..) |c, i| {
            if (c.usable and c.width == @as(u32, want.width) and c.height == @as(u32, want.height)) return .{ .index = i, .reason = .edid_native };
        }
    }
    var best: ?usize = null;
    for (candidates, 0..) |c, i| {
        if (!c.usable) continue;
        if (best) |b| {
            const cur = candidates[b];
            const area = @as(u64, c.width) * c.height;
            const cur_area = @as(u64, cur.width) * cur.height;
            if (area > cur_area or (area == cur_area and c.width > cur.width)) best = i;
        } else best = i;
    }
    const index = best orelse return null;
    return .{ .index = index, .reason = if (preferred == null) .largest_no_edid else .largest_no_match };
}

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

test "pick: EDID native, then largest" {
    const modes = [_]Candidate{
        .{ .width = 640, .height = 480, .usable = true },
        .{ .width = 1024, .height = 768, .usable = true },
        .{ .width = 1920, .height = 1080, .usable = true },
        .{ .width = 2560, .height = 1600, .usable = true },
        .{ .width = 3840, .height = 2160, .usable = false },
    };
    try std.testing.expectEqual(Pick{ .index = 2, .reason = .edid_native }, pickMode(&modes, Size{ .width = 1920, .height = 1080 }).?);
    // No cap: a 2560x1600 monitor gets 2560x1600.
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .edid_native }, pickMode(&modes, Size{ .width = 2560, .height = 1600 }).?);
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .largest_no_edid }, pickMode(&modes, null).?);
    // The 4K mode exists but is not usable (e.g. not 32 bpp): largest usable.
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .largest_no_match }, pickMode(&modes, Size{ .width = 3840, .height = 2160 }).?);
    try std.testing.expect(pickMode(&[_]Candidate{.{ .width = 800, .height = 600, .usable = false }}, null) == null);
    // Same area: the wider mode wins.
    const tie = [_]Candidate{ .{ .width = 1200, .height = 1600, .usable = true }, .{ .width = 1600, .height = 1200, .usable = true } };
    try std.testing.expectEqual(@as(usize, 1), pickMode(&tie, null).?.index);
}
