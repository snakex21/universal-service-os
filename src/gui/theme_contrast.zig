//! Readability rules every menu theme must meet: WCAG 2 contrast ratios
//! for the colour pairs the toolkit really draws (src/gui/ui.zig), and
//! colour distance for things that only need to be told apart (the
//! selection fill against the list panel, the four pad faces from each
//! other). Integer arithmetic only: the Legacy BIOS Core is i386 without
//! an FPU requirement, and the sRGB table is built at compile time.
const std = @import("std");
const Color = @import("color.zig").Color;
const Theme = @import("theme.zig").Theme;

/// Relative luminance scale: 1.0 = `unit`.
const unit: u32 = 100_000;
/// WCAG adds 0.05 to both luminances.
const flare: u32 = unit / 20;

/// sRGB channel (0..255) to linear light (0..unit).
const linear: [256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        const c: f64 = @as(f64, @floatFromInt(i)) / 255.0;
        const l = if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        table[i] = @intFromFloat(@round(l * @as(f64, @floatFromInt(unit))));
    }
    break :blk table;
};

pub fn luminance(color: Color) u32 {
    return (2126 * linear[color.r] + 7152 * linear[color.g] + 722 * linear[color.b]) / 10_000;
}

/// Contrast ratio of two colours times ten (WCAG: 4.5:1 -> 45).
pub fn ratio10(a: Color, b: Color) u32 {
    const la = luminance(a) + flare;
    const lb = luminance(b) + flare;
    const hi: u64 = @max(la, lb);
    const lo: u64 = @min(la, lb);
    return @intCast(hi * 10 / lo);
}

/// Sum of the channel differences (0..765).
pub fn distance(a: Color, b: Color) u32 {
    const dr = @as(i32, a.r) - b.r;
    const dg = @as(i32, a.g) - b.g;
    const db = @as(i32, a.b) - b.b;
    return @abs(dr) + @abs(dg) + @abs(db);
}

pub const Rule = struct {
    name: []const u8,
    fore: []const u8,
    back: []const u8,
    /// Minimum contrast ratio times ten, or 0 for a distance rule.
    min_ratio10: u32 = 0,
    /// Minimum channel distance (distance rules).
    min_distance: u32 = 0,
};

/// Body text 4.5:1 on every surface it is drawn on; secondary text,
/// badges, icons and the selection frame 3:1; greyed-out text 2:1 (it
/// is meant to look disabled but must stay legible).
pub const rules = [_]Rule{
    .{ .name = "text on background", .fore = "text", .back = "background", .min_ratio10 = 45 },
    .{ .name = "text on header", .fore = "text", .back = "header", .min_ratio10 = 45 },
    .{ .name = "text on panel", .fore = "text", .back = "panel", .min_ratio10 = 45 },
    .{ .name = "text on panel_alt", .fore = "text", .back = "panel_alt", .min_ratio10 = 45 },
    .{ .name = "text on selection", .fore = "text", .back = "accent_soft", .min_ratio10 = 45 },
    .{ .name = "on_accent on accent", .fore = "on_accent", .back = "accent", .min_ratio10 = 45 },
    .{ .name = "muted on header", .fore = "muted", .back = "header", .min_ratio10 = 30 },
    .{ .name = "muted on panel", .fore = "muted", .back = "panel", .min_ratio10 = 30 },
    .{ .name = "muted on panel_alt", .fore = "muted", .back = "panel_alt", .min_ratio10 = 30 },
    .{ .name = "muted on selection", .fore = "muted", .back = "accent_soft", .min_ratio10 = 30 },
    .{ .name = "accent on panel", .fore = "accent", .back = "panel", .min_ratio10 = 30 },
    .{ .name = "accent on selection", .fore = "accent", .back = "accent_soft", .min_ratio10 = 30 },
    .{ .name = "success badge", .fore = "success", .back = "success_soft", .min_ratio10 = 30 },
    .{ .name = "warning badge", .fore = "warning", .back = "warning_soft", .min_ratio10 = 30 },
    .{ .name = "danger badge", .fore = "danger", .back = "danger_soft", .min_ratio10 = 30 },
    .{ .name = "disabled text on panel", .fore = "disabled_text", .back = "panel", .min_ratio10 = 20 },
    .{ .name = "pad A letter", .fore = "on_pad", .back = "success", .min_ratio10 = 30 },
    .{ .name = "pad B letter", .fore = "on_pad", .back = "danger", .min_ratio10 = 30 },
    .{ .name = "pad X letter", .fore = "on_pad", .back = "pad_x", .min_ratio10 = 30 },
    .{ .name = "pad Y letter", .fore = "on_pad", .back = "warning", .min_ratio10 = 30 },
    .{ .name = "selection fill vs panel", .fore = "accent_soft", .back = "panel", .min_distance = 48 },
    .{ .name = "hover fill vs panel", .fore = "panel_alt", .back = "panel", .min_distance = 16 },
    .{ .name = "pad A vs footer", .fore = "success", .back = "header", .min_distance = 120 },
    .{ .name = "pad B vs footer", .fore = "danger", .back = "header", .min_distance = 120 },
    .{ .name = "pad X vs footer", .fore = "pad_x", .back = "header", .min_distance = 120 },
    .{ .name = "pad Y vs footer", .fore = "warning", .back = "header", .min_distance = 120 },
    .{ .name = "pad A vs B", .fore = "success", .back = "danger", .min_distance = 120 },
    .{ .name = "pad A vs X", .fore = "success", .back = "pad_x", .min_distance = 120 },
    .{ .name = "pad A vs Y", .fore = "success", .back = "warning", .min_distance = 120 },
    .{ .name = "pad B vs X", .fore = "danger", .back = "pad_x", .min_distance = 120 },
    .{ .name = "pad B vs Y", .fore = "danger", .back = "warning", .min_distance = 120 },
    .{ .name = "pad X vs Y", .fore = "pad_x", .back = "warning", .min_distance = 120 },
};

fn field(theme: Theme, comptime name: []const u8) Color {
    return @field(theme, name);
}

pub fn passes(theme: Theme, comptime rule: Rule) bool {
    const fore = field(theme, rule.fore);
    const back = field(theme, rule.back);
    if (rule.min_ratio10 != 0) return ratio10(fore, back) >= rule.min_ratio10;
    return distance(fore, back) >= rule.min_distance;
}

/// The first rule `theme` breaks, or null when it is readable.
pub fn firstProblem(theme: Theme) ?[]const u8 {
    inline for (rules) |rule| {
        if (!passes(theme, rule)) return rule.name;
    }
    return null;
}

test "contrast ratios match WCAG reference values" {
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    const white = Color{ .r = 0xff, .g = 0xff, .b = 0xff };
    try std.testing.expectEqual(@as(u32, 210), ratio10(black, white));
    try std.testing.expectEqual(@as(u32, 210), ratio10(white, black));
    try std.testing.expectEqual(@as(u32, 10), ratio10(white, white));
    // #767676 on white is the classic 4.54:1 grey.
    try std.testing.expectEqual(@as(u32, 45), ratio10(.{ .r = 0x76, .g = 0x76, .b = 0x76 }, white));
    try std.testing.expectEqual(@as(u32, 765), distance(black, white));
}

test "the default theme is readable" {
    try std.testing.expectEqual(@as(?[]const u8, null), firstProblem(.{}));
}

test "an unreadable theme is reported by rule" {
    var theme = Theme{};
    theme.text = theme.panel;
    try std.testing.expect(firstProblem(theme) != null);
    theme = .{};
    theme.pad_x = theme.success;
    try std.testing.expectEqualStrings("pad A vs X", firstProblem(theme).?);
}
