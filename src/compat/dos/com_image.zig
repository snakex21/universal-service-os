pub fn load(file: []const u8, destination: []u8) !usize {
    if (file.len > 0xFF00) return error.ComTooLarge;
    if (destination.len < file.len) return error.DestinationTooSmall;
    @memcpy(destination[0..file.len], file);
    return file.len;
}

test "COM image is copied verbatim" {
    const std = @import("std");
    const file = [_]u8{ 0xB4, 0x09, 0xCD, 0x21 };
    var memory = [_]u8{0} ** 8;
    const loaded = try load(&file, &memory);
    try std.testing.expectEqual(@as(usize, 4), loaded);
    try std.testing.expectEqualSlices(u8, &file, memory[0..4]);
}
