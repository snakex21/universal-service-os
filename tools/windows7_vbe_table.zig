// UefiSeven 1.30 VBE table at 0xC0000: recognise it and retarget its single
// mode (0x00F1) to another GOP mode. Pure code on a byte window, host-tested.
//
// UefiSeven (tools/vendor/uefiseven/1.30, BSD-2-Clause) writes at C000:0000
// a VBE controller block ("VESA", 3.00, vendor "UefiSeven", mode list
// {0x00F1, 0xFFFF}) and at C000:0100 one VBE 3.0 mode block for 1024x768x32
// with the GOP framebuffer as the linear framebuffer; its handler (entry
// C000:0200) only copies these two blocks. USOS keeps the handler and the
// mode number and rewrites only the GOP-derived fields, so Windows' basic
// display driver (vgapnp.sys, XDDM over VBE) sees the native mode.
// Field offsets: VESA BIOS Extension 3.0, ModeInfoBlock / VbeInfoBlock.
const std = @import("std");

pub const window_size = 0x10000;
pub const mode_info_offset = 0x100;
pub const handler_offset = 0x200;
pub const mode_number: u16 = 0x00f1;
pub const vendor = "UefiSeven";

pub const Framebuffer = struct {
    width: u32,
    height: u32,
    /// GOP PixelsPerScanLine.
    stride_pixels: u32,
    base: u64,
    size: u64,
    /// true = PixelBlueGreenRedReserved8BitPerColor, false = RGB.
    bgr: bool,
};

pub const Current = struct {
    width: u16,
    height: u16,
    lfb: u32,
    bytes_per_line: u16,
};

fn get16(w: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, w[at..][0..2], .little);
}
fn get32(w: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, w[at..][0..4], .little);
}
fn put16(w: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, w[at..][0..2], v, .little);
}
fn put32(w: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, w[at..][0..4], v, .little);
}

/// Offset inside the window of a real-mode far pointer into segment C000.
fn nearOffset(far: u32, len: usize) ?usize {
    if (far >> 16 != 0xc000) return null;
    const off: usize = far & 0xffff;
    if (off + len > mode_info_offset) return null;
    return off;
}

/// The mode the table currently describes, when the window holds exactly
/// UefiSeven's one-mode 32 bpp table; null for anything else (a real VGA
/// BIOS, another shim, an unexpected layout).
pub fn recognize(w: []const u8) ?Current {
    if (w.len < handler_offset + 1) return null;
    if (!std.mem.eql(u8, w[0..4], "VESA")) return null;
    if (get16(w, 0x04) != 0x0300) return null;
    const oem = nearOffset(get32(w, 0x06), vendor.len) orelse return null;
    if (!std.mem.eql(u8, w[oem..][0..vendor.len], vendor)) return null;
    const list = nearOffset(get32(w, 0x0e), 4) orelse return null;
    if (get16(w, list) != mode_number or get16(w, list + 2) != 0xffff) return null;
    const m = w[mode_info_offset..][0..0x100];
    if (get16(m, 0x00) != 0x00fb) return null; // LFB-only 32 bpp graphics, as UefiSeven sets
    if (m[0x19] != 32 or m[0x1b] != 6 or m[0x18] != 1) return null;
    const cur = Current{ .width = get16(m, 0x12), .height = get16(m, 0x14), .lfb = get32(m, 0x28), .bytes_per_line = get16(m, 0x32) };
    if (cur.width == 0 or cur.height == 0 or cur.lfb == 0) return null;
    return cur;
}

pub const PatchError = error{ NotUefiSeven, FramebufferAbove4G, StrideTooLarge, TooSmall };

