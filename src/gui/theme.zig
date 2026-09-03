const std = @import("std");
const Color = @import("color.zig").Color;

pub const Theme = struct {
    background: Color = .{ .r = 0x11, .g = 0x15, .b = 0x1c },
    panel: Color = .{ .r = 0x1b, .g = 0x23, .b = 0x30 },
    panel_alt: Color = .{ .r = 0x22, .g = 0x2d, .b = 0x3d },
    text: Color = .{ .r = 0xf2, .g = 0xf5, .b = 0xf8 },
    muted: Color = .{ .r = 0x9a, .g = 0xa8, .b = 0xb8 },
    accent: Color = .{ .r = 0x5a, .g = 0xa9, .b = 0xff },
    selected: Color = .{ .r = 0x2f, .g = 0x6f, .b = 0xae },
    border: Color = .{ .r = 0x34, .g = 0x46, .b = 0x5d },
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
