//! /usos/iso.map: where the selected ISO file lies on the USOS disk, written
//! by the UEFI menu / BIOS Core into the generated cpio and read by the static
//! helper /usos/init inside the distro initramfs (docs/design/linux-iso-boot.md
//! section 3). Text, no secrets:
//!
//!   usos-iso-map 1
//!   size <iso bytes>
//!   crc <crc32 of ISO bytes 32768..34815>
//!   extent <first disk LBA, 512-byte sectors> <sector count>
//!
//! Every number is lowercase hexadecimal without prefix (written with shifts
//! only: the i386 BIOS Core has no 64-bit division).
//!   ...
//!
//! No allocator; fixed capacity.
const std = @import("std");

pub const max_extents: usize = 64;
/// ISO9660 primary volume descriptor: sector 16 of 2048 bytes.
pub const pvd_offset: u64 = 16 * 2048;
pub const pvd_bytes: usize = 2048;

pub const Extent = struct {
    lba: u64,
    sectors: u64,
};

pub const Map = struct {
    size: u64 = 0,
    crc: u32 = 0,
    extents: [max_extents]Extent = undefined,
    len: usize = 0,

    pub fn append(self: *Map, lba: u64, sectors: u64) error{TooFragmented}!void {
        if (sectors == 0) return;
        if (self.len != 0) {
            const last = &self.extents[self.len - 1];
            if (last.lba + last.sectors == lba) {
                last.sectors += sectors;
                return;
            }
        }
        if (self.len == max_extents) return error.TooFragmented;
        self.extents[self.len] = .{ .lba = lba, .sectors = sectors };
        self.len += 1;
    }

    pub fn slice(self: *const Map) []const Extent {
        return self.extents[0..self.len];
    }

    pub fn totalSectors(self: *const Map) u64 {
        var total: u64 = 0;
        for (self.slice()) |extent| total += extent.sectors;
        return total;
    }

    /// Disk byte offset of an ISO byte offset (null: outside the map).
    pub fn diskOffset(self: *const Map, iso_offset: u64) ?u64 {
        var base: u64 = 0;
        for (self.slice()) |extent| {
            const bytes = extent.sectors * 512;
            if (iso_offset < base + bytes) return extent.lba * 512 + (iso_offset - base);
            base += bytes;
        }
        return null;
    }

    pub fn write(self: *const Map, out: []u8) error{NoSpaceLeft}![]const u8 {
        var w = HexWriter{ .out = out };
        try w.text("usos-iso-map 1\nsize ");
        try w.hex(self.size);
        try w.text("\ncrc ");
        try w.hex(self.crc);
        try w.text("\n");
        for (self.slice()) |extent| {
            try w.text("extent ");
            try w.hex(extent.lba);
            try w.text(" ");
            try w.hex(extent.sectors);
            try w.text("\n");
        }
        return out[0..w.len];
    }
};

const HexWriter = struct {
    out: []u8,
    len: usize = 0,

    fn text(self: *HexWriter, bytes: []const u8) error{NoSpaceLeft}!void {
        if (self.out.len - self.len < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.out[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn hex(self: *HexWriter, value: u64) error{NoSpaceLeft}!void {
        var digits: [16]u8 = undefined;
        var n: usize = 0;
        var v = value;
        while (true) {
            digits[n] = "0123456789abcdef"[@as(usize, @intCast(v & 0xf))];
            n += 1;
            v >>= 4;
            if (v == 0) break;
        }
        if (self.out.len - self.len < n) return error.NoSpaceLeft;
        for (0..n) |i| self.out[self.len + i] = digits[n - 1 - i];
        self.len += n;
    }
};

pub const ParseError = error{ InvalidIsoMap, TooFragmented };

pub fn parse(text: []const u8) ParseError!Map {
    var map = Map{};
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const header = lines.next() orelse return error.InvalidIsoMap;
    if (!std.mem.eql(u8, header, "usos-iso-map 1")) return error.InvalidIsoMap;
    var have_size = false;
    var have_crc = false;
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const key = words.next() orelse continue;
        if (std.mem.eql(u8, key, "size")) {
            map.size = number(words.next(), 16) orelse return error.InvalidIsoMap;
            have_size = true;
        } else if (std.mem.eql(u8, key, "crc")) {
            const value = number(words.next(), 16) orelse return error.InvalidIsoMap;
            map.crc = std.math.cast(u32, value) orelse return error.InvalidIsoMap;
            have_crc = true;
        } else if (std.mem.eql(u8, key, "extent")) {
            const lba = number(words.next(), 16) orelse return error.InvalidIsoMap;
            const sectors = number(words.next(), 16) orelse return error.InvalidIsoMap;
            if (sectors == 0) return error.InvalidIsoMap;
            if (map.len == max_extents) return error.TooFragmented;
            map.extents[map.len] = .{ .lba = lba, .sectors = sectors };
            map.len += 1;
        }
    }
    if (!have_size or !have_crc or map.len == 0 or map.totalSectors() * 512 < map.size) return error.InvalidIsoMap;
    if (map.diskOffset(pvd_offset + pvd_bytes - 1) == null) return error.InvalidIsoMap;
    return map;
}

fn number(word: ?[]const u8, base: u8) ?u64 {
    return std.fmt.parseInt(u64, word orelse return null, base) catch null;
}

pub fn pvdCrc(pvd: []const u8) u32 {
    return std.hash.Crc32.hash(pvd);
}

test "iso map round trip, merge of adjacent runs, disk offsets" {
    var map = Map{ .size = 80 * 512 + 100, .crc = 0x0badcafe };
    try map.append(2048, 72);
    try map.append(2120, 8); // adjacent: merged
    try map.append(9000, 1);
    try std.testing.expectEqual(@as(usize, 2), map.len);
    var buffer: [256]u8 = undefined;
    const text = try map.write(&buffer);
    try std.testing.expectEqualStrings("usos-iso-map 1\nsize a064\ncrc badcafe\nextent 800 50\nextent 2328 1\n", text);
    const back = try parse(text);
    try std.testing.expectEqual(map.size, back.size);
    try std.testing.expectEqual(map.crc, back.crc);
    try std.testing.expectEqualSlices(Extent, map.slice(), back.slice());
    try std.testing.expectEqual(@as(?u64, 2048 * 512 + 5), back.diskOffset(5));
    try std.testing.expectEqual(@as(?u64, 9000 * 512 + 1), back.diskOffset(80 * 512 + 1));
    try std.testing.expectEqual(@as(?u64, null), back.diskOffset(81 * 512));
}

test "iso map parser refuses short or broken maps" {
    try std.testing.expectError(error.InvalidIsoMap, parse(""));
    try std.testing.expectError(error.InvalidIsoMap, parse("usos-iso-map 2\n"));
    // size larger than the extents
    try std.testing.expectError(error.InvalidIsoMap, parse("usos-iso-map 1\nsize fffff\ncrc 1\nextent a 64\n"));
    // PVD not covered
    try std.testing.expectError(error.InvalidIsoMap, parse("usos-iso-map 1\nsize 200\ncrc 1\nextent a 1\n"));
    const ok = try parse("usos-iso-map 1\r\nsize 9000\r\ncrc ffffffff\r\nextent a 48\r\n");
    try std.testing.expectEqual(@as(u32, 0xffffffff), ok.crc);
}

test "too many extents" {
    var map = Map{};
    var i: u64 = 0;
    while (i < max_extents) : (i += 1) try map.append(i * 10, 1);
    try std.testing.expectError(error.TooFragmented, map.append(99999, 1));
}
