const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const rows_model = @import("manual_rows.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");

const max_rows = usos.catalog.systems.all.len;

pub fn select(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, category: usos.catalog.Category, firmware: usos.firmware.Firmware) ?*const usos.catalog.SystemEntry {
    const count = usos.catalog.systems.countInCategory(category);
    if (count == 0) return null;

    var selectable: [max_rows]bool = undefined;
    var rows: [max_rows]usos.gui.ui.Row = undefined;
    var details: [max_rows]rows_model.DetailBuffer = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse {
            selectable[index] = false;
            rows[index] = .{ .title = "", .enabled = false };
            continue;
        };
        const media = discovery.mediaStatus(entry.image_directory);
        selectable[index] = access(entry, media, firmware).navigable();
        rows[index] = rows_model.system(entry, system_icons.get(root, entry), media, firmware, &details[index]);
    }

    var selected: usize = usos.gui.selectable_list.first(selectable[0..count]) orelse 0;
    var list: view.ListScreen = undefined;
    list.open(view.tr(category.label()), view.t(.systems_subtitle), rows[0..count], selected, true, null);

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, count, list.visibleStart(), list.visibleCount(), selectable[0..count])) {
            .activate => {
                const entry = usos.catalog.systems.byCategoryIndex(category, selected) orelse continue;
                const media = discovery.mediaStatus(entry.image_directory);
                switch (access(entry, media, firmware).activation()) {
                    .firmware_mismatch => continue,
                    .no_image => {
                        showMissingImageNotice(entry);
                        list.redrawFull(selected, null);
                    },
                    .backend_unavailable => {
                        showBackendDisabledNotice(entry, view.t(.notice_backend_line2));
                        list.redrawFull(selected, null);
                    },
                    .open => return entry,
                }
            },
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

pub fn access(entry: *const usos.catalog.SystemEntry, media: usos.catalog.SystemMediaStatus, firmware: usos.firmware.Firmware) usos.gui.menu_policy.Access {
    return .{
        .firmware_compatible = entry.firmware.accepts(firmware),
        .has_images = media.hasImages(),
        .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
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
