const std = @import("std");

pub const size: usize = 256;

pub const Psp = struct {
    bytes: [size]u8 = [_]u8{0} ** size,

    pub fn init(end_segment: u16, parent_segment: u16, environment_segment: u16, command_tail: []const u8) !Psp {
        if (command_tail.len > 126) return error.CommandTailTooLong;

        var result = Psp{};
        result.bytes[0] = 0xCD;
        result.bytes[1] = 0x20;
        std.mem.writeInt(u16, result.bytes[2..4], end_segment, .little);
        std.mem.writeInt(u16, result.bytes[0x16..0x18], parent_segment, .little);
        std.mem.writeInt(u16, result.bytes[0x2C..0x2E], environment_segment, .little);

        result.bytes[0x50] = 0xCD;
        result.bytes[0x51] = 0x21;
        result.bytes[0x52] = 0xCB;

        result.bytes[0x80] = @intCast(command_tail.len);
        @memcpy(result.bytes[0x81 .. 0x81 + command_tail.len], command_tail);
        result.bytes[0x81 + command_tail.len] = 0x0D;
        return result;
    }
};

test "PSP contains INT 20 entry command tail and DOS call gate" {
    const psp = try Psp.init(0x3000, 0x1000, 0x2000, " /Q");
    try std.testing.expectEqualSlices(u8, &.{ 0xCD, 0x20 }, psp.bytes[0..2]);
    try std.testing.expectEqual(@as(u16, 0x3000), std.mem.readInt(u16, psp.bytes[2..4], .little));
    try std.testing.expectEqual(@as(u16, 0x1000), std.mem.readInt(u16, psp.bytes[0x16..0x18], .little));
    try std.testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, psp.bytes[0x2C..0x2E], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xCD, 0x21, 0xCB }, psp.bytes[0x50..0x53]);
    try std.testing.expectEqual(@as(u8, 3), psp.bytes[0x80]);
    try std.testing.expectEqualStrings(" /Q", psp.bytes[0x81..0x84]);
    try std.testing.expectEqual(@as(u8, 0x0D), psp.bytes[0x84]);
}
