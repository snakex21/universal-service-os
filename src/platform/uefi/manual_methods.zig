const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub fn select(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem, firmware: usos.firmware.Firmware) ?usos.catalog.BootMethod {
    const model = usos.gui.boot_method_model.collect(system, image.kind, firmware);
    if (model.len == 0) {
        showNoMethodNotice(image);
        return null;
    }
    if (model.singleEnabledIndex()) |index| return model.items[index].method;

    var selectable_storage: [usos.gui.boot_method_model.max_items]bool = undefined;
    const selectable = model.selectable(&selectable_storage);
    var rows: [usos.gui.boot_method_model.max_items]view.ListRow = undefined;
    for (model.items[0..model.len], 0..) |*item, index| {
        rows[index] = if (item.enabled)
            .{ .plain = item.label.slice() }
        else
            .{ .disabled = .{ .value = item.label.slice(), .reason = item.reason } };
    }

    var selected: usize = usos.gui.selectable_list.first(selectable) orelse 0;
    var list = view.ListScreen.open("methods", image.name.slice(), rows[0..model.len], selected, model.len, helpFor(&model.items[selected]));

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, model.len, list.visibleStart(), list.visibleCount(), selectable)) {
            .activate => {
                if (model.items[selected].enabled) return model.items[selected].method;
            },
            .back => return null,
            .changed => list.updateSelection(selected, helpFor(&model.items[selected])),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn helpFor(item: *const usos.gui.boot_method_model.Item) view.ListHelp {
    return .{
        .title = item.help.title,
        .line1 = item.help.line1,
        .line2 = item.help.line2,
        .status = item.statusLabel(),
    };
}

fn showNoMethodNotice(image: usos.catalog.ImageItem) void {
    view.begin("methods", image.name.slice());
    view.row(false, "No boot methods are configured for this system.");
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
