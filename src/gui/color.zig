pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(text: []const u8) ?Color {
        if (text.len != 7 or text[0] != '#') return null;
        return .{
            .r = hexByte(text[1], text[2]) orelse return null,
            .g = hexByte(text[3], text[4]) orelse return null,
            .b = hexByte(text[5], text[6]) orelse return null,
        };
    }
};

fn hexByte(high: u8, low: u8) ?u8 {
    const h = hexNibble(high) orelse return null;
    const l = hexNibble(low) orelse return null;
    return (h << 4) | l;
}

fn hexNibble(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

test "hex colors parse" {
    const std = @import("std");
    const c = Color.fromHex("#5aa9ff").?;
    try std.testing.expectEqual(@as(u8, 0x5a), c.r);
    try std.testing.expectEqual(@as(u8, 0xa9), c.g);
    try std.testing.expectEqual(@as(u8, 0xff), c.b);
}
