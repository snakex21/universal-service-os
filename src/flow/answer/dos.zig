//! MS-DOS 6.22 and Windows 1.x-3.x (installed on top of it): the regional
//! settings of an answer profile as DOS.INI, which the UEFI menu stages next
//! to the 9x / NT answers (\EFI\USOS\answer\DOS.INI) and micro-Linux turns
//! into start-file lines (tools/dos_win3_menu.sh, dos_csmwrap_target.sh):
//!
//!   CONFIG.SYS    COUNTRY=<code>,<code page>,C:\DOS\COUNTRY.SYS
//!                 DEVICE=C:\DOS\DISPLAY.SYS CON=(EGA,,1)
//!   AUTOEXEC.BAT  MODE CON CODEPAGE PREPARE=((<code page>) C:\DOS\<cpi>)
//!                 MODE CON CODEPAGE SELECT=<code page>
//!                 KEYB <layout>,,C:\DOS\<KEYBOARD.SYS|KEYBRD2.SYS> (dos_keyb)
//!
//! The way a localized MS-DOS 6.22 Setup configures a country. USOS itself
//! installs MS-DOS without its Setup (SYS + PREPDOS), so these lines are
//! the only regional answer there is; `dos_regional=manual` writes none and
//! leaves the regional text pages of Windows 3.1 Setup (Central European
//! editions: keyboard layout, code page) to the user.
//!
//! The table is the country list of the MS-DOS 6.22 COUNTRY.TXT, section 4
//! (country code, first character set, CPI file, keyboard code; checked
//! against COUNTRY.SYS, EGA*.CPI and KEYBOARD.SYS / KEYBRD2.SYS of the MS-DOS
//! 6.22 media, 2026-10-24). Languages MS-DOS 6.22 has no country for
//! (Estonian, Latvian, Lithuanian, Ukrainian) write nothing; the far-east
//! countries only COUNTRY with code page 437 (their code pages need the
//! special DOS editions).
//!
//! KEYB is off by default: MS-DOS KEYB translates scan codes in its INT 09h
//! handler; under CSMWrap SeaBIOS feeds USB keys from its timer through INT
//! 15h/4Fh straight into the BIOS buffer, so KEYB never sees them (QEMU,
//! usb-kbd without i8042, 2026-10-24). It works with a PS/2 keyboard.
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const tables = @import("tables.zig");

pub const file_name = "DOS.INI";

/// The rendered file the UEFI menu leaves for micro-Linux (one for every
/// DOS-based system: the settings do not depend on the Windows version).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "ms-dos", .file = file_name },
};

/// Catalog systems installed through the MS-DOS 6.22 path.
pub const systems = [_][]const u8{
    "ms-dos",       "windows-1-01",     "windows-1-04",     "windows-2-03", "windows-2-11-286",
    "windows-2-11-386", "windows-3-0", "windows-3-1", "windows-3-11", "windows-wfw-3-11",
};

pub fn isDos(system_id: []const u8) bool {
    for (systems) |id| {
        if (std.ascii.eqlIgnoreCase(id, system_id)) return true;
    }
    return false;
}

pub const KeybFile = enum { keyboard, keybrd2 };

pub const Country = struct {
    /// Language tag of tables.languages.
    tag: []const u8,
    /// MS-DOS country code (three digits as COUNTRY= takes it).
    code: u16,
    code_page: u16,
    /// Empty: no code page switching (437, the VGA's own).
    cpi: []const u8 = "",
    /// KEYB layout code; empty: none (US or not in MS-DOS 6.22).
    keyb: []const u8 = "",
    keyb_file: KeybFile = .keyboard,
};

