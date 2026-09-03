const std = @import("std");
const usos = @import("usos");
const image_scan = @import("image_scan.zig");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

const visible_rows: usize = 12;

pub fn select(root: *std.os.uefi.protocol.File, system: *const usos.catalog.SystemEntry) ?usos.catalog.ImageItem {
    const images = image_scan.scan(root, system.image_directory);
    if (images.len == 0) {
        view.begin("images", system.name);
        view.row(false, "No supported image files found in Images.");
        view.row(false, "Copy ISO/WIM/IMG/VHD/VHDX/EFI into Images and retry.");
        view.footer(true);
        while (true) {
            switch (input.readBlocking()) {
                .enter => return null,
                .back => return null,
                .pointer => |mouse| {
                    if (mouse.right_click) return null;
                    if (mouse.left_click) return null;
                    if (mouse.moved) view.updatePointer();
                },
                else => {},
            }
        }
    }

    var selected: usize = 0;
    var start = visibleStart(selected);
    render(system.name, &images, selected, start);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, images.len, start, @min(visible_rows, images.len - start))) {
            .activate => return images.items[selected],
            .back => return null,
            .changed => {
                start = visibleStart(selected);
                render(system.name, &images, selected, start);
            },
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn visibleStart(selected: usize) usize {
    return if (selected >= visible_rows) selected - visible_rows + 1 else 0;
}

fn render(system_name: []const u8, images: *const usos.catalog.ImageList, selected: usize, start: usize) void {
    view.begin("images", system_name);
    const end = @min(start + visible_rows, images.len);

    for (images.items[start..end], start..) |image, index| {
        view.rowParts(index == selected, kindPrefix(image.kind), image.name.slice());
    }
    view.footer(true);
}

fn kindPrefix(kind: usos.catalog.ImageKind) []const u8 {
    return switch (kind) {
        .iso => "[ISO] ",
        .wim => "[WIM] ",
        .img => "[IMG] ",
        .vhd => "[VHD] ",
        .vhdx => "[VHDX] ",
        .efi => "[EFI] ",
    };
}
