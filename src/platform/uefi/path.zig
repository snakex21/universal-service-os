pub const max_path_units: usize = 260;

pub fn asciiZ(text: []const u8, buffer: *[max_path_units + 1]u16) ?[*:0]const u16 {
    if (text.len > max_path_units) return null;

    for (text, 0..) |byte, index| {
        if (byte > 0x7f) return null;
        buffer[index] = byte;
    }
    buffer[text.len] = 0;
    return @ptrCast(buffer);
}

test "ASCII paths are converted to zero terminated UTF-16" {
    const std = @import("std");
    var buffer: [max_path_units + 1]u16 = undefined;
    const path = asciiZ("\\Programs", &buffer).?;
    try std.testing.expectEqual(@as(u16, '\\'), path[0]);
    try std.testing.expectEqual(@as(u16, 0), path[9]);
}
