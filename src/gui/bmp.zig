//! Minimal reader for the uncompressed Windows bitmaps firmware publishes as
//! its boot logo (ACPI BGRT image type 0): BITMAPINFOHEADER or later, 24 or
//! 32 bits per pixel, BI_RGB (or BI_BITFIELDS with the standard BGRA masks),
//! bottom-up or top-down rows. Anything else is rejected, so a malformed or
//! unexpected image simply falls back to the USOS logo.
const std = @import("std");
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;

/// Upper bound for a firmware logo (4K screen, 32 bpp).
pub const max_bytes: usize = 3840 * 2160 * 4 + 1024;

pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
    row_stride: usize,
    bottom_up: bool,

    pub fn pixel(self: Image, x: u32, y: u32) Color {
        const row = if (self.bottom_up) self.height - 1 - y else y;
        const at = @as(usize, row) * self.row_stride + @as(usize, x) * self.bytes_per_pixel;
        return .{ .r = self.pixels[at + 2], .g = self.pixels[at + 1], .b = self.pixels[at] };
    }

    /// Copies the image to (x, y); pixels outside the surface are skipped.
    pub fn draw(self: Image, surface: Surface, x: u32, y: u32) void {
        var row: u32 = 0;
        while (row < self.height and y + row < surface.framebuffer.height) : (row += 1) {
            var column: u32 = 0;
            while (column < self.width and x + column < surface.framebuffer.width) : (column += 1) {
                surface.setPixel(x + column, y + row, self.pixel(column, row));
            }
        }
    }
};

pub const Error = error{ TooShort, NotBitmap, Unsupported, Truncated };

/// Reads the header of `bytes` (at most `max_bytes` long).
pub fn parse(bytes: []const u8) Error!Image {
    if (bytes.len < 54) return error.TooShort;
    if (bytes[0] != 'B' or bytes[1] != 'M') return error.NotBitmap;
    const data_offset = std.mem.readInt(u32, bytes[10..14], .little);
    const info_size = std.mem.readInt(u32, bytes[14..18], .little);
    if (info_size < 40 or 14 + @as(u64, info_size) > bytes.len) return error.Unsupported;
    const width_raw = std.mem.readInt(i32, bytes[18..22], .little);
    const height_raw = std.mem.readInt(i32, bytes[22..26], .little);
    const planes = std.mem.readInt(u16, bytes[26..28], .little);
    const bits = std.mem.readInt(u16, bytes[28..30], .little);
    const compression = std.mem.readInt(u32, bytes[30..34], .little);
    if (planes != 1 or (bits != 24 and bits != 32)) return error.Unsupported;
    if (compression != 0) {
        // BI_BITFIELDS is accepted only with the default BGRA layout.
        if (compression != 3 or bits != 32 or info_size < 52) return error.Unsupported;
        const red = std.mem.readInt(u32, bytes[54..58], .little);
        const green = std.mem.readInt(u32, bytes[58..62], .little);
        const blue = std.mem.readInt(u32, bytes[62..66], .little);
        if (red != 0x00FF0000 or green != 0x0000FF00 or blue != 0x000000FF) return error.Unsupported;
    }
    if (width_raw <= 0 or height_raw == 0 or height_raw == std.math.minInt(i32)) return error.Unsupported;
    const width: u32 = @intCast(width_raw);
    const height: u32 = @intCast(if (height_raw < 0) -height_raw else height_raw);
    if (width > 3840 or height > 2160) return error.Unsupported;
    const bytes_per_pixel: u32 = bits / 8;
    const row_stride = ((@as(usize, width) * bytes_per_pixel) + 3) & ~@as(usize, 3);
    const needed = @as(u64, data_offset) + @as(u64, row_stride) * height;
    if (data_offset < 14 + info_size or needed > bytes.len) return error.Truncated;
    return .{
        .pixels = bytes[data_offset..@intCast(needed)],
        .width = width,
        .height = height,
        .bytes_per_pixel = bytes_per_pixel,
        .row_stride = row_stride,
        .bottom_up = height_raw > 0,
    };
}

/// Total file size declared in the header (to bound a read of a bitmap
/// whose length is not known, such as the BGRT image in memory).
pub fn declaredSize(header: []const u8) ?usize {
    if (header.len < 6 or header[0] != 'B' or header[1] != 'M') return null;
    const size = std.mem.readInt(u32, header[2..6], .little);
    if (size < 54 or size > max_bytes) return null;
    return size;
}

fn testBitmap(comptime width: u32, comptime height: u32, comptime bits: u16, top_down: bool) [54 + (((width * (bits / 8)) + 3) & ~@as(u32, 3)) * height]u8 {
    const stride = ((width * (bits / 8)) + 3) & ~@as(u32, 3);
    var out = [_]u8{0} ** (54 + stride * height);
    out[0] = 'B';
    out[1] = 'M';
    std.mem.writeInt(u32, out[2..6], out.len, .little);
    std.mem.writeInt(u32, out[10..14], 54, .little);
    std.mem.writeInt(u32, out[14..18], 40, .little);
    std.mem.writeInt(i32, out[18..22], width, .little);
    std.mem.writeInt(i32, out[22..26], if (top_down) -@as(i32, height) else height, .little);
    std.mem.writeInt(u16, out[26..28], 1, .little);
    std.mem.writeInt(u16, out[28..30], bits, .little);
    // Stored row 0 gets blue-ish pixels, the others red-ish.
    for (0..height) |row| {
        for (0..width) |column| {
            const at = 54 + row * stride + column * (bits / 8);
            out[at] = if (row == 0) 200 else 10;
            out[at + 1] = @intCast(column);
            out[at + 2] = if (row == 0) 10 else 200;
        }
    }
    return out;
}

test "bottom-up 24-bit bitmap rows are flipped" {
    const bytes = testBitmap(3, 2, 24, false);
    const image = try parse(&bytes);
    try std.testing.expectEqual(@as(u32, 3), image.width);
    try std.testing.expectEqual(@as(usize, 12), image.row_stride);
    // Stored row 0 is the bottom row of a bottom-up bitmap.
    try std.testing.expectEqual(@as(u8, 200), image.pixel(0, 1).b);
    try std.testing.expectEqual(@as(u8, 200), image.pixel(2, 0).r);
    try std.testing.expectEqual(@as(u8, 2), image.pixel(2, 0).g);
    try std.testing.expectEqual(@as(?usize, bytes.len), declaredSize(&bytes));
}

test "top-down 32-bit bitmap keeps row order" {
    const bytes = testBitmap(2, 2, 32, true);
    const image = try parse(&bytes);
    try std.testing.expect(!image.bottom_up);
    try std.testing.expectEqual(@as(u8, 200), image.pixel(1, 0).b);
}

test "truncated, compressed and paletted bitmaps are rejected" {
    var bytes = testBitmap(4, 4, 24, false);
    try std.testing.expectError(error.Truncated, parse(bytes[0 .. bytes.len - 1]));
    std.mem.writeInt(u32, bytes[30..34], 1, .little);
    try std.testing.expectError(error.Unsupported, parse(&bytes));
    std.mem.writeInt(u32, bytes[30..34], 0, .little);
    std.mem.writeInt(u16, bytes[28..30], 8, .little);
    try std.testing.expectError(error.Unsupported, parse(&bytes));
    bytes[0] = 'X';
    try std.testing.expectError(error.NotBitmap, parse(&bytes));
}
