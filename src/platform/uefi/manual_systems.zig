const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const rows_model = @import("manual_rows.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");
const boot_timing = @import("boot_timing.zig");
const secure_boot = @import("secure_boot.zig");

var list_timing_reported = false;

const max_rows = usos.catalog.systems.all.len;

pub fn select(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, category: usos.catalog.Category, firmware: usos.firmware.Firmware) ?*const usos.catalog.SystemEntry {
    const count = usos.catalog.systems.countInCategory(category);
    if (count == 0) return null;
    if (!list_timing_reported) boot_timing.mark("first systems list requested");

    var selectable: [max_rows]bool = undefined;
    var rows: [max_rows]usos.gui.ui.Row = undefined;
    var details: [max_rows]rows_model.DetailBuffer = undefined;
    var statuses: [max_rows]usos.catalog.SystemMediaStatus = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse continue;
        statuses[index] = discovery.mediaStatus(entry.image_directory);
    }
    if (!list_timing_reported) boot_timing.mark("systems media discovery (NTFS directories)");
    index = 0;
    while (index < count) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse {
            selectable[index] = false;
            rows[index] = .{ .title = "", .enabled = false };
            continue;
        };
        selectable[index] = access(entry, statuses[index], firmware).navigable();
        rows[index] = rows_model.system(entry, system_icons.get(root, entry), statuses[index], firmware, &details[index]);
    }

    if (!list_timing_reported) boot_timing.mark("systems icons loaded");
    var selected: usize = usos.gui.selectable_list.first(selectable[0..count]) orelse 0;
    var help_lines: HelpLines = undefined;
    var shown_block = blockAt(category, selected, firmware);
    var shown_help = blockedHelp(shown_block, &help_lines);
    var list: view.ListScreen = undefined;
    list.open(view.tr(category.label()), view.t(.systems_subtitle), rows[0..count], selected, true, shown_help);
    if (!list_timing_reported) {
        list_timing_reported = true;
        boot_timing.mark("first systems list presented");
        boot_timing.report(root, "boot-timing.txt", 0);
    }

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, count, &list, selectable[0..count])) {
            .activate => {
                const entry = usos.catalog.systems.byCategoryIndex(category, selected) orelse continue;
                const media = discovery.mediaStatus(entry.image_directory);
                switch (access(entry, media, firmware).activation()) {
                    .firmware_mismatch, .secure_boot_off_required => {
                        // Selectable so the reason can be read; never launched.
                        var notice_lines: HelpLines = undefined;
                        if (blockedHelp(blockAt(category, selected, firmware), &notice_lines)) |help| {
                            view.notice(entry.name, .warning, .warning, help.title, help.lines);
                            view.waitForDismiss();
                        }
                        list.redrawFull(selected, shown_help);
                    },
                    .no_image => {
                        showMissingImageNotice(entry);
                        list.redrawFull(selected, shown_help);
                    },
                    .backend_unavailable => {
                        showBackendDisabledNotice(entry, view.t(.notice_backend_line2));
                        list.redrawFull(selected, shown_help);
                    },
                    .open => return entry,
                }
            },
            .back => return null,
            .changed => {
                const block = blockAt(category, selected, firmware);
                // The help panel takes list space: a panel appearing,
                // disappearing or changing text needs a full relayout.
                const relayout = block != shown_block;
                shown_block = block;
                shown_help = blockedHelp(block, &help_lines);
                if (relayout) list.redrawFull(selected, shown_help) else list.updateSelection(selected, shown_help);
            },
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

const HelpLines = [2][]const u8;

const Block = enum { none, requires_bios, requires_uefi, secure_boot_off };

fn blockAt(category: usos.catalog.Category, index: usize, firmware: usos.firmware.Firmware) Block {
    const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse return .none;
    if (!entry.firmware.accepts(firmware)) return if (entry.firmware == .uefi) .requires_uefi else .requires_bios;
    if (secureBootBlocked(entry, firmware)) return .secure_boot_off;
    return .none;
}

/// Why a row cannot be started and what to do about it, for the help panel
/// and the notice shown when it is activated anyway. Null for rows that
/// can start (or only lack images, which the row detail already says).
fn blockedHelp(block: Block, lines: *HelpLines) ?usos.gui.menu_screens.Help {
    switch (block) {
        .none => return null,
        .requires_bios, .requires_uefi => {
            const requires_uefi = block == .requires_uefi;
            lines.* = .{
                view.t(if (requires_uefi) .system_requires_uefi_detail else .system_requires_bios_detail),
                view.t(if (requires_uefi) .system_requires_uefi_hint else .system_requires_bios_hint),
            };
            // The row already carries the badge; its text heads the panel.
            return .{ .title = view.t(if (requires_uefi) .system_requires_uefi else .system_requires_bios), .lines = lines };
        },
        .secure_boot_off => {
            lines.* = .{ view.t(.summary_secure_boot_line1), view.t(.summary_secure_boot_line2) };
            return .{ .title = view.t(.summary_secure_boot_badge), .lines = lines };
        },
    }
}

fn secureBootBlocked(entry: *const usos.catalog.SystemEntry, firmware: usos.firmware.Firmware) bool {
    return firmware == .uefi and usos.flow.secure_boot_policy.blocked(secure_boot.state(), entry.id);
}

pub fn access(entry: *const usos.catalog.SystemEntry, media: usos.catalog.SystemMediaStatus, firmware: usos.firmware.Firmware) usos.gui.menu_policy.Access {
    return .{
        .firmware_compatible = entry.firmware.accepts(firmware),
        .has_images = media.hasImages(),
        .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
        .secure_boot_blocked = secureBootBlocked(entry, firmware),
    };
}

pub fn showMissingImageNotice(entry: *const usos.catalog.SystemEntry) void {
    const lines = [_][]const u8{ view.t(.notice_no_image_line1), usos.gui.menu_policy.displayImagePath(entry.image_directory) };
    view.notice(entry.name, .warning, .warning, view.t(.notice_no_image_title), &lines);
    view.waitForDismiss();
}

pub fn showBackendDisabledNotice(entry: *const usos.catalog.SystemEntry, reason: []const u8) void {
    const lines = [_][]const u8{ view.t(.notice_backend_line1), reason };
    view.notice(entry.name, .info, .neutral, view.t(.system_unavailable), &lines);
    view.waitForDismiss();
}
