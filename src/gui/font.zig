//! USOS boot font pack (src/gui/fonts/usos-font.bin, written by
//! tools/usos_font_gen.py from Roboto + a Noto Sans symbol subset, see
//! assets/fonts/README.md). Glyphs are 4-bit alpha coverage bitmaps in two
//! natively rasterized tiers (1x and 1.5x) of four text roles.
const std = @import("std");

pub const magic = "USOSFONT";
pub const version: u16 = 1;
pub const header_size: usize = 32;
const face_record: usize = 16;
const metrics_record: usize = 8;
pub const max_faces: usize = 8;
pub const max_pack_bytes: usize = 2 * 1024 * 1024;

pub const Role = enum(u8) { small = 0, body = 1, strong = 2, heading = 3 };
pub const role_count = 4;
pub const tier_count = 2;

pub const ParseError = error{ TooShort, TooLarge, BadMagic, UnsupportedVersion, LengthMismatch, ChecksumMismatch, BadLayout };

pub const Glyph = struct {
    width: u8,
    height: u8,
    left: i8,
    top: i8,
    advance: u8,
    /// Two pixels per byte, high nibble first, rows packed without padding.
    bitmap: []const u8,

    pub fn coverage(self: Glyph, x: u32, y: u32) u8 {
        const index: usize = @as(usize, y) * self.width + x;
        const byte = self.bitmap[index / 2];
        return if (index % 2 == 0) byte >> 4 else byte & 0x0F;
    }
};

pub const Face = struct {
    pack: *const Pack,
    size: u8,
    ascent: u8,
    descent: u8,
    line_height: u8,
    metrics: []const u8,
    bitmaps: []const u8,

    pub fn glyph(self: Face, codepoint: u21) ?Glyph {
        const index = self.pack.indexOf(codepoint) orelse return null;
        return self.glyphAt(index);
    }

    fn glyphAt(self: Face, index: usize) ?Glyph {
        const record = self.metrics[index * metrics_record ..][0..metrics_record];
        const width = record[0];
        const height = record[1];
        const offset: usize = @as(usize, record[5]) | (@as(usize, record[6]) << 8) | (@as(usize, record[7]) << 16);
        const bytes = (@as(usize, width) * height + 1) / 2;
        if (offset + bytes > self.bitmaps.len) return null;
        return .{
            .width = width,
            .height = height,
            .left = @bitCast(record[2]),
            .top = @bitCast(record[3]),
            .advance = record[4],
            .bitmap = self.bitmaps[offset .. offset + bytes],
        };
    }
};

const FaceInfo = struct {
    present: bool = false,
    size: u8 = 0,
    ascent: u8 = 0,
    descent: u8 = 0,
    line_height: u8 = 0,
    metrics_offset: u32 = 0,
    bitmap_offset: u32 = 0,
    bitmap_end: u32 = 0,
};

