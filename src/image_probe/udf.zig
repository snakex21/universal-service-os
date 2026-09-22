const std = @import("std");
const random_access = @import("random_access.zig");

pub const FileInfo = struct {
    size: u64,
    is_directory: bool,
};

pub const Error = error{
    NotUdf,
    InvalidUdf,
    UnsupportedBlockSize,
    UnsupportedPartitionMap,
    UnsupportedAllocationDescriptors,
    TooManyExtents,
};

const sector_size: u64 = 2048;
const max_block_size: usize = 4096;
const max_partitions: usize = 8;
const max_maps: usize = 8;
const max_extents: usize = 64;

const LongAd = struct {
    length: u32,
    logical_block: u32,
    partition_ref: u16,
};

const Partition = struct {
    number: u16,
    start_sector: u32,
};

const Volume = struct {
    block_size: u32,
    partitions: [max_partitions]Partition = undefined,
    partition_count: usize = 0,
    partition_maps: [max_maps]?u16 = [_]?u16{null} ** max_maps,
    map_count: usize = 0,
    file_set: LongAd,

    fn partitionStart(self: *const Volume, partition_ref: u16) Error!u64 {
        if (partition_ref >= self.map_count) return error.InvalidUdf;
        const wanted_number = self.partition_maps[partition_ref] orelse return error.UnsupportedPartitionMap;
        for (self.partitions[0..self.partition_count]) |partition| {
            if (partition.number == wanted_number) return @as(u64, partition.start_sector) * sector_size;
        }
        return error.InvalidUdf;
    }

    fn absoluteBlock(self: *const Volume, ad: LongAd) Error!u64 {
        const start = try self.partitionStart(ad.partition_ref);
        return start + @as(u64, ad.logical_block) * self.block_size;
    }
};

const Extent = struct {
    offset: u64,
    length: u64,
};

pub const Node = struct {
    size: u64,
    is_directory: bool,
    extents: [max_extents]Extent = undefined,
    extent_count: usize = 0,
    embedded: [max_block_size]u8 = undefined,
    embedded_len: usize = 0,
};

pub fn findPath(reader: anytype, path: []const u8) !?FileInfo {
    var node: Node = undefined;
    if (!try openPath(reader, path, &node)) return null;
    return .{ .size = node.size, .is_directory = node.is_directory };
}

/// Retain the allocation descriptors so callers can stream file contents.
pub fn openPath(reader: anytype, path: []const u8, current: *Node) !bool {
    const volume = try openVolume(reader);
    const fsd = try readDescriptor(reader, try volume.absoluteBlock(volume.file_set), volume.block_size);
    if (tagId(&fsd) != 256) return error.InvalidUdf;
    const root_icb = readLongAd(fsd[400..416]);
    try readNode(reader, &volume, root_icb, current);

    var components = std.mem.tokenizeScalar(u8, path, '/');
    while (components.next()) |component| {
        if (!current.is_directory) return false;
        const child = (try findInDirectory(reader, &volume, current, component)) orelse return false;
        try readNode(reader, &volume, child.icb, current);
        current.is_directory = child.is_directory;
    }

    return true;
}

fn openVolume(reader: anytype) !Volume {
    if (!try hasUdfRecognitionSequence(reader)) return error.NotUdf;
    const anchor = try findAnchor(reader);
    const main_length = readLe32(anchor[16..20]) & 0x3fffffff;
    const main_location = readLe32(anchor[20..24]);
    if (main_length < sector_size or main_length > 1024 * 1024) return error.InvalidUdf;

    var volume: Volume = undefined;
    volume.partitions = undefined;
    volume.partition_count = 0;
    volume.partition_maps = [_]?u16{null} ** max_maps;
    volume.map_count = 0;
    volume.block_size = 0;
    volume.file_set = .{ .length = 0, .logical_block = 0, .partition_ref = 0 };

    var offset: u64 = @as(u64, main_location) * sector_size;
    const end = offset + main_length;
    var descriptor: [2048]u8 = undefined;
    while (offset + descriptor.len <= end) : (offset += descriptor.len) {
        try random_access.readExactAt(reader, offset, &descriptor);
        switch (tagId(&descriptor)) {
            5 => try parsePartitionDescriptor(&volume, &descriptor),
            6 => try parseLogicalVolumeDescriptor(&volume, &descriptor),
            8 => break,
            else => {},
        }
    }

    if (volume.block_size == 0 or volume.file_set.length == 0 or volume.partition_count == 0 or volume.map_count == 0) {
        return error.InvalidUdf;
    }
    return volume;
}

