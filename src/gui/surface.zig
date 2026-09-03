const BootFramebuffer = @import("../kernel/boot_info.zig").Framebuffer;
const PixelFormat = @import("../kernel/boot_info.zig").PixelFormat;
const Color = @import("color.zig").Color;

pub const Surface = struct {
    framebuffer: BootFramebuffer,

    pub fn init(framebuffer: BootFramebuffer) ?Surface {
        if (framebuffer.pixel_format == .bit_mask) return null;
        if (framebuffer.address == 0 or framebuffer.width == 0 or framebuffer.height == 0) return null;
        return .{ .framebuffer = framebuffer };
    }

    pub fn fill(self: Surface, color: Color) void {
        self.fillRect(0, 0, self.framebuffer.width, self.framebuffer.height, color);
    }

    pub fn fillRect(self: Surface, x: u32, y: u32, width: u32, height: u32, color: Color) void {
        const max_x = @min(x +| width, self.framebuffer.width);
        const max_y = @min(y +| height, self.framebuffer.height);
        var py = y;
        while (py < max_y) : (py += 1) {
            var px = x;
            while (px < max_x) : (px += 1) self.setPixel(px, py, color);
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

    pub fn getRawPixel(self: Surface, x: u32, y: u32) u32 {
        if (x >= self.framebuffer.width or y >= self.framebuffer.height) return 0;
        const index: usize = @as(usize, y) * self.framebuffer.pixels_per_scan_line + x;
        const pixels: [*]volatile u32 = @ptrFromInt(self.framebuffer.address);
        return pixels[index];
    }

    pub fn setRawPixel(self: Surface, x: u32, y: u32, value: u32) void {
        if (x >= self.framebuffer.width or y >= self.framebuffer.height) return;
        const index: usize = @as(usize, y) * self.framebuffer.pixels_per_scan_line + x;
        const pixels: [*]volatile u32 = @ptrFromInt(self.framebuffer.address);
        pixels[index] = value;
    }
};

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
