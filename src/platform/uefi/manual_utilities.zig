const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");

const max_utilities: usize = usos.catalog.utility_catalog.max_items;
const visible_rows: usize = 12;

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

    var rows: [max_utilities]view.ListRow = undefined;
    index = 0;
    while (index < count) : (index += 1) {
        const entry = &entries[index];
        const icon = system_icons.get(root, entry);
        const media = discovery.mediaStatus(entry.image_directory);
        rows[index] = if (!entry.firmware.accepts(firmware))
            .{ .system_disabled = .{ .value = entry.name, .icon = icon, .reason = entry.firmware.mismatchReason(firmware) } }
        else if (!media.hasImages())
            .{ .system_disabled = .{ .value = entry.name, .icon = icon, .reason = "[no image]" } }
        else if (!usos.flow.preparation_capability.supportsSystem(entry.id))
            .{ .system_disabled = .{ .value = entry.name, .icon = icon, .reason = "[backend unavailable]" } }
        else
            .{ .system = .{ .value = entry.name, .icon = icon } };
    }

    var selected: usize = usos.gui.selectable_list.first(selectable[0..count]) orelse 0;
    var list = view.ListScreen.open("systems", "Utilities", rows[0..count], selected, visible_rows, null);

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
                        showMissingImageNotice(entry);
                        list.redrawFull(selected, null);
                        continue;
                    },
                    .backend_unavailable => {
                        showBackendDisabledNotice(entry);
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
    view.begin("systems", "Utilities");
    view.row(false, "No utility folders found.");
    view.row(false, "Create Utilities/<tool name>/Images on DATA, then run Update USOS.");
    waitForDismiss();
}

fn showMissingImageNotice(entry: *const usos.catalog.SystemEntry) void {
    view.begin("systems", entry.name);
    view.row(false, "No supported image files were found. Copy a file to:");
    view.row(false, usos.gui.menu_policy.displayImagePath(entry.image_directory));
    waitForDismiss();
}

fn showBackendDisabledNotice(entry: *const usos.catalog.SystemEntry) void {
    view.begin("systems", entry.name);
    view.row(false, usos.flow.preparation_capability.unavailable_reason);
    view.row(false, "The utility remains visible while its boot backend is unavailable.");
    waitForDismiss();
}

fn waitForDismiss() void {
    view.footer(true);
    while (true) {
        switch (input.readBlocking()) {
            .enter => return,
            .back => return,
            .pointer => |mouse| {
                if (mouse.right_click or mouse.left_click) return;
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}
