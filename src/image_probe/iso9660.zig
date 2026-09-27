const std = @import("std");
const random_access = @import("random_access.zig");

pub const FileInfo = struct {
    size: u64,
    is_directory: bool,
};

pub const Error = error{
    NotIso9660,
    InvalidIso9660,
    UnsupportedBlockSize,
};

const descriptor_sector: u64 = 16;
const descriptor_size: usize = 2048;

pub fn findPath(reader: anytype, path: []const u8) !?FileInfo {
    const current = (try findRecord(reader, path)) orelse return null;
    return .{ .size = current.size, .is_directory = current.is_directory };
}

pub fn findRecord(reader: anytype, path: []const u8) !?Record {
    var pvd: [descriptor_size]u8 = undefined;
    try random_access.readExactAt(reader, descriptor_sector * descriptor_size, &pvd);
    if (pvd[0] != 1 or !std.mem.eql(u8, pvd[1..6], "CD001")) return error.NotIso9660;

    const block_size = readLe16(pvd[128..130]);
    if (block_size < 512 or block_size > 4096 or block_size & (block_size - 1) != 0) return error.UnsupportedBlockSize;
    if (pvd[156] < 34) return error.InvalidIso9660;

    var current = recordInfo(pvd[156..]) orelse return error.InvalidIso9660;
    var remaining = std.mem.tokenizeScalar(u8, path, '/');
    while (remaining.next()) |component| {
        if (!current.is_directory) return null;
        current = (try findInDirectory(reader, block_size, current, component)) orelse return null;
    }
    return current;
}

pub const Record = struct {
    extent_lba: u32,
    size: u64,
    is_directory: bool,
    name_offset: usize = 0,
    name_len: usize = 0,
};

fn findInDirectory(reader: anytype, block_size: u16, directory: Record, wanted: []const u8) !?Record {
    var consumed: u64 = 0;
    var record_buf: [255]u8 = undefined;

    while (consumed < directory.size) {
        const absolute = @as(u64, directory.extent_lba) * block_size + consumed;
        var len_byte: [1]u8 = undefined;
        try random_access.readExactAt(reader, absolute, &len_byte);
        const record_len = len_byte[0];
        if (record_len == 0) {
            const next_block = (consumed & ~(@as(u64, block_size) - 1)) + block_size;
            if (next_block <= consumed) return error.InvalidIso9660;
            consumed = next_block;
            continue;
        }
        if (record_len < 34) return error.InvalidIso9660;
        try random_access.readExactAt(reader, absolute, record_buf[0..record_len]);
        const rec = recordInfo(record_buf[0..record_len]) orelse return error.InvalidIso9660;
        const raw_name = record_buf[rec.name_offset .. rec.name_offset + rec.name_len];
        if (!isSpecialName(raw_name)) {
            if (isoNameEquals(raw_name, wanted)) return rec;
            // Rock Ridge alternate name (Linux ISOs: long, mixed-case names).
            var rr_buffer: [255]u8 = undefined;
            if (rockRidgeName(record_buf[0..record_len], &rr_buffer)) |rr_name| {
                if (std.ascii.eqlIgnoreCase(rr_name, wanted)) return rec;
            }
        }
        consumed += record_len;
    }
    return null;
}

pub fn recordInfo(bytes: []const u8) ?Record {
    if (bytes.len < 34) return null;
    const record_len = bytes[0];
    if (record_len < 34 or record_len > bytes.len) return null;
    const name_len = bytes[32];
    if (@as(usize, 33) + name_len > record_len) return null;
    return .{
        .extent_lba = readLe32(bytes[2..6]),
        .size = readLe32(bytes[10..14]),
        .is_directory = (bytes[25] & 0x02) != 0,
        .name_offset = 33,
        .name_len = name_len,
    };
}

/// The Rock Ridge `NM` name of a directory record (SUSP entries in the
/// record's system use area; continuation areas are not followed).
pub fn rockRidgeName(record: []const u8, out: []u8) ?[]const u8 {
    if (record.len < 34) return null;
    const name_len: usize = record[32];
    var at: usize = 33 + name_len + @intFromBool(name_len % 2 == 0);
    var len: usize = 0;
    var found = false;
    while (at + 4 <= record.len) {
        const entry_len: usize = record[at + 2];
        if (entry_len < 4 or at + entry_len > record.len) break;
        if (record[at] == 'N' and record[at + 1] == 'M' and entry_len >= 5) {
            const flags = record[at + 4];
            // CURRENT/PARENT names carry no text.
            if (flags & 0x06 == 0) {
                const part = record[at + 5 .. at + entry_len];
                if (len + part.len > out.len) return null;
                @memcpy(out[len..][0..part.len], part);
                len += part.len;
                found = true;
            }
        }
        at += entry_len;
    }
    return if (found and len != 0) out[0..len] else null;
}

