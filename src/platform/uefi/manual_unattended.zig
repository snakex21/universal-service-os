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
    var options: [9]?[]const u8 = .{ null, null, null, null, null, null, null, null, null };
    var len: usize = 1;

    if (system.unattended_directory) |directory| {
        const found = discovery.listFilesWithExtension(directory, usos.flow.unattended_policy.extension(system), file_storage[0..]);
        var index: usize = 0;
        while (index < found) : (index += 1) {
            options[1 + index] = file_storage[index].slice();
        }
        len = 1 + found;
    }

    var rows: [9]view.ListRow = undefined;
    for (options[0..len], 0..) |option, index| rows[index] = .{ .plain = option orelse "None" };

    var selected: usize = 0;
    var list = view.ListScreen.open("unattended", "Select unattended file", rows[0..len], selected, len, null);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, list.visibleStart(), list.visibleCount())) {
            .activate => return .{ .path = options[selected] },
            .back => return .{ .back = true },
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}
