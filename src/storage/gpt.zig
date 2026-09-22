const random_reader = @import("random_reader.zig");

pub const Error = random_reader.Error || error{
    InvalidHeader,
    InvalidHeaderCRC,
    InvalidEntryArray,
    InvalidEntryArrayCRC,
    UnsupportedEntryLayout,
    UsosEspNotFound,
    UsosEspAmbiguous,
    UsosDataNotFound,
    UsosDataAmbiguous,
    UsosWorkNotFound,
    UsosWorkAmbiguous,
};

pub const Partition = struct {
    start_lba: u64,
    end_lba: u64,
    part_guid: [16]u8,
    name_utf16: [36]u16,

    pub fn sectorCount(self: Partition) u64 {
        return self.end_lba - self.start_lba + 1;
    }

    pub fn copyNameAscii(self: Partition, output: []u8) usize {
        var written: usize = 0;
        for (self.name_utf16) |unit| {
            if (unit == 0 or written == output.len) break;
            output[written] = if (unit <= 0x7f) @intCast(unit) else '?';
            written += 1;
        }
        return written;
    }
};

const sector_bytes: usize = 512;
const entry_bytes: usize = 128;
const max_entries: u32 = 128;
const esp_type_guid_disk = [_]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
const basic_data_type_guid_disk = [_]u8{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 };
const usos_esp_name = [_]u16{ 'U', 'S', 'O', 'S', '_', 'E', 'S', 'P' };
const usos_data_name = [_]u16{ 'U', 'S', 'O', 'S', '_', 'D', 'A', 'T', 'A' };

const UsosPartitionKind = enum { esp, data, work };

pub fn findUsosWork(reader: random_reader.Reader) Error!Partition {
    return findUsosPartition(reader, &basic_data_type_guid_disk, &[_]u16{ 'U', 'S', 'O', 'S', '_', 'W', 'O', 'R', 'K' }, .work);
}

pub fn findUsosEsp(reader: random_reader.Reader) Error!Partition {
    return findUsosPartition(reader, &esp_type_guid_disk, &usos_esp_name, .esp);
}

pub fn findUsosData(reader: random_reader.Reader) Error!Partition {
    return findUsosPartition(reader, &basic_data_type_guid_disk, &usos_data_name, .data);
}

