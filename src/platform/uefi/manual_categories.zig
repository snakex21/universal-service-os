const usos = @import("usos");
const input = @import("input.zig");
const manual_power = @import("manual_power.zig");
const manual_secure_boot = @import("manual_secure_boot.zig");
const view = @import("manual_view.zig");

const category_count = usos.catalog.categories.all.len;
const power_index = category_count;
const item_count = category_count + 1;

pub fn select() usos.catalog.Category {
    var items: [item_count]usos.gui.menu_screens.HomeItem = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .icon = icon(index), .title = title(index), .description = description(index) };
    var home: view.Home = undefined;
    home.open(&items, 0, manual_secure_boot.banner());

    while (true) {
        switch (input.readBlocking()) {
            .up => home.select(moveVertical(home.selected, -1, home.count())),
            .down => home.select(moveVertical(home.selected, 1, home.count())),
            .left => home.select(moveHorizontal(home.selected, -1)),
            .right => home.select(moveHorizontal(home.selected, 1)),
            .enter => {
                if (home.selected == item_count) {
                    openBanner(&home);
                    continue;
                }
                if (home.selected == power_index) {
                    manual_power.show();
                    home.redraw();
                    continue;
                }
                return usos.catalog.categories.all[home.selected];
            },
            .back => home.select(power_index),
            .pointer => |mouse| {
                if (mouse.right_click) {
                    home.select(power_index);
                    continue;
                }
                if (mouse.scroll != 0) {
                    const selected = home.selected;
                    const next = if (mouse.scroll > 0)
                        if (selected > 0) selected - 1 else selected
                    else if (selected + 1 < home.count())
                        selected + 1
                    else
                        selected;
                    home.select(next);
                    continue;
                }
                if (mouse.left_click) {
                    if (view.hitCategoryCard(mouse.x, mouse.y)) |index| {
                        home.select(index);
                        if (index == item_count) {
                            openBanner(&home);
                            continue;
                        }
                        if (index == power_index) {
                            manual_power.show();
                            home.redraw();
                            continue;
                        }
                        return usos.catalog.categories.all[index];
                    }
                }
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}

/// The Secure Boot key offer under the cards: after it the banner may be
/// gone (saved, "Not now", "Don't ask again").
fn openBanner(home: *view.Home) void {
    manual_secure_boot.offer();
    home.selected = 0;
    home.setBanner(manual_secure_boot.banner());
}

fn title(index: usize) []const u8 {
    if (index == power_index) return view.t(.category_power);
    return view.tr(usos.catalog.categories.all[index].label());
}

fn description(index: usize) []const u8 {
    if (index == power_index) return view.t(.category_power_desc);
    return switch (usos.catalog.categories.all[index]) {
        .windows => view.t(.category_windows_desc),
        .linux => view.t(.category_linux_desc),
        .beta => view.t(.category_beta_desc),
        .dos => view.t(.category_dos_desc),
        .utilities => view.t(.category_utilities_desc),
    };
}

pub fn icon(index: usize) usos.gui.icons.Kind {
    if (index == power_index) return .power;
    return switch (usos.catalog.categories.all[index]) {
        .windows => .windows,
        .linux => .terminal,
        .beta => .flask,
        .dos => .floppy,
        .utilities => .gear,
    };
}

fn moveHorizontal(selected: usize, direction: i8) usize {
    if (selected >= item_count) return selected;
    if (direction < 0) {
        return if (selected % 2 == 1) selected - 1 else selected;
    }
    return if (selected % 2 == 0 and selected + 1 < item_count) selected + 1 else selected;
}

/// Up/down through the 2-column grid; the banner (index item_count, when
/// `count` includes it) sits below the last row.
fn moveVertical(selected: usize, direction: i8, count: usize) usize {
    if (selected >= item_count) return if (direction < 0) item_count - 2 else selected;
    if (direction < 0) return if (selected >= 2) selected - 2 else selected;
    if (selected + 2 < item_count) return selected + 2;
    return if (count > item_count) item_count else selected;
}
