const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const view = @import("manual_view.zig");

const visible_rows: usize = 12;

pub fn select(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, category: usos.catalog.Category, firmware: usos.firmware.Firmware) ?*const usos.catalog.SystemEntry {
    const count = usos.catalog.systems.countInCategory(category);
    if (count == 0) return null;

    var selectable: [usos.catalog.systems.all.len]bool = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse {
            selectable[index] = false;
            continue;
        };
        const media = discovery.mediaStatus(entry.image_directory);
        selectable[index] = (usos.gui.menu_policy.Access{
            .firmware_compatible = entry.firmware.accepts(firmware),
            .has_images = media.hasImages(),
            .backend_available = usos.flow.preparation_capability.supportsSystem(entry.id),
        }).navigable();
    }

    var rows: [usos.catalog.systems.all.len]view.ListRow = undefined;
    index = 0;
    while (index < count) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse continue;
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
    var list = view.ListScreen.open("systems", category.label(), rows[0..count], selected, visible_rows, null);

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, count, list.visibleStart(), list.visibleCount(), selectable[0..count])) {
            .activate => {
                if (usos.catalog.systems.byCategoryIndex(category, selected)) |entry| {
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
                }
            },
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
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
    view.row(false, "This system remains visible because its backend is planned.");
    waitForDismiss();
}

fn waitForDismiss() void {
    view.footer(true);
    while (true) {
        switch (input.readBlocking()) {
            .enter => return,
            .back => return,
            .pointer => |mouse| {
                if (mouse.right_click) return;
                if (mouse.left_click) return;
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}
