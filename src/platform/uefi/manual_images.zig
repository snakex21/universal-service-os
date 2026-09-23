const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) ?usos.catalog.ImageItem {
    const images = discovery.images(system.image_directory);
    if (images.len == 0) {
        const lines = [_][]const u8{ view.t(.images_none_line1), view.t(.images_none_line2) };
        view.notice(system.name, .warning, .warning, view.t(.notice_no_image_title), &lines);
        view.waitForDismiss();
        return null;
    }

    var rows: [usos.catalog.image_list_max_items]usos.gui.ui.Row = undefined;
    for (images.items[0..images.len], 0..) |*image, index| {
        rows[index] = .{ .title = image.name.slice(), .icon = .{ .label = kindLabel(image.kind) } };
    }

    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(system.name, view.t(.images_subtitle), rows[0..images.len], selected, false, null);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, images.len, &list)) {
            .activate => return images.items[selected],
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

pub fn kindLabel(kind: usos.catalog.ImageKind) []const u8 {
    return switch (kind) {
        .iso => "ISO",
        .wim => "WIM",
        .img => "IMG",
        .vhd => "VHD",
        .vhdx => "VHDX",
        .efi => "EFI",
    };
}