/// Point the table at `fb` (offset 0, no centering). The window must hold
/// UefiSeven's table (checked again here).
pub fn patch(w: []u8, fb: Framebuffer) PatchError!void {
    _ = recognize(w) orelse return error.NotUefiSeven;
    if (fb.width < 640 or fb.height < 480 or fb.stride_pixels < fb.width) return error.TooSmall;
    if (fb.width > 0xffff or fb.height > 0xffff) return error.StrideTooLarge;
    const bytes_per_line = @as(u64, fb.stride_pixels) * 4;
    if (bytes_per_line > 0xffff) return error.StrideTooLarge;
    const visible = bytes_per_line * fb.height;
    if (fb.base == 0 or fb.base + @max(visible, fb.size) > 0x1_0000_0000) return error.FramebufferAbove4G;
    const m = w[mode_info_offset..][0..0x100];
    put16(m, 0x10, @intCast(bytes_per_line));
    put16(m, 0x12, @intCast(fb.width));
    put16(m, 0x14, @intCast(fb.height));
    put32(m, 0x28, @intCast(fb.base));
    put16(m, 0x32, @intCast(bytes_per_line));
    const red: u8, const blue: u8 = if (fb.bgr) .{ 16, 0 } else .{ 0, 16 };
    // Linear colour layout (what UefiSeven fills) and the banked copy.
    m[0x37] = red;
    m[0x39] = 8;
    m[0x3b] = blue;
    m[0x3d] = 24;
    m[0x1f] = 8;
    m[0x20] = red;
    m[0x21] = 8;
    m[0x22] = 8;
    m[0x23] = 8;
    m[0x24] = blue;
    m[0x25] = 8;
    m[0x26] = 24;
    const mem = @max(visible, fb.size);
    put16(w, 0x12, @intCast(@min((mem + 0xffff) / 0x10000, 0xffff)));
}

pub const multi_count_offset = 0x3fe;
pub const multi_current_offset = 0x3fc;
pub const multi_modes_offset = 0x400;
pub const multi_vendor = "USOS VBE";
pub const max_modes = 8;

/// One mode of the USOS multi-mode table: a `width` x `height` window into
/// the framebuffer `fb` (centred; the native mode is the whole framebuffer).
pub fn windowFits(fb: Framebuffer, width: u32, height: u32) bool {
    return width <= fb.width and height <= fb.height;
}

/// Replace UefiSeven's one-mode table and handler with the USOS multi-mode
/// layout (tools/windows7_vbe_handler.S): mode 0x00F1 + i describes
/// `sizes[i]` as a centred window of the current framebuffer `fb`.
/// `handler` is the assembled code, placed at the same entry (C000:0200)
/// the IVT already points to. The window must hold UefiSeven's table.
pub fn buildMulti(w: []u8, fb: Framebuffer, sizes: []const [2]u32, handler: []const u8) PatchError!void {
    _ = recognize(w) orelse return error.NotUefiSeven;
    if (sizes.len == 0 or sizes.len > max_modes) return error.TooSmall;
    if (handler.len > multi_current_offset - handler_offset) return error.TooSmall;
    if (fb.stride_pixels < fb.width) return error.TooSmall;
    const bytes_per_line = @as(u64, fb.stride_pixels) * 4;
    if (bytes_per_line > 0xffff) return error.StrideTooLarge;
    const mem = @max(bytes_per_line * fb.height, fb.size);
    if (fb.base == 0 or fb.base + mem > 0x1_0000_0000) return error.FramebufferAbove4G;
    for (sizes) |size| {
        if (size[0] < 640 or size[1] < 480 or !windowFits(fb, size[0], size[1])) return error.TooSmall;
    }
    // Keep a copy of the mode block UefiSeven filled as the template.
    var template: [0x100]u8 = undefined;
    @memcpy(&template, w[mode_info_offset..][0..0x100]);
    @memset(w[0 .. multi_modes_offset + max_modes * 0x100], 0);
    @memcpy(w[0..4], "VESA");
    put16(w, 0x04, 0x0300);
    var at: u16 = 0x22;
    put32(w, 0x06, 0xc000_0000 | @as(u32, at));
    @memcpy(w[at..][0..multi_vendor.len], multi_vendor);
    at += multi_vendor.len + 1;
    put32(w, 0x0a, 1);
    put32(w, 0x0e, 0xc000_0000 | @as(u32, at));
    for (sizes, 0..) |_, i| {
        put16(w, at, mode_number + @as(u16, @intCast(i)));
        at += 2;
    }
    put16(w, at, 0xffff);
    put16(w, 0x12, @intCast(@min((mem + 0xffff) / 0x10000, 0xffff)));
    for (sizes, 0..) |size, i| {
        const m = w[multi_modes_offset + i * 0x100 ..][0..0x100];
        @memcpy(m, &template);
        const x = (fb.width - size[0]) / 2;
        const y = (fb.height - size[1]) / 2;
        const lfb = fb.base + (@as(u64, y) * fb.stride_pixels + x) * 4;
        writeMode(m, size[0], size[1], @intCast(bytes_per_line), @intCast(lfb), fb.bgr);
    }
    put16(w, multi_count_offset, @intCast(sizes.len));
    put16(w, multi_current_offset, 0x4000 | (mode_number + @as(u16, @intCast(sizes.len - 1))));
    @memcpy(w[handler_offset..][0..handler.len], handler);
}

