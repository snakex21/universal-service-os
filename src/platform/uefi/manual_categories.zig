const usos = @import("usos");
const input = @import("input.zig");
const view = @import("manual_view.zig");

pub fn select() ?usos.catalog.Category {
    var selected: usize = 0;
    render(selected);

    while (true) {
        switch (input.readBlocking()) {
            .up => {
                const next = moveVertical(selected, -1);
                if (next != selected) {
                    selected = next;
                    render(selected);
                }
            },
            .down => {
                const next = moveVertical(selected, 1);
                if (next != selected) {
                    selected = next;
                    render(selected);
                }
            },
            .left => {
                const next = moveHorizontal(selected, -1);
                if (next != selected) {
                    selected = next;
                    render(selected);
                }
            },
            .right => {
                const next = moveHorizontal(selected, 1);
                if (next != selected) {
                    selected = next;
                    render(selected);
                }
            },
            .enter => return usos.catalog.categories.all[selected],
            .back => return null,
            .pointer => |mouse| {
                if (mouse.right_click) return null;
                if (mouse.scroll != 0) {
                    const before = selected;
                    if (mouse.scroll > 0) {
                        if (selected > 0) selected -= 1;
                    } else if (selected + 1 < usos.catalog.categories.all.len) {
                        selected += 1;
                    }
                    if (selected != before) render(selected) else if (mouse.moved) view.updatePointer();
                    continue;
                }
                if (view.hitCategoryCard(mouse.x, mouse.y, usos.catalog.categories.all.len)) |index| {
                    if (index != selected) {
                        selected = index;
                        render(selected);
                    } else if (mouse.moved) {
                        view.updatePointer();
                    }
                    if (mouse.left_click) return usos.catalog.categories.all[selected];
                } else if (mouse.moved) {
                    view.updatePointer();
                }
            },
            .other => {},
        }
    }
}

fn render(selected: usize) void {
    view.beginHome();
    for (usos.catalog.categories.all, 0..) |category, index| {
        view.categoryCard(index, index == selected, category.label(), description(category), symbol(category));
    }
    view.footer(true);
}

fn description(category: usos.catalog.Category) []const u8 {
    return switch (category) {
        .windows => "Install and repair Microsoft Windows",
        .linux => "Linux installers and live systems",
        .beta => "Whistler, Longhorn and other builds",
        .dos => "DOS systems and legacy boot images",
        .utilities => "Diagnostics, recovery and firmware tools",
    };
}

fn symbol(category: usos.catalog.Category) []const u8 {
    return switch (category) {
        .windows => "W",
        .linux => "L",
        .beta => "B",
        .dos => "D",
        .utilities => "+",
    };
}

fn moveHorizontal(selected: usize, direction: i8) usize {
    const count = usos.catalog.categories.all.len;
    if (direction < 0) {
        return if (selected % 2 == 1) selected - 1 else selected;
    }
    return if (selected % 2 == 0 and selected + 1 < count) selected + 1 else selected;
}

fn moveVertical(selected: usize, direction: i8) usize {
    const count = usos.catalog.categories.all.len;
    if (direction < 0) return if (selected >= 2) selected - 2 else selected;
    return if (selected + 2 < count) selected + 2 else selected;
}