fn hasUdfRecognitionSequence(reader: anytype) !bool {
    var descriptor: [2048]u8 = undefined;
    var sector: u64 = 16;
    while (sector < 32) : (sector += 1) {
        const offset = sector * sector_size;
        if (offset + descriptor.len > reader.size()) break;
        try random_access.readExactAt(reader, offset, &descriptor);
        if (std.mem.eql(u8, descriptor[1..6], "NSR02") or std.mem.eql(u8, descriptor[1..6], "NSR03")) return true;
        if (std.mem.eql(u8, descriptor[1..6], "TEA01")) break;
    }
    return false;
}

fn findAnchor(reader: anytype) ![2048]u8 {
    const total_sectors = reader.size() / sector_size;
    const candidates = [_]u64{
        256,
        if (total_sectors > 256) total_sectors - 256 else 0,
        if (total_sectors > 0) total_sectors - 1 else 0,
    };
    for (candidates) |sector| {
        if (sector == 0 or (sector + 1) * sector_size > reader.size()) continue;
        var descriptor: [2048]u8 = undefined;
        random_access.readExactAt(reader, sector * sector_size, &descriptor) catch continue;
        if (tagId(&descriptor) == 2) return descriptor;
    }
    return error.InvalidUdf;
}

fn parsePartitionDescriptor(volume: *Volume, descriptor: []const u8) Error!void {
    if (volume.partition_count == max_partitions) return error.InvalidUdf;
    volume.partitions[volume.partition_count] = .{
        .number = readLe16(descriptor[22..24]),
        .start_sector = readLe32(descriptor[188..192]),
    };
    volume.partition_count += 1;
}

fn parseLogicalVolumeDescriptor(volume: *Volume, descriptor: []const u8) Error!void {
    const block_size = readLe32(descriptor[212..216]);
    if (block_size < 512 or block_size > max_block_size or !std.math.isPowerOfTwo(block_size)) {
        return error.UnsupportedBlockSize;
    }
    volume.block_size = block_size;
    volume.file_set = readLongAd(descriptor[248..264]);

    const map_table_length = readLe32(descriptor[264..268]);
    const number_of_maps = readLe32(descriptor[268..272]);
    if (number_of_maps > max_maps or map_table_length > descriptor.len - 440) return error.InvalidUdf;

    var map_offset: usize = 440;
    var map_index: usize = 0;
    while (map_index < number_of_maps) : (map_index += 1) {
        if (map_offset + 2 > 440 + map_table_length) return error.InvalidUdf;
        const map_type = descriptor[map_offset];
        const map_length = descriptor[map_offset + 1];
        if (map_length < 2 or map_offset + map_length > 440 + map_table_length) return error.InvalidUdf;
        if (map_type == 1 and map_length == 6) {
            volume.partition_maps[map_index] = readLe16(descriptor[map_offset + 4 .. map_offset + 6]);
        } else {
            volume.partition_maps[map_index] = null;
        }
        map_offset += map_length;
    }
    volume.map_count = number_of_maps;
}

fn readDescriptor(reader: anytype, offset: u64, block_size: u32) ![max_block_size]u8 {
    var block = [_]u8{0} ** max_block_size;
    try random_access.readExactAt(reader, offset, block[0..block_size]);
    return block;
}

