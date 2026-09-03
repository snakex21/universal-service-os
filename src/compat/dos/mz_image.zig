const Header = @import("mz_header.zig").Header;
const relocation = @import("relocation.zig");

pub fn load(file: []const u8, header: Header, load_segment: u16, destination: []u8) !usize {
    const image_offset = header.headerSizeBytes();
    const image_size = header.imageSizeBytes();
    if (file.len < header.fileSizeBytes()) return error.TruncatedExecutable;
    if (destination.len < image_size) return error.DestinationTooSmall;

    @memcpy(destination[0..image_size], file[image_offset .. image_offset + image_size]);

    var index: usize = 0;
    while (index < header.relocation_count) : (index += 1) {
        const entry = try relocation.read(file, header, index);
        try relocation.apply(destination[0..image_size], entry, load_segment);
    }
    return image_size;
}

test "MZ image is copied and relocation table is applied" {
    const std = @import("std");
    var file = [_]u8{0} ** 64;
    file[0] = 'M';
    file[1] = 'Z';
    std.mem.writeInt(u16, file[2..4], 64, .little);
    std.mem.writeInt(u16, file[4..6], 1, .little);
    std.mem.writeInt(u16, file[6..8], 1, .little);
    std.mem.writeInt(u16, file[8..10], 2, .little);
    std.mem.writeInt(u16, file[24..26], 0x1C, .little);
    std.mem.writeInt(u16, file[28..30], 2, .little);
    std.mem.writeInt(u16, file[30..32], 0, .little);
    std.mem.writeInt(u16, file[34..36], 0x1111, .little);

    const header = try Header.parse(&file);
    var image = [_]u8{0} ** 32;
    _ = try load(&file, header, 0x2000, &image);
    try std.testing.expectEqual(@as(u16, 0x3111), std.mem.readInt(u16, image[2..4], .little));
}
