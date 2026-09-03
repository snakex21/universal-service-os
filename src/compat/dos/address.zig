pub fn linear(segment: u16, offset: u16) usize {
    return @as(usize, segment) * 16 + offset;
}

test "real mode segment offset converts to linear address" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 0x12350), linear(0x1234, 0x10));
}
