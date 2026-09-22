//! Partition plan and commit contract, independent of the BIOS and its UI.
const std = @import("std");
pub const Plan = struct {
    drive: u8,
    source_drive: u8,
    disk_sectors: u32,
    partition_sectors: u32,
    before: [512]u8,
    fat16: bool = false,
    cylinders: u16 = 0,
    heads: u16 = 0,
    sectors_per_track: u16 = 0,
};
/// Repair currently supports the single active FAT32 partition created by USOS.
pub fn repairLayout(before: *const [512]u8) bool {
    if (before[510] != 0x55 or before[511] != 0xaa or before[446] != 0x80 or
        (before[450] != 0x0b and before[450] != 0x0c)) return false;
    for (1..4) |i| if (before[446 + i * 16 + 4] != 0) return false;
    return std.mem.readInt(u32, before[454..458], .little) >= 2048;
}
pub fn plan(drive: u8, source: u8, sectors: u32, gib: u32, before: [512]u8) !Plan {
    if (drive < 0x80 or drive > 0x8f or drive == source) return error.UnsafeDosTarget;
    if (gib != 2 and gib != 4 and gib != 8) return error.InvalidDosPartitionSize;
    const wanted = gib * 2 * 1024 * 1024;
    if (sectors < wanted + 2048 + 34) return error.DosTargetTooSmall;
    return .{ .drive = drive, .source_drive = source, .disk_sectors = sectors, .partition_sectors = wanted, .before = before };
}
pub fn planFat16(drive: u8, source: u8, sectors: u32, mib: u32, cylinders: u16, heads: u16, spt: u16, before: [512]u8) !Plan {
    if (drive < 0x80 or drive > 0x8f or drive == source) return error.UnsafeDosTarget;
    if (mib != 128 and mib != 256 and mib != 512) return error.InvalidDosPartitionSize;
    if (cylinders == 0 or cylinders > 1024 or heads == 0 or heads > 255 or spt == 0 or spt > 63) return error.UnsupportedDosGeometry;
    const wanted = mib * 2048;
    if (sectors < wanted + 2082) return error.DosTargetTooSmall;
    if (wanted + 2048 > @as(u32, cylinders) * heads * spt) return error.DosPartitionOutsideChs;
    return .{ .drive = drive, .source_drive = source, .disk_sectors = sectors, .partition_sectors = wanted, .before = before,
        .fat16 = true, .cylinders = cylinders, .heads = heads, .sectors_per_track = spt };
}
fn chs(lba: u32, heads: u16, spt: u16) [3]u8 {
    const cylinder = lba / (@as(u32, heads) * spt);
    return .{ @intCast((lba / spt) % heads), @as(u8, @intCast(lba % spt + 1)) | @as(u8, @intCast((cylinder >> 2) & 0xc0)), @truncate(cylinder) };
}
pub fn mbr(p: Plan, boot: *const [512]u8) [512]u8 {
    var result = boot.*;
    @memset(result[440..510], 0);
    std.mem.writeInt(u32, result[440..444], std.hash.Crc32.hash(&p.before) ^ p.disk_sectors, .little);
    result[446] = 0x80;
    // LBA partition; saturated CHS prevents truncated geometry interpretations.
    @memcpy(result[447..450], "\xfe\xff\xff");
    result[450] = 0x0c;
    @memcpy(result[451..454], "\xfe\xff\xff");
    if (p.fat16) {
        @memcpy(result[447..450], &chs(2048, p.heads, p.sectors_per_track));
        result[450] = 0x06;
        @memcpy(result[451..454], &chs(2048 + p.partition_sectors - 1, p.heads, p.sectors_per_track));
    }
    std.mem.writeInt(u32, result[454..458], 2048, .little);
    std.mem.writeInt(u32, result[458..462], p.partition_sectors, .little);
    result[510] = 0x55; result[511] = 0xaa;
    return result;
}
pub fn apply(writer: anytype, p: Plan, boot: *const [512]u8) !void {
    if (p.drive == p.source_drive or p.partition_sectors > p.disk_sectors -| 2082) return error.UnsafeDosTarget;
    if (p.fat16) {
        const checked = try planFat16(p.drive, p.source_drive, p.disk_sectors, p.partition_sectors / 2048, p.cylinders, p.heads, p.sectors_per_track, p.before);
        if (checked.partition_sectors != p.partition_sectors) return error.InvalidDosPartitionSize;
    }
    var current: [512]u8 = undefined;
    try writer.read(0, &current);
    if (!std.mem.eql(u8, &current, &p.before)) return error.DosTargetChanged;
    const zero = [_]u8{0} ** 512;
    // Invalidate old GPT copies and the new partition's stale filesystem header.
    for (1..34) |lba| try writer.write(@intCast(lba), &zero);
    for (p.disk_sectors - 33..p.disk_sectors) |lba| try writer.write(@intCast(lba), &zero);
    for (2048..2176) |lba| try writer.write(@intCast(lba), &zero);
    const prepared = mbr(p, boot);
    try writer.write(0, &prepared);
    try writer.read(0, &current);
    if (!std.mem.eql(u8, &prepared, &current)) return error.DosPartitionReadbackFailed;
}
test "DOS partition plan excludes the boot source and out-of-bounds layouts" {
    const zero = [_]u8{0} ** 512;
    try std.testing.expectError(error.UnsafeDosTarget, plan(0x80, 0x80, 50_000_000, 8, zero));
    try std.testing.expectError(error.DosTargetTooSmall, plan(0x81, 0x80, 1_000_000, 8, zero));
    const p = try plan(0x81, 0x80, 50_000_000, 8, zero);
    const result = mbr(p, &zero);
    try std.testing.expectEqual(@as(u32, 2048), std.mem.readInt(u32, result[454..458], .little));
    try std.testing.expectEqual(@as(u32, 16_777_216), std.mem.readInt(u32, result[458..462], .little));
    try std.testing.expectEqual(@as(u8, 0x80), result[446]);
    try std.testing.expectEqual(@as(u8, 0x0c), result[450]);
    for (result[462..510]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "partition commit checks identity before any write and verifies the final MBR" {
    const Fake = struct {
        sector: [512]u8 = [_]u8{0} ** 512,
        writes: usize = 0,
        corrupt: bool = false,
        pub fn read(self: *@This(), lba: u32, out: *[512]u8) !void { try std.testing.expectEqual(@as(u32, 0), lba); out.* = self.sector; }
        pub fn write(self: *@This(), lba: u32, bytes: *const [512]u8) !void { self.writes += 1; if (lba == 0 and !self.corrupt) self.sector = bytes.*; }
    };
    var writer = Fake{};
    const p = try plan(0x81, 0x80, 50_000_000, 8, writer.sector);
    writer.sector[5] = 1;
    try std.testing.expectError(error.DosTargetChanged, apply(&writer, p, &p.before));
    try std.testing.expectEqual(@as(usize, 0), writer.writes);
    writer.sector[5] = 0;
    try apply(&writer, p, &p.before);
    try std.testing.expectEqual(@as(usize, 195), writer.writes);
    writer = Fake{ .corrupt = true };
    try std.testing.expectError(error.DosPartitionReadbackFailed, apply(&writer, p, &p.before));
}
test "RAM repair accepts one active FAT32 partition and rejects ambiguous layouts" {
    const empty = [_]u8{0} ** 512;
    const p = try plan(0x81, 0x80, 50_000_000, 8, empty);
    var sector = mbr(p, &empty);
    try std.testing.expect(repairLayout(&sector));
    sector[450] = 7;
    try std.testing.expect(!repairLayout(&sector));
    sector[450] = 0x0c; sector[466] = 0x0c;
    try std.testing.expect(!repairLayout(&sector));
    sector[466] = 0; sector[446] = 0;
    try std.testing.expect(!repairLayout(&sector));
    try std.testing.expect(!repairLayout(&empty));
}

test "FAT16 plans preserve real BIOS CHS geometry and reject inaccessible sectors" {
    const zero = [_]u8{0} ** 512;
    const p = try planFat16(0x81, 0x80, 40_000_000, 256, 1024, 16, 63, zero);
    const sector = mbr(p, &zero);
    try std.testing.expectEqual(@as(u8, 6), sector[450]);
    for ([_]usize{447, 451}, [_]u32{2048, 2048 + 256 * 2048 - 1}) |offset, expected_lba| {
        const cylinder = @as(u32, sector[offset + 2]) | (@as(u32, sector[offset + 1] & 0xc0) << 2);
        const lba = (cylinder * 16 + sector[offset]) * 63 + (sector[offset + 1] & 63) - 1;
        try std.testing.expectEqual(expected_lba, lba);
    }
    try std.testing.expectError(error.DosPartitionOutsideChs, planFat16(0x81, 0x80, 40_000_000, 512, 1024, 16, 63, zero));
    try std.testing.expectError(error.UnsupportedDosGeometry, planFat16(0x81, 0x80, 40_000_000, 256, 1024, 256, 63, zero));
    try std.testing.expectError(error.UnsafeDosTarget, planFat16(0x80, 0x80, 40_000_000, 256, 1024, 16, 63, zero));
}
