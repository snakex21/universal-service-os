const usos = @import("usos");
const input = @import("input.zig");
const view = @import("manual_view.zig");

pub const Result = enum {
    changed,
    activate,
    back,
    pointer_moved,
    ignored,
};

pub fn handle(event: input.Event, selected: *usize, total: usize, visible_start: usize, visible_count: usize) Result {
    return handleInternal(event, selected, total, visible_start, visible_count, null);
}

pub fn handleSelectable(
    event: input.Event,
    selected: *usize,
    total: usize,
    visible_start: usize,
    visible_count: usize,
    selectable: []const bool,
) Result {
    if (selectable.len < total) return .ignored;
    return handleInternal(event, selected, total, visible_start, visible_count, selectable);
}

fn handleInternal(
    event: input.Event,
    selected: *usize,
    total: usize,
    visible_start: usize,
    visible_count: usize,
    selectable: ?[]const bool,
) Result {
    if (total == 0) return .ignored;

    return switch (event) {
        .up => moveWrapped(selected, total, selectable, false),
        .down => moveWrapped(selected, total, selectable, true),
        .left, .right => .ignored,
        .enter => if (isSelectable(selectable, selected.*)) .activate else .ignored,
        .back => .back,
        .pointer => |mouse| blk: {
            if (mouse.right_click) break :blk .back;
            if (mouse.scroll != 0) {
                if (selectable) |items| {
                    if (usos.gui.selectable_list.stepLinear(items[0..total], selected.*, mouse.scroll < 0)) |next| {
                        selected.* = next;
                        break :blk .changed;
                    }
                } else {
                    const before = selected.*;
                    if (mouse.scroll > 0) {
                        if (selected.* > 0) selected.* -= 1;
                    } else if (selected.* + 1 < total) {
                        selected.* += 1;
                    }
                    if (selected.* != before) break :blk .changed;
                }
            }
            if (view.hitRow(mouse.x, mouse.y, visible_count)) |visible_index| {
                const index = visible_start + visible_index;
                if (index < total and isSelectable(selectable, index)) {
                    const changed = index != selected.*;
                    selected.* = index;
                    if (mouse.left_click) break :blk .activate;
                    if (changed) break :blk .changed;
                }
            }
            break :blk if (mouse.moved) .pointer_moved else .ignored;
        },
        .other => .ignored,
    };
}

fn moveWrapped(selected: *usize, total: usize, selectable: ?[]const bool, forward: bool) Result {
    if (selectable) |items| {
        const next = usos.gui.selectable_list.stepWrapped(items[0..total], selected.*, forward) orelse return .ignored;
        if (next == selected.*) return .ignored;
        selected.* = next;
        return .changed;
    }

    selected.* = if (forward)
        (selected.* + 1) % total
    else if (selected.* == 0)
        total - 1
    else
        selected.* - 1;
    return .changed;
}

fn isSelectable(selectable: ?[]const bool, index: usize) bool {
    return if (selectable) |items| index < items.len and items[index] else true;
}
