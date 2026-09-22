pub const PixelFormat = enum {
    rgbx8,
    bgrx8,
    bit_mask,
};

pub const Framebuffer = struct {
    address: u64,
    size: usize,
    width: u32,
    height: u32,
    pixels_per_scan_line: u32,
    pixel_format: PixelFormat,
    red_mask: u32 = 0,
    green_mask: u32 = 0,
    blue_mask: u32 = 0,
    reserved_mask: u32 = 0,
};
