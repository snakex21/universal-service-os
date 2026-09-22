//! Empty FAT16 filesystem bounded by the confirmed MS-DOS CHS partition.
const std = @import("std");
const partition = @import("dos_partition.zig");
pub const Layout = struct { cluster_sectors: u8, fat_sectors: u16, clusters: u32 };

pub fn layout(total: u32) !Layout {
    if (total != 128 * 2048 and total != 256 * 2048 and total != 512 * 2048) return error.InvalidDosPartitionSize;
    const spc: u8 = @intCast(total / 65536);
    // An upper bound keeps both FAT copies large enough, even including their
    // two reserved entries. Unused tail entries remain zero.
    const spf: u16 = @intCast(((total - 33) / spc + 2 + 255) / 256);
    const clusters = (total - 33 - 2 * @as(u32, spf)) / spc;
    if (clusters < 4085 or clusters >= 65525) return error.InvalidDosPartitionSize;
    return .{ .cluster_sectors = spc, .fat_sectors = spf, .clusters = clusters };
}

pub fn header(p: partition.Plan) ![512]u8 {
    if (!p.fat16) return error.InvalidDosPartitionSize;
    _ = try partition.planFat16(p.drive, p.source_drive, p.disk_sectors, p.partition_sectors / 2048, p.cylinders, p.heads, p.sectors_per_track, p.before);
    const shape = try layout(p.partition_sectors);
    var bytes = [_]u8{0} ** 512;
    @memcpy(bytes[0..3], "\xeb\x3c\x90"); @memcpy(bytes[3..11], "MSDOS6.2");
    put16(&bytes, 11, 512); bytes[13] = shape.cluster_sectors;
    put16(&bytes, 14, 1); bytes[16] = 2; put16(&bytes, 17, 512); bytes[21] = 0xf8;
    put16(&bytes, 22, shape.fat_sectors); put16(&bytes, 24, p.sectors_per_track); put16(&bytes, 26, p.heads);
    put32(&bytes, 28, 2048); put32(&bytes, 32, p.partition_sectors);
    bytes[36] = 0x80; bytes[38] = 0x29; put32(&bytes, 39, 0x36325355);
    @memcpy(bytes[43..54], "USOSDOS    "); @memcpy(bytes[54..62], "FAT16   ");
    // The source's original SYS.COM installs the DOS executable boot sector.
    @memcpy(bytes[62..66], "\xfa\xf4\xeb\xfd"); put16(&bytes, 510, 0xaa55);
    return bytes;
}

pub fn format(writer: anytype, p: partition.Plan) !void {
    const boot = try header(p);
    const shape = try layout(p.partition_sectors);
    try writer.zero(2048, 33 + 2 * @as(u32, shape.fat_sectors));
    var fat = [_]u8{0} ** 512;
    put16(&fat, 0, 0xfff8); put16(&fat, 2, 0xffff);
    try writer.write(2049, &fat); try writer.write(2049 + @as(u32, shape.fat_sectors), &fat);
    try writer.write(2048, &boot);
    var check: [512]u8 = undefined;
    try writer.read(2048, &check);
    if (!std.mem.eql(u8, &boot, &check)) return error.DosFormatReadbackFailed;
}
fn put16(bytes: []u8, offset: usize, value: u16) void { std.mem.writeInt(u16, bytes[offset..][0..2], value, .little); }
fn put32(bytes: []u8, offset: usize, value: u32) void { std.mem.writeInt(u32, bytes[offset..][0..4], value, .little); }

test "FAT16 metadata covers its clusters and uses the confirmed BIOS geometry" {
    for ([_]u32{128, 256, 512}) |mib| {
        const total = mib * 2048;
        const shape = try layout(total);
        try std.testing.expect(@as(u32, shape.fat_sectors) * 256 >= shape.clusters + 2);
        const zero = [_]u8{0} ** 512;
        const p = try partition.planFat16(0x81, 0x80, 40_000_000, mib, 1024, 255, 63, zero);
        const boot = try header(p);
        try std.testing.expectEqual(@as(u16, 255), std.mem.readInt(u16, boot[26..28], .little));
        try std.testing.expectEqual(total, std.mem.readInt(u32, boot[32..36], .little));
        try std.testing.expectEqualStrings("FAT16   ", boot[54..62]);
    }
    try std.testing.expectError(error.InvalidDosPartitionSize, layout(2048 * 2048));
}
