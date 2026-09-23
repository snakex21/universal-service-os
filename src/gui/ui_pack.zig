//! Reader for EFI/USOS/bios-ui.bin (tools/generate_bios_ui_pack.py): the
//! 1x font tier and every built-in system icon, pre-scaled to 32x32 RGBA
//! and run-length encoded at build time. The Legacy BIOS Core loads it
//! (src/platform/bios/boot_ui.zig); the UEFI menu reads only its icons,
//! which replaces decoding a ~500 KiB 1254x1254 PNG per system row.
//!
//!   header 32 bytes: "USOSBUI1", u32 payload_len, u32 crc32(payload),
//!                    u32 font_offset, u32 font_len, u32 icons_offset,
//!                    u32 icons_len  (offsets relative to the payload)
//!   icons: u16 count, then per icon: u8 id_len, id, u16 rle_len, RLE
const std = @import("std");
const rgba_rle = @import("rgba_rle.zig");

pub const magic = "USOSBUI1";
pub const header_bytes: usize = 32;
pub const path = "\\EFI\\USOS\\bios-ui.bin";
pub const max_bytes: usize = 0x80000;
pub const icon_bytes: usize = 32 * 32 * 4;

pub const Pack = struct {
    font: []const u8,
    icons: []const u8,

    /// Decodes icon `id` into `output` (32x32 RGBA); false when the pack
    /// has no such icon or its data is corrupt.
    pub fn icon(self: Pack, id: []const u8, output: *[icon_bytes]u8) bool {
        const table = self.icons;
        if (table.len < 2) return false;
        const count = std.mem.readInt(u16, table[0..2], .little);
        var offset: usize = 2;
        for (0..count) |_| {
            if (offset + 1 > table.len) return false;
            const name_len = table[offset];
            offset += 1;
            if (offset + name_len + 2 > table.len) return false;
            const name = table[offset .. offset + name_len];
            offset += name_len;
            const rle_len = std.mem.readInt(u16, table[offset..][0..2], .little);
            offset += 2;
            if (offset + rle_len > table.len) return false;
            const rle = table[offset .. offset + rle_len];
            offset += rle_len;
            if (!std.mem.eql(u8, name, id)) continue;
            const decoded = rgba_rle.decode(rle, output) catch return false;
            return decoded.len == icon_bytes;
        }
        return false;
    }
};

/// Validates the header and CRC and returns the font and icon sections.
pub fn parse(bytes: []const u8) ?Pack {
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return null;
    const payload_len = std.mem.readInt(u32, bytes[8..12], .little);
    if (payload_len != bytes.len - header_bytes) return null;
    const payload = bytes[header_bytes..];
    if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, bytes[12..16], .little)) return null;
    const font_offset = std.mem.readInt(u32, bytes[16..20], .little);
    const font_len = std.mem.readInt(u32, bytes[20..24], .little);
    const icons_offset = std.mem.readInt(u32, bytes[24..28], .little);
    const icons_len = std.mem.readInt(u32, bytes[28..32], .little);
    if (@as(u64, font_offset) + font_len > payload.len or @as(u64, icons_offset) + icons_len > payload.len) return null;
    return .{ .font = payload[font_offset .. font_offset + font_len], .icons = payload[icons_offset .. icons_offset + icons_len] };
}

fn testPack(buffer: []u8, icons: []const u8) []const u8 {
    const font = "FONT";
    @memcpy(buffer[0..8], magic);
    const payload = buffer[header_bytes .. header_bytes + font.len + icons.len];
    @memcpy(payload[0..font.len], font);
    @memcpy(payload[font.len..], icons);
    std.mem.writeInt(u32, buffer[8..12], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buffer[12..16], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, buffer[16..20], 0, .little);
    std.mem.writeInt(u32, buffer[20..24], font.len, .little);
    std.mem.writeInt(u32, buffer[24..28], font.len, .little);
    std.mem.writeInt(u32, buffer[28..32], @intCast(icons.len), .little);
    return buffer[0 .. header_bytes + payload.len];
}

test "icons are found by id and decoded to 32x32 RGBA" {
    // One icon "a": a single run of 1024 identical pixels is 8 runs of 128.
    var table: [2 + 1 + 1 + 2 + 8 * 5]u8 = undefined;
    std.mem.writeInt(u16, table[0..2], 1, .little);
    table[2] = 1;
    table[3] = 'a';
    std.mem.writeInt(u16, table[4..6], 8 * 5, .little);
    for (0..8) |run| {
        const at = 6 + run * 5;
        table[at] = 0x80 | 127;
        @memcpy(table[at + 1 .. at + 5], &[_]u8{ 1, 2, 3, 200 });
    }
    var storage: [256]u8 = undefined;
    const bytes = testPack(&storage, &table);
    const pack = parse(bytes).?;
    try std.testing.expectEqualStrings("FONT", pack.font);
    var pixels: [icon_bytes]u8 = undefined;
    try std.testing.expect(pack.icon("a", &pixels));
    try std.testing.expectEqual(@as(u8, 200), pixels[icon_bytes - 1]);
    try std.testing.expect(!pack.icon("b", &pixels));
    var corrupt = storage;
    corrupt[header_bytes] ^= 1;
    try std.testing.expect(parse(corrupt[0..bytes.len]) == null);
}
