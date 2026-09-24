//! Naming and bookkeeping for the ACPI table dump the UEFI menu writes to
//! EFI\USOS\Logs\acpi\<machine>\ (DSDT and every SSDT as raw .aml, plus an
//! index.txt of all tables). <machine> is the SMBIOS system UUID, so a stick
//! moved between PCs keeps one folder per machine and a machine that was
//! already dumped is skipped (index.txt is written last and marks a
//! complete dump). Decompile with `iasl -d DSDT.aml SSDT-*.aml`.
const std = @import("std");

pub const header_size = 36;
/// Tables larger than this are not written (no real DSDT comes close).
pub const max_table = 8 * 1024 * 1024;

pub const Header = struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum_ok: bool,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
};

/// Parses an ACPI description header (36 bytes). `whole` is the full
/// table when available, for the checksum (null: not checked).
pub fn parseHeader(bytes: []const u8, whole: ?[]const u8) ?Header {
    if (bytes.len < header_size) return null;
    const length = std.mem.readInt(u32, bytes[4..8], .little);
    if (length < header_size or length > max_table) return null;
    for (bytes[0..4]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    var sum: u8 = 0;
    if (whole) |table| for (table) |c| {
        sum +%= c;
    };
    return .{
        .signature = bytes[0..4].*,
        .length = length,
        .revision = bytes[8],
        .checksum_ok = whole == null or sum == 0,
        .oem_id = bytes[10..16].*,
        .oem_table_id = bytes[16..24].*,
        .oem_revision = std.mem.readInt(u32, bytes[24..28], .little),
    };
}

/// DSDT address from a FADT: X_DSDT (offset 140, ACPI 2.0+) when present
/// and non-zero, else the 32-bit DSDT field (offset 40).
pub fn dsdtAddress(fadt: []const u8) u64 {
    if (fadt.len >= 148) {
        const x = std.mem.readInt(u64, fadt[140..148], .little);
        if (x != 0) return x;
    }
    if (fadt.len >= 44) return std.mem.readInt(u32, fadt[40..44], .little);
    return 0;
}

/// "DSDT.aml", or "SSDT-03-CpuSsdt.aml" (index, then the OEM table ID with
/// anything but letters, digits, '-' and '_' dropped).
pub fn fileName(header: Header, index: usize, out: []u8) []const u8 {
    if (std.mem.eql(u8, &header.signature, "DSDT")) return std.fmt.bufPrint(out, "DSDT.aml", .{}) catch "";
    var id: [8]u8 = undefined;
    var n: usize = 0;
    for (header.oem_table_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            id[n] = c;
            n += 1;
        }
    }
    if (n == 0) return std.fmt.bufPrint(out, "{s}-{d:0>2}.aml", .{ header.signature, index }) catch "";
    return std.fmt.bufPrint(out, "{s}-{d:0>2}-{s}.aml", .{ header.signature, index, id[0..n] }) catch "";
}

/// The per-machine folder name: the SMBIOS UUID (as Windows prints it), or
/// "nouuid-<crc32>" over the dumped tables' headers when the firmware has
/// no UUID, so the same firmware still maps to the same folder.
pub fn machineKey(uuid: ?[16]u8, headers_crc: u32, out: *[48]u8) []const u8 {
    if (uuid) |bytes| {
        var text: [36]u8 = undefined;
        const formatted = @import("../gui/handheld.zig").formatUuid(bytes, &text);
        @memcpy(out[0..36], formatted);
        return out[0..36];
    }
    return std.fmt.bufPrint(out, "nouuid-{x:0>8}", .{headers_crc}) catch "nouuid";
}

/// Only DSDT and SSDTs are written as .aml; every table goes in the index.
pub fn dumped(signature: [4]u8) bool {
    return std.mem.eql(u8, &signature, "DSDT") or std.mem.eql(u8, &signature, "SSDT");
}

test "ACPI header, FADT DSDT pointer and dump names" {
    var table = [_]u8{0} ** 48;
    @memcpy(table[0..4], "SSDT");
    std.mem.writeInt(u32, table[4..8], 48, .little);
    table[8] = 2;
    @memcpy(table[10..16], "ALASKA");
    @memcpy(table[16..24], "CPU SSDT");
    var sum: u8 = 0;
    for (table) |c| sum +%= c;
    table[9] = 0 -% sum;
    const header = parseHeader(&table, &table).?;
    try std.testing.expect(header.checksum_ok);
    try std.testing.expectEqualStrings("ALASKA", &header.oem_id);
    var name: [64]u8 = undefined;
    try std.testing.expectEqualStrings("SSDT-03-CPUSSDT.aml", fileName(header, 3, &name));
    table[20] = 0xFF;
    try std.testing.expect(!parseHeader(&table, &table).?.checksum_ok);
    // Garbage (not a table) and absurd lengths are rejected.
    try std.testing.expect(parseHeader(&([_]u8{0xFF} ** 36), null) == null);
    var dsdt = table;
    @memcpy(dsdt[0..4], "DSDT");
    try std.testing.expectEqualStrings("DSDT.aml", fileName(parseHeader(&dsdt, null).?, 0, &name));
    try std.testing.expect(dumped("DSDT".*) and dumped("SSDT".*) and !dumped("FACP".*));

    var fadt = [_]u8{0} ** 276;
    std.mem.writeInt(u32, fadt[40..44], 0x7A000000, .little);
    try std.testing.expectEqual(@as(u64, 0x7A000000), dsdtAddress(&fadt));
    std.mem.writeInt(u64, fadt[140..148], 0x1_2345_6000, .little);
    try std.testing.expectEqual(@as(u64, 0x1_2345_6000), dsdtAddress(&fadt));
    try std.testing.expectEqual(@as(u64, 0x7A000000), dsdtAddress(fadt[0..116]));
}

test "machine key is the SMBIOS UUID, else a stable CRC" {
    var out: [48]u8 = undefined;
    const uuid = [16]u8{ 0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };
    try std.testing.expectEqualStrings("00112233-4455-6677-8899-AABBCCDDEEFF", machineKey(uuid, 0, &out));
    try std.testing.expectEqualStrings("nouuid-0000abcd", machineKey(null, 0xabcd, &out));
}
