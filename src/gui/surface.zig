const framebuffer_types = @import("framebuffer.zig");
const BootFramebuffer = framebuffer_types.Framebuffer;
const PixelFormat = framebuffer_types.PixelFormat;
const Color = @import("color.zig").Color;

pub const Surface = struct {
    framebuffer: BootFramebuffer,

    pub fn init(framebuffer: BootFramebuffer) ?Surface {
        if (framebuffer.pixel_format == .bit_mask) return null;
        if (framebuffer.address == 0 or framebuffer.width == 0 or framebuffer.height == 0) return null;
        if (@bitSizeOf(usize) == 32 and framebuffer.address > 0xFFFFFFFF) return null;
        return .{ .framebuffer = framebuffer };
    }

    pub fn fill(self: Surface, color: Color) void {
        self.fillRect(0, 0, self.framebuffer.width, self.framebuffer.height, color);
    }

    pub fn fillRect(self: Surface, x: u32, y: u32, width: u32, height: u32, color: Color) void {
        const max_x = @min(x +| width, self.framebuffer.width);
        const max_y = @min(y +| height, self.framebuffer.height);
        if (x >= max_x or y >= max_y) return;
        const raw = pack(self.framebuffer.pixel_format, color);
        const address: usize = @intCast(self.framebuffer.address);
        const pixels: [*]volatile u32 = @ptrFromInt(address);
        var py = y;
        while (py < max_y) : (py += 1) {
            const row: usize = @as(usize, py) * self.framebuffer.pixels_per_scan_line;
            var px = x;
            while (px < max_x) : (px += 1) pixels[row + px] = raw;
        }
    }

    pub fn borderRect(self: Surface, x: u32, y: u32, width: u32, height: u32, thickness: u32, color: Color) void {
        if (width == 0 or height == 0 or thickness == 0) return;
        self.fillRect(x, y, width, thickness, color);
        self.fillRect(x, y +| (height -| thickness), width, thickness, color);
        self.fillRect(x, y, thickness, height, color);
        self.fillRect(x +| (width -| thickness), y, thickness, height, color);
    }

    pub fn setPixel(self: Surface, x: u32, y: u32, color: Color) void {
        self.setRawPixel(x, y, pack(self.framebuffer.pixel_format, color));
    }

    pub fn getPixel(self: Surface, x: u32, y: u32) Color {
        return unpack(self.framebuffer.pixel_format, self.getRawPixel(x, y));
    }

    /// Draws color with coverage alpha (0..255) over `background`, or over
    /// the pixel already on the surface when background is null.
    pub fn blendPixel(self: Surface, x: u32, y: u32, color: Color, alpha: u8, background: ?Color) void {
        if (alpha == 0 or x >= self.framebuffer.width or y >= self.framebuffer.height) return;
        if (alpha == 255) return self.setPixel(x, y, color);
        const under = background orelse self.getPixel(x, y);
        self.setPixel(x, y, mix(under, color, alpha));
    }

    pub fn packColor(self: Surface, color: Color) u32 {
        return pack(self.framebuffer.pixel_format, color);
    }

    pub fn unpackColor(self: Surface, raw: u32) Color {
        return unpack(self.framebuffer.pixel_format, raw);
    }

    pub fn getRawPixel(self: Surface, x: u32, y: u32) u32 {
        if (x >= self.framebuffer.width or y >= self.framebuffer.height) return 0;
        const index: usize = @as(usize, y) * self.framebuffer.pixels_per_scan_line + x;
        const address: usize = @intCast(self.framebuffer.address);
        const pixels: [*]volatile u32 = @ptrFromInt(address);
        return pixels[index];
    }

    pub fn setRawPixel(self: Surface, x: u32, y: u32, value: u32) void {
        if (x >= self.framebuffer.width or y >= self.framebuffer.height) return;
        const index: usize = @as(usize, y) * self.framebuffer.pixels_per_scan_line + x;
        const address: usize = @intCast(self.framebuffer.address);
        const pixels: [*]volatile u32 = @ptrFromInt(address);
        pixels[index] = value;
    }
};

/// Linear blend of `to` over `from` with alpha 0..255.
pub fn mix(from: Color, to: Color, alpha: u8) Color {
    return .{
        .r = mixChannel(from.r, to.r, alpha),
        .g = mixChannel(from.g, to.g, alpha),
        .b = mixChannel(from.b, to.b, alpha),
    };
}

fn mixChannel(from: u8, to: u8, alpha: u8) u8 {
    const a: u32 = alpha;
    return @intCast((@as(u32, from) * (255 - a) + @as(u32, to) * a + 127) / 255);
}

fn unpack(format: PixelFormat, raw: u32) Color {
    return switch (format) {
        .rgbx8 => .{ .r = @truncate(raw), .g = @truncate(raw >> 8), .b = @truncate(raw >> 16) },
        .bgrx8, .bit_mask => .{ .r = @truncate(raw >> 16), .g = @truncate(raw >> 8), .b = @truncate(raw) },
    };
}

fn pack(format: PixelFormat, color: Color) u32 {
    return switch (format) {
        .rgbx8 => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16),
        .bgrx8 => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16),
        .bit_mask => 0,
    };
}

test "pixel packing follows framebuffer format" {
    const std = @import("std");
    const color = Color{ .r = 0x11, .g = 0x22, .b = 0x33 };
    try std.testing.expectEqual(@as(u32, 0x00332211), pack(.rgbx8, color));
    try std.testing.expectEqual(@as(u32, 0x00112233), pack(.bgrx8, color));
}