fn readNode(reader: anytype, volume: *const Volume, icb: LongAd, node: *Node) !void {
    const absolute = try volume.absoluteBlock(icb);
    const block = try readDescriptor(reader, absolute, volume.block_size);
    const id = tagId(&block);
    if (id != 261 and id != 266) return error.InvalidUdf;

    const extended = id == 266;
    const information_length = readLe64(block[56..64]);
    const file_type = block[27];
    const flags = readLe16(block[34..36]);
    const ad_type = flags & 0x0007;
    const length_ea_offset: usize = if (extended) 208 else 168;
    const length_ad_offset: usize = if (extended) 212 else 172;
    const ad_start_base: usize = if (extended) 216 else 176;
    const length_ea: usize = @intCast(readLe32(block[length_ea_offset .. length_ea_offset + 4]));
    const length_ads: usize = @intCast(readLe32(block[length_ad_offset .. length_ad_offset + 4]));
    if (length_ea > volume.block_size - ad_start_base) return error.InvalidUdf;
    const ad_start = ad_start_base + length_ea;
    if (length_ads > volume.block_size - ad_start) return error.InvalidUdf;

    node.* = .{
        .size = information_length,
        .is_directory = file_type == 4,
    };

    if (ad_type == 3) {
        if (length_ads > node.embedded.len or information_length > length_ads) return error.InvalidUdf;
        @memcpy(node.embedded[0..length_ads], block[ad_start .. ad_start + length_ads]);
        node.embedded_len = length_ads;
        return;
    }

    const ad_size: usize = switch (ad_type) {
        0 => 8,
        1 => 16,
        else => return error.UnsupportedAllocationDescriptors,
    };
    if (length_ads % ad_size != 0) return error.InvalidUdf;

    var offset = ad_start;
    while (offset < ad_start + length_ads) : (offset += ad_size) {
        const encoded_length = readLe32(block[offset .. offset + 4]);
        const allocation_type = encoded_length >> 30;
        const extent_length = encoded_length & 0x3fffffff;
        if (extent_length == 0) continue;
        if (allocation_type != 0) return error.UnsupportedAllocationDescriptors;
        if (node.extent_count == max_extents) return error.TooManyExtents;

        const extent_offset = if (ad_type == 0) blk: {
            const partition_start = try volume.partitionStart(icb.partition_ref);
            const logical_block = readLe32(block[offset + 4 .. offset + 8]);
            break :blk partition_start + @as(u64, logical_block) * volume.block_size;
        } else blk: {
            const child_ad = readLongAd(block[offset .. offset + 16]);
            break :blk try volume.absoluteBlock(child_ad);
        };
        node.extents[node.extent_count] = .{ .offset = extent_offset, .length = extent_length };
        node.extent_count += 1;
    }

}

const Child = struct {
    icb: LongAd,
    is_directory: bool,
};

fn findInDirectory(reader: anytype, volume: *const Volume, directory: *const Node, wanted: []const u8) !?Child {
    var pos: u64 = 0;
    var header: [38]u8 = undefined;
    var record: [1024]u8 = undefined;

    while (pos + header.len <= directory.size) {
        try readNodeAt(reader, directory, pos, &header);
        const id = tagId(&header);
        if (id == 0) {
            const next_block = (pos | (@as(u64, volume.block_size) - 1)) + 1;
            if (next_block <= pos) return error.InvalidUdf;
            pos = next_block;
            continue;
        }
        if (id != 257) return error.InvalidUdf;

        const file_characteristics = header[18];
        const file_identifier_len: usize = header[19];
        const implementation_use_len: usize = readLe16(header[36..38]);
        const raw_len = 38 + implementation_use_len + file_identifier_len;
        const padded_len = std.mem.alignForward(usize, raw_len, 4);
        if (padded_len > record.len or pos + padded_len > directory.size) return error.InvalidUdf;
        try readNodeAt(reader, directory, pos, record[0..padded_len]);

        const deleted = (file_characteristics & 0x04) != 0;
        const parent = (file_characteristics & 0x08) != 0;
        const name = record[38 + implementation_use_len .. raw_len];
        if (!deleted and !parent and udfNameEquals(name, wanted)) {
            return .{
                .icb = readLongAd(record[20..36]),
                .is_directory = (file_characteristics & 0x02) != 0,
            };
        }
        pos += padded_len;
    }
    return null;
}

pub fn readNodeAt(reader: anytype, node: *const Node, logical_offset: u64, buffer: []u8) !void {
    if (logical_offset > node.size or buffer.len > node.size - logical_offset) return error.EndOfStream;
    if (buffer.len == 0) return;
    if (node.embedded_len != 0) {
        const start: usize = @intCast(logical_offset);
        if (start + buffer.len > node.embedded_len) return error.EndOfStream;
        @memcpy(buffer, node.embedded[start .. start + buffer.len]);
        return;
    }

    var remaining = buffer;
    var logical_cursor: u64 = 0;
    var wanted_offset = logical_offset;
    for (node.extents[0..node.extent_count]) |extent| {
        if (wanted_offset >= logical_cursor + extent.length) {
            logical_cursor += extent.length;
            continue;
        }
        const inside = wanted_offset - logical_cursor;
        const available = extent.length - inside;
        const amount: usize = @intCast(@min(@as(u64, remaining.len), available));
        try random_access.readExactAt(reader, extent.offset + inside, remaining[0..amount]);
        remaining = remaining[amount..];
        if (remaining.len == 0) return;
        wanted_offset += amount;
        logical_cursor += extent.length;
    }
    return error.EndOfStream;
}

