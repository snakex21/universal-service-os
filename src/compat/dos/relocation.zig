const std = @import("std");
const Header = @import("mz_header.zig").Header;

pub const Entry = struct {
    offset: u16,
    segment: u16,
};

pub fn read(bytes: []const u8, header: Header, index: usize) !Entry {
    if (index >= header.relocation_count) return error.RelocationOutOfRange;
    const start = @as(usize, header.relocation_table_offset) + index * 4;
    if (start + 4 > bytes.len) return error.TruncatedRelocationTable;
    return .{
        .offset = std.mem.readInt(u16, bytes[start..][0..2], .little),
        .segment = std.mem.readInt(u16, bytes[start + 2 ..][0..2], .little),
    };
}

pub fn apply(image: []u8, entry: Entry, relocation_segment: u16) !void {
    const address = @as(usize, entry.segment) * 16 + entry.offset;
    if (address + 2 > image.len) return error.RelocationOutsideImage;
    const original = std.mem.readInt(u16, image[address..][0..2], .little);
    std.mem.writeInt(u16, image[address..][0..2], original +% relocation_segment, .little);
}

test "relocation adds load segment to target word" {
    var image = [_]u8{0} ** 64;
    std.mem.writeInt(u16, image[18..20], 0x1234, .little);
    try apply(&image, .{ .segment = 1, .offset = 2 }, 0x2000);
    try std.testing.expectEqual(@as(u16, 0x3234), std.mem.readInt(u16, image[18..20], .little));
}
