const usos = @import("usos");
const input = @import("input.zig");
const manual_power = @import("manual_power.zig");
const view = @import("manual_view.zig");

const category_count = usos.catalog.categories.all.len;
const power_index = category_count;
const item_count = category_count + 1;

pub fn select() usos.catalog.Category {
    var selected: usize = 0;
    render(selected);

    while (true) {
        switch (input.readBlocking()) {
            .up => selectIndex(&selected, moveVertical(selected, -1)),
            .down => selectIndex(&selected, moveVertical(selected, 1)),
            .left => selectIndex(&selected, moveHorizontal(selected, -1)),
            .right => selectIndex(&selected, moveHorizontal(selected, 1)),
            .enter => {
                if (selected == power_index) {
                    manual_power.show();
                    render(selected);
                    continue;
                }
                return usos.catalog.categories.all[selected];
            },
            .back => selectIndex(&selected, power_index),
            .pointer => |mouse| {
                if (mouse.right_click) {
                    selectIndex(&selected, power_index);
                    continue;
                }
                if (mouse.scroll != 0) {
                    const next = if (mouse.scroll > 0)
                        if (selected > 0) selected - 1 else selected
                    else if (selected + 1 < item_count)
                        selected + 1
                    else
                        selected;
                    selectIndex(&selected, next);
                    continue;
                }
                if (view.hitCategoryCard(mouse.x, mouse.y, item_count)) |index| {
                    selectIndex(&selected, index);
                    if (mouse.left_click) {
                        if (selected == power_index) {
                            manual_power.show();
                            render(selected);
                        } else {
                            return usos.catalog.categories.all[selected];
                        }
                    } else if (mouse.moved) {
                        view.updatePointer();
                    }
                } else if (mouse.moved) {
                    view.updatePointer();
                }
            },
            .other => {},
        }
    }
}

fn selectIndex(selected: *usize, next: usize) void {
    if (next == selected.*) return;
    const previous = selected.*;
    selected.* = next;
    redrawItem(previous, false);
    redrawItem(next, true);
}

fn render(selected: usize) void {
    view.beginHome();
    var index: usize = 0;
    while (index < item_count) : (index += 1) {
        view.categoryCard(index, index == selected, title(index), description(index), symbol(index));
    }
    view.footer(true);
}

fn redrawItem(index: usize, selected: bool) void {
    view.redrawCategoryCard(index, selected, title(index), description(index), symbol(index));
}

fn title(index: usize) []const u8 {
    if (index == power_index) return "POWER";
    return usos.catalog.categories.all[index].label();
}

fn description(index: usize) []const u8 {
    if (index == power_index) return "Restart, shut down or enter firmware setup";
    return switch (usos.catalog.categories.all[index]) {
        .windows => "Install and repair Microsoft Windows",
        .linux => "Linux installers and live systems",
        .beta => "Whistler, Longhorn and other builds",
        .dos => "DOS systems and legacy boot images",
        .utilities => "Diagnostics, recovery and firmware tools",
    };
}

fn symbol(index: usize) []const u8 {
    if (index == power_index) return "P";
    return switch (usos.catalog.categories.all[index]) {
        .windows => "W",
        .linux => "L",
        .beta => "B",
        .dos => "D",
        .utilities => "+",
    };
}

fn moveHorizontal(selected: usize, direction: i8) usize {
    if (direction < 0) {
        return if (selected % 2 == 1) selected - 1 else selected;
    }
    return if (selected % 2 == 0 and selected + 1 < item_count) selected + 1 else selected;
}

fn moveVertical(selected: usize, direction: i8) usize {
    if (direction < 0) return if (selected >= 2) selected - 2 else selected;
    return if (selected + 2 < item_count) selected + 2 else selected;
}
