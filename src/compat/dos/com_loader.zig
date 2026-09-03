const Registers = @import("registers.zig").Registers;
const psp = @import("psp.zig");

pub const Plan = struct {
    psp_segment: u16,
    image_offset: u16 = 0x0100,
    image_size: usize,
    registers: Registers,

    pub fn imageLinearAddress(self: Plan) usize {
        return @as(usize, self.psp_segment) * 16 + self.image_offset;
    }
};

pub fn plan(psp_segment: u16, allocation_paragraphs: u16, image_size: usize) !Plan {
    if (image_size > 0xFF00) return error.ComTooLarge;
    if (allocation_paragraphs <= 0x10) return error.NotEnoughMemory;

    const allocation_bytes = @as(usize, allocation_paragraphs) * 16;
    if (allocation_bytes <= psp.size + 2) return error.NotEnoughMemory;

    const top = @min(allocation_bytes - 2, @as(usize, 0xFFFE));
    if (top <= 0x100 or image_size > top - 0x100) return error.NotEnoughMemory;

    return .{
        .psp_segment = psp_segment,
        .image_size = image_size,
        .registers = .{
            .ip = 0x0100,
            .sp = @intCast(top),
            .cs = psp_segment,
            .ds = psp_segment,
            .es = psp_segment,
            .ss = psp_segment,
        },
    };
}

test "COM starts at PSP:100h with all segment registers at PSP" {
    const std = @import("std");
    const result = try plan(0x1234, 0x1000, 4096);
    try std.testing.expectEqual(@as(u16, 0x1234), result.registers.cs);
    try std.testing.expectEqual(@as(u16, 0x1234), result.registers.ds);
    try std.testing.expectEqual(@as(u16, 0x0100), result.registers.ip);
    try std.testing.expectEqual(@as(u16, 0xFFFE), result.registers.sp);
}
