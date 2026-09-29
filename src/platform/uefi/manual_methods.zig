//! Boot method choice. Only methods that can actually run here are listed:
//! methods that do not fit the image type, have no backend yet or need the
//! other firmware mode are left out instead of shown as disabled filler.
//! A single runnable method is used without asking (`automatic`): Back on
//! the next screen then returns to the image list, since there is no method
//! screen to go back to.
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

const model_mod = usos.gui.boot_method_model;

/// The last select() returned its single runnable method without a screen.
pub var automatic = false;

pub fn select(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem, firmware: usos.firmware.Firmware) ?usos.catalog.BootMethod {
    const model = model_mod.collect(system, image.kind, firmware);
    automatic = false;
    if (model.enabledCount() == 0) {
        const lines = [_][]const u8{view.t(.methods_none)};
        view.notice(image.name.slice(), .warning, .warning, view.t(.error_unsupported_title), &lines);
        view.waitForDismiss();
        return null;
    }
    if (model.singleEnabledIndex()) |index| {
        automatic = true;
        return model.items[index].method;
    }

    var map: [model_mod.max_items]usize = undefined;
    var rows: [model_mod.max_items]usos.gui.ui.Row = undefined;
    var count: usize = 0;
    for (model.items[0..model.len], 0..) |*item, index| {
        if (!item.enabled) continue;
        map[count] = index;
        rows[count] = .{ .title = label(item), .badge = badge(item, count == 0) };
        count += 1;
    }

    var selected: usize = 0;
    var help_lines: [3][]const u8 = undefined;
    var list: view.ListScreen = undefined;
    list.open(view.t(.methods_title), image.name.slice(), rows[0..count], selected, false, help(&model.items[map[selected]], &help_lines));

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, count, &list)) {
            .activate => return model.items[map[selected]].method,
            .back => return null,
            .changed => list.updateSelection(selected, help(&model.items[map[selected]], &help_lines)),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

/// The method label without the validation suffix (shown as a badge).
pub fn label(item: *const model_mod.Item) []const u8 {
    var text = item.label.slice();
    if (item.validation_status) |status| {
        const suffix = status.badge();
        if (suffix.len > 0 and std.mem.endsWith(u8, text, suffix)) text = std.mem.trimEnd(u8, text[0 .. text.len - suffix.len], " ");
    }
    return view.tr(text);
}

pub fn badge(item: *const model_mod.Item, recommended: bool) ?usos.gui.ui.Badge {
    const status = item.validation_status orelse return if (recommended) .{ .text = view.t(.badge_recommended), .tone = .accent } else null;
    return switch (status) {
        .validated_hardware => if (recommended and item.method == .automatic) .{ .text = view.t(.badge_recommended), .tone = .accent } else .{ .text = view.t(.badge_ready), .tone = .success },
        // A dimmed dot, no label: the details pane says "Tested in a virtual machine".
        .tested_in_vm => .{ .text = "", .dot = true },
        .experimental => .{ .text = view.t(.badge_experimental), .tone = .warning },
    };
}

fn help(item: *const model_mod.Item, lines: *[3][]const u8) usos.gui.menu_screens.Help {
    lines.* = .{ view.tr(item.help.line1), view.tr(item.help.line2), verification(item) };
    const pill = badge(item, false);
    return .{ .title = view.tr(item.help.title), .lines = lines, .badge = if (pill != null and pill.?.dot) null else pill };
}

/// Where the method was verified, in words (the list row shows a pill or a dot).
fn verification(item: *const model_mod.Item) []const u8 {
    const status = item.validation_status orelse return "";
    return switch (status) {
        .validated_hardware => view.t(.verify_hardware),
        .tested_in_vm => view.t(.verify_vm),
        .experimental => "",
    };
}