fn udfNameEquals(encoded: []const u8, wanted: []const u8) bool {
    if (encoded.len < 1) return false;
    switch (encoded[0]) {
        8 => {
            if (encoded.len - 1 != wanted.len) return false;
            for (encoded[1..], wanted) |actual, expected| {
                if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
            }
            return true;
        },
        16 => {
            if ((encoded.len - 1) % 2 != 0 or (encoded.len - 1) / 2 != wanted.len) return false;
            var index: usize = 1;
            for (wanted) |expected| {
                if (encoded[index] != 0) return false;
                if (std.ascii.toLower(encoded[index + 1]) != std.ascii.toLower(expected)) return false;
                index += 2;
            }
            return true;
        },
        else => return false,
    }
}

fn tagId(bytes: []const u8) u16 {
    if (bytes.len < 2) return 0;
    return readLe16(bytes[0..2]);
}

fn readLongAd(bytes: []const u8) LongAd {
    return .{
        .length = readLe32(bytes[0..4]) & 0x3fffffff,
        .logical_block = readLe32(bytes[4..8]),
        .partition_ref = readLe16(bytes[8..10]),
    };
}

fn readLe16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readLe32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readLe64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

test "UDF parser returns 64-bit size and matches uppercase media case-insensitively" {
    const block: usize = 2048;
    var image = [_]u8{0} ** (308 * block);
    const expected_size: u64 = 5 * 1024 * 1024 * 1024 + 12345;
    writeTestImage(&image, "SOURCES", "INSTALL.WIM", expected_size);

    var reader = random_access.SliceReader{ .bytes = &image };
    const info = (try findPath(&reader, "sources/install.wim")).?;
    try std.testing.expectEqual(expected_size, info.size);
    try std.testing.expect(!info.is_directory);
}

test "UDF path matching is case-insensitive for lowercase media" {
    const block: usize = 2048;
    var image = [_]u8{0} ** (308 * block);
    writeTestImage(&image, "sources", "install.wim", 987654321);

    var reader = random_access.SliceReader{ .bytes = &image };
    const info = (try findPath(&reader, "SOURCES/INSTALL.WIM")).?;
    try std.testing.expectEqual(@as(u64, 987654321), info.size);
    try std.testing.expect(!info.is_directory);
}

test "UDF file content reads preserve extent order and reject truncated media" {
    var node = Node{ .size = 6, .is_directory = false, .extent_count = 2 };
    node.extents[0] = .{ .offset = 4, .length = 3 };
    node.extents[1] = .{ .offset = 12, .length = 3 };
    var reader = random_access.SliceReader{ .bytes = "xxxxabcxxxxxdef" };
    var out: [4]u8 = undefined;
    try readNodeAt(&reader, &node, 1, &out);
    try std.testing.expectEqualStrings("bcde", &out);
    try std.testing.expectError(error.EndOfStream, readNodeAt(&reader, &node, 3, &out));
    try std.testing.expectError(error.EndOfStream, readNodeAt(&reader, &node, std.math.maxInt(u64), &out));
    node.extents[1].offset = 14;
    try std.testing.expectError(error.EndOfStream, readNodeAt(&reader, &node, 2, &out));
}

test "UDF embedded files and unsupported allocation types fail predictably" {
    var image = [_]u8{0} ** (308 * 2048);
    writeTestImage(&image, "sources", "boot.wim", 3);
    const entry = image[306 * 2048..][0..2048];
    std.mem.writeInt(u16, entry[34..36], 3, .little);
    std.mem.writeInt(u32, entry[172..176], 3, .little);
    @memcpy(entry[176..179], "wim");
    var reader = random_access.SliceReader{ .bytes = &image };
    var node: Node = undefined;
    try std.testing.expect(try openPath(&reader, "sources/boot.wim", &node));
    var data: [3]u8 = undefined;
    try readNodeAt(&reader, &node, 0, &data);
    try std.testing.expectEqualStrings("wim", &data);
    std.mem.writeInt(u16, entry[34..36], 0, .little);
    std.mem.writeInt(u32, entry[172..176], 8, .little);
    std.mem.writeInt(u32, entry[176..180], 0x40000003, .little);
    try std.testing.expectError(error.UnsupportedAllocationDescriptors, openPath(&reader, "sources/boot.wim", &node));
    std.mem.writeInt(u32, entry[168..172], 0xffffffff, .little);
    try std.testing.expectError(error.InvalidUdf, openPath(&reader, "sources/boot.wim", &node));
}

