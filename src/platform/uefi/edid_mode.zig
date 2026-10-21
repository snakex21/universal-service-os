// Monitor-native display mode selection, shared by UEFI code that has to pick
// one GOP mode for an operating system without its own GPU driver.
//
// Policy (USOS, 2026-10-21): the monitor's native resolution from EDID (the
// first detailed timing descriptor = the preferred timing, EDID 1.3+), with
// no upper cap; when there is no usable EDID or no GOP mode with that size,
// the largest mode the adapter offers. Only 32-bit direct-colour modes count
// (RGB or BGR, 8 bits per channel), since VBE/legacy consumers need a plain
// linear framebuffer.
//
// Pure code: the UEFI calls stay with the caller (see readEdid in
// tools/windows7_native_mode.zig for the EDID_ACTIVE / EDID_DISCOVERED read),
// so this file is host-tested by `zig build test`.
const std = @import("std");

pub const Resolution = struct {
    width: u32,
    height: u32,

    pub fn eql(a: Resolution, b: Resolution) bool {
        return a.width == b.width and a.height == b.height;
    }
};

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

const header = [8]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };

/// Size of the preferred timing of an EDID base block, or null when the block
/// is missing, has a bad header or checksum, or carries no detailed timing in
/// the first descriptor slot (bytes 54..71).
pub fn preferredResolution(edid: []const u8) ?Resolution {
    if (edid.len < 128) return null;
    const block = edid[0..128];
    if (!std.mem.eql(u8, block[0..8], &header)) return null;
    var sum: u8 = 0;
    for (block) |byte| sum +%= byte;
    if (sum != 0) return null;
    const d = block[54..72];
    // A pixel clock of 0 marks a display descriptor (name, range limits...),
    // not a timing.
    if (d[0] == 0 and d[1] == 0) return null;
    const width = @as(u32, d[2]) | (@as(u32, d[4] >> 4) << 8);
    var height = @as(u32, d[5]) | (@as(u32, d[7] >> 4) << 8);
    // Interlaced timings give the field height; the frame is twice that.
    if (d[17] & 0x80 != 0) height *= 2;
    if (width < 320 or height < 200) return null;
    return .{ .width = width, .height = height };
}

/// Index of the mode to use, or null when no candidate is usable.
pub fn pickMode(candidates: []const Candidate, preferred: ?Resolution) ?Pick {
    if (preferred) |want| {
        for (candidates, 0..) |c, i| {
            if (c.usable and c.width == want.width and c.height == want.height) return .{ .index = i, .reason = .edid_native };
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

fn testEdid(width: u32, height: u32, interlaced: bool) [128]u8 {
    var e = [_]u8{0} ** 128;
    @memcpy(e[0..8], &header);
    e[18] = 1;
    e[19] = 4;
    const d = e[54..72];
    d[0] = 0x02; // 148.50 MHz
    d[1] = 0x3a;
    d[2] = @truncate(width);
    d[4] = @as(u8, @truncate(width >> 8)) << 4;
    d[5] = @truncate(height);
    d[7] = @as(u8, @truncate(height >> 8)) << 4;
    if (interlaced) d[17] = 0x80;
    var sum: u8 = 0;
    for (e[0..127]) |byte| sum +%= byte;
    e[127] = 0 -% sum;
    return e;
}

test "EDID preferred timing" {
    const fhd = testEdid(1920, 1080, false);
    try std.testing.expectEqual(Resolution{ .width = 1920, .height = 1080 }, preferredResolution(&fhd).?);
    const qhd = testEdid(2560, 1440, false);
    try std.testing.expectEqual(Resolution{ .width = 2560, .height = 1440 }, preferredResolution(&qhd).?);
    const uhd = testEdid(3840, 2160, false);
    try std.testing.expectEqual(Resolution{ .width = 3840, .height = 2160 }, preferredResolution(&uhd).?);
    const interlaced = testEdid(1920, 540, true);
    try std.testing.expectEqual(Resolution{ .width = 1920, .height = 1080 }, preferredResolution(&interlaced).?);
    // Extension blocks after the base block are ignored.
    var two: [256]u8 = undefined;
    @memcpy(two[0..128], &fhd);
    @memset(two[128..], 0xaa);
    try std.testing.expectEqual(Resolution{ .width = 1920, .height = 1080 }, preferredResolution(&two).?);
}

test "EDID rejects bad blocks" {
    try std.testing.expect(preferredResolution(&[_]u8{}) == null);
    var bad = testEdid(1920, 1080, false);
    bad[127] +%= 1;
    try std.testing.expect(preferredResolution(&bad) == null);
    var no_header = testEdid(1920, 1080, false);
    no_header[0] = 1;
    no_header[127] -%= 1;
    try std.testing.expect(preferredResolution(&no_header) == null);
    var descriptor = testEdid(1920, 1080, false);
    const c0 = descriptor[54];
    const c1 = descriptor[55];
    descriptor[54] = 0;
    descriptor[55] = 0;
    descriptor[127] +%= c0 +% c1;
    try std.testing.expect(preferredResolution(&descriptor) == null);
}

test "pick: EDID native, then largest" {
    const modes = [_]Candidate{
        .{ .width = 640, .height = 480, .usable = true },
        .{ .width = 1024, .height = 768, .usable = true },
        .{ .width = 1920, .height = 1080, .usable = true },
        .{ .width = 2560, .height = 1600, .usable = true },
        .{ .width = 3840, .height = 2160, .usable = false },
    };
    try std.testing.expectEqual(Pick{ .index = 2, .reason = .edid_native }, pickMode(&modes, .{ .width = 1920, .height = 1080 }).?);
    // No cap: a 2560x1600 monitor gets 2560x1600.
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .edid_native }, pickMode(&modes, .{ .width = 2560, .height = 1600 }).?);
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .largest_no_edid }, pickMode(&modes, null).?);
    // The 4K mode exists but is not usable (e.g. not 32 bpp): largest usable.
    try std.testing.expectEqual(Pick{ .index = 3, .reason = .largest_no_match }, pickMode(&modes, .{ .width = 3840, .height = 2160 }).?);
    try std.testing.expect(pickMode(&[_]Candidate{.{ .width = 800, .height = 600, .usable = false }}, null) == null);
    // Same area: the wider mode wins.
    const tie = [_]Candidate{ .{ .width = 1200, .height = 1600, .usable = true }, .{ .width = 1600, .height = 1200, .usable = true } };
    try std.testing.expectEqual(@as(usize, 1), pickMode(&tie, null).?.index);
}
