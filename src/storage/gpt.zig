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
/// Entry array read size: 4 KiB (8 sectors, one BlockIo call) where the
/// stack allows it; the i386 Legacy BIOS Core reads one sector at a time
/// (its reader issues one INT 13h call per sector anyway).
const scan_block_bytes: usize = if (@import("builtin").os.tag == .freestanding and @import("builtin").cpu.arch == .x86) sector_bytes else 8 * sector_bytes;
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
    _ = addChecked(array_offset, array_bytes_u64) orelse return error.InvalidEntryArray;

    // One pass over the entry array in whole blocks: the CRC and the entry
    // scan share the reads (a 128-entry array was 161 single-sector reads
    // per search before, which cost ~0.3 s per disk on USB and in QEMU).
    // Results are only used once the CRC of the whole array matched; the
    // first entry-level error in array order wins, as before.
    var crc_state: u32 = 0xFFFFFFFF;
    var remaining: u64 = array_bytes_u64;
    var offset = array_offset;
    var block: [scan_block_bytes]u8 = undefined;
    var index: u32 = 0;
    var found: ?Partition = null;
    var entry_error: ?Error = null;
    while (remaining > 0) {
        const amount: usize = @intCast(if (remaining > scan_block_bytes) scan_block_bytes else remaining);
        try reader.readAt(offset, block[0..amount]);
        crc_state = crc32Update(crc_state, block[0..amount]);
        offset += amount;
        remaining -= amount;

        var at: usize = 0;
        while (at + entry_bytes <= amount) : (at += entry_bytes) {
            defer index += 1;
            if (entry_error != null) continue;
            const entry = block[at..][0..entry_bytes];
            if (allZero(entry[0..16])) continue;
            if (!bytesEqual(entry[0..16], type_guid)) continue;

            const start_lba = le64(entry[32..40]);
            const end_lba = le64(entry[40..48]);
            if (start_lba < first_usable or end_lba > last_usable or start_lba > end_lba) {
                entry_error = error.InvalidEntryArray;
                continue;
            }

            var name: [36]u16 = [_]u16{0} ** 36;
            var n: usize = 0;
            while (n < name.len) : (n += 1) name[n] = le16(entry[56 + n * 2 .. 58 + n * 2]);
            if (!isExactName(name, wanted_name)) continue;

            var part_guid: [16]u8 = undefined;
            copyBytes(&part_guid, entry[16..32]);
            if (found != null) {
                entry_error = switch (kind) {
                    .esp => error.UsosEspAmbiguous,
                    .data => error.UsosDataAmbiguous,
                    .work => error.UsosWorkAmbiguous,
                };
                continue;
            }
            found = Partition{ .start_lba = start_lba, .end_lba = end_lba, .part_guid = part_guid, .name_utf16 = name };
        }
    }
    if ((crc_state ^ 0xFFFFFFFF) != expected_entries_crc) return error.InvalidEntryArrayCRC;
    if (entry_error) |err| return err;
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

const TestDisk = struct {
    bytes: [64 * sector_bytes]u8 = [_]u8{0} ** (64 * sector_bytes),
    reads: usize = 0,

    fn read(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        if (offset + output.len > self.bytes.len) return error.OutOfBounds;
        self.reads += 1;
        const start: usize = @intCast(offset);
        @memcpy(output, self.bytes[start..][0..output.len]);
    }

    fn reader(self: *TestDisk) random_reader.Reader {
        return .{ .context = self, .read_fn = read };
    }

    fn putEntry(self: *TestDisk, index: usize, type_guid: []const u8, name: []const u16, start: u64, end: u64) void {
        const entry = self.bytes[2 * sector_bytes + index * entry_bytes ..][0..entry_bytes];
        @memcpy(entry[0..16], type_guid);
        entry[16] = @intCast(index + 1);
        tstd.mem.writeInt(u64, entry[32..40], start, .little);
        tstd.mem.writeInt(u64, entry[40..48], end, .little);
        for (name, 0..) |unit, n| tstd.mem.writeInt(u16, entry[56 + n * 2 ..][0..2], unit, .little);
    }

    fn seal(self: *TestDisk) void {
        const header = self.bytes[sector_bytes..][0..sector_bytes];
        @memcpy(header[0..8], "EFI PART");
        tstd.mem.writeInt(u32, header[8..12], 0x00010000, .little);
        tstd.mem.writeInt(u32, header[12..16], 92, .little);
        tstd.mem.writeInt(u64, header[40..48], 34, .little);
        tstd.mem.writeInt(u64, header[48..56], 63, .little);
        tstd.mem.writeInt(u64, header[72..80], 2, .little);
        tstd.mem.writeInt(u32, header[80..84], max_entries, .little);
        tstd.mem.writeInt(u32, header[84..88], entry_bytes, .little);
        tstd.mem.writeInt(u32, header[88..92], crc32(self.bytes[2 * sector_bytes ..][0 .. max_entries * entry_bytes]), .little);
        tstd.mem.writeInt(u32, header[16..20], 0, .little);
        tstd.mem.writeInt(u32, header[16..20], crc32(header[0..92]), .little);
    }
};

const tstd = @import("std");

test "USOS partitions are found in one pass over the entry array" {
    var disk = TestDisk{};
    disk.putEntry(0, &esp_type_guid_disk, &usos_esp_name, 34, 40);
    disk.putEntry(5, &basic_data_type_guid_disk, &[_]u16{ 'O', 'T', 'H', 'E', 'R' }, 41, 45);
    disk.putEntry(97, &basic_data_type_guid_disk, &usos_data_name, 46, 63);
    disk.seal();
    const esp = try findUsosEsp(disk.reader());
    try tstd.testing.expectEqual(@as(u64, 34), esp.start_lba);
    try tstd.testing.expectEqual(@as(u8, 1), esp.part_guid[0]);
    const reads_for_esp = disk.reads;
    // Header + 16 KiB of entries: 1 + 4 reads (host) instead of 1 + 32 + 128.
    try tstd.testing.expect(reads_for_esp <= 1 + max_entries * entry_bytes / sector_bytes);
    const data = try findUsosData(disk.reader());
    try tstd.testing.expectEqual(@as(u64, 46), data.start_lba);
    try tstd.testing.expectEqual(@as(u64, 18), data.sectorCount());
    try tstd.testing.expectError(error.UsosWorkNotFound, findUsosWork(disk.reader()));
}

test "a second USOS_DATA entry is ambiguous and a bad entry array CRC wins" {
    var disk = TestDisk{};
    disk.putEntry(3, &basic_data_type_guid_disk, &usos_data_name, 40, 45);
    disk.putEntry(90, &basic_data_type_guid_disk, &usos_data_name, 46, 50);
    disk.seal();
    try tstd.testing.expectError(error.UsosDataAmbiguous, findUsosData(disk.reader()));
    // Corrupt an entry after sealing: the CRC error is reported first.
    disk.bytes[2 * sector_bytes + 90 * entry_bytes + 32] ^= 0xff;
    try tstd.testing.expectError(error.InvalidEntryArrayCRC, findUsosData(disk.reader()));
}

test "an entry outside the usable range is rejected" {
    var disk = TestDisk{};
    disk.putEntry(1, &esp_type_guid_disk, &usos_esp_name, 10, 20);
    disk.seal();
    try tstd.testing.expectError(error.InvalidEntryArray, findUsosEsp(disk.reader()));
}
