//! Boot UI strings: English built in (boot_strings.zig and linux_strings.zig,
//! generated from the installer catalogs) plus optional \EFI\USOS\lang.bin
//! written by the installer with ONLY the chosen language. Any missing,
//! corrupt or undrawable entry falls back to the built-in English string.
//!
//! Menu code asks for strings by Key. Text that reaches the renderer as
//! English from shared catalog code or from the micro-Linux shell scripts is
//! translated by its English value (`translate`), including simple
//! "{0} of {1} files" templates.
const std = @import("std");
pub const strings = @import("boot_strings.zig");
/// The Legacy BIOS Core (freestanding i386, fixed 256 KiB slot) never shows
/// the micro-Linux screens, so it leaves their strings out.
const with_linux_strings = !(@import("builtin").os.tag == .freestanding and @import("builtin").cpu.arch == .x86);
pub const linux_strings = if (with_linux_strings) @import("linux_strings.zig") else struct {
    pub const hashes = [_]u32{};
    pub const english = [_][]const u8{};
};
pub const Key = strings.Key;

pub const path = "\\EFI\\USOS\\lang.bin";
/// Path of lang.bin inside the micro-Linux initramfs (from lang.cpio).
pub const linux_path = "/etc/usos/lang.bin";
pub const magic = "USOSLANG";
pub const format_version: u16 = 1;
pub const header_size: usize = 28;
/// The BIOS Core keeps only the strings it shows: the generator puts them
/// first (strings.bios_count), so its tables end there. The UEFI menu and
/// usos-fb-ui keep every key.
pub const key_count = if (with_linux_strings) strings.english.len else strings.bios_count;
/// Name hashes of the kept keys.
const kept_hashes = strings.hashes[0..key_count];
pub const linux_key_count = linux_strings.english.len;
pub const max_blob_bytes: usize = 256 * 1024;

pub const ParseError = error{ TooShort, TooLarge, BadMagic, UnsupportedFormat, LengthMismatch, ChecksumMismatch, Truncated };

/// Answers whether the active boot font can draw a codepoint. Strings with a
/// codepoint it cannot draw keep English.
pub const Coverage = struct {
    context: *const anyopaque,
    has: *const fn (context: *const anyopaque, codepoint: u21) bool,

    fn covers(self: Coverage, value: []const u8) bool {
        var index: usize = 0;
        while (index < value.len) {
            const decoded = decodeUtf8(value[index..]);
            index += decoded.len;
            if (decoded.codepoint == '\n') continue;
            if (decoded.invalid or !self.has(self.context, decoded.codepoint)) return false;
        }
        return true;
    }
};

/// Built-in English (the BIOS Core: only the strings it can show).
const english_values: [key_count][]const u8 = strings.english[0..key_count].*;

comptime {
    // The BIOS strings are exactly the first bios_count keys.
    for (strings.bios, 0..) |used, index| {
        if (used != (index < strings.bios_count)) @compileError("boot_strings.zig: BIOS keys must come first (regenerate with usos-i18n-gen)");
    }
}

