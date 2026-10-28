//! Fresh FAT32 metadata for the partition confirmed in the USOS UI.
const std = @import("std");
const partition = @import("dos_partition.zig");
/// Microsoft's FAT32 defaults: 4 KiB clusters up to 8 GiB, 8 KiB up to 16 GiB,
/// 16 KiB up to 32 GiB. The FAT then stays below 16 MiB, the limit of the
/// 16-bit ScanDisk that Windows 9x runs after an unclean shutdown.
pub fn clusterSectors(total: u32) u8 {
    if (total <= 16 * 1024 * 1024) return 8;
    if (total <= 32 * 1024 * 1024) return 16;
    return 32;
}
pub fn fatSectors(total: u32) u32 { return ((total - 32) / clusterSectors(total) + 2 + 127) / 128; }
pub fn header(total: u32) [512]u8 {
    var b = [_]u8{0} ** 512;
    @memcpy(b[0..3], "\xeb\x58\x90"); @memcpy(b[3..11], "MSWIN4.1");
    put16(&b, 11, 512); b[13] = clusterSectors(total); put16(&b, 14, 32); b[16] = 2;
    b[21] = 0xf8; put16(&b, 24, 63); put16(&b, 26, 255);
    put32(&b, 28, 2048); put32(&b, 32, total); put32(&b, 36, fatSectors(total));
    put32(&b, 44, 2); put16(&b, 48, 1); put16(&b, 50, 6);
    b[64] = 0x80; b[66] = 0x29; put32(&b, 67, 0x39385355);
    @memcpy(b[71..82], "WINDOWS98  "); @memcpy(b[82..90], "FAT32   ");
    // SYS from the selected Microsoft boot image installs the executable VBR.
    @memcpy(b[90..94], "\xfa\xf4\xeb\xfd");
    put16(&b, 510, 0xaa55); return b;
}
pub fn format(writer: anytype, p: partition.Plan) !void {
    const spf = fatSectors(p.partition_sectors);
    const data = 32 + 2 * spf;
    try writer.zero(2048, data + clusterSectors(p.partition_sectors));
    const boot = header(p.partition_sectors);
    try writer.write(2048, &boot); try writer.write(2054, &boot);
    var info = [_]u8{0} ** 512;
    put32(&info, 0, 0x41615252); put32(&info, 484, 0x61417272);
    put32(&info, 488, (p.partition_sectors - data) / clusterSectors(p.partition_sectors) - 1);
    put32(&info, 492, 3); put32(&info, 508, 0xaa550000);
    try writer.write(2049, &info); try writer.write(2055, &info);
    var fat = [_]u8{0} ** 512;
    put32(&fat, 0, 0x0ffffff8); put32(&fat, 4, 0x0fffffff); put32(&fat, 8, 0x0fffffff);
    try writer.write(2080, &fat); try writer.write(2080 + spf, &fat);
    var check: [512]u8 = undefined;
    try writer.read(2048, &check);
    if (!std.mem.eql(u8, &boot, &check)) return error.DosFormatReadbackFailed;
}
fn put16(b: []u8, o: usize, v: u16) void { std.mem.writeInt(u16, b[o..][0..2], v, .little); }
fn put32(b: []u8, o: usize, v: u32) void { std.mem.writeInt(u32, b[o..][0..4], v, .little); }
test "FAT32 metadata covers every cluster and fits each supported partition" {
    for ([_]u32{2,4,8,32}) |gib| {
        const total = gib * 2 * 1024 * 1024;
        const spf = fatSectors(total);
        const clusters = (total - 32 - 2 * spf) / clusterSectors(total);
        try std.testing.expect(clusters >= 65525);
        try std.testing.expect(spf * 128 >= clusters + 2);
        // 16-bit ScanDisk: the FAT must stay below 16 MiB.
        try std.testing.expect(spf * 512 < 16 * 1024 * 1024);
        const boot = header(total);
        try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, boot[11..13], .little));
        try std.testing.expectEqual(@as(u32, 2048), std.mem.readInt(u32, boot[28..32], .little));
        try std.testing.expectEqual(total, std.mem.readInt(u32, boot[32..36], .little));
        try std.testing.expectEqual(@as(u16, 0xaa55), std.mem.readInt(u16, boot[510..512], .little));
        try std.testing.expectEqual(clusterSectors(total), boot[13]);
    }
    try std.testing.expectEqual(@as(u8, 8), clusterSectors(8 * 2 * 1024 * 1024));
    try std.testing.expectEqual(@as(u8, 32), clusterSectors(32 * 2 * 1024 * 1024));
}
