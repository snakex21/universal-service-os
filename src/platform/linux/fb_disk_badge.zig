//! Disk bus and media chips for the micro-Linux disk pickers
//! (tools/xp_menu_ui.sh writes `badge=<token>` lines after each disk item;
//! tools/target_disk_identity.sh usos_disk_badges picks the tokens).
//!
//! Every bus has its own solid colour, so NVMe, SATA, IDE, SCSI, SAS, USB,
//! SD/MMC and VirtIO disks are told apart at a glance; the label colour comes
//! from the theme (ui.readableOn, WCAG 4.5:1). Media (SSD, HDD, SSHD) uses the
//! theme's soft tones, so it never looks like a second bus. The labels are
//! technical abbreviations and stay the same in every language; an unknown
//! token is shown as a neutral chip with the token text.
const std = @import("std");
const usos = @import("usos");
const Color = usos.gui.Color;
const Badge = usos.gui.ui.Badge;

pub const Bus = struct { token: []const u8, label: []const u8, fill: Color };

fn rgb(comptime hex: *const [7]u8) Color {
    return comptime Color.fromHex(hex) orelse @compileError("bad colour " ++ hex);
}

/// Mid-tone hues: readable with white or black text, visible on dark and
/// light list panels alike.
pub const buses = [_]Bus{
    .{ .token = "nvme", .label = "NVMe", .fill = rgb("#8b6cf0") },
    .{ .token = "sata", .label = "SATA", .fill = rgb("#3b8eea") },
    .{ .token = "ide", .label = "IDE", .fill = rgb("#c08a3e") },
    .{ .token = "scsi", .label = "SCSI", .fill = rgb("#d35d9a") },
    .{ .token = "sas", .label = "SAS", .fill = rgb("#e2703a") },
    .{ .token = "usb", .label = "USB", .fill = rgb("#3fae5a") },
    .{ .token = "mmc", .label = "MMC", .fill = rgb("#1fa8a8") },
    .{ .token = "emmc", .label = "eMMC", .fill = rgb("#1fa8a8") },
    .{ .token = "sd", .label = "SD", .fill = rgb("#1fa8a8") },
    .{ .token = "virtio", .label = "VirtIO", .fill = rgb("#8a96a3") },
};

pub fn badge(token: []const u8) Badge {
    for (buses) |bus| {
        if (std.ascii.eqlIgnoreCase(bus.token, token)) return .{ .text = bus.label, .fill = bus.fill };
    }
    if (std.ascii.eqlIgnoreCase(token, "ssd")) return .{ .text = "SSD", .tone = .accent };
    if (std.ascii.eqlIgnoreCase(token, "hdd")) return .{ .text = "HDD", .tone = .neutral };
    if (std.ascii.eqlIgnoreCase(token, "sshd")) return .{ .text = "SSHD", .tone = .warning };
    return .{ .text = token, .tone = .neutral };
}

test "every bus has its own colour and readable text in every built-in theme" {
    const contrast = usos.gui.theme_contrast;
    for (buses, 0..) |a, i| {
        for (buses[i + 1 ..]) |b| {
            const mmc_family = (std.mem.indexOf(u8, "mmc emmc sd", a.token) != null) and (std.mem.indexOf(u8, "mmc emmc sd", b.token) != null);
            if (!mmc_family) try std.testing.expect(contrast.distance(a.fill, b.fill) >= 60);
        }
    }
    for (usos.gui.theme_presets.all) |preset| {
        for (buses) |bus| {
            const text = usos.gui.ui.readableOn(preset.theme, bus.fill);
            try std.testing.expect(contrast.ratio10(text, bus.fill) >= 45);
            // The chip stands out from the list panel it sits on.
            try std.testing.expect(contrast.distance(bus.fill, preset.theme.panel) >= 90);
        }
    }
}

test "tokens map to labels; media uses theme tones; unknown tokens stay visible" {
    try std.testing.expectEqualStrings("NVMe", badge("nvme").text);
    try std.testing.expect(badge("NVME").fill != null);
    try std.testing.expectEqualStrings("IDE", badge("ide").text);
    try std.testing.expectEqualStrings("SSHD", badge("sshd").text);
    try std.testing.expect(badge("ssd").fill == null);
    try std.testing.expectEqual(usos.gui.ui.Tone.accent, badge("ssd").tone);
    try std.testing.expectEqualStrings("raid", badge("raid").text);
}