fn writeMode(m: []u8, width: u32, height: u32, bytes_per_line: u16, lfb: u32, bgr: bool) void {
    put16(m, 0x00, 0x00fb);
    put16(m, 0x10, bytes_per_line);
    put16(m, 0x12, @intCast(width));
    put16(m, 0x14, @intCast(height));
    m[0x18] = 1;
    m[0x19] = 32;
    m[0x1b] = 6;
    put32(m, 0x28, lfb);
    put16(m, 0x32, bytes_per_line);
    const red: u8, const blue: u8 = if (bgr) .{ 16, 0 } else .{ 0, 16 };
    m[0x36] = 8;
    m[0x37] = red;
    m[0x38] = 8;
    m[0x39] = 8;
    m[0x3a] = 8;
    m[0x3b] = blue;
    m[0x3c] = 8;
    m[0x3d] = 24;
    m[0x1f] = 8;
    m[0x20] = red;
    m[0x21] = 8;
    m[0x22] = 8;
    m[0x23] = 8;
    m[0x24] = blue;
    m[0x25] = 8;
    m[0x26] = 24;
}

/// Mode info block of mode index `i` in the multi-mode layout.
pub fn multiMode(w: []const u8, i: usize) Current {
    const m = w[multi_modes_offset + i * 0x100 ..][0..0x100];
    return .{ .width = get16(m, 0x12), .height = get16(m, 0x14), .lfb = get32(m, 0x28), .bytes_per_line = get16(m, 0x32) };
}

test "multi-mode table: 1024x768 window plus native" {
    var w = [_]u8{0} ** window_size;
    fillLikeUefiSeven(&w, .{ .width = 1024, .height = 768, .stride_pixels = 1024, .base = 0xe000_0000, .size = 1024 * 768 * 4, .bgr = true });
    const fb = Framebuffer{ .width = 1920, .height = 1080, .stride_pixels = 1920, .base = 0xe000_0000, .size = 1920 * 1080 * 4, .bgr = true };
    const code = [_]u8{ 0x3d, 0x00, 0x4f, 0xcf };
    try buildMulti(&w, fb, &.{ .{ 1024, 768 }, .{ 1920, 1080 } }, &code);
    try std.testing.expectEqualSlices(u8, "VESA", w[0..4]);
    const list = get32(&w, 0x0e) & 0xffff;
    try std.testing.expectEqual(@as(u16, 0x00f1), get16(&w, list));
    try std.testing.expectEqual(@as(u16, 0x00f2), get16(&w, list + 2));
    try std.testing.expectEqual(@as(u16, 0xffff), get16(&w, list + 4));
    try std.testing.expectEqual(@as(u16, 2), get16(&w, multi_count_offset));
    try std.testing.expectEqual(@as(u16, 0x40f2), get16(&w, multi_current_offset));
    const small = multiMode(&w, 0);
    try std.testing.expectEqual(@as(u16, 1024), small.width);
    try std.testing.expectEqual(@as(u32, 0xe000_0000 + (156 * 1920 + 448) * 4), small.lfb);
    try std.testing.expectEqual(@as(u16, 7680), small.bytes_per_line);
    const native = multiMode(&w, 1);
    try std.testing.expectEqual(@as(u16, 1920), native.width);
    try std.testing.expectEqual(@as(u32, 0xe000_0000), native.lfb);
    try std.testing.expectEqualSlices(u8, &code, w[handler_offset..][0..code.len]);
    // Not UefiSeven's table any more: a second build is refused.
    try std.testing.expectError(error.NotUefiSeven, buildMulti(&w, fb, &.{.{ 1920, 1080 }}, &code));
}

