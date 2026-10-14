//! Row models shared by the systems and utilities lists.
const std = @import("std");
const usos = @import("usos");
const view = @import("manual_view.zig");
const secure_boot = @import("secure_boot.zig");
const media_probe = @import("windows_media_probe.zig");
/// A BIOS-only system with no UEFI install flow yet (FreeDOS, PC DOS, NT 4.0,
/// betas). Shown like any system without a working backend; the Legacy BIOS
/// mode stays an advanced tool under Utilities and is not offered here.
pub fn biosOnly(entry: *const usos.catalog.SystemEntry, firmware: usos.firmware.Firmware) bool {
    return firmware == .uefi and entry.firmware == .bios;
}

/// Per-row storage the returned Row points into: the detail text and the
/// architecture chips.
pub const DetailBuffer = struct {
    text: [48]u8 = undefined,
    archs: [4]usos.image_probe.windows_media.Arch = undefined,
    chips: [4]usos.gui.ui.Badge = undefined,
};

pub fn system(
    entry: *const usos.catalog.SystemEntry,
    icon: ?*const usos.gui.RgbaImage,
    media: usos.catalog.SystemMediaStatus,
    firmware: usos.firmware.Firmware,
    detail_buffer: *DetailBuffer,
) usos.gui.ui.Row {
    const row_icon: usos.gui.ui.RowIcon = if (icon) |image| .{ .image = image } else .{ .vector = fallbackIcon(entry) };
    if (biosOnly(entry, firmware)) {
        if (!media.hasImages()) return .{ .title = view.tr(entry.name), .detail = view.t(.system_no_image), .icon = row_icon, .enabled = false };
        return .{ .title = view.tr(entry.name), .detail = view.t(.system_unavailable_detail), .icon = row_icon, .badge = .{ .text = view.t(.system_unavailable) }, .enabled = false };
    }
    if (!entry.firmware.accepts(firmware)) {
        const requires_uefi = entry.firmware == .uefi;
        return .{
            .title = view.tr(entry.name),
            .detail = view.t(if (requires_uefi) .system_requires_uefi_detail else .system_requires_bios_detail),
            .icon = row_icon,
            .badge = .{ .text = view.t(if (requires_uefi) .system_requires_uefi else .system_requires_bios), .tone = .warning },
            .enabled = false,
        };
    }
    if (firmware == .uefi and usos.flow.secure_boot_policy.blocked(secure_boot.state(), entry.id)) {
        // CSM/UefiSeven/pre-Secure-Boot Windows: say why instead of failing later.
        return .{
            .title = view.tr(entry.name),
            .detail = view.t(.summary_secure_boot_detail),
            .icon = row_icon,
            .badge = .{ .text = view.t(.summary_secure_boot_badge), .tone = .warning },
            .enabled = false,
        };
    }
    if (!media.hasImages()) {
        return .{ .title = view.tr(entry.name), .detail = view.t(.system_no_image), .icon = row_icon, .enabled = false };
    }
    var count_buffer: [12]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d}", .{media.imageCount()}) catch "?";
    const detail = view.format(&detail_buffer.text, .system_image_count, &.{count});
    if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
        return .{ .title = view.tr(entry.name), .detail = view.t(.system_unavailable_detail), .icon = row_icon, .badge = .{ .text = view.t(.system_unavailable) }, .enabled = false };
    }
    return .{ .title = view.tr(entry.name), .detail = detail, .icon = row_icon, .badge = .{ .text = view.t(.system_ready), .tone = .success }, .chips = archChips(entry, detail_buffer) };
}

/// x86 / x64 / ... chips of the ISOs already probed in this session (the
/// system's image list was opened); nothing before that, nothing is read.
fn archChips(entry: *const usos.catalog.SystemEntry, buffer: *DetailBuffer) []const usos.gui.ui.Badge {
    if (!media_probe.applies(entry)) return &.{};
    const archs = media_probe.cachedArchs(entry.image_directory, &buffer.archs);
    var n: usize = 0;
    for (archs) |arch| {
        const chip = usos.gui.arch_badge.badge(arch) orelse continue;
        buffer.chips[n] = chip;
        n += 1;
    }
    return buffer.chips[0..n];
}

fn fallbackIcon(entry: *const usos.catalog.SystemEntry) usos.gui.icons.Kind {
    return switch (entry.category) {
        .windows => .windows,
        .linux => .terminal,
        .beta => .flask,
        .dos => .floppy,
        .other => .disc,
        .utilities => .gear,
    };
}
