const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const system_media_scan = @import("system_media_scan.zig");
const view = @import("manual_view.zig");

const visible_rows: usize = 12;

pub fn select(root: *std.os.uefi.protocol.File, category: usos.catalog.Category) ?*const usos.catalog.SystemEntry {
    const count = usos.catalog.systems.countInCategory(category);
    if (count == 0) return null;

    var selected: usize = 0;
    var start = visibleStart(selected);
    render(root, category, selected, count, start);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, count, start, @min(visible_rows, count - start))) {
            .activate => {
                if (usos.catalog.systems.byCategoryIndex(category, selected)) |entry| {
                    if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
                        showBackendDisabledNotice(entry);
                        render(root, category, selected, count, start);
                        continue;
                    }
                    if (system_media_scan.scan(root, entry).hasImages()) return entry;
                    showMissingImageNotice(entry);
                    render(root, category, selected, count, start);
                }
            },
            .back => return null,
            .changed => {
                start = visibleStart(selected);
                render(root, category, selected, count, start);
            },
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn visibleStart(selected: usize) usize {
    return if (selected >= visible_rows) selected - visible_rows + 1 else 0;
}

fn render(root: *std.os.uefi.protocol.File, category: usos.catalog.Category, selected: usize, count: usize, start: usize) void {
    view.begin("systems", category.label());
    const end = @min(start + visible_rows, count);

    var index = start;
    while (index < end) : (index += 1) {
        const entry = usos.catalog.systems.byCategoryIndex(category, index) orelse continue;
        const icon = system_icons.get(root, entry.id);
        if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
            view.systemRowDisabled(index == selected, entry.name, icon, "[backend: Windows 11 + ISO only]");
        } else if (system_media_scan.scan(root, entry).hasImages()) {
            view.systemRow(index == selected, entry.name, icon);
        } else {
            view.systemRowDisabled(index == selected, entry.name, icon, "[no image]");
        }
    }

    view.footer(true);
}

fn showMissingImageNotice(entry: *const usos.catalog.SystemEntry) void {
    view.begin("systems", entry.name);
    view.row(false, "No image files found for this system.");
    view.row(false, "Copy ISO/WIM/IMG/VHD/VHDX/EFI into Images first.");
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