pub const countries = [_]Country{
    .{ .tag = "bg-BG", .code = 359, .code_page = 855, .cpi = "EGA3.CPI", .keyb = "BG", .keyb_file = .keybrd2 },
    .{ .tag = "cs-CZ", .code = 42, .code_page = 852, .cpi = "EGA.CPI", .keyb = "CZ" },
    .{ .tag = "da-DK", .code = 45, .code_page = 850, .cpi = "EGA.CPI", .keyb = "DK" },
    .{ .tag = "de-DE", .code = 49, .code_page = 850, .cpi = "EGA.CPI", .keyb = "GR" },
    .{ .tag = "el-GR", .code = 30, .code_page = 869, .cpi = "EGA2.CPI", .keyb = "GK", .keyb_file = .keybrd2 },
    .{ .tag = "en-GB", .code = 44, .code_page = 850, .cpi = "EGA.CPI", .keyb = "UK" },
    .{ .tag = "en-US", .code = 1, .code_page = 437 },
    .{ .tag = "es-ES", .code = 34, .code_page = 850, .cpi = "EGA.CPI", .keyb = "SP" },
    .{ .tag = "es-MX", .code = 52, .code_page = 850, .cpi = "EGA.CPI", .keyb = "LA" },
    .{ .tag = "fi-FI", .code = 358, .code_page = 850, .cpi = "EGA.CPI", .keyb = "SU" },
    .{ .tag = "fr-FR", .code = 33, .code_page = 850, .cpi = "EGA.CPI", .keyb = "FR" },
    .{ .tag = "fr-CA", .code = 2, .code_page = 850, .cpi = "EGA.CPI", .keyb = "CF" },
    .{ .tag = "hr-HR", .code = 384, .code_page = 852, .cpi = "EGA.CPI", .keyb = "YU" },
    .{ .tag = "hu-HU", .code = 36, .code_page = 852, .cpi = "EGA.CPI", .keyb = "HU" },
    .{ .tag = "it-IT", .code = 39, .code_page = 850, .cpi = "EGA.CPI", .keyb = "IT" },
    .{ .tag = "ja-JP", .code = 81, .code_page = 437 },
    .{ .tag = "ko-KR", .code = 82, .code_page = 437 },
    .{ .tag = "nb-NO", .code = 47, .code_page = 850, .cpi = "EGA.CPI", .keyb = "NO" },
    .{ .tag = "nl-NL", .code = 31, .code_page = 850, .cpi = "EGA.CPI", .keyb = "NL" },
    .{ .tag = "pl-PL", .code = 48, .code_page = 852, .cpi = "EGA.CPI", .keyb = "PL" },
    .{ .tag = "pt-BR", .code = 55, .code_page = 850, .cpi = "EGA.CPI", .keyb = "BR" },
    .{ .tag = "pt-PT", .code = 351, .code_page = 850, .cpi = "EGA.CPI", .keyb = "PO" },
    .{ .tag = "ro-RO", .code = 40, .code_page = 852, .cpi = "EGA.CPI", .keyb = "RO", .keyb_file = .keybrd2 },
    .{ .tag = "ru-RU", .code = 7, .code_page = 866, .cpi = "EGA3.CPI", .keyb = "RU", .keyb_file = .keybrd2 },
    .{ .tag = "sk-SK", .code = 421, .code_page = 852, .cpi = "EGA.CPI", .keyb = "SL" },
    .{ .tag = "sl-SI", .code = 386, .code_page = 852, .cpi = "EGA.CPI", .keyb = "YU" },
    .{ .tag = "sr-Latn-RS", .code = 38, .code_page = 852, .cpi = "EGA.CPI", .keyb = "YU" },
    .{ .tag = "sv-SE", .code = 46, .code_page = 850, .cpi = "EGA.CPI", .keyb = "SV" },
    .{ .tag = "tr-TR", .code = 90, .code_page = 857, .cpi = "EGA2.CPI", .keyb = "TR", .keyb_file = .keybrd2 },
    .{ .tag = "zh-CN", .code = 86, .code_page = 437 },
    .{ .tag = "zh-TW", .code = 886, .code_page = 437 },
};

pub fn countryFor(tag: []const u8) ?*const Country {
    for (&countries) |*c| {
        if (std.ascii.eqlIgnoreCase(c.tag, tag)) return c;
    }
    return null;
}

/// The layout of an input profile (LLLL:KKKKKKKK): the country whose
/// language has that keyboard, else whose language id matches.
fn keyboardCountry(k: profile_mod.Keyboard) ?*const Country {
    for (tables.languages) |entry| {
        if (entry.keyboard == k.klid) if (countryFor(entry.tag)) |c| return c;
    }
    for (tables.languages) |entry| {
        if (entry.lcid == k.lcid) if (countryFor(entry.tag)) |c| return c;
    }
    return null;
}

pub const Settings = struct {
    country: ?*const Country = null,
    /// KEYB layout and file; null: no KEYB line.
    keyb: ?*const Country = null,
};

/// What `auto` writes for the profile (manual: nothing).
pub fn settings(p: *const Profile) Settings {
    if (p.dos_regional == .manual) return .{};
    const locale = p.localeEntry() orelse return .{};
    const country = countryFor(locale.tag) orelse return .{};
    var out: Settings = .{ .country = country };
    if (p.dos_keyb) {
        if (p.inputProfile()) |k| if (keyboardCountry(k)) |kc| {
            // KEYB needs the layout's code page prepared on the console:
            // only a layout of the same code page (or none).
            if (kc.keyb.len > 0 and kc.code_page == country.code_page) out.keyb = kc;
        };
    }
    return out;
}

/// DOS.INI (CRLF): `mode=auto|manual`, then for auto the values the shell
/// writes into the start files. Keys without a value are left out.
pub fn render(p: *const Profile, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; USOS MS-DOS / Windows 1.x-3.x regional settings (src/flow/answer/dos.zig)\r\n");
    try w.writeAll("[dos]\r\n");
    try w.print("mode={s}\r\n", .{@tagName(p.dos_regional)});
    const s = settings(p);
    if (s.country) |c| {
        try w.print("country={d:0>3}\r\ncodepage={d}\r\n", .{ c.code, c.code_page });
        if (c.cpi.len > 0) try w.print("cpi={s}\r\n", .{c.cpi});
    }
    if (s.keyb) |k| try w.print("keyb={s}\r\nkeybfile={s}\r\n", .{ k.keyb, if (k.keyb_file == .keybrd2) "KEYBRD2.SYS" else "KEYBOARD.SYS" });
    return w.buffered();
}