pub const Table = struct {
    /// The validated blob the values point into.
    blob: []const u8 = "",
    /// Offsets of each value inside `blob` (its u16 length precedes it);
    /// 0 means "use English". Compact so the BIOS Core stays small.
    values: [key_count]u32 = [_]u32{0} ** key_count,
    linux_values: [linux_key_count]u32 = [_]u32{0} ** linux_key_count,
    language: [8]u8 = [_]u8{0} ** 8,

    pub const english_only = Table{ .language = "en\x00\x00\x00\x00\x00\x00".* };

    /// Validates the whole blob before accepting any entry. The blob must
    /// outlive the table. With coverage == null (no boot font pack) every
    /// value stays English, since the fallback font draws ASCII only.
    pub fn parse(blob: []const u8, coverage: ?Coverage) ParseError!Table {
        if (blob.len < header_size) return error.TooShort;
        if (blob.len > max_blob_bytes) return error.TooLarge;
        if (!std.mem.eql(u8, blob[0..8], magic)) return error.BadMagic;
        if (std.mem.readInt(u16, blob[8..10], .little) != format_version) return error.UnsupportedFormat;
        const count = std.mem.readInt(u16, blob[10..12], .little);
        const payload_len = std.mem.readInt(u32, blob[20..24], .little);
        if (payload_len != blob.len - header_size) return error.LengthMismatch;
        const payload = blob[header_size..];
        if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, blob[24..28], .little)) return error.ChecksumMismatch;

        var table = Table{ .blob = blob };
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
            const value_offset: u32 = @intCast(header_size + offset);
            offset += value_len;
            const cover = coverage orelse continue;
            // Unknown keys (newer installer) are ignored; undrawable values stay English.
            if (!cover.covers(value)) continue;
            const hash = nameHash(name);
            if (indexOfHash(kept_hashes, hash)) |slot| {
                table.values[slot] = value_offset;
            } else if (with_linux_strings) {
                if (indexOfHash(&linux_strings.hashes, hash)) |slot| table.linux_values[slot] = value_offset;
            }
        }
        if (offset != payload.len) return error.LengthMismatch;
        return table;
    }

    /// Parses `blob`, or returns English only when it is absent or invalid.
    pub fn parseOrEnglish(blob: ?[]const u8, coverage: ?Coverage) Table {
        const bytes = blob orelse return english_only;
        return parse(bytes, coverage) catch english_only;
    }

    fn at(self: *const Table, offset: u32) ?[]const u8 {
        if (offset == 0) return null;
        const len = std.mem.readInt(u16, self.blob[offset - 2 ..][0..2], .little);
        return self.blob[offset .. offset + len];
    }

    pub fn get(self: *const Table, key: Key) []const u8 {
        const index = @intFromEnum(key);
        // A UEFI-only string in the BIOS Core: empty, as before.
        if (index >= key_count) return "";
        return self.at(self.values[index]) orelse english_values[index];
    }

    pub fn languageCode(self: *const Table) []const u8 {
        return std.mem.sliceTo(&self.language, 0);
    }

    /// `get` with {0}..{9} replaced by args, written into buffer.
    pub fn format(self: *const Table, buffer: []u8, key: Key, args: []const []const u8) []const u8 {
        return substitute(buffer, self.get(key), args);
    }

    /// Exact reverse lookup of an English catalog value (no templates, no
    /// buffer); unknown text is returned unchanged.
    pub fn lookup(self: *const Table, text: []const u8) []const u8 {
        for (english_values, 0..) |english, index| {
            if (english.len > 0 and std.mem.eql(u8, english, text)) return self.at(self.values[index]) orelse english;
        }
        for (linux_strings.english, 0..) |english, index| {
            if (std.mem.eql(u8, english, text)) return self.at(self.linux_values[index]) orelse english;
        }
        return text;
    }

    /// Translates text that arrives as its English value. Exact matches win;
    /// otherwise an English template such as "{0} of {1} files" is matched
    /// and its captures are placed into the translated template. Unknown text
    /// is returned unchanged.
    pub fn translate(self: *const Table, buffer: []u8, text: []const u8) []const u8 {
        if (text.len == 0) return text;
        const exact = self.lookup(text);
        if (exact.ptr != text.ptr) return exact;
        var captures: [3][]const u8 = undefined;
        for (linux_strings.english, 0..) |english, index| {
            const translated = self.at(self.linux_values[index]) orelse continue;
            if (std.mem.indexOfScalar(u8, english, '{') == null) continue;
            if (matchTemplate(english, text, &captures)) |count| return substitute(buffer, translated, captures[0..count]);
        }
        for (english_values, 0..) |english, index| {
            const translated = self.at(self.values[index]) orelse continue;
            if (std.mem.indexOfScalar(u8, english, '{') == null) continue;
            if (matchTemplate(english, text, &captures)) |count| return substitute(buffer, translated, captures[0..count]);
        }
        return text;
    }
};

