//! List navigation shared by every UEFI list screen: arrows (and the
//! firmware-emulated controls of handhelds, which arrive as arrows, Enter
//! and Esc), Page Up/Down, Home/End, the mouse wheel, hover, click/tap and
//! drag-to-scroll. A list that does not fit scrolls its view with the
//! wheel or a drag and the selection follows the view; a list that fits
//! moves the selection instead.
const usos = @import("usos");
const input = @import("input.zig");
const view = @import("manual_view.zig");

const input_map = usos.gui.input_map;

pub const Result = enum {
    changed,
    activate,
    back,
    pointer_moved,
    ignored,
};

var drag_scroll = input_map.DragScroll{};

pub fn handle(event: input.Event, selected: *usize, total: usize, list: *view.ListScreen) Result {
    return handleInternal(event, selected, total, list, null);
}

pub fn handleSelectable(
    event: input.Event,
    selected: *usize,
    total: usize,
    list: *view.ListScreen,
    selectable: []const bool,
) Result {
    if (selectable.len < total) return .ignored;
    return handleInternal(event, selected, total, list, selectable[0..total]);
}

fn handleInternal(
    event: input.Event,
    selected: *usize,
    total: usize,
    list: *view.ListScreen,
    selectable: ?[]const bool,
) Result {
    if (total == 0) return .ignored;

    return switch (event) {
        .up => moveWrapped(selected, total, selectable, false),
        .down => moveWrapped(selected, total, selectable, true),
        .page_up => jump(selected, total, selectable, -@as(i64, @intCast(@max(1, list.visibleCount())))),
        .page_down => jump(selected, total, selectable, @intCast(@max(1, list.visibleCount()))),
        .home => jump(selected, total, selectable, -@as(i64, @intCast(total))),
        .end => jump(selected, total, selectable, @intCast(total)),
        .left, .right => .ignored,
        .enter => if (isSelectable(selectable, selected.*)) .activate else .ignored,
        .back => .back,
        .pointer => |mouse| pointerEvent(mouse, selected, total, list, selectable),
        .other => .ignored,
    };
}

fn pointerEvent(mouse: @import("pointer.zig").Event, selected: *usize, total: usize, list: *view.ListScreen, selectable: ?[]const bool) Result {
    if (mouse.right_click) return .back;

    if (mouse.scroll != 0) {
        const before = selected.*;
        if (list.overflows()) {
            // Positive notches turn the wheel away: towards the list start.
            selected.* = list.scrollBy(-@as(i32, mouse.scroll), selectable);
        } else {
            stepLinear(selected, total, selectable, mouse.scroll < 0, @abs(mouse.scroll));
        }
        return if (selected.* != before) .changed else .ignored;
    }

    if (mouse.dragging or mouse.drag_dy != 0) {
        if (mouse.drag_dy != 0 and list.overflows()) {
            const rows = drag_scroll.feed(mouse.drag_dy, list.rowPitch());
            if (rows != 0) {
                const before = selected.*;
                selected.* = list.scrollBy(rows, selectable);
                if (selected.* != before) return .changed;
            }
        }
        return if (mouse.moved) .pointer_moved else .ignored;
    }
    drag_scroll.reset();

    const visible_start = list.visibleStart();
    const visible_count = list.visibleCount();
    if (view.hitRow(mouse.x, mouse.y, visible_count)) |visible_index| {
        const index = visible_start + visible_index;
        if (index < total and isSelectable(selectable, index)) {
            const changed = index != selected.*;
            selected.* = index;
            if (mouse.left_click) return .activate;
            if (changed) return .changed;
        }
    }
    return if (mouse.moved) .pointer_moved else .ignored;
}

fn stepLinear(selected: *usize, total: usize, selectable: ?[]const bool, forward: bool, steps: u8) void {
    var remaining = steps;
    while (remaining > 0) : (remaining -= 1) {
        if (selectable) |items| {
            selected.* = usos.gui.selectable_list.stepLinear(items, selected.*, forward) orelse return;
        } else if (forward) {
            if (selected.* + 1 >= total) return;
            selected.* += 1;
        } else {
            if (selected.* == 0) return;
            selected.* -= 1;
        }
    }
}

fn jump(selected: *usize, total: usize, selectable: ?[]const bool, delta: i64) Result {
    const before = selected.*;
    const target: usize = @intCast(@max(0, @min(@as(i64, @intCast(total)) - 1, @as(i64, @intCast(before)) + delta)));
    if (isSelectable(selectable, target)) {
        selected.* = target;
    } else if (selectable) |items| {
        // Nearest selectable row in the jump direction, else backwards.
        const forward = delta > 0;
        selected.* = usos.gui.selectable_list.stepLinear(items, target, forward) orelse
            usos.gui.selectable_list.stepLinear(items, target, !forward) orelse before;
    }
    return if (selected.* != before) .changed else .ignored;
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