pub const Pack = struct {
    payload: []const u8,
    glyph_count: u16,
    faces: [tier_count][role_count]FaceInfo,

    /// Validates the header, CRC and every face/glyph bound. The bytes must
    /// outlive the pack.
    pub fn parse(bytes: []const u8) ParseError!Pack {
        if (bytes.len < header_size) return error.TooShort;
        if (bytes.len > max_pack_bytes) return error.TooLarge;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadMagic;
        if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.UnsupportedVersion;
        const face_count = std.mem.readInt(u16, bytes[10..12], .little);
        const payload = bytes[header_size..];
        if (std.mem.readInt(u32, bytes[12..16], .little) != payload.len) return error.LengthMismatch;
        if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, bytes[16..20], .little)) return error.ChecksumMismatch;
        const glyph_count = std.mem.readInt(u16, bytes[20..22], .little);
        if (glyph_count == 0 or face_count == 0 or face_count > max_faces) return error.BadLayout;

        var codepoints_len: usize = @as(usize, glyph_count) * 2;
        codepoints_len = (codepoints_len + 3) & ~@as(usize, 3);
        const faces_offset = codepoints_len;
        if (faces_offset + @as(usize, face_count) * face_record > payload.len) return error.BadLayout;

        var pack = Pack{ .payload = payload, .glyph_count = glyph_count, .faces = undefined };
        for (&pack.faces) |*tier| tier.* = [_]FaceInfo{.{}} ** role_count;

        var previous: u16 = 0;
        for (0..glyph_count) |index| {
            const codepoint = std.mem.readInt(u16, payload[index * 2 ..][0..2], .little);
            if (index > 0 and codepoint <= previous) return error.BadLayout;
            previous = codepoint;
        }

        var starts: [max_faces]u32 = undefined;
        for (0..face_count) |index| {
            const record = payload[faces_offset + index * face_record ..][0..face_record];
            starts[index] = std.mem.readInt(u32, record[8..12], .little);
        }
        for (0..face_count) |index| {
            const record = payload[faces_offset + index * face_record ..][0..face_record];
            const role = record[0];
            const tier = record[1];
            if (role >= role_count or tier >= tier_count) return error.BadLayout;
            const metrics_offset = std.mem.readInt(u32, record[8..12], .little);
            const bitmap_offset = std.mem.readInt(u32, record[12..16], .little);
            const metrics_end = @as(usize, metrics_offset) + @as(usize, glyph_count) * metrics_record;
            if (metrics_end > bitmap_offset or bitmap_offset > payload.len) return error.BadLayout;
            var bitmap_end: u32 = @intCast(payload.len);
            for (starts[0..face_count]) |start| {
                if (start > bitmap_offset and start < bitmap_end) bitmap_end = start;
            }
            const info = FaceInfo{
                .present = true,
                .size = record[2],
                .ascent = record[3],
                .descent = record[4],
                .line_height = record[5],
                .metrics_offset = metrics_offset,
                .bitmap_offset = bitmap_offset,
                .bitmap_end = bitmap_end,
            };
            if (info.line_height == 0 or info.ascent == 0) return error.BadLayout;
            // Every glyph bitmap must lie inside its face's bitmap region.
            const metrics = payload[metrics_offset..metrics_end];
            for (0..glyph_count) |glyph_index| {
                const glyph_record = metrics[glyph_index * metrics_record ..][0..metrics_record];
                const offset: usize = @as(usize, glyph_record[5]) | (@as(usize, glyph_record[6]) << 8) | (@as(usize, glyph_record[7]) << 16);
                const glyph_bytes = (@as(usize, glyph_record[0]) * glyph_record[1] + 1) / 2;
                if (bitmap_offset + offset + glyph_bytes > bitmap_end) return error.BadLayout;
            }
            pack.faces[tier][role] = info;
        }
        for (0..role_count) |role| {
            if (!pack.faces[0][role].present) return error.BadLayout;
        }
        return pack;
    }

    pub fn indexOf(self: *const Pack, codepoint: u21) ?usize {
        if (codepoint > 0xFFFF) return null;
        const wanted: u16 = @intCast(codepoint);
        var low: usize = 0;
        var high: usize = self.glyph_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const value = std.mem.readInt(u16, self.payload[middle * 2 ..][0..2], .little);
            if (value == wanted) return middle;
            if (value < wanted) low = middle + 1 else high = middle;
        }
        return null;
    }

    pub fn has(self: *const Pack, codepoint: u21) bool {
        return self.indexOf(codepoint) != null;
    }

    pub fn hasTier(self: *const Pack, tier: u1) bool {
        return self.faces[tier][@intFromEnum(Role.body)].present;
    }

    /// The face for a role; tier 1 falls back to tier 0 when it is absent.
    pub fn face(self: *const Pack, role: Role, tier: u1) Face {
        var info = self.faces[tier][@intFromEnum(role)];
        if (!info.present) info = self.faces[0][@intFromEnum(role)];
        const metrics_end = info.metrics_offset + @as(u32, self.glyph_count) * metrics_record;
        return .{
            .pack = self,
            .size = info.size,
            .ascent = info.ascent,
            .descent = info.descent,
            .line_height = info.line_height,
            .metrics = self.payload[info.metrics_offset..metrics_end],
            .bitmaps = self.payload[info.bitmap_offset..info.bitmap_end],
        };
    }
};

/// Adapter for lang_file.Coverage.
pub fn coverageHas(context: *const anyopaque, codepoint: u21) bool {
    const pack: *const Pack = @ptrCast(@alignCast(context));
    return pack.has(codepoint);
}

test "committed font pack parses and covers the UI alphabets" {
    const bytes = @embedFile("fonts/usos-font.bin");
    const pack = try Pack.parse(bytes);
    for ("Universal Service OS 0123456789") |byte| try std.testing.expect(pack.has(byte));
    for ([_]u21{ 0x0105, 0x0142, 0x017C, 0x0151, 0x0219, 0x03B1, 0x0416, 0x0436, 0x0454, 0x2192 }) |codepoint| {
        try std.testing.expect(pack.has(codepoint));
    }
    try std.testing.expect(!pack.has(0x4E00));
    const body = pack.face(.body, 0);
    const glyph = body.glyph('A').?;
    try std.testing.expect(glyph.width > 4 and glyph.height > 8 and glyph.advance > 4);
    try std.testing.expect(pack.face(.heading, 1).size > pack.face(.heading, 0).size);
}

test "corrupted font packs are rejected" {
    const good = @embedFile("fonts/usos-font.bin");
    var bad: [good.len]u8 = good.*;
    bad[good.len - 3] ^= 0x55;
    try std.testing.expectError(error.ChecksumMismatch, Pack.parse(&bad));
    try std.testing.expectError(error.TooShort, Pack.parse(good[0..16]));
    try std.testing.expectError(error.LengthMismatch, Pack.parse(good[0 .. good.len - 1]));
}
