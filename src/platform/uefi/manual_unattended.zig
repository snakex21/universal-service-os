const std = @import("std");
const usos = @import("usos");
const directory_scan = @import("directory_scan.zig");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub const Result = struct {
    back: bool = false,
    path: ?[]const u8 = null,
};

var file_storage: [8]usos.catalog.FixedText = undefined;

pub fn select(root: *std.os.uefi.protocol.File, system: *const usos.catalog.SystemEntry) Result {
    var options: [9]?[]const u8 = .{ null, null, null, null, null, null, null, null, null };
    var len: usize = 1;

    if (system.unattended_directory) |directory| {
        const found = directory_scan.listXmlFiles(root, directory, file_storage[0..]);
        var index: usize = 0;
        while (index < found) : (index += 1) {
            options[1 + index] = file_storage[index].slice();
        }
        len = 1 + found;
    }

    var selected: usize = 0;
    render(&options, len, selected);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, 0, len)) {
            .activate => return .{ .path = options[selected] },
            .back => return .{ .back = true },
            .changed => render(&options, len, selected),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn render(options: *const [9]?[]const u8, len: usize, selected: usize) void {
    view.begin("unattended", "Select unattended file");
    for (options[0..len], 0..) |option, index| {
        view.row(index == selected, option orelse "None");
    }
    view.footer(true);
}
