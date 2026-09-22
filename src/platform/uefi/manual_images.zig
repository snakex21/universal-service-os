const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

const visible_rows: usize = 12;

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) ?usos.catalog.ImageItem {
    const images = discovery.images(system.image_directory);
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

    var rows: [usos.catalog.image_list_max_items]view.ListRow = undefined;
    for (images.items[0..images.len], 0..) |*image, index| {
        rows[index] = .{ .parts = .{ .first = kindPrefix(image.kind), .second = image.name.slice() } };
    }

    var selected: usize = 0;
    var list = view.ListScreen.open("images", system.name, rows[0..images.len], selected, visible_rows, null);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, images.len, list.visibleStart(), list.visibleCount())) {
            .activate => return images.items[selected],
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
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