test "every country row names a known language" {
    for (countries) |c| try std.testing.expect(tables.language(c.tag) != null);
    // Every language of the table: either a country row or one of the four
    // MS-DOS 6.22 has none for.
    for (tables.languages) |entry| {
        if (countryFor(entry.tag) == null) {
            var known = false;
            for ([_][]const u8{ "et-EE", "lt-LT", "lv-LV", "uk-UA" }) |none| known = known or std.mem.eql(u8, none, entry.tag);
            try std.testing.expect(known);
        }
    }
    // Code pages and CPI files as the MS-DOS 6.22 media carries them.
    for (countries) |c| {
        if (c.cpi.len == 0) {
            try std.testing.expectEqual(@as(u16, 437), c.code_page);
            continue;
        }
        const in_ega = switch (c.code_page) {
            437, 850, 852, 860, 863, 865 => true,
            else => false,
        };
        if (std.mem.eql(u8, c.cpi, "EGA.CPI")) try std.testing.expect(in_ega);
        if (std.mem.eql(u8, c.cpi, "EGA2.CPI")) try std.testing.expect(c.code_page == 857 or c.code_page == 869 or c.code_page == 861 or c.code_page == 737);
        if (std.mem.eql(u8, c.cpi, "EGA3.CPI")) try std.testing.expect(c.code_page == 855 or c.code_page == 866);
    }
}

fn profileFrom(text: []const u8) !Profile {
    var p: Profile = .{};
    if (profile_mod.parse(text, &p) != .ok) return error.Parse;
    return p;
}

test "Polish profile: COUNTRY 048, code page 852, KEYB PL only with dos_keyb" {
    var buffer: [512]u8 = undefined;
    const pl = try profileFrom("name=Dom\nuser=Jan\nlanguage=pl-PL\n");
    try std.testing.expectEqualStrings("; USOS MS-DOS / Windows 1.x-3.x regional settings (src/flow/answer/dos.zig)\r\n[dos]\r\nmode=auto\r\ncountry=048\r\ncodepage=852\r\ncpi=EGA.CPI\r\n", try render(&pl, &buffer));
    const keyb = try profileFrom("name=Dom\nuser=Jan\nlanguage=pl-PL\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&keyb, &buffer), "cpi=EGA.CPI\r\nkeyb=PL\r\nkeybfile=KEYBOARD.SYS\r\n"));
    const manual = try profileFrom("name=Dom\nuser=Jan\nlanguage=pl-PL\ndos_regional=manual\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&manual, &buffer), "[dos]\r\nmode=manual\r\n"));
}

test "formats and keyboard: locale wins, KEYB only for a layout of the same code page" {
    var buffer: [512]u8 = undefined;
    // English UI, Polish formats, Polish keyboard.
    const mixed = try profileFrom("name=A\nuser=B\nlanguage=en-US\nlocale=pl-PL\nkeyboard=0415:00000415\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.indexOf(u8, try render(&mixed, &buffer), "country=048\r\ncodepage=852\r\ncpi=EGA.CPI\r\nkeyb=PL\r\n") != null);
    // Polish formats with a German keyboard: 850 layout on an 852 console, no KEYB.
    const german = try profileFrom("name=A\nuser=B\nlocale=pl-PL\nkeyboard=0407:00000407\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.indexOf(u8, try render(&german, &buffer), "keyb=") == null);
    // US: COUNTRY 001 / 437, no code page switching, no KEYB.
    const us = try profileFrom("name=A\nuser=B\nlanguage=en-US\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&us, &buffer), "country=001\r\ncodepage=437\r\n"));
    // Russian: KEYBRD2.SYS and EGA3.CPI.
    const ru = try profileFrom("name=A\nuser=B\nlanguage=ru-RU\ndos_keyb=yes\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&ru, &buffer), "country=007\r\ncodepage=866\r\ncpi=EGA3.CPI\r\nkeyb=RU\r\nkeybfile=KEYBRD2.SYS\r\n"));
    // No language: nothing but the mode; Ukrainian: no MS-DOS 6.22 country.
    const auto_lang = try profileFrom("name=A\nuser=B\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&auto_lang, &buffer), "mode=auto\r\n"));
    const uk = try profileFrom("name=A\nuser=B\nlanguage=uk-UA\n");
    try std.testing.expect(std.mem.endsWith(u8, try render(&uk, &buffer), "mode=auto\r\n"));
}

test "DOS systems" {
    try std.testing.expect(isDos("ms-dos") and isDos("windows-3-1") and isDos("windows-wfw-3-11") and isDos("windows-1-01"));
    try std.testing.expect(!isDos("windows-95") and !isDos("freedos"));
}
