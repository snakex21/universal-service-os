const std = @import("std");
const Color = @import("color.zig").Color;

pub const Theme = struct {
    background: Color = .{ .r = 0x08, .g = 0x0d, .b = 0x14 },
    panel: Color = .{ .r = 0x10, .g = 0x19, .b = 0x23 },
    panel_alt: Color = .{ .r = 0x17, .g = 0x25, .b = 0x35 },
    text: Color = .{ .r = 0xef, .g = 0xfc, .b = 0xff },
    muted: Color = .{ .r = 0x8f, .g = 0xa8, .b = 0xb8 },
    accent: Color = .{ .r = 0x43, .g = 0xd8, .b = 0xe8 },
    selected: Color = .{ .r = 0x14, .g = 0x5b, .b = 0x7a },
    border: Color = .{ .r = 0x29, .g = 0x44, .b = 0x57 },
    disabled: Color = .{ .r = 0x3a, .g = 0x42, .b = 0x4c },

    pub fn parse(css: []const u8) Theme {
        var result = Theme{};
        result.background = property(css, "--background") orelse result.background;
        result.panel = property(css, "--panel") orelse result.panel;
        result.panel_alt = property(css, "--panel-alt") orelse result.panel_alt;
        result.text = property(css, "--text") orelse result.text;
        result.muted = property(css, "--muted") orelse result.muted;
        result.accent = property(css, "--accent") orelse result.accent;
        result.selected = property(css, "--selected") orelse result.selected;
        result.border = property(css, "--border") orelse result.border;
        result.disabled = property(css, "--disabled") orelse result.disabled;
        return result;
    }
};

fn property(css: []const u8, name: []const u8) ?Color {
    const start = std.mem.indexOf(u8, css, name) orelse return null;
    const after_name = css[start + name.len ..];
    const colon = std.mem.indexOfScalar(u8, after_name, ':') orelse return null;
    const after_colon = std.mem.trimStart(u8, after_name[colon + 1 ..], " \t\r\n");
    if (after_colon.len < 7) return null;
    return Color.fromHex(after_colon[0..7]);
}

test "theme reads CSS custom properties" {
    const std_testing = std.testing;
    const theme = Theme.parse(":root { --background: #010203; --accent: #a0b0c0; }");
    try std_testing.expectEqual(@as(u8, 1), theme.background.r);
    try std_testing.expectEqual(@as(u8, 0xb0), theme.accent.g);
}