/// Test helper and documentation of the layout UefiSeven 1.30 writes
/// (ShimVesaInformation in UefiSeven.c) for a 1024x768 GOP mode.
pub fn fillLikeUefiSeven(w: []u8, fb: Framebuffer) void {
    @memset(w, 0);
    @memcpy(w[0..4], "VESA");
    put16(w, 0x04, 0x0300);
    var at: u16 = 0x22;
    put32(w, 0x06, 0xc000_0000 | @as(u32, at));
    @memcpy(w[at..][0..vendor.len], vendor);
    at += vendor.len + 1;
    put32(w, 0x0a, 1);
    put32(w, 0x0e, 0xc000_0000 | @as(u32, at));
    put16(w, at, mode_number);
    put16(w, at + 2, 0xffff);
    put16(w, 0x12, @intCast((fb.size + 0xffff) / 0x10000));
    const m = w[mode_info_offset..][0..0x100];
    put16(m, 0x00, 0x00fb);
    put16(m, 0x12, 1024);
    put16(m, 0x14, 768);
    m[0x16] = 8;
    m[0x17] = 16;
    m[0x18] = 1;
    m[0x19] = 32;
    m[0x1a] = 1;
    m[0x1b] = 6;
    m[0x1e] = 1;
    put32(m, 0x28, @intCast(fb.base));
    put16(m, 0x32, @intCast(fb.stride_pixels * 4));
    m[0x36] = 8;
    m[0x37] = 16;
    m[0x38] = 8;
    m[0x39] = 8;
    m[0x3a] = 8;
    m[0x3b] = 0;
    m[0x3c] = 8;
    m[0x3d] = 24;
    @memset(w[handler_offset..][0..16], 0x90);
}

test "recognise and retarget the UefiSeven table" {
    var w = [_]u8{0} ** window_size;
    const old = Framebuffer{ .width = 1024, .height = 768, .stride_pixels = 1024, .base = 0xe000_0000, .size = 1024 * 768 * 4, .bgr = true };
    fillLikeUefiSeven(&w, old);
    const cur = recognize(&w).?;
    try std.testing.expectEqual(@as(u16, 1024), cur.width);
    try std.testing.expectEqual(@as(u32, 0xe000_0000), cur.lfb);
    const handler_before = w[handler_offset..][0..16].*;
    try patch(&w, .{ .width = 1920, .height = 1080, .stride_pixels = 1920, .base = 0xe000_0000, .size = 1920 * 1080 * 4, .bgr = true });
    const now = recognize(&w).?;
    try std.testing.expectEqual(@as(u16, 1920), now.width);
    try std.testing.expectEqual(@as(u16, 1080), now.height);
    try std.testing.expectEqual(@as(u16, 7680), now.bytes_per_line);
    try std.testing.expectEqual(@as(u16, 7680), get16(&w, mode_info_offset + 0x10));
    try std.testing.expectEqual(@as(u16, 127), get16(&w, 0x12)); // 8 294 400 bytes
    try std.testing.expectEqual(handler_before, w[handler_offset..][0..16].*);
    // Padded stride, RGB order.
    try patch(&w, .{ .width = 2560, .height = 1440, .stride_pixels = 2560 + 64, .base = 0xd000_0000, .size = 16 << 20, .bgr = false });
    try std.testing.expectEqual(@as(u16, 2624 * 4), recognize(&w).?.bytes_per_line);
    try std.testing.expectEqual(@as(u8, 0), w[mode_info_offset + 0x37]);
    try std.testing.expectEqual(@as(u8, 16), w[mode_info_offset + 0x3b]);
    try std.testing.expectEqual(@as(u16, 256), get16(&w, 0x12));
}

test "refuse what the shim cannot describe" {
    var w = [_]u8{0} ** window_size;
    try std.testing.expect(recognize(&w) == null);
    try std.testing.expectError(error.NotUefiSeven, patch(&w, .{ .width = 1920, .height = 1080, .stride_pixels = 1920, .base = 0xe000_0000, .size = 0, .bgr = true }));
    const fb = Framebuffer{ .width = 1024, .height = 768, .stride_pixels = 1024, .base = 0xe000_0000, .size = 1024 * 768 * 4, .bgr = true };
    fillLikeUefiSeven(&w, fb);
    try std.testing.expectError(error.FramebufferAbove4G, patch(&w, .{ .width = 1920, .height = 1080, .stride_pixels = 1920, .base = 0x8_0000_0000, .size = 1920 * 1080 * 4, .bgr = true }));
    try std.testing.expectError(error.StrideTooLarge, patch(&w, .{ .width = 16384, .height = 1024, .stride_pixels = 16384, .base = 0x8000_0000, .size = 16384 * 1024 * 4, .bgr = true }));
    // A real VGA BIOS table (other vendor string) is left alone.
    var bios = w;
    @memcpy(bios[0x22..][0..vendor.len], "ATOMBIOS!");
    try std.testing.expect(recognize(&bios) == null);
    // A table with more than one mode is not UefiSeven's.
    var two = w;
    const list = get32(&w, 0x0e) & 0xffff;
    put16(&two, list + 2, 0x0101);
    try std.testing.expect(recognize(&two) == null);
}
