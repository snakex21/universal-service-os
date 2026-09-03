pub const icon_width: usize = 32;
pub const icon_height: usize = 32;
pub const channels: usize = 4;

pub const RgbaImage = struct {
    pixels: [icon_width * icon_height * channels]u8 = [_]u8{0} ** (icon_width * icon_height * channels),

    pub fn pixel(self: *const RgbaImage, x: usize, y: usize) Pixel {
        const index = (y * icon_width + x) * channels;
        return .{
            .r = self.pixels[index],
            .g = self.pixels[index + 1],
            .b = self.pixels[index + 2],
            .a = self.pixels[index + 3],
        };
    }
};

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};
