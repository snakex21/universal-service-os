//! Built-in menu themes, chosen with `theme=<name>` in usos-settings.ini
//! (any section; the installer keeps the key when it rewrites the file).
//! "default" is the USOS palette (Theme{} field defaults), pixel-identical
//! to the menu before themes existed. Every theme here meets the rules in
//! theme_contrast.zig (checked by the tests below). A name that is not
//! built in may be a user theme (DATA\Themes\<name>\theme.ini,
//! theme_file.zig); the platform decides whether it can read one.
const std = @import("std");
const Color = @import("color.zig").Color;
const Theme = @import("theme.zig").Theme;

pub const setting_key = "theme";
/// Longest theme name accepted (built-in or a user theme folder).
pub const max_name_len = 32;

pub const Preset = struct {
    name: []const u8,
    theme: Theme,
};

fn rgb(comptime hex: *const [7]u8) Color {
    return comptime Color.fromHex(hex) orelse @compileError("bad colour " ++ hex);
}

/// Neutral graphite with a soft blue accent.
const dark = Theme{
    .background = rgb("#0a0a0a"),
    .header = rgb("#121212"),
    .panel = rgb("#161616"),
    .panel_alt = rgb("#222222"),
    .field = rgb("#0e0e0e"),
    .text = rgb("#f2f2f2"),
    .muted = rgb("#a8a8a8"),
    .faint = rgb("#7a7a7a"),
    .accent = rgb("#8ab4f8"),
    .accent_pressed = rgb("#6d9eeb"),
    .accent_soft = rgb("#1d3050"),
    .on_accent = rgb("#0a0f1a"),
    .selected = rgb("#2d4a7a"),
    .border = rgb("#2e2e2e"),
    .border_strong = rgb("#4a4a4a"),
    .disabled = rgb("#262626"),
    .disabled_text = rgb("#6e6e6e"),
    .danger = rgb("#f07070"),
    .danger_soft = rgb("#3a1b1a"),
    .warning = rgb("#fdd663"),
    .warning_soft = rgb("#332a10"),
    .success = rgb("#81c995"),
    .success_soft = rgb("#16301f"),
    .pad_x = rgb("#5e97f6"),
    .on_pad = rgb("#0a0a0a"),
};

/// Dark text on light grey and white panels.
const light = Theme{
    .background = rgb("#eef1f5"),
    .header = rgb("#ffffff"),
    .panel = rgb("#ffffff"),
    .panel_alt = rgb("#e6ebf1"),
    .field = rgb("#ffffff"),
    .text = rgb("#111827"),
    .muted = rgb("#4b5563"),
    .faint = rgb("#6b7280"),
    .accent = rgb("#0b5cb8"),
    .accent_pressed = rgb("#094a94"),
    .accent_soft = rgb("#d6e6f8"),
    .on_accent = rgb("#ffffff"),
    .selected = rgb("#c7dcf5"),
    .border = rgb("#d0d7de"),
    .border_strong = rgb("#8c96a0"),
    .disabled = rgb("#e5e7eb"),
    .disabled_text = rgb("#80878f"),
    .danger = rgb("#c62828"),
    .danger_soft = rgb("#fbe4e4"),
    .warning = rgb("#8a5a00"),
    .warning_soft = rgb("#fdf1d6"),
    .success = rgb("#1a7f37"),
    .success_soft = rgb("#dcf3e2"),
    .pad_x = rgb("#1f6feb"),
    .on_pad = rgb("#ffffff"),
};

/// Accessibility: white on black, yellow selection, strong borders.
const high_contrast = Theme{
    .background = rgb("#000000"),
    .header = rgb("#000000"),
    .panel = rgb("#000000"),
    .panel_alt = rgb("#1f1f1f"),
    .field = rgb("#000000"),
    .text = rgb("#ffffff"),
    .muted = rgb("#e6e6e6"),
    .faint = rgb("#c8c8c8"),
    .accent = rgb("#ffff00"),
    .accent_pressed = rgb("#e6e600"),
    .accent_soft = rgb("#383800"),
    .on_accent = rgb("#000000"),
    .selected = rgb("#ffff00"),
    .border = rgb("#a0a0a0"),
    .border_strong = rgb("#ffffff"),
    .disabled = rgb("#262626"),
    .disabled_text = rgb("#a8a8a8"),
    .danger = rgb("#ff6e6e"),
    .danger_soft = rgb("#3d0000"),
    .warning = rgb("#ffb000"),
    .warning_soft = rgb("#332300"),
    .success = rgb("#3dff7a"),
    .success_soft = rgb("#00300f"),
    .pad_x = rgb("#4da3ff"),
    .on_pad = rgb("#000000"),
};

