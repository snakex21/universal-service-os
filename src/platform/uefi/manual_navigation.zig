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
    if (total == 0) return .ignored;

    return switch (event) {
        .up => blk: {
            selected.* = if (selected.* == 0) total - 1 else selected.* - 1;
            break :blk .changed;
        },
        .down => blk: {
            selected.* = (selected.* + 1) % total;
            break :blk .changed;
        },
        .left, .right => .ignored,
        .enter => .activate,
        .back => .back,
        .pointer => |mouse| blk: {
            if (mouse.right_click) break :blk .back;
            if (mouse.scroll != 0) {
                const before = selected.*;
                if (mouse.scroll > 0) {
                    if (selected.* > 0) selected.* -= 1;
                } else if (selected.* + 1 < total) {
                    selected.* += 1;
                }
                if (selected.* != before) break :blk .changed;
            }
            if (view.hitRow(mouse.x, mouse.y, visible_count)) |visible_index| {
                const index = visible_start + visible_index;
                if (index < total) {
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
