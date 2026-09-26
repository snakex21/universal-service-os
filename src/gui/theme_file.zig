//! User theme file: DATA\Themes\<name>\theme.ini, chosen with
//! `theme=<name>` in usos-settings.ini.
//!
//!   ; comment (lines starting with ; or #), [sections] are ignored
//!   base=dark                 optional built-in to start from (default)
//!   background=#101820        any Theme field (theme.zig), #rrggbb
//!   panel-alt=#1a2a3a         "-" and "_" are the same
//!
//! The file is all-or-nothing: an unknown key, a malformed colour, an
//! unknown base, a file that is too large or a theme that breaks a
//! readability rule (theme_contrast.zig) gives the default theme and the
//! reason, never a half-applied or unreadable menu.
const std = @import("std");
const Color = @import("color.zig").Color;
const Theme = @import("theme.zig").Theme;
const presets = @import("theme_presets.zig");
const contrast = @import("theme_contrast.zig");

pub const file_name = "theme.ini";
pub const folder = "Themes";
pub const max_bytes = 4096;

pub const Outcome = struct {
    theme: Theme,
    /// Why the file was not used (null: it was).
    problem: ?[]const u8 = null,
    /// 1-based line of a syntax problem (0: whole file).
    line: usize = 0,

    pub fn ok(self: Outcome) bool {
        return self.problem == null;
    }
};

fn rejected(problem: []const u8, line: usize) Outcome {
    return .{ .theme = .{}, .problem = problem, .line = line };
}

/// Parses and validates `text`; falls back to the default theme on any
/// problem.
pub fn resolve(text: []const u8) Outcome {
    return resolveWith(text, true);
}

/// The theme only (null on any problem), without the problem texts and
/// rule names: the Legacy BIOS Core, which has no place to show them.
pub fn resolveTheme(text: []const u8) ?Theme {
    const outcome = resolveWith(text, false);
    return if (outcome.problem == null) outcome.theme else null;
}

fn resolveWith(text: []const u8, comptime messages: bool) Outcome {
    const Text = struct {
        fn of(comptime value: []const u8) []const u8 {
            return if (messages) value else "";
        }
    };
    if (text.len > max_bytes) return rejected(Text.of("file too large"), 0);
    var theme = Theme{};
    var base_seen = false;
    var colours_seen: usize = 0;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_number += 1;
        var line = std.mem.trim(u8, raw, " \t\r\x00");
        if (line_number == 1 and std.mem.startsWith(u8, line, "\xef\xbb\xbf")) line = line[3..];
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return rejected(Text.of("line without '='"), line_number);
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "base")) {
            // The base must come first so it cannot undo colours set above.
            if (base_seen or colours_seen != 0) return rejected(Text.of("base= must be the first setting"), line_number);
            theme = presets.find(value) orelse return rejected(Text.of("unknown base theme"), line_number);
            base_seen = true;
            continue;
        }
        const colour = Color.fromHex(value) orelse return rejected(Text.of("colour is not #rrggbb"), line_number);
        if (!setField(&theme, key, colour)) return rejected(Text.of("unknown key"), line_number);
        colours_seen += 1;
    }
    if (contrast.firstProblemIndex(theme)) |index| return rejected(if (messages) contrast.rules[index].name else "", 0);
    return .{ .theme = theme };
}

/// Theme field names and offsets (a table, not an unrolled comparison per
/// field: the Legacy BIOS Core reads user themes too).
const Slot = struct { name: []const u8, offset: u16 };
const slots = blk: {
    var out: [std.meta.fields(Theme).len]Slot = undefined;
    var n: usize = 0;
    for (std.meta.fields(Theme)) |f| {
        if (f.type != Color) continue;
        out[n] = .{ .name = f.name, .offset = @offsetOf(Theme, f.name) };
        n += 1;
    }
    break :blk out[0..n].*;
};

fn setField(theme: *Theme, key: []const u8, colour: Color) bool {
    for (slots) |slot| {
        if (keyMatches(key, slot.name)) {
            const target: *Color = @ptrFromInt(@intFromPtr(theme) + slot.offset);
            target.* = colour;
            return true;
        }
    }
    return false;
}

fn keyMatches(key: []const u8, name: []const u8) bool {
    if (key.len != name.len) return false;
    for (key, name) |k, n| {
        const normal = if (k == '-') '_' else std.ascii.toLower(k);
        if (normal != n) return false;
    }
    return true;
}

test "a theme file sets colours over a base" {
    const outcome = resolve(
        \\; my theme
        \\[theme]
        \\base = retro
        \\accent=#FFEE00
        \\panel-alt=#2020c0
        \\
    );
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqual(@as(u8, 0xee), outcome.theme.accent.g);
    try std.testing.expectEqual(@as(u8, 0xc0), outcome.theme.panel_alt.b);
    // Untouched fields come from the base.
    try std.testing.expectEqualDeep(presets.find("retro").?.background, outcome.theme.background);
}

test "an empty theme file is the default theme" {
    const outcome = resolve("");
    try std.testing.expect(outcome.ok());
    try std.testing.expectEqualDeep(Theme{}, outcome.theme);
    try std.testing.expect(resolve("\xef\xbb\xbfbase=dark\r\n").ok());
}

test "any error falls back to the default theme" {
    const cases = [_]struct { text: []const u8, problem: []const u8, line: usize }{
        .{ .text = "base=dark\ntext=#fff\n", .problem = "colour is not #rrggbb", .line = 2 },
        .{ .text = "text=#gggggg\n", .problem = "colour is not #rrggbb", .line = 1 },
        .{ .text = "txet=#ffffff\n", .problem = "unknown key", .line = 1 },
        .{ .text = "background_image=bg.bmp\n", .problem = "colour is not #rrggbb", .line = 1 },
        .{ .text = "base=neon\n", .problem = "unknown base theme", .line = 1 },
        .{ .text = "text=#ffffff\nbase=dark\n", .problem = "base= must be the first setting", .line = 2 },
        .{ .text = "just words\n", .problem = "line without '='", .line = 1 },
        // Readable syntax, unreadable result: white text on white.
        .{ .text = "base=light\ntext=#ffffff\n", .problem = "text on background", .line = 0 },
        // The X face may not look like the A face.
        .{ .text = "pad_x=#4ad68c\n", .problem = "pad A vs X", .line = 0 },
    };
    for (cases) |case| {
        const outcome = resolve(case.text);
        try std.testing.expect(!outcome.ok());
        try std.testing.expectEqualStrings(case.problem, outcome.problem.?);
        try std.testing.expectEqual(case.line, outcome.line);
        try std.testing.expectEqualDeep(Theme{}, outcome.theme);
    }
    const big = [_]u8{' '} ** (max_bytes + 1);
    try std.testing.expectEqualStrings("file too large", resolve(&big).problem.?);
}

test "the example themes on the stick pass every rule (UEFI and BIOS parsers)" {
    inline for (.{ "usos-ocean", "usos-sunset", "usos-forest" }) |name| {
        const text = @embedFile("themes/" ++ name ++ ".ini");
        const outcome = resolve(text);
        std.testing.expect(outcome.ok()) catch |err| {
            std.debug.print("{s}: {s}\n", .{ name, outcome.problem.? });
            return err;
        };
        try std.testing.expectEqualDeep(outcome.theme, resolveTheme(text).?);
    }
    try std.testing.expect(resolveTheme("base=light\ntext=#ffffff\n") == null);
}
