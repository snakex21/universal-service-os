//! CSMWrap ESP on an MS-DOS / Windows 3.x target prepared under CSMWrap
//! (docs/design/bios-via-csmwrap.md section 4.2): the BIOS-side equivalent of
//! tools/xp_csmwrap_esp.sh. The build writes the used part of the 64 MiB
//! FAT16 ESP (tools/build_csmwrap_dos_esp.py -> EFI\USOS\dos-native\msdos\
//! CSMESP.IMG: \EFI\BOOT\BOOTX64.EFI = CSMWrap 3.1.2-usos3 with csmwrap.ini,
//! \CSMWRAP\ licences, source and patches). The Core copies it to the XP
//! tail position, sets the BPB hidden sectors, reads every sector back, and
//! only then publishes MBR slot 2 as type 0xEF. The firmware then boots the
//! disk through its UEFI removable path -> CSMWrap -> SeaBIOS -> DOS MBR.
const std = @import("std");

pub const esp_sectors: u32 = 131072;
/// USOS_XP_ESP_TAIL_SECTORS: the ESP starts at align2048(total - tail).
pub const tail_sectors: u32 = 133120;
pub const image_name = "CSMESP.IMG";
const slot2 = 446 + 16;

pub fn start(total: u32) u32 {
    return (total -| tail_sectors + 2047) / 2048 * 2048;
}

/// The ESP fits behind the DOS partition (which ends before `used_end`).
pub fn fits(total: u32, used_end: u32) bool {
    if (total < tail_sectors) return false;
    const first = start(total);
    return first >= used_end and first + esp_sectors <= total;
}

pub fn entry(first: u32) [16]u8 {
    var result = [_]u8{ 0x00, 0xfe, 0xff, 0xff, 0xef, 0xfe, 0xff, 0xff } ++ [_]u8{0} ** 8;
    std.mem.writeInt(u32, result[8..12], first, .little);
    std.mem.writeInt(u32, result[12..16], esp_sectors, .little);
    return result;
}

/// `writer`: read(lba, *[512]u8), write(lba, *const [512]u8) on the target;
/// `source`: read(offset, []u8) of the image; `buffer`: 512-byte multiple.
/// Returns the ESP's first LBA.
pub fn write(writer: anytype, source: anytype, buffer: []u8, image_bytes: u32, total: u32, used_end: u32) !u32 {
    if (image_bytes == 0 or image_bytes % 512 != 0 or image_bytes > esp_sectors * 512 or buffer.len < 512 or buffer.len % 512 != 0)
        return error.InvalidCsmwrapEspImage;
    if (!fits(total, used_end)) return error.NoRoomForCsmwrapEsp;
    const first = start(total);
    var mbr: [512]u8 = undefined;
    try writer.read(0, &mbr);
    // Only slot 1 (the DOS partition commitDos just wrote) may be in use.
    if (mbr[510] != 0x55 or mbr[511] != 0xaa) return error.DosTargetChanged;
    for (mbr[slot2..510]) |byte| if (byte != 0) return error.DosTargetChanged;
    var offset: u32 = 0;
    var check: [512]u8 = undefined;
    while (offset < image_bytes) {
        const amount: u32 = @intCast(@min(buffer.len, image_bytes - offset));
        try source.read(offset, buffer[0..amount]);
        var done: u32 = 0;
        while (done < amount) : (done += 512) {
            const index = (offset + done) / 512;
            const sector: *[512]u8 = buffer[done..][0..512];
            // BPB hidden sectors = the partition start.
            if (index == 0) std.mem.writeInt(u32, sector[28..32], first, .little);
            try writer.write(first + index, sector);
            try writer.read(first + index, &check);
            if (!std.mem.eql(u8, sector, &check)) return error.DosPartitionReadbackFailed;
        }
        offset += amount;
    }
    // Publish the partition only after every sector is verified.
    const published = entry(first);
    @memcpy(mbr[slot2 .. slot2 + 16], &published);
    try writer.write(0, &mbr);
    try writer.read(0, &check);
    if (!std.mem.eql(u8, &mbr, &check)) return error.DosPartitionReadbackFailed;
    return first;
}

test "CSMWrap ESP follows the XP tail rule and stays behind the DOS partition" {
    // 1 GiB disk: 2097152 sectors.
    try std.testing.expectEqual(@as(u32, 1964032), start(2097152));
    try std.testing.expect(fits(2097152, 2048 + 512 * 2048));
    try std.testing.expect(!fits(2097152, 1964033));
    try std.testing.expect(!fits(100_000, 0));
    const e = entry(1964032);
    try std.testing.expectEqual(@as(u8, 0xef), e[4]);
    try std.testing.expectEqual(@as(u8, 0), e[0]);
    try std.testing.expectEqual(@as(u32, 1964032), std.mem.readInt(u32, e[8..12], .little));
    try std.testing.expectEqual(esp_sectors, std.mem.readInt(u32, e[12..16], .little));
}

test "CSMWrap ESP image is copied, patched, verified, then published" {
    const total: u32 = 600_000;
    const Disk = struct {
        sectors: std.AutoHashMap(u32, [512]u8),
        fail_readback_at: ?u32 = null,
        pub fn read(self: *@This(), lba: u32, out: *[512]u8) !void {
            out.* = self.sectors.get(lba) orelse [_]u8{0} ** 512;
            if (self.fail_readback_at == lba) out[0] ^= 1;
        }
        pub fn write(self: *@This(), lba: u32, bytes: *const [512]u8) !void {
            try self.sectors.put(lba, bytes.*);
        }
    };
    const Image = struct {
        bytes: []const u8,
        pub fn read(self: @This(), offset: u32, out: []u8) !void {
            @memcpy(out, self.bytes[offset..][0..out.len]);
        }
    };
    const image = [_]u8{0xa5} ** (300 * 512);
    var disk = Disk{ .sectors = std.AutoHashMap(u32, [512]u8).init(std.testing.allocator) };
    defer disk.sectors.deinit();
    var mbr = [_]u8{0} ** 512;
    mbr[446] = 0x80;
    mbr[450] = 0x06;
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    try disk.write(0, &mbr);
    var buffer: [4096]u8 = undefined;
    const first = try write(&disk, Image{ .bytes = &image }, &buffer, image.len, total, 2048 + 128 * 2048);
    try std.testing.expectEqual(start(total), first);
    var sector: [512]u8 = undefined;
    try disk.read(first, &sector);
    try std.testing.expectEqual(first, std.mem.readInt(u32, sector[28..32], .little));
    try disk.read(first + 299, &sector);
    try std.testing.expectEqual(@as(u8, 0xa5), sector[511]);
    try disk.read(0, &sector);
    try std.testing.expectEqual(@as(u8, 0xef), sector[slot2 + 4]);
    try std.testing.expectEqual(@as(u8, 0x06), sector[450]);
    // A second run finds slot 2 taken; a failed read-back leaves it empty.
    try std.testing.expectError(error.DosTargetChanged, write(&disk, Image{ .bytes = &image }, &buffer, image.len, total, 0));
    try disk.write(0, &mbr);
    disk.fail_readback_at = first + 5;
    try std.testing.expectError(error.DosPartitionReadbackFailed, write(&disk, Image{ .bytes = &image }, &buffer, image.len, total, 0));
    try disk.read(0, &sector);
    try std.testing.expectEqual(@as(u8, 0), sector[slot2 + 4]);
}
