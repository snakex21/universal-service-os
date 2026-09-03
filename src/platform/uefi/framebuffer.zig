const std = @import("std");
const boot_info = @import("usos").boot_info;

pub fn locate() !?boot_info.Framebuffer {
    const boot_services = std.os.uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const GraphicsOutput = std.os.uefi.protocol.GraphicsOutput;
    const graphics = try boot_services.locateProtocol(GraphicsOutput, null) orelse return null;
    const mode = graphics.mode;
    const info = mode.info;

    if (info.pixel_format == .blt_only) return null;

    const pixel_format: boot_info.PixelFormat = switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .rgbx8,
        .blue_green_red_reserved_8_bit_per_color => .bgrx8,
        .bit_mask => .bit_mask,
        .blt_only => unreachable,
    };

    return .{
        .address = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pixels_per_scan_line = info.pixels_per_scan_line,
        .pixel_format = pixel_format,
        .red_mask = info.pixel_information.red_mask,
        .green_mask = info.pixel_information.green_mask,
        .blue_mask = info.pixel_information.blue_mask,
        .reserved_mask = info.pixel_information.reserved_mask,
    };
}
