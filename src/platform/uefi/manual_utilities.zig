const std = @import("std");
const usos = @import("usos");
const directory_scan = @import("directory_scan.zig");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const system_icons = @import("system_icons.zig");
const system_media_scan = @import("system_media_scan.zig");
const view = @import("manual_view.zig");

const max_utilities: usize = 32;
const max_path_bytes: usize = 260;
const visible_rows: usize = 12;
const utilities_root = "\\Utilities";
const path_prefix = "\\Utilities\\";
const images_suffix = "\\Images";

var names: [max_utilities]usos.catalog.FixedText = undefined;
var paths: [max_utilities][max_path_bytes]u8 = undefined;
var entries: [max_utilities]usos.catalog.SystemEntry = undefined;

pub fn select(root: *std.os.uefi.protocol.File) ?*const usos.catalog.SystemEntry {
    const count = scan(root);
    if (count == 0) {
        showEmpty();
        return null;
    }

    var selected: usize = 0;
    var start = visibleStart(selected);
    render(root, selected, count, start);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, count, start, @min(visible_rows, count - start))) {
            .activate => {
                const entry = &entries[selected];
                const media = system_media_scan.scan(root, entry);
                if (!media.hasImages()) {
                    showMissingImageNotice(entry);
                    render(root, selected, count, start);
                    continue;
                }
                if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
                    showBackendDisabledNotice(entry);
                    render(root, selected, count, start);
                    continue;
                }
                return entry;
            },
            .back => return null,
            .changed => {
                start = visibleStart(selected);
                render(root, selected, count, start);
            },
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn scan(root: *std.os.uefi.protocol.File) usize {
    const count = directory_scan.listDirectories(root, utilities_root, &names);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const name = names[index].slice();
        const image_directory = buildImageDirectory(name, &paths[index]) orelse continue;
        entries[index] = .{
            .id = name,
            .name = name,
            .category = .utilities,
            .family = .utility,
            .image_directory = image_directory,
            .boot_methods = &usos.catalog.utility_boot_methods.all,
        };
    }
    return count;
}

fn buildImageDirectory(name: []const u8, buffer: *[max_path_bytes]u8) ?[]const u8 {
    const needed = path_prefix.len + name.len + images_suffix.len;
    if (needed > buffer.len) return null;
    var offset: usize = 0;
    @memcpy(buffer[offset .. offset + path_prefix.len], path_prefix);
    offset += path_prefix.len;
    @memcpy(buffer[offset .. offset + name.len], name);
    offset += name.len;
    @memcpy(buffer[offset .. offset + images_suffix.len], images_suffix);
    offset += images_suffix.len;
    return buffer[0..offset];
}

fn visibleStart(selected: usize) usize {
    return if (selected >= visible_rows) selected - visible_rows + 1 else 0;
}

fn render(root: *std.os.uefi.protocol.File, selected: usize, count: usize, start: usize) void {
    view.begin("systems", "Utilities");
    const end = @min(start + visible_rows, count);
    var index = start;
    while (index < end) : (index += 1) {
        const entry = &entries[index];
        const icon = system_icons.get(root, entry);
        const media = system_media_scan.scan(root, entry);
        if (!media.hasImages()) {
            view.systemRowDisabled(index == selected, entry.name, icon, "[no image]");
        } else if (!usos.flow.preparation_capability.supportsSystem(entry.id)) {
            view.systemRowDisabled(index == selected, entry.name, icon, "[backend unavailable]");
        } else {
            view.systemRow(index == selected, entry.name, icon);
        }
    }
    view.footer(true);
}

fn showEmpty() void {
    view.begin("systems", "Utilities");
    view.row(false, "No utility folders found.");
    view.row(false, "Create Utilities/<tool name>/Images on DATA, then run Update USOS.");
    waitForDismiss();
}

fn showMissingImageNotice(entry: *const usos.catalog.SystemEntry) void {
    view.begin("systems", entry.name);
    view.row(false, "No supported image files found in this utility folder.");
    view.row(false, "Copy ISO/WIM/IMG/VHD/VHDX/EFI into Images and run Update USOS.");
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

test "dynamic utility image directory follows folder name" {
    var buffer: [max_path_bytes]u8 = undefined;
    const path = buildImageDirectory("MemTest86", &buffer).?;
    try std.testing.expectEqualStrings("\\Utilities\\MemTest86\\Images", path);
}
