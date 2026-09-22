const framebuffer = @import("framebuffer.zig");
const Surface = @import("surface.zig").Surface;

pub const ScreenBuffer = struct {
    surface: Surface,
    byte_len: usize,

    pub fn requiredBytes(width: u32, height: u32) ?usize {
        const pixels = @mulWithOverflow(@as(usize, width), @as(usize, height));
        if (pixels[1] != 0) return null;
        const bytes = @mulWithOverflow(pixels[0], @sizeOf(u32));
        if (bytes[1] != 0) return null;
        return bytes[0];
    }

    pub fn init(address: usize, available_bytes: usize, width: u32, height: u32, pixel_format: framebuffer.PixelFormat) ?ScreenBuffer {
        if (address == 0 or width == 0 or height == 0 or pixel_format == .bit_mask) return null;
        const needed = requiredBytes(width, height) orelse return null;
        if (available_bytes < needed) return null;
        const info = framebuffer.Framebuffer{
            .address = address,
            .size = needed,
            .width = width,
            .height = height,
            .pixels_per_scan_line = width,
            .pixel_format = pixel_format,
        };
        const surface = Surface.init(info) orelse return null;
        return .{ .surface = surface, .byte_len = needed };
    }

    pub fn copyTo(self: ScreenBuffer, destination: Surface) void {
        const width = @min(self.surface.framebuffer.width, destination.framebuffer.width);
        const height = @min(self.surface.framebuffer.height, destination.framebuffer.height);
        const same_format = self.surface.framebuffer.pixel_format == destination.framebuffer.pixel_format;
        if (same_format) {
            const source: [*]const u32 = @ptrFromInt(self.surface.framebuffer.address);
            const target: [*]u32 = @ptrFromInt(destination.framebuffer.address);
            const source_stride: usize = self.surface.framebuffer.pixels_per_scan_line;
            const target_stride: usize = destination.framebuffer.pixels_per_scan_line;
            const row_len: usize = @intCast(width);
            const height_rows: usize = @intCast(height);
            if (source_stride == row_len and target_stride == row_len) {
                const pixel_count = row_len * height_rows;
                @memcpy(target[0..pixel_count], source[0..pixel_count]);
                return;
            }
            var y: usize = 0;
            while (y < height_rows) : (y += 1) {
                @memcpy(target[y * target_stride ..][0..row_len], source[y * source_stride ..][0..row_len]);
            }
            return;
        }

        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                destination.setRawPixel(x, y, swapRedBlue(self.surface.getRawPixel(x, y)));
            }
        }
    }

    fn swapRedBlue(value: u32) u32 {
        return (value & 0xff00ff00) | ((value & 0x000000ff) << 16) | ((value & 0x00ff0000) >> 16);
    }
};

test "screen buffer byte count is width times height times four" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?usize, 1280 * 800 * 4), ScreenBuffer.requiredBytes(1280, 800));
}

test "screen buffer rejects storage that is too small" {
    var pixels: [4]u32 = .{ 0, 0, 0, 0 };
    const address = @intFromPtr(&pixels);
    try @import("std").testing.expect(ScreenBuffer.init(address, 4, 2, 2, .bgrx8) == null);
}

test "screen buffer presents a complete contiguous frame" {
    const std = @import("std");
    var source_pixels = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var target_pixels = [_]u32{0} ** 6;
    const source = ScreenBuffer.init(@intFromPtr(&source_pixels), @sizeOf(@TypeOf(source_pixels)), 3, 2, .bgrx8).?;
    const destination = Surface.init(.{
        .address = @intFromPtr(&target_pixels),
        .size = @sizeOf(@TypeOf(target_pixels)),
        .width = 3,
        .height = 2,
        .pixels_per_scan_line = 3,
        .pixel_format = .bgrx8,
    }).?;
    source.copyTo(destination);
    try std.testing.expectEqualSlices(u32, &source_pixels, &target_pixels);
}
