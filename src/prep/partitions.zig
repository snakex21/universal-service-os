//! GPT layout follows UEFI 2.11 chapter 5; all disk offsets remain u64 on IA32.
const std = @import("std");
const platform = @import("platform.zig");
const identity = @import("identity.zig");
pub const Kind = enum { gpt, mbr };
pub const Partition = struct { start_bytes: u64, size_bytes: u64 };
const first_lba: u64 = 2048;
const basic_data = [_]u8{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 };

fn put(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
fn chs(out: []u8, lba: u64) void {
    if (lba >= 1024 * 255 * 63) { @memset(out[0..3], 0xff); return; }
    const cylinder = lba / (255 * 63);
    out[0] = @intCast((lba / 63) % 255);
    out[1] = @as(u8, @intCast(lba % 63 + 1)) | @as(u8, @intCast((cylinder >> 8) << 6));
    out[2] = @truncate(cylinder);
}

pub fn create(disk: platform.Disk, kind: Kind, ids: identity.Identifiers) platform.Error!Partition {
    try ids.validate();
    if (disk.sector_bytes != 512) return error.Unsupported;
    if (disk.sectors < 32768) return error.NoSpace;
    if (kind == .mbr and disk.sectors - first_lba > std.math.maxInt(u32)) return error.Unsupported;

    // Clear stale primary/backup GPT metadata also when replacing GPT with MBR.
    var zero: [512]u8 = @splat(0);
    for (0..34) |lba| try disk.write(@as(u64, lba) * 512, &zero);
    for (0..33) |n| try disk.write((disk.sectors - 1 - n) * 512, &zero);
    var mbr: [512]u8 = @splat(0);
    put(u32, &mbr, 440, ids.mbr_signature);
    chs(mbr[447..450], if (kind == .gpt) 1 else first_lba);
    chs(mbr[451..454], disk.sectors - 1);
    mbr[450] = if (kind == .gpt) 0xee else 0x07;
    put(u32, &mbr, 454, if (kind == .gpt) 1 else @intCast(first_lba));
    put(u32, &mbr, 458, @intCast(@min(if (kind == .gpt) disk.sectors - 1 else disk.sectors - first_lba, std.math.maxInt(u32))));
    put(u16, &mbr, 510, 0xaa55);
    try disk.write(0, &mbr);
    const last_lba = if (kind == .gpt) disk.sectors - 34 else disk.sectors - 1;
    if (kind == .gpt) {
        var entries: [128 * 128]u8 = @splat(0);
        @memcpy(entries[0..16], &basic_data);
        @memcpy(entries[16..32], &ids.partition_guid);
        put(u64, &entries, 32, first_lba);
        put(u64, &entries, 40, last_lba);
        const label = std.unicode.utf8ToUtf16LeStringLiteral("USOSPREP");
        for (label, 0..) |c, i| put(u16, &entries, 56 + i * 2, c);
        const crc = std.hash.Crc32.hash(&entries);
        try disk.write(2 * 512, &entries);
        try disk.write((disk.sectors - 33) * 512, &entries);
        var header: [512]u8 = undefined;
        makeHeader(&header, 1, disk.sectors - 1, 2, disk.sectors - 34, &ids.disk_guid, crc);
        try disk.write(512, &header);
        makeHeader(&header, disk.sectors - 1, 1, disk.sectors - 33, disk.sectors - 34, &ids.disk_guid, crc);
        try disk.write((disk.sectors - 1) * 512, &header);
    }
    try disk.flush();
    return .{ .start_bytes = first_lba * 512, .size_bytes = (last_lba - first_lba + 1) * 512 };
}

fn makeHeader(header: *[512]u8, current: u64, backup: u64, entries_lba: u64, last_usable: u64, guid: []const u8, entries_crc: u32) void {
    @memset(header, 0);
    @memcpy(header[0..8], "EFI PART");
    put(u32, header, 8, 0x00010000);
    put(u32, header, 12, 92);
    put(u64, header, 24, current);
    put(u64, header, 32, backup);
    put(u64, header, 40, 34);
    put(u64, header, 48, last_usable);
    @memcpy(header[56..72], guid);
    put(u64, header, 72, entries_lba);
    put(u32, header, 80, 128);
    put(u32, header, 84, 128);
    put(u32, header, 88, entries_crc);
    put(u32, header, 16, std.hash.Crc32.hash(header[0..92]));
}

const MemoryDisk = struct {
    bytes: []u8,
    writes: usize = 0,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *MemoryDisk = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) platform.Error!void {
        const self: *MemoryDisk = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        @memcpy(self.bytes[@intCast(offset)..][0..input.len], input);
    }
    fn flush(_: *anyopaque) platform.Error!void {}
    fn disk(self: *MemoryDisk) platform.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};