pub fn nameHash(name: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

fn indexOfHash(hashes: []const u32, hash: u32) ?usize {
    for (hashes, 0..) |candidate, index| {
        if (candidate == hash) return index;
    }
    return null;
}

pub fn keyFromName(name: []const u8) ?Key {
    const index = indexOfHash(&strings.hashes, nameHash(name)) orelse return null;
    return @enumFromInt(index);
}

/// Replaces {0}..{9} in template with args (missing args stay as written).
pub fn substitute(buffer: []u8, template: []const u8, args: []const []const u8) []const u8 {
    var used: usize = 0;
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '{' and index + 2 < template.len and template[index + 2] == '}' and template[index + 1] >= '0' and template[index + 1] <= '9') {
            const arg = template[index + 1] - '0';
            if (arg < args.len) {
                const value = args[arg];
                const room = @min(value.len, buffer.len - used);
                @memcpy(buffer[used .. used + room], value[0..room]);
                used += room;
                index += 3;
                continue;
            }
        }
        if (used == buffer.len) break;
        buffer[used] = template[index];
        used += 1;
        index += 1;
    }
    return trimUtf8(buffer[0..used]);
}

/// Matches `text` against an English template with up to three {n}
/// placeholders separated by literal text. Returns the capture count.
fn matchTemplate(template: []const u8, text: []const u8, captures: *[3][]const u8) ?usize {
    var literals: [4][]const u8 = undefined;
    var slots: [3]u8 = undefined;
    var slot_count: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    while (index + 2 < template.len) : (index += 1) {
        if (template[index] != '{' or template[index + 2] != '}' or template[index + 1] < '0' or template[index + 1] > '2') continue;
        if (slot_count == 3) return null;
        literals[slot_count] = template[start..index];
        slots[slot_count] = template[index + 1] - '0';
        slot_count += 1;
        index += 2;
        start = index + 1;
    }
    if (slot_count == 0) return null;
    literals[slot_count] = template[start..];
    if (!std.mem.startsWith(u8, text, literals[0])) return null;
    var cursor: usize = literals[0].len;
    var found: [3][]const u8 = undefined;
    var slot: usize = 0;
    while (slot < slot_count) : (slot += 1) {
        const next = literals[slot + 1];
        const end = if (slot + 1 == slot_count)
            (if (text.len >= next.len and text.len - next.len >= cursor and std.mem.endsWith(u8, text, next)) text.len - next.len else return null)
        else if (next.len == 0)
            return null
        else
            cursor + (std.mem.indexOf(u8, text[cursor..], next) orelse return null);
        if (end <= cursor) return null;
        found[slot] = text[cursor..end];
        cursor = end + next.len;
    }
    for (0..slot_count) |position| {
        if (slots[position] >= slot_count) return null;
        captures[slots[position]] = found[position];
    }
    return slot_count;
}

pub const Decoded = struct { codepoint: u21, len: usize, invalid: bool = false };

