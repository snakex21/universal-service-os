const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const manual_systems = @import("manual_systems.zig");
const rows_model = @import("manual_rows.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");
const manual_secure_boot = @import("manual_secure_boot.zig");
const manual_drivers = @import("manual_drivers.zig");

const max_utilities: usize = usos.catalog.utility_catalog.max_items;

var utility_list: usos.catalog.utility_catalog.List = .{};
var entries: [max_utilities]usos.catalog.SystemEntry = undefined;

/// Rows 0 and 1 are the built-in Secure Boot and Drivers pages; utilities
/// from DATA follow.
const builtin_rows = 2;

pub fn select(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, firmware: usos.firmware.Firmware) ?*const usos.catalog.SystemEntry {
    const count = scan(discovery);
    const total = count + builtin_rows;

    var selectable: [max_utilities + builtin_rows]bool = undefined;
    selectable[0] = true;
    selectable[1] = true;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = &entries[index];
        const media = discovery.mediaStatus(entry.image_directory);
        selectable[builtin_rows + index] = (usos.gui.menu_policy.Access{
            .firmware_compatible = entry.firmware.accepts(firmware),
            .has_images = media.hasImages(),
            .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
        }).navigable();
    }

    var rows: [max_utilities + builtin_rows]usos.gui.ui.Row = undefined;
    var details: [max_utilities]rows_model.DetailBuffer = undefined;
    rows[0] = manual_secure_boot.toolsRow();
    rows[1] = manual_drivers.toolsRow();
    index = 0;
    while (index < count) : (index += 1) {
        const entry = &entries[index];
        rows[builtin_rows + index] = rows_model.system(entry, system_icons.get(root, entry), discovery.mediaStatus(entry.image_directory), firmware, &details[index]);
    }

    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.tr("Utilities"), view.t(.category_utilities_desc), rows[0..total], selected, true, null);
    if (count == 0) showEmptyOnce(&list, selected);

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, total, &list, selectable[0..total])) {
            .activate => {
                if (selected < builtin_rows) {
                    if (selected == 0) manual_secure_boot.page() else manual_drivers.page();
                    rows[0] = manual_secure_boot.toolsRow();
                    rows[1] = manual_drivers.toolsRow();
                    list.redrawFull(selected, null);
                    continue;
                }
                const entry = &entries[selected - builtin_rows];
                const media = discovery.mediaStatus(entry.image_directory);
                switch ((usos.gui.menu_policy.Access{
                    .firmware_compatible = entry.firmware.accepts(firmware),
                    .has_images = media.hasImages(),
                    .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
                }).activation()) {
                    // Utilities are firmware-neutral and never Secure Boot gated.
                    .firmware_mismatch, .secure_boot_off_required => continue,
                    .no_image => {
                        manual_systems.showMissingImageNotice(entry);
                        list.redrawFull(selected, null);
                        continue;
                    },
                    .backend_unavailable => {
                        manual_systems.showBackendDisabledNotice(entry, view.t(.utility_unavailable));
                        list.redrawFull(selected, null);
                        continue;
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

fn scan(discovery: *usos.catalog.media_discovery.Discovery) usize {
    usos.catalog.utility_catalog.discover(discovery, &utility_list);
    var index: usize = 0;
    while (index < utility_list.len) : (index += 1) {
        const item = &utility_list.items[index];
        entries[index] = .{
            .id = item.name.slice(),
            .name = item.name.slice(),
            .category = .utilities,
            .family = .utility,
            .image_directory = item.imageDirectory(),
            .boot_methods = &usos.catalog.utility_boot_methods.all,
        };
    }
    return utility_list.len;
}

var empty_shown = false;

/// Without utilities on DATA the list still has the Secure Boot page; the
/// "no utilities" notice is shown once per start.
fn showEmptyOnce(list: *view.ListScreen, selected: usize) void {
    if (empty_shown) return;
    empty_shown = true;
    showEmpty();
    list.redrawFull(selected, null);
}

fn showEmpty() void {
    const lines = [_][]const u8{ view.t(.utilities_none_line1), view.t(.utilities_none_line2) };
    view.notice(view.tr("Utilities"), .info, .neutral, view.t(.utilities_none_title), &lines);
    view.waitForDismiss();
}
