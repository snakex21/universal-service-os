//! The menu theme on the micro-Linux kernel command line, so usos-fb-ui
//! (disk picker, confirmation, progress) keeps the look of the UEFI or
//! Legacy BIOS screens that started it.
//!
//!   usos.theme=<rrggbb x N>
//!
//! N is the number of colour fields of Theme (theme.zig), in declaration
//! order, with no separators. The loaders send the theme they already
//! resolved (built-in, \EFI\USOS\themes\<name>.ini, DATA\Themes or
//! \UI\theme.css), so micro-Linux needs neither the settings file nor the
//! DATA partition and has the theme from its first frame. The default
//! theme sends nothing from UEFI (option); the Legacy BIOS Core always
//! sends its theme (encode). Micro-Linux applies the same all-or-nothing rule
//! as theme_file.zig: a malformed value or a theme that breaks a
//! readability rule (theme_contrast.zig) gives the default theme.
const std = @import("std");
const Color = @import("color.zig").Color;
const Theme = @import("theme.zig").Theme;
const contrast = @import("theme_contrast.zig");

pub const key = "usos.theme=";

const offsets = blk: {
    var out: [std.meta.fields(Theme).len]u8 = undefined;
    var n: usize = 0;
    for (std.meta.fields(Theme)) |f| {
        if (f.type != Color) continue;
        out[n] = @offsetOf(Theme, f.name);
        n += 1;
    }
    break :blk out[0..n].*;
};

pub const value_len = offsets.len * 6;
/// " usos.theme=" and the value.
pub const option_len = 1 + key.len + value_len;

const digits = "0123456789abcdef";

/// " usos.theme=<value>" for `theme`, or "" for the plain default theme.
/// `buffer` must hold option_len bytes.
pub fn option(buffer: []u8, theme: Theme) []const u8 {
    const plain = Theme{};
    if (std.mem.eql(u8, std.mem.asBytes(&theme), std.mem.asBytes(&plain))) return "";
    return encode(buffer, theme);
}

/// " usos.theme=<value>" for `theme`, the default theme included (it
/// decodes to the same Theme{}), or "" when `buffer` is shorter than
/// option_len. The Legacy BIOS Core uses this form: it has a fixed size
/// budget (tools/build_legacy_bios.ps1, at least 4 KiB free), so it skips
/// the default-theme comparison and encodes byte-wise over the theme.
pub fn encode(buffer: []u8, theme: Theme) []const u8 {
    if (buffer.len < option_len) return "";
    const head = " " ++ key;
    @memcpy(buffer[0..head.len], head);
    const bytes = std.mem.asBytes(&theme);
    var at: usize = head.len;
    for (offsets) |offset| {
        for (bytes[offset..][0..3]) |byte| {
            buffer[at] = digits[byte >> 4];
            buffer[at + 1] = digits[byte & 15];
            at += 2;
        }
    }
    return buffer[0..at];
}

/// The value of the last usos.theme= argument of `cmdline`, or null.
pub fn valueOf(cmdline: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var arguments = std.mem.tokenizeAny(u8, cmdline, " \t\r\n\x00");
    while (arguments.next()) |argument| {
        if (std.mem.startsWith(u8, argument, key)) result = argument[key.len..];
    }
    return result;
}

/// Decodes a value; null when it is malformed or the theme is unreadable.
pub fn decode(value: []const u8) ?Theme {
    if (value.len != value_len) return null;
    var theme = Theme{};
    for (offsets, 0..) |offset, i| {
        var hex: [7]u8 = undefined;
        hex[0] = '#';
        @memcpy(hex[1..], value[i * 6 ..][0..6]);
        const target: *Color = @ptrFromInt(@intFromPtr(&theme) + offset);
        target.* = Color.fromHex(&hex) orelse return null;
    }
    if (contrast.firstProblemIndex(theme) != null) return null;
    return theme;
}

/// The theme of a kernel command line: the usos.theme= theme when it is
/// valid and readable, else the default theme.
pub fn fromCmdline(cmdline: []const u8) Theme {
    return decode(valueOf(cmdline) orelse return .{}) orelse .{};
}

const presets = @import("theme_presets.zig");
const theme_file = @import("theme_file.zig");

test "every built-in theme round-trips through the command line" {
    for (presets.all) |preset| {
        var buffer: [option_len]u8 = undefined;
        const text = option(&buffer, preset.theme);
        if (std.mem.eql(u8, preset.name, "default")) {
            try std.testing.expectEqualStrings("", text);
        } else {
            try std.testing.expectEqual(@as(usize, option_len), text.len);
        }
        const cmdline = try std.fmt.allocPrint(std.testing.allocator, "rdinit=/usos-init quiet{s} usos.plan_profile=xp", .{text});
        defer std.testing.allocator.free(cmdline);
        try std.testing.expectEqualDeep(preset.theme, fromCmdline(cmdline));
    }
}

test "the always-encoded default theme decodes to the default theme" {
    var buffer: [option_len]u8 = undefined;
    const text = encode(&buffer, .{});
    try std.testing.expectEqual(@as(usize, option_len), text.len);
    try std.testing.expectEqualDeep(Theme{}, fromCmdline(text));
    try std.testing.expectEqualStrings("", encode(buffer[0 .. option_len - 1], .{}));
}

test "the usos-sunset user theme reaches micro-Linux unchanged" {
    const outcome = theme_file.resolve(@embedFile("themes/usos-sunset.ini"));
    try std.testing.expect(outcome.ok());
    var buffer: [option_len]u8 = undefined;
    const text = option(&buffer, outcome.theme);
    try std.testing.expect(std.mem.startsWith(u8, text, " usos.theme="));
    try std.testing.expectEqualDeep(outcome.theme, fromCmdline(text));
    // Background is the first field.
    var first: [6]u8 = undefined;
    _ = try std.fmt.bufPrint(&first, "{x:0>2}{x:0>2}{x:0>2}", .{ outcome.theme.background.r, outcome.theme.background.g, outcome.theme.background.b });
    try std.testing.expectEqualStrings(&first, text[1 + key.len ..][0..6]);
}

test "a bad or unreadable command-line theme gives the default theme" {
    try std.testing.expectEqualDeep(Theme{}, fromCmdline(""));
    try std.testing.expectEqualDeep(Theme{}, fromCmdline("quiet usos.theme="));
    try std.testing.expectEqualDeep(Theme{}, fromCmdline("usos.theme=0000aa"));
    try std.testing.expectEqualDeep(Theme{}, fromCmdline("usos.theme=" ++ "zz" ** (value_len / 2)));
    // Well formed but white text on white: the contrast rules reject it.
    try std.testing.expectEqualDeep(Theme{}, fromCmdline("usos.theme=" ++ "ffffff" ** offsets.len));
    // A key that only starts like ours is not ours.
    try std.testing.expectEqual(@as(?[]const u8, null), valueOf("xusos.theme=1 usos.themes=2"));
    // The last one wins, like the other options.
    var buffer: [option_len]u8 = undefined;
    const retro = option(&buffer, presets.find("retro").?);
    const cmdline = try std.fmt.allocPrint(std.testing.allocator, "usos.theme=bad{s}", .{retro});
    defer std.testing.allocator.free(cmdline);
    try std.testing.expectEqualDeep(presets.find("retro").?, fromCmdline(cmdline));
}
