//! Answer file choice. When the system's Unattended folder has no answer
//! files there is nothing to choose, so the screen is skipped.
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub const Result = struct {
    back: bool = false,
    path: ?[]const u8 = null,
};

var file_storage: [8]usos.catalog.FixedText = undefined;

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) Result {
    const directory = system.unattended_directory orelse return .{};
    const found = discovery.listFilesWithExtension(directory, usos.flow.unattended_policy.extension(system), file_storage[0..]);
    if (found == 0) return .{};

    var options: [9]?[]const u8 = undefined;
    var rows: [9]usos.gui.ui.Row = undefined;
    options[0] = null;
    rows[0] = .{ .title = view.t(.unattended_none), .icon = .{ .vector = .close } };
    for (0..found) |index| {
        options[1 + index] = file_storage[index].slice();
        rows[1 + index] = .{ .title = file_storage[index].slice(), .icon = .{ .label = usos.flow.unattended_policy.fileKindLabel(system) } };
    }
    const len = 1 + found;

    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.t(.unattended_title), view.t(.unattended_subtitle), rows[0..len], selected, false, help(selected));

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, &list)) {
            .activate => return .{ .path = options[selected] },
            .back => return .{ .back = true },
            .changed => list.updateSelection(selected, help(selected)),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

var help_line: [1][]const u8 = undefined;

fn help(selected: usize) usos.gui.menu_screens.Help {
    help_line[0] = if (selected == 0) view.t(.unattended_none_detail) else view.t(.unattended_file_detail);
    return .{ .title = view.t(.unattended_title), .lines = &help_line };
}
