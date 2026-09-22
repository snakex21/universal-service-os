//! Boot UI strings: English built in (boot_strings.zig, generated from the
//! installer catalog) plus optional \EFI\USOS\lang.bin written by the
//! installer with ONLY the chosen language. Any missing, corrupt or
//! unrenderable entry falls back to the built-in English string.
//!
//! Not wired into rendering yet: the 5x7 boot font covers printable ASCII
//! only, so Polish/Czech/German strings would fall back to English anyway.
const std = @import("std");
pub const strings = @import("boot_strings.zig");
pub const Key = strings.Key;

pub const path = "\\EFI\\USOS\\lang.bin";
pub const magic = "USOSLANG";
pub const format_version: u16 = 1;
pub const header_size: usize = 28;
const key_count = @typeInfo(Key).@"enum".fields.len;

pub const ParseError = error{ TooShort, BadMagic, UnsupportedFormat, LengthMismatch, ChecksumMismatch, Truncated };

pub const Table = struct {
    /// Borrowed slices into the blob; null means "use English".
    values: [key_count]?[]const u8 = [_]?[]const u8{null} ** key_count,
    language: [8]u8 = [_]u8{0} ** 8,

    pub const english_only = Table{ .language = "en\x00\x00\x00\x00\x00\x00".* };

    /// Validates the whole blob before accepting any entry.
    pub fn parse(blob: []const u8) ParseError!Table {
        if (blob.len < header_size) return error.TooShort;
        if (!std.mem.eql(u8, blob[0..8], magic)) return error.BadMagic;
        if (std.mem.readInt(u16, blob[8..10], .little) != format_version) return error.UnsupportedFormat;
        const count = std.mem.readInt(u16, blob[10..12], .little);
        const payload_len = std.mem.readInt(u32, blob[20..24], .little);
        if (payload_len != blob.len - header_size) return error.LengthMismatch;
        const payload = blob[header_size..];
        if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, blob[24..28], .little)) return error.ChecksumMismatch;

        var table = Table{};
        @memcpy(&table.language, blob[12..20]);
        var offset: usize = 0;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (offset + 1 > payload.len) return error.Truncated;
            const name_len = payload[offset];
            offset += 1;
            if (offset + name_len + 2 > payload.len) return error.Truncated;
            const name = payload[offset .. offset + name_len];
            offset += name_len;
            const value_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + value_len > payload.len) return error.Truncated;
            const value = payload[offset .. offset + value_len];
            offset += value_len;
            // Unknown keys (newer installer) are ignored; unrenderable values stay English.
            if (keyFromName(name)) |key| {
                if (renderable(value)) table.values[@intFromEnum(key)] = value;
            }
        }
        if (offset != payload.len) return error.LengthMismatch;
        return table;
    }

    /// Parses `blob`, or returns English only when it is absent or invalid.
    pub fn parseOrEnglish(blob: ?[]const u8) Table {
        const bytes = blob orelse return english_only;
        return parse(bytes) catch english_only;
    }

    pub fn get(self: *const Table, key: Key) []const u8 {
        return self.values[@intFromEnum(key)] orelse strings.english[@intFromEnum(key)];
    }

    pub fn languageCode(self: *const Table) []const u8 {
        return std.mem.sliceTo(&self.language, 0);
    }
};

pub fn keyFromName(name: []const u8) ?Key {
    for (strings.names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return @enumFromInt(index);
    }
    return null;
}

/// Mirrors src/gui/font5x7.zig: printable ASCII 32..126 plus newline.
pub fn renderable(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\n') continue;
        if (byte < 32 or byte > 126) return false;
    }
    return true;
}

test "generated English table matches the strings the boot UI draws today" {
    const preparation_screen = @import("../gui/preparation_screen.zig");
    const table = Table.english_only;
    const stages = [_]Key{ .prep_stage_1, .prep_stage_2, .prep_stage_3, .prep_stage_4, .prep_stage_5 };
    for (stages, preparation_screen.stage_labels) |key, label| {
        try std.testing.expectEqualStrings(label, table.get(key));
    }
    try std.testing.expectEqual(strings.names.len, strings.english.len);
    for (strings.english) |value| try std.testing.expect(renderable(value));
}

test "installer-written Polish lang.bin parses; unrenderable strings stay English" {
    const blob = @embedFile("testdata/lang-pl.bin");
    const table = try Table.parse(blob);
    try std.testing.expectEqualStrings("pl", table.languageCode());
    // Pure-ASCII Polish string is taken from the file.
    try std.testing.expectEqualStrings("PRZYGOTOWANIE INSTALATORA WINDOWS", table.get(.prep_title));
    // Diacritics (not in font5x7) fall back to the built-in English text.
    try std.testing.expectEqualStrings("COPYING FILES", table.get(.prep_stage_4));
}

test "corrupt or missing lang.bin falls back to built-in English" {
    const good = @embedFile("testdata/lang-pl.bin");
    var bad: [good.len]u8 = good.*;
    bad[bad.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, Table.parse(&bad));
    try std.testing.expectError(error.TooShort, Table.parse(good[0..10]));
    try std.testing.expectError(error.LengthMismatch, Table.parse(good[0 .. good.len - 1]));
    var wrong_magic: [good.len]u8 = good.*;
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, Table.parse(&wrong_magic));
    const fallback = Table.parseOrEnglish(&bad);
    try std.testing.expectEqualStrings("PREPARING WINDOWS INSTALLER", fallback.get(.prep_title));
    try std.testing.expectEqualStrings("en", Table.parseOrEnglish(null).languageCode());
}
