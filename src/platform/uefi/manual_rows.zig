//! Row models shared by the systems and utilities lists.
const std = @import("std");
const usos = @import("usos");
const view = @import("manual_view.zig");
const secure_boot = @import("secure_boot.zig");
/// A BIOS-only system with no UEFI install flow yet (FreeDOS, PC DOS, NT 4.0,
/// betas). Shown like any system without a working backend; the Legacy BIOS
/// mode stays an advanced tool under Utilities and is not offered here.
pub fn biosOnly(entry: *const usos.catalog.SystemEntry, firmware: usos.firmware.Firmware) bool {
    return firmware == .uefi and entry.firmware == .bios;
}

pub const DetailBuffer = [48]u8;

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
    const detail = view.format(detail_buffer, .system_image_count, &.{count});
    if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
        return .{ .title = view.tr(entry.name), .detail = view.t(.system_unavailable_detail), .icon = row_icon, .badge = .{ .text = view.t(.system_unavailable) }, .enabled = false };
    }
    return .{ .title = view.tr(entry.name), .detail = detail, .icon = row_icon, .badge = .{ .text = view.t(.system_ready), .tone = .success } };
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