/// Decodes one UTF-8 sequence; malformed input yields U+FFFD with length 1.
pub fn decodeUtf8(bytes: []const u8) Decoded {
    const replacement = Decoded{ .codepoint = 0xFFFD, .len = 1, .invalid = true };
    if (bytes.len == 0) return replacement;
    const first = bytes[0];
    if (first < 0x80) return .{ .codepoint = first, .len = 1 };
    const len: usize = if (first & 0xE0 == 0xC0) 2 else if (first & 0xF0 == 0xE0) 3 else if (first & 0xF8 == 0xF0) 4 else return replacement;
    if (bytes.len < len) return replacement;
    var value: u21 = @intCast(first & (@as(u8, 0x7F) >> @intCast(len)));
    for (bytes[1..len]) |byte| {
        if (byte & 0xC0 != 0x80) return replacement;
        value = (value << 6) | @as(u21, byte & 0x3F);
    }
    const minimum: u21 = switch (len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (value < minimum or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return replacement;
    return .{ .codepoint = value, .len = len };
}

/// Drops a trailing partial UTF-8 sequence left by truncation.
pub fn trimUtf8(value: []const u8) []const u8 {
    var end = value.len;
    var back: usize = 0;
    while (end > 0 and back < 4) : (back += 1) {
        const byte = value[end - 1];
        if (byte & 0x80 == 0) return value;
        if (byte & 0xC0 == 0xC0) {
            const need: usize = if (byte & 0xE0 == 0xC0) 2 else if (byte & 0xF0 == 0xE0) 3 else 4;
            return if (back + 1 >= need) value else value[0 .. end - 1];
        }
        end -= 1;
    }
    return value;
}

const test_context: u8 = 0;

fn testCoverage() Coverage {
    const Any = struct {
        fn has(context: *const anyopaque, codepoint: u21) bool {
            _ = context;
            return codepoint != 0x2603; // everything but a snowman
        }
    };
    return .{ .context = @ptrCast(&test_context), .has = Any.has };
}

test "generated English tables are consistent" {
    try std.testing.expectEqual(strings.hashes.len, strings.english.len);
    try std.testing.expectEqual(linux_strings.hashes.len, linux_strings.english.len);
    try std.testing.expectEqual(@as(u32, strings.hashes[@intFromEnum(Key.menu_title)]), nameHash("menu.title"));
    try std.testing.expectEqual(Key.menu_title, keyFromName("menu.title").?);
    const table = Table.english_only;
    try std.testing.expectEqualStrings("Starting environment", table.get(.prep_stage_1));
}

test "installer-written Polish lang.bin parses with diacritics" {
    const blob = @embedFile("testdata/lang-pl.bin");
    const table = try Table.parse(blob, testCoverage());
    try std.testing.expectEqualStrings("pl", table.languageCode());
    try std.testing.expectEqualStrings("Przygotowanie instalatora Windows", table.get(.prep_title));
    try std.testing.expectEqualStrings("Kopiowanie plików", table.get(.prep_stage_4));
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Krok 2 z 5", table.format(&buffer, .prep_step, &.{ "2", "5" }));
    // Without a font pack everything stays English.
    const plain = try Table.parse(blob, null);
    try std.testing.expectEqualStrings("Copying files", plain.get(.prep_stage_4));
}

test "reverse lookup translates catalog and script English, including templates" {
    const blob = @embedFile("testdata/lang-pl.bin");
    const table = try Table.parse(blob, testCoverage());
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Weryfikacja liczby plików", table.translate(&buffer, "Verifying file count"));
    try std.testing.expectEqualStrings("12 z 40 plików", table.translate(&buffer, "12 of 40 files"));
    try std.testing.expectEqualStrings("WINDOWS XP - wybierz dysk", table.translate(&buffer, "WINDOWS XP - SELECT DISK"));
    try std.testing.expectEqualStrings("Automatycznie (ISO)", table.translate(&buffer, "Automatic (ISO)"));
    try std.testing.expectEqualStrings("not a catalog string", table.translate(&buffer, "not a catalog string"));
    const english = Table.english_only;
    try std.testing.expectEqualStrings("12 of 40 files", english.translate(&buffer, "12 of 40 files"));
}

test "corrupt or missing lang.bin falls back to built-in English" {
    const good = @embedFile("testdata/lang-pl.bin");
    var bad: [good.len]u8 = good.*;
    bad[bad.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, Table.parse(&bad, testCoverage()));
    try std.testing.expectError(error.TooShort, Table.parse(good[0..10], testCoverage()));
    try std.testing.expectError(error.LengthMismatch, Table.parse(good[0 .. good.len - 1], testCoverage()));
    var wrong_magic: [good.len]u8 = good.*;
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, Table.parse(&wrong_magic, testCoverage()));
    const fallback = Table.parseOrEnglish(&bad, testCoverage());
    try std.testing.expectEqualStrings("Preparing Windows installer", fallback.get(.prep_title));
    try std.testing.expectEqualStrings("en", Table.parseOrEnglish(null, null).languageCode());
}

test "utf8 decoding and truncation are safe" {
    try std.testing.expectEqual(@as(u21, 0x142), decodeUtf8("ł").codepoint);
    try std.testing.expect(decodeUtf8("\xc5").invalid);
    try std.testing.expect(decodeUtf8("\xc0\x80").invalid);
    try std.testing.expectEqualStrings("ab", trimUtf8("ab\xc5"));
    try std.testing.expectEqualStrings("abł", trimUtf8("abł"));
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("zaż", substitute(&buffer, "{0}", &.{"zażółć"}));
}