test "GPT header and backup CRC, aligned Basic Data partition" {
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var memory: MemoryDisk = .{ .bytes = bytes };
    var seed: [64]u8 = undefined; for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    const part = try create(memory.disk(), .gpt, ids);
    try std.testing.expectEqualSlices(u8, &ids.disk_guid, bytes[512+56..][0..16]);
    try std.testing.expectEqualSlices(u8, &ids.partition_guid, bytes[1024+16..][0..16]);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), part.start_bytes);
    try std.testing.expectEqual(@as(u8, 0xee), bytes[450]);
    try std.testing.expectEqualSlices(u8, "EFI PART", bytes[512..520]);
    const saved = std.mem.readInt(u32, bytes[528..532], .little);
    @memset(bytes[528..532], 0);
    try std.testing.expectEqual(saved, std.hash.Crc32.hash(bytes[512..604]));
    const backup = bytes.len - 512;
    const backup_saved = std.mem.readInt(u32, bytes[backup + 16 ..][0..4], .little);
    @memset(bytes[backup + 16 ..][0..4], 0);
    try std.testing.expectEqual(backup_saved, std.hash.Crc32.hash(bytes[backup..][0..92]));
    try std.testing.expectEqualSlices(u8, bytes[1024..][0..16384], bytes[bytes.len - 33 * 512 ..][0..16384]);
}

test "MBR removes GPT and has 0x07 type" {
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xaa);
    var memory: MemoryDisk = .{ .bytes = bytes };
    var seed: [64]u8 = undefined; for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try identity.Identifiers.fromEntropy(seed);
    const part = try create(memory.disk(), .mbr, ids);
    try std.testing.expectEqual(ids.mbr_signature, std.mem.readInt(u32, bytes[440..444], .little));
    try std.testing.expectEqual(@as(u8, 7), bytes[450]);
    try std.testing.expectEqual(@as(u64, bytes.len - 1024 * 1024), part.size_bytes);
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, bytes[512..520], .little));
}

test "invalid identities fail before writes and reformatting same marker uses fresh IDs" {
    const bytes = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xaa);
    var memory: MemoryDisk = .{ .bytes = bytes };
    var seed: [64]u8 = undefined; for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    var ids = try identity.Identifiers.fromEntropy(seed);
    ids.ntfs_serial = 0;
    try std.testing.expectError(error.InvalidArgument, create(memory.disk(), .gpt, ids));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
    try std.testing.expect(std.mem.allEqual(u8, bytes, 0xaa));
    ids = try identity.Identifiers.fromEntropy(seed);
    _ = try create(memory.disk(), .gpt, ids);
    const first_guid = bytes[568..584].*;
    // Same disk content/marker and size, independent new platform entropy.
    seed[0] ^= 0x80; seed[16] ^= 0x80; seed[32] ^= 0x80; seed[36] ^= 0x80;
    const next = try identity.Identifiers.fromEntropy(seed);
    _ = try create(memory.disk(), .gpt, next);
    try std.testing.expect(!std.mem.eql(u8, &first_guid, bytes[568..584]));
    try std.testing.expectEqualSlices(u8, &next.partition_guid, bytes[1040..1056]);
}