fn writeTestImage(image: []u8, sources_name: []const u8, install_name: []const u8, install_size: u64) void {
    const block: usize = 2048;
    @memset(image, 0);

    const vrs = image[16 * block .. 17 * block];
    @memcpy(vrs[1..6], "NSR03");

    const anchor = image[256 * block .. 257 * block];
    std.mem.writeInt(u16, anchor[0..2], 2, .little);
    std.mem.writeInt(u32, anchor[16..20], 4 * block, .little);
    std.mem.writeInt(u32, anchor[20..24], 257, .little);

    const partition = image[257 * block .. 258 * block];
    std.mem.writeInt(u16, partition[0..2], 5, .little);
    std.mem.writeInt(u16, partition[22..24], 0, .little);
    std.mem.writeInt(u32, partition[188..192], 300, .little);

    const lvd = image[258 * block .. 259 * block];
    std.mem.writeInt(u16, lvd[0..2], 6, .little);
    std.mem.writeInt(u32, lvd[212..216], block, .little);
    writeLongAd(lvd[248..264], block, 1, 0);
    std.mem.writeInt(u32, lvd[264..268], 6, .little);
    std.mem.writeInt(u32, lvd[268..272], 1, .little);
    lvd[440] = 1;
    lvd[441] = 6;
    std.mem.writeInt(u16, lvd[442..444], 1, .little);
    std.mem.writeInt(u16, lvd[444..446], 0, .little);

    const terminating = image[259 * block .. 260 * block];
    std.mem.writeInt(u16, terminating[0..2], 8, .little);

    const fsd = image[301 * block .. 302 * block];
    std.mem.writeInt(u16, fsd[0..2], 256, .little);
    writeLongAd(fsd[400..416], block, 2, 0);

    const root_fid_len = writeFid(image[303 * block .. 304 * block], sources_name, true, 4, 0);
    writeFileEntry(image[302 * block .. 303 * block], true, root_fid_len, 3);

    const install_fid_len = writeFid(image[305 * block .. 306 * block], install_name, false, 6, 0);
    writeFileEntry(image[304 * block .. 305 * block], true, install_fid_len, 5);
    writeFileEntrySize(image[306 * block .. 307 * block], false, install_size);
}

fn writeLongAd(dest: []u8, length: u32, logical_block: u32, partition_ref: u16) void {
    @memset(dest[0..16], 0);
    std.mem.writeInt(u32, dest[0..4], length, .little);
    std.mem.writeInt(u32, dest[4..8], logical_block, .little);
    std.mem.writeInt(u16, dest[8..10], partition_ref, .little);
}

fn writeFileEntry(dest: []u8, is_directory: bool, directory_size: usize, data_block: u32) void {
    writeFileEntrySize(dest, is_directory, directory_size);
    std.mem.writeInt(u32, dest[172..176], 8, .little);
    std.mem.writeInt(u32, dest[176..180], @intCast(directory_size), .little);
    std.mem.writeInt(u32, dest[180..184], data_block, .little);
}

fn writeFileEntrySize(dest: []u8, is_directory: bool, size: u64) void {
    @memset(dest[0..2048], 0);
    std.mem.writeInt(u16, dest[0..2], 261, .little);
    dest[27] = if (is_directory) 4 else 5;
    std.mem.writeInt(u16, dest[34..36], 0, .little);
    std.mem.writeInt(u64, dest[56..64], size, .little);
    std.mem.writeInt(u32, dest[168..172], 0, .little);
    std.mem.writeInt(u32, dest[172..176], 0, .little);
}

fn writeFid(dest: []u8, name: []const u8, is_directory: bool, logical_block: u32, partition_ref: u16) usize {
    const name_len = name.len + 1;
    const raw_len = 38 + name_len;
    const len = std.mem.alignForward(usize, raw_len, 4);
    @memset(dest[0..len], 0);
    std.mem.writeInt(u16, dest[0..2], 257, .little);
    std.mem.writeInt(u16, dest[16..18], 1, .little);
    dest[18] = if (is_directory) 0x02 else 0;
    dest[19] = @intCast(name_len);
    writeLongAd(dest[20..36], 2048, logical_block, partition_ref);
    std.mem.writeInt(u16, dest[36..38], 0, .little);
    dest[38] = 8;
    @memcpy(dest[39 .. 39 + name.len], name);
    return len;
}
