//! Architecture chips for the UEFI menu (system entries and the ISO list,
//! src/platform/uefi/manual_rows.zig, manual_images.zig): every architecture
//! has its own solid colour, like the disk bus chips of the micro-Linux
//! pickers (src/platform/linux/fb_disk_badge.zig), so x86 and x64 media are
//! told apart at a glance. The label colour comes from the theme
//! (ui.readableOn); the tests check WCAG 4.5:1 and the distance to the list
//! panel in every built-in theme. Labels are the technical names and stay
//! the same in every language.
const std = @import("std");
const Color = @import("color.zig").Color;
const ui = @import("ui.zig");
const windows_media = @import("../image_probe/windows_media.zig");

pub const Arch = windows_media.Arch;

fn rgb(comptime hex: *const [7]u8) Color {
    return comptime Color.fromHex(hex) orelse @compileError("bad colour " ++ hex);
}

/// Mid-tone hues readable with white or black text on dark and light panels.
pub fn fill(arch: Arch) ?Color {
    return switch (arch) {
        .unknown => null,
        .x86 => rgb("#e2703a"),
        .x64 => rgb("#3b8eea"),
        .arm64 => rgb("#3fae5a"),
        .multi => rgb("#8b6cf0"),
        .ia64 => rgb("#8a96a3"),
    };
}

/// The chip for an architecture; null when it is not known.
pub fn badge(arch: Arch) ?ui.Badge {
    const colour = fill(arch) orelse return null;
    return .{ .text = arch.label(), .fill = colour };
}

test "x86 and x64 chips differ and are readable in every built-in theme" {
    const contrast = @import("theme_contrast.zig");
    const presets = @import("theme_presets.zig");
    const archs = [_]Arch{ .x86, .x64, .arm64, .multi, .ia64 };
    for (archs, 0..) |a, i| {
        for (archs[i + 1 ..]) |b| try std.testing.expect(contrast.distance(fill(a).?, fill(b).?) >= 60);
    }
    for (presets.all) |preset| {
        for (archs) |arch| {
            const colour = fill(arch).?;
            const text = ui.readableOn(preset.theme, colour);
            try std.testing.expect(contrast.ratio10(text, colour) >= 45);
            try std.testing.expect(contrast.distance(colour, preset.theme.panel) >= 90);
        }
    }
    try std.testing.expectEqualStrings("x86", badge(.x86).?.text);
    try std.testing.expectEqualStrings("x64", badge(.x64).?.text);
    try std.testing.expect(badge(.unknown) == null);
}