/// Classic BIOS setup look: white and yellow on VGA blue.
const retro = Theme{
    .background = rgb("#0000aa"),
    .header = rgb("#00007a"),
    .panel = rgb("#0000aa"),
    .panel_alt = rgb("#1c1cc0"),
    .field = rgb("#000080"),
    .text = rgb("#ffffff"),
    .muted = rgb("#c8c8c8"),
    .faint = rgb("#9a9ae0"),
    .accent = rgb("#ffff55"),
    .accent_pressed = rgb("#e0e040"),
    .accent_soft = rgb("#000050"),
    .on_accent = rgb("#000080"),
    .selected = rgb("#aa0000"),
    .border = rgb("#5555ff"),
    .border_strong = rgb("#aaaaff"),
    .disabled = rgb("#202090"),
    .disabled_text = rgb("#8a8ad0"),
    .danger = rgb("#ff5555"),
    .danger_soft = rgb("#550000"),
    .warning = rgb("#ffaa00"),
    .warning_soft = rgb("#3d2800"),
    .success = rgb("#55ff55"),
    .success_soft = rgb("#004400"),
    .pad_x = rgb("#55aaff"),
    .on_pad = rgb("#000000"),
};

pub const all = [_]Preset{
    .{ .name = "default", .theme = .{} },
    .{ .name = "dark", .theme = dark },
    .{ .name = "light", .theme = light },
    .{ .name = "high-contrast", .theme = high_contrast },
    .{ .name = "retro", .theme = retro },
};

/// Index into `all` of a built-in name (case-insensitive), or null.
pub fn index(name: []const u8) ?usize {
    for (all, 0..) |preset, i| {
        if (std.ascii.eqlIgnoreCase(preset.name, name)) return i;
    }
    return null;
}

pub fn find(name: []const u8) ?Theme {
    return all[index(name) orelse return null].theme;
}

/// The `theme=` value of usos-settings.ini text (trimmed; empty when the
/// key is missing, the last one wins like the other readers).
pub fn settingValue(settings: []const u8) []const u8 {
    var result: []const u8 = "";
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), setting_key)) continue;
        result = std.mem.trim(u8, line[equals + 1 ..], " \t");
    }
    return result;
}

/// A theme name that can be written to usos-settings.ini and used as a
/// folder name: 1..max_name_len of A-Z a-z 0-9 - _ (no dots, so never a
/// path).
pub fn nameUsable(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// The built-in theme chosen by `settings`; "default" when the key is
/// missing or names no built-in theme (a user theme is resolved by the
/// platform on top of this).
pub fn fromSettings(settings: []const u8) Theme {
    return find(settingValue(settings)) orelse .{};
}

const contrast = @import("theme_contrast.zig");

test "default preset is the plain Theme" {
    try std.testing.expectEqualDeep(Theme{}, find("default").?);
    try std.testing.expectEqualDeep(Theme{}, find("DEFAULT").?);
    try std.testing.expectEqual(@as(?usize, 0), index("default"));
}

test "every built-in theme is readable" {
    for (all) |preset| {
        if (contrast.firstProblem(preset.theme)) |problem| {
            std.debug.print("theme {s}: {s}\n", .{ preset.name, problem });
            return error.UnreadableTheme;
        }
        try std.testing.expect(nameUsable(preset.name));
    }
}

test "built-in themes differ from each other" {
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            try std.testing.expect(!std.meta.eql(a.theme, b.theme));
        }
    }
}

test "theme setting is read from usos-settings.ini" {
    try std.testing.expectEqualStrings("", settingValue(""));
    try std.testing.expectEqualStrings("retro", settingValue("[ui]\r\nlanguage=pl\r\ntheme = retro \r\n"));
    try std.testing.expectEqualStrings("b", settingValue("theme=a\ntheme=b\n"));
    // Other keys that start with "theme" are not the setting.
    try std.testing.expectEqualStrings("", settingValue("theme_file=x\nthemes=y\n"));
    try std.testing.expectEqualDeep(retro, fromSettings("theme=Retro\n"));
    try std.testing.expectEqualDeep(Theme{}, fromSettings("theme=no-such-theme\n"));
    try std.testing.expectEqualDeep(Theme{}, fromSettings("language=pl\n"));
    try std.testing.expectEqualDeep(Theme{}, fromSettings("theme=\n"));
}

test "theme names are safe folder names" {
    try std.testing.expect(nameUsable("My_Theme-2"));
    try std.testing.expect(!nameUsable(""));
    try std.testing.expect(!nameUsable("..\\x"));
    try std.testing.expect(!nameUsable("a.b"));
    try std.testing.expect(!nameUsable("a b"));
    try std.testing.expect(!nameUsable("x" ** (max_name_len + 1)));
}
