//! Disk type for the Legacy BIOS disk pickers, from the EDD 3.0 part of the
//! INT 13h AH=48h drive parameter block (interface type at 0x28, valid when
//! the block is at least 0x42 bytes and carries the 0xBEDD key at 0x1E).
//! Firmware that fills only the EDD 1.x/2.x part (likely SeaBIOS behind
//! CSMWrap for AHCI/NVMe/USB disks) gives null: the picker then shows no
//! type. Media (SSD/HDD) would need ATA IDENTIFY, not available here, except
//! that NVMe is always an SSD.
const std = @import("std");

/// DRIVE_PARAMS in src/platform/bios/core.S: the block the last
/// bios_drive_info call filled (flat address, below 1 MiB).
pub const drive_params_address: usize = 0x9500;
/// Bytes bios_drive_info asks AH=48h for (T13 EDD-3 size).
pub const drive_params_bytes: usize = 0x4A;

/// "SATA", "ATA", "USB", "M.2 NVMe SSD", "SCSI", "SAS" or "RAID"; null when the
/// firmware does not report a disk interface.
pub fn label(params: []const u8) ?[]const u8 {
    if (params.len < 0x42) return null;
    const size = std.mem.readInt(u16, params[0..2], .little);
    if (size < 0x42 or std.mem.readInt(u16, params[0x1E..0x20], .little) != 0xBEDD) return null;
    const raw = std.mem.trimEnd(u8, params[0x28..0x30], " \x00");
    const known = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "SATA", .text = "SATA" },
        .{ .name = "ATA", .text = "ATA" },
        .{ .name = "USB", .text = "USB" },
        .{ .name = "NVME", .text = "M.2 NVMe SSD" },
        .{ .name = "SCSI", .text = "SCSI" },
        .{ .name = "SAS", .text = "SAS" },
        .{ .name = "RAID", .text = "RAID" },
    };
    for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(raw, entry.name)) return entry.text;
    }
    return null;
}

/// The block bios_drive_info left at DRIVE_PARAMS (call right after it).
pub fn lastLabel() ?[]const u8 {
    const params: [*]const volatile u8 = @ptrFromInt(drive_params_address);
    var copy: [drive_params_bytes]u8 = undefined;
    for (&copy, 0..) |*byte, index| byte.* = params[index];
    return label(&copy);
}

/// "<kind> - <text>" in buffer (just text without a kind, or when the
/// prefix does not fit).
pub fn prefixed(buffer: []u8, kind: ?[]const u8, text: []const u8) []const u8 {
    if (kind) |name| {
        if (std.fmt.bufPrint(buffer, "{s} - {s}", .{ name, text })) |result| return result else |_| {}
    }
    const length = @min(buffer.len, text.len);
    @memcpy(buffer[0..length], text[0..length]);
    return buffer[0..length];
}

fn block(size: u16, key: u16, interface: []const u8) [drive_params_bytes]u8 {
    var bytes = [_]u8{0} ** drive_params_bytes;
    std.mem.writeInt(u16, bytes[0..2], size, .little);
    std.mem.writeInt(u16, bytes[0x1E..0x20], key, .little);
    @memset(bytes[0x28..0x30], ' ');
    @memcpy(bytes[0x28 .. 0x28 + interface.len], interface);
    return bytes;
}

test "EDD 3.0 interface types map to picker labels" {
    try std.testing.expectEqualStrings("SATA", label(&block(0x42, 0xBEDD, "SATA")).?);
    try std.testing.expectEqualStrings("ATA", label(&block(0x4A, 0xBEDD, "ATA")).?);
    try std.testing.expectEqualStrings("USB", label(&block(0x42, 0xBEDD, "USB")).?);
    try std.testing.expectEqualStrings("M.2 NVMe SSD", label(&block(0x4A, 0xBEDD, "NVMe")).?);
    try std.testing.expectEqualStrings("SCSI", label(&block(0x42, 0xBEDD, "SCSI")).?);
}

test "no type without a valid EDD 3.0 block" {
    try std.testing.expect(label(&block(0x1E, 0xBEDD, "SATA")) == null);
    try std.testing.expect(label(&block(0x42, 0x0000, "SATA")) == null);
    try std.testing.expect(label(&block(0x42, 0xBEDD, "ATAPI")) == null);
    try std.testing.expect(label(&block(0x42, 0xBEDD, "")) == null);
    try std.testing.expect(label(&[_]u8{0} ** 0x1E) == null);
}

test "picker label prefix" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("SATA - Disk 1 - 100 MiB - GPT", prefixed(&buffer, "SATA", "Disk 1 - 100 MiB - GPT"));
    try std.testing.expectEqualStrings("Disk 1 - 100 MiB - GPT", prefixed(&buffer, null, "Disk 1 - 100 MiB - GPT"));
    var small: [24]u8 = undefined;
    try std.testing.expectEqualStrings("Disk 1 - 100 MiB - GPT", prefixed(&small, "M.2 NVMe", "Disk 1 - 100 MiB - GPT"));
}
