const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const manual_systems = @import("manual_systems.zig");
const rows_model = @import("manual_rows.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");

const max_utilities: usize = usos.catalog.utility_catalog.max_items;

var utility_list: usos.catalog.utility_catalog.List = .{};
var entries: [max_utilities]usos.catalog.SystemEntry = undefined;

pub fn select(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, firmware: usos.firmware.Firmware) ?*const usos.catalog.SystemEntry {
    const count = scan(discovery);
    if (count == 0) {
        showEmpty();
        return null;
    }

    var selectable: [max_utilities]bool = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = &entries[index];
        const media = discovery.mediaStatus(entry.image_directory);
        selectable[index] = (usos.gui.menu_policy.Access{
            .firmware_compatible = entry.firmware.accepts(firmware),
            .has_images = media.hasImages(),
            .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
        }).navigable();
    }

    var rows: [max_utilities]usos.gui.ui.Row = undefined;
    var details: [max_utilities]rows_model.DetailBuffer = undefined;
    index = 0;
    while (index < count) : (index += 1) {
        const entry = &entries[index];
        rows[index] = rows_model.system(entry, system_icons.get(root, entry), discovery.mediaStatus(entry.image_directory), firmware, &details[index]);
    }

    var selected: usize = usos.gui.selectable_list.first(selectable[0..count]) orelse 0;
    var list: view.ListScreen = undefined;
    list.open(view.tr("Utilities"), view.t(.category_utilities_desc), rows[0..count], selected, true, null);

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, count, list.visibleStart(), list.visibleCount(), selectable[0..count])) {
            .activate => {
                const entry = &entries[selected];
                const media = discovery.mediaStatus(entry.image_directory);
                switch ((usos.gui.menu_policy.Access{
                    .firmware_compatible = entry.firmware.accepts(firmware),
                    .has_images = media.hasImages(),
                    .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
                }).activation()) {
                    .firmware_mismatch => continue,
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

fn showEmpty() void {
    const lines = [_][]const u8{ view.t(.utilities_none_line1), view.t(.utilities_none_line2) };
    view.notice(view.tr("Utilities"), .info, .neutral, view.t(.utilities_none_title), &lines);
    view.waitForDismiss();
}
