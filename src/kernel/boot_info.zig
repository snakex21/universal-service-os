const Architecture = @import("../core/architecture.zig").Architecture;
const Firmware = @import("../core/firmware.zig").Firmware;

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

pub const MemorySummary = struct {
    descriptor_count: usize,
    conventional_bytes: u64,
};

pub const BootInfo = struct {
    architecture: Architecture,
    firmware: Firmware,
    framebuffer: ?Framebuffer,
    memory: MemorySummary,
};

test "boot info keeps platform-neutral startup data" {
    const std = @import("std");
    const info = BootInfo{
        .architecture = .x86_64,
        .firmware = .uefi,
        .framebuffer = null,
        .memory = .{
            .descriptor_count = 12,
            .conventional_bytes = 64 * 1024 * 1024,
        },
    };

    try std.testing.expectEqual(Architecture.x86_64, info.architecture);
    try std.testing.expectEqual(Firmware.uefi, info.firmware);
    try std.testing.expectEqual(@as(usize, 12), info.memory.descriptor_count);
}
