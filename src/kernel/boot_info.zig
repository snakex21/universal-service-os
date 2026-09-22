const Architecture = @import("../core/architecture.zig").Architecture;
const Firmware = @import("../core/firmware.zig").Firmware;

const framebuffer = @import("../gui/framebuffer.zig");
pub const PixelFormat = framebuffer.PixelFormat;
pub const Framebuffer = framebuffer.Framebuffer;

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