fn findUsosPartition(reader: random_reader.Reader, type_guid: *const [16]u8, wanted_name: []const u16, kind: UsosPartitionKind) Error!Partition {
    var header: [sector_bytes]u8 = undefined;
    try reader.readAt(sector_bytes, &header);
    if (!bytesEqual(header[0..8], "EFI PART")) return error.InvalidHeader;
    if (le32(header[8..12]) != 0x00010000) return error.InvalidHeader;
    const header_size = le32(header[12..16]);
    if (header_size < 92 or header_size > sector_bytes) return error.InvalidHeader;
    const expected_header_crc = le32(header[16..20]);
    header[16] = 0;
    header[17] = 0;
    header[18] = 0;
    header[19] = 0;
    if (crc32(header[0..@intCast(header_size)]) != expected_header_crc) return error.InvalidHeaderCRC;

    const first_usable = le64(header[40..48]);
    const last_usable = le64(header[48..56]);
    if (first_usable < 2 or last_usable < first_usable) return error.InvalidHeader;
    const entries_lba = le64(header[72..80]);
    const count = le32(header[80..84]);
    const size = le32(header[84..88]);
    const expected_entries_crc = le32(header[88..92]);
    if (entries_lba < 2 or count == 0 or count > max_entries or size != entry_bytes) return error.UnsupportedEntryLayout;

    const array_bytes_u64 = @as(u64, count) * entry_bytes;
    const array_offset = mul512(entries_lba) orelse return error.InvalidEntryArray;
    var crc_state: u32 = 0xFFFFFFFF;
    var remaining: u64 = array_bytes_u64;
    var offset = array_offset;
    var block: [sector_bytes]u8 = undefined;
    while (remaining > 0) {
        const amount: usize = @intCast(if (remaining > sector_bytes) sector_bytes else remaining);
        try reader.readAt(offset, block[0..amount]);
        crc_state = crc32Update(crc_state, block[0..amount]);
        offset = addChecked(offset, amount) orelse return error.InvalidEntryArray;
        remaining -= amount;
    }
    if ((crc_state ^ 0xFFFFFFFF) != expected_entries_crc) return error.InvalidEntryArrayCRC;

    var found: ?Partition = null;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var entry: [entry_bytes]u8 = undefined;
        const entry_offset = addChecked(array_offset, @as(u64, index) * entry_bytes) orelse return error.InvalidEntryArray;
        try reader.readAt(entry_offset, &entry);
        if (allZero(entry[0..16])) continue;
        if (!bytesEqual(entry[0..16], type_guid)) continue;

        const start_lba = le64(entry[32..40]);
        const end_lba = le64(entry[40..48]);
        if (start_lba < first_usable or end_lba > last_usable or start_lba > end_lba) return error.InvalidEntryArray;

        var name: [36]u16 = [_]u16{0} ** 36;
        var n: usize = 0;
        while (n < name.len) : (n += 1) name[n] = le16(entry[56 + n * 2 .. 58 + n * 2]);
        if (!isExactName(name, wanted_name)) continue;

        var part_guid: [16]u8 = undefined;
        copyBytes(&part_guid, entry[16..32]);
        const candidate = Partition{ .start_lba = start_lba, .end_lba = end_lba, .part_guid = part_guid, .name_utf16 = name };
        if (found != null) return switch (kind) {
            .esp => error.UsosEspAmbiguous,
            .data => error.UsosDataAmbiguous,
            .work => error.UsosWorkAmbiguous,
        };
        found = candidate;
    }
    return found orelse switch (kind) {
        .esp => error.UsosEspNotFound,
        .data => error.UsosDataNotFound,
        .work => error.UsosWorkNotFound,
    };
}

fn isExactName(name: [36]u16, wanted: []const u16) bool {
    if (wanted.len >= name.len) return false;
    var i: usize = 0;
    while (i < wanted.len) : (i += 1) if (name[i] != wanted[i]) return false;
    return name[wanted.len] == 0;
}

fn mul512(value: u64) ?u64 {
    const result = @mulWithOverflow(value, @as(u64, sector_bytes));
    return if (result[1] == 0) result[0] else null;
}

fn addChecked(a: u64, b: anytype) ?u64 {
    const result = @addWithOverflow(a, @as(u64, @intCast(b)));
    return if (result[1] == 0) result[0] else null;
}

fn le16(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}
fn le32(data: []const u8) u32 {
    return @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16) | (@as(u32, data[3]) << 24);
}
fn le64(data: []const u8) u64 {
    return @as(u64, le32(data[0..4])) | (@as(u64, le32(data[4..8])) << 32);
}
fn allZero(data: []const u8) bool {
    for (data) |value| if (value != 0) return false;
    return true;
}
fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| if (av != bv) return false;
    return true;
}
fn copyBytes(dest: []u8, source: []const u8) void {
    var i: usize = 0;
    while (i < dest.len and i < source.len) : (i += 1) dest[i] = source[i];
}

test "GPT CRC32 matches the standard check vector" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "USOS GPT name match is exact" {
    const std = @import("std");
    var exact = [_]u16{0} ** 36;
    for (usos_esp_name, 0..) |unit, index| exact[index] = unit;
    try std.testing.expect(isExactName(exact, &usos_esp_name));
    exact[usos_esp_name.len] = 'X';
    try std.testing.expect(!isExactName(exact, &usos_esp_name));

    exact = [_]u16{0} ** 36;
    for (usos_data_name, 0..) |unit, index| exact[index] = unit;
    try std.testing.expect(isExactName(exact, &usos_data_name));
}

pub fn crc32(data: []const u8) u32 {
    return crc32Update(0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

fn crc32Update(initial: u32, data: []const u8) u32 {
    var crc = initial;
    for (data) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) crc = if ((crc & 1) != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
    }
    return crc;
}
