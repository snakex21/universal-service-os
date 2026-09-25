const std = @import("std");
const Color = @import("color.zig").Color;

/// The USOS palette, shared with the Windows installer
/// (installer/internal/ui/theme.go). The field defaults are the "default"
/// theme; the other built-in themes are in theme_presets.zig and a user
/// theme file (theme_file.zig) sets fields by name. \UI\theme.css may
/// override the base colours of the default theme with CSS custom
/// properties.
pub const Theme = struct {
    background: Color = .{ .r = 0x08, .g = 0x0d, .b = 0x14 },
    header: Color = .{ .r = 0x0c, .g = 0x14, .b = 0x1e },
    panel: Color = .{ .r = 0x10, .g = 0x19, .b = 0x23 },
    panel_alt: Color = .{ .r = 0x17, .g = 0x25, .b = 0x35 },
    field: Color = .{ .r = 0x0b, .g = 0x12, .b = 0x1b },
    text: Color = .{ .r = 0xef, .g = 0xfc, .b = 0xff },
    muted: Color = .{ .r = 0x8f, .g = 0xa8, .b = 0xb8 },
    faint: Color = .{ .r = 0x5d, .g = 0x73, .b = 0x82 },
    accent: Color = .{ .r = 0x43, .g = 0xd8, .b = 0xe8 },
    accent_pressed: Color = .{ .r = 0x2f, .g = 0xb4, .b = 0xc4 },
    accent_soft: Color = .{ .r = 0x0f, .g = 0x33, .b = 0x40 },
    on_accent: Color = .{ .r = 0x05, .g = 0x14, .b = 0x1c },
    selected: Color = .{ .r = 0x14, .g = 0x5b, .b = 0x7a },
    border: Color = .{ .r = 0x29, .g = 0x44, .b = 0x57 },
    border_strong: Color = .{ .r = 0x3a, .g = 0x5c, .b = 0x73 },
    disabled: Color = .{ .r = 0x22, .g = 0x2b, .b = 0x35 },
    disabled_text: Color = .{ .r = 0x5a, .g = 0x66, .b = 0x72 },
    danger: Color = .{ .r = 0xf0, .g = 0x5a, .b = 0x5f },
    danger_soft: Color = .{ .r = 0x35, .g = 0x14, .b = 0x19 },
    warning: Color = .{ .r = 0xf2, .g = 0xb1, .b = 0x3c },
    warning_soft: Color = .{ .r = 0x2f, .g = 0x24, .b = 0x10 },
    success: Color = .{ .r = 0x4a, .g = 0xd6, .b = 0x8c },
    success_soft: Color = .{ .r = 0x0f, .g = 0x2b, .b = 0x21 },
    /// Controller X face (A, B and Y use success, danger and warning).
    pad_x: Color = .{ .r = 0x4a, .g = 0x9b, .b = 0xf0 },
    /// Letter on the A/B/X/Y faces.
    on_pad: Color = .{ .r = 0x0b, .g = 0x0f, .b = 0x14 },

    pub fn parse(css: []const u8) Theme {
        return parseOver(.{}, css);
    }

    /// `base` with the colours that `css` sets.
    pub fn parseOver(base: Theme, css: []const u8) Theme {
        var result = base;
        result.background = property(css, "--background") orelse result.background;
        result.panel = property(css, "--panel") orelse result.panel;
        result.panel_alt = property(css, "--panel-alt") orelse result.panel_alt;
        result.text = property(css, "--text") orelse result.text;
        result.muted = property(css, "--muted") orelse result.muted;
        result.accent = property(css, "--accent") orelse result.accent;
        result.selected = property(css, "--selected") orelse result.selected;
        result.border = property(css, "--border") orelse result.border;
        result.disabled = property(css, "--disabled-fill") orelse result.disabled;
        return result;
    }
};

fn property(css: []const u8, name: []const u8) ?Color {
    var search = css;
    while (std.mem.indexOf(u8, search, name)) |start| {
        const after_name = search[start + name.len ..];
        search = after_name;
        // "--panel" must not match "--panel-alt".
        if (after_name.len > 0 and (after_name[0] == '-' or std.ascii.isAlphanumeric(after_name[0]))) continue;
        const colon = std.mem.indexOfScalar(u8, after_name, ':') orelse return null;
        const after_colon = std.mem.trimStart(u8, after_name[colon + 1 ..], " \t\r\n");
        if (after_colon.len < 7) return null;
        return Color.fromHex(after_colon[0..7]);
    }
    return null;
}

test "theme reads CSS custom properties" {
    const std_testing = std.testing;
    const theme = Theme.parse(":root { --background: #010203; --panel-alt: #445566; --panel: #112233; --accent: #a0b0c0; }");
    try std_testing.expectEqual(@as(u8, 1), theme.background.r);
    try std_testing.expectEqual(@as(u8, 0xb0), theme.accent.g);
    try std_testing.expectEqual(@as(u8, 0x11), theme.panel.r);
    try std_testing.expectEqual(@as(u8, 0x44), theme.panel_alt.r);
}