fn isSpecialName(name: []const u8) bool {
    return name.len == 1 and (name[0] == 0 or name[0] == 1);
}

fn isoNameEquals(raw_name: []const u8, wanted: []const u8) bool {
    var name = raw_name;
    if (std.mem.indexOfScalar(u8, name, ';')) |index| name = name[0..index];
    while (name.len > 0 and name[name.len - 1] == '.') name = name[0 .. name.len - 1];
    return std.ascii.eqlIgnoreCase(name, wanted);
}

fn readLe16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readLe32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

test "ISO9660 path matching is case-insensitive for uppercase media" {
    var image = [_]u8{0} ** (24 * descriptor_size);
    writeTestImage(&image, "SOURCES", "INSTALL.WIM;1", 123456);

    var reader = random_access.SliceReader{ .bytes = &image };
    const info = (try findPath(&reader, "sources/install.wim")).?;
    try std.testing.expectEqual(@as(u64, 123456), info.size);
    try std.testing.expect(!info.is_directory);
}

test "ISO9660 path matching is case-insensitive for lowercase media" {
    var image = [_]u8{0} ** (24 * descriptor_size);
    writeTestImage(&image, "sources", "install.wim;1", 654321);

    var reader = random_access.SliceReader{ .bytes = &image };
    const info = (try findPath(&reader, "SOURCES/INSTALL.WIM")).?;
    try std.testing.expectEqual(@as(u64, 654321), info.size);
    try std.testing.expect(!info.is_directory);
}

fn writeTestImage(image: []u8, directory_name: []const u8, file_name: []const u8, file_size: u32) void {
    const pvd = image[16 * descriptor_size .. 17 * descriptor_size];
    pvd[0] = 1;
    @memcpy(pvd[1..6], "CD001");
    std.mem.writeInt(u16, pvd[128..130], descriptor_size, .little);
    _ = writeRecord(pvd[156..], 20, descriptor_size, true, &.{0});

    const root = image[20 * descriptor_size .. 21 * descriptor_size];
    _ = writeRecord(root, 21, descriptor_size, true, directory_name);
    const sources = image[21 * descriptor_size .. 22 * descriptor_size];
    _ = writeRecord(sources, 22, file_size, false, file_name);
}

fn writeRecord(dest: []u8, extent: u32, size: u32, is_dir: bool, name: []const u8) usize {
    const padded_name_len = name.len + @intFromBool((name.len & 1) == 0);
    const len: u8 = @intCast(33 + padded_name_len);
    @memset(dest[0..len], 0);
    dest[0] = len;
    std.mem.writeInt(u32, dest[2..6], extent, .little);
    std.mem.writeInt(u32, dest[10..14], size, .little);
    dest[25] = if (is_dir) 0x02 else 0;
    dest[32] = @intCast(name.len);
    @memcpy(dest[33 .. 33 + name.len], name);
    return len;
}

test "Rock Ridge NM names are matched next to the primary name" {
    var image = [_]u8{0} ** (24 * descriptor_size);
    writeTestImage(&image, "LIVE", "VMLINUZ_.;1", 4242);
    // Append an NM entry to the file record in LIVE (extent 21).
    const live = image[21 * descriptor_size .. 22 * descriptor_size];
    const long = "vmlinuz-6.12.107+deb13-amd64";
    const base_len: usize = live[0];
    const nm_len: usize = 5 + long.len;
    live[base_len] = 'N';
    live[base_len + 1] = 'M';
    live[base_len + 2] = @intCast(nm_len);
    live[base_len + 3] = 1;
    live[base_len + 4] = 0;
    @memcpy(live[base_len + 5 ..][0..long.len], long);
    live[0] = @intCast(base_len + nm_len);
    var reader = random_access.SliceReader{ .bytes = &image };
    try std.testing.expectEqual(@as(u64, 4242), (try findPath(&reader, "live/vmlinuz-6.12.107+deb13-amd64")).?.size);
    try std.testing.expectEqual(@as(u64, 4242), (try findPath(&reader, "LIVE/VMLINUZ_")).?.size);
    try std.testing.expect((try findPath(&reader, "live/vmlinuz")) == null);
}
