pub fn u64ToAscii(buffer: *[20]u8, value: u64) []const u8 {
    var index = buffer.len;
    var remaining = value;

    if (remaining == 0) {
        index -= 1;
        buffer[index] = '0';
        return buffer[index..];
    }

    while (remaining != 0) {
        index -= 1;
        buffer[index] = @as(u8, @intCast(remaining % 10)) + '0';
        remaining /= 10;
    }

    return buffer[index..];
}

test "decimal conversion handles zero" {
    const std = @import("std");
    var buffer: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", u64ToAscii(&buffer, 0));
}

test "decimal conversion handles u64 values" {
    const std = @import("std");
    var buffer: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1234567890123456789", u64ToAscii(&buffer, 1_234_567_890_123_456_789));
}
