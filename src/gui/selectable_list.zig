pub fn first(items: []const bool) ?usize {
    for (items, 0..) |selectable, index| {
        if (selectable) return index;
    }
    return null;
}

pub fn stepWrapped(items: []const bool, current: usize, forward: bool) ?usize {
    if (items.len == 0) return null;
    var index = if (current < items.len) current else 0;
    var checked: usize = 0;
    while (checked < items.len) : (checked += 1) {
        index = if (forward)
            (index + 1) % items.len
        else if (index == 0)
            items.len - 1
        else
            index - 1;
        if (items[index]) return index;
    }
    return null;
}

pub fn stepLinear(items: []const bool, current: usize, forward: bool) ?usize {
    if (items.len == 0 or current >= items.len) return null;
    if (forward) {
        var index = current + 1;
        while (index < items.len) : (index += 1) {
            if (items[index]) return index;
        }
        return null;
    }

    var index = current;
    while (index > 0) {
        index -= 1;
        if (items[index]) return index;
    }
    return null;
}

/// Wrapped one-row move for list screens; `items` null = every row selectable.
pub fn move(items: ?[]const bool, count: usize, current: usize, forward: bool) ?usize {
    if (count == 0) return null;
    if (items) |mask| return stepWrapped(mask[0..@min(count, mask.len)], current, forward);
    return if (forward) (current + 1) % count else if (current == 0 or current >= count) count - 1 else current - 1;
}

/// Up to `steps` linear moves (the wheel on a list that fits), stopping at
/// the list edges.
pub fn stepLinearBy(items: ?[]const bool, count: usize, current: usize, forward: bool, steps: usize) usize {
    var selected = current;
    var remaining = steps;
    while (remaining > 0) : (remaining -= 1) {
        if (items) |mask| {
            selected = stepLinear(mask[0..@min(count, mask.len)], selected, forward) orelse return selected;
        } else if (forward) {
            if (selected + 1 >= count) return selected;
            selected += 1;
        } else {
            if (selected == 0) return selected;
            selected -= 1;
        }
    }
    return selected;
}

/// Page Up/Down and Home/End: jumps `delta` rows, clamped to the list, then
/// to the nearest selectable row in the jump direction (else backwards).
pub fn jump(items: ?[]const bool, count: usize, current: usize, delta: i64) usize {
    if (count == 0) return current;
    const target: usize = @intCast(@max(0, @min(@as(i64, @intCast(count)) - 1, @as(i64, @intCast(current)) + delta)));
    const mask = items orelse return target;
    const bounded = mask[0..@min(count, mask.len)];
    if (target < bounded.len and bounded[target]) return target;
    const forward = delta > 0;
    return stepLinear(bounded, target, forward) orelse stepLinear(bounded, target, !forward) orelse current;
}

test "selection starts on first enabled row" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?usize, 2), first(&.{ false, false, true, true }));
    try std.testing.expect(first(&.{ false, false }) == null);
}

test "wrapped movement skips disabled rows in both directions" {
    const std = @import("std");
    const items = [_]bool{ true, false, false, true };
    try std.testing.expectEqual(@as(?usize, 3), stepWrapped(&items, 0, true));
    try std.testing.expectEqual(@as(?usize, 0), stepWrapped(&items, 3, true));
    try std.testing.expectEqual(@as(?usize, 0), stepWrapped(&items, 3, false));
    try std.testing.expectEqual(@as(?usize, 3), stepWrapped(&items, 0, false));
}

test "linear movement stops at edge instead of selecting disabled row" {
    const std = @import("std");
    const items = [_]bool{ true, false, true, false };
    try std.testing.expectEqual(@as(?usize, 2), stepLinear(&items, 0, true));
    try std.testing.expect(stepLinear(&items, 2, true) == null);
    try std.testing.expectEqual(@as(?usize, 0), stepLinear(&items, 2, false));
}

/// The Windows category as the UEFI menu sees it with Secure Boot on:
/// Windows 11..8 ready, 7/Vista/XP need Secure Boot off, 2000..3.1 need
/// BIOS. Every row must stay reachable; only launching is refused.
const TestRow = struct { firmware_ok: bool, sb_blocked: bool };
const windows_uefi_sb = [_]TestRow{
    .{ .firmware_ok = true, .sb_blocked = false }, // 11
    .{ .firmware_ok = true, .sb_blocked = false }, // 10
    .{ .firmware_ok = true, .sb_blocked = false }, // 8.1
    .{ .firmware_ok = true, .sb_blocked = false }, // 8
    .{ .firmware_ok = true, .sb_blocked = true }, // 7
    .{ .firmware_ok = true, .sb_blocked = true }, // Vista
    .{ .firmware_ok = true, .sb_blocked = true }, // XP
    .{ .firmware_ok = false, .sb_blocked = false }, // 2000
    .{ .firmware_ok = false, .sb_blocked = false }, // NT 4.0
    .{ .firmware_ok = false, .sb_blocked = false }, // Me
    .{ .firmware_ok = false, .sb_blocked = false }, // 98 SE
    .{ .firmware_ok = false, .sb_blocked = false }, // 98
    .{ .firmware_ok = false, .sb_blocked = false }, // 95
    .{ .firmware_ok = false, .sb_blocked = false }, // 3.11
    .{ .firmware_ok = false, .sb_blocked = false }, // 3.1
};

fn testAccess(row: TestRow) @import("menu_policy.zig").Access {
    return .{ .firmware_compatible = row.firmware_ok, .has_images = true, .secure_boot_blocked = row.sb_blocked };
}

fn testMask(out: *[windows_uefi_sb.len]bool) []const bool {
    for (windows_uefi_sb, 0..) |row, index| out[index] = testAccess(row).navigable();
    return out;
}

test "arrows move past XP onto the rows that need BIOS and wrap from the last" {
    const std = @import("std");
    var storage: [windows_uefi_sb.len]bool = undefined;
    const mask = testMask(&storage);
    const count = mask.len;
    try std.testing.expectEqual(@as(?usize, 0), first(mask));
    var selected: usize = 6; // Windows XP
    selected = move(mask, count, selected, true).?;
    try std.testing.expectEqual(@as(usize, 7), selected); // Windows 2000 (requires BIOS)
    var steps: usize = 0;
    while (selected != count - 1) : (steps += 1) selected = move(mask, count, selected, true).?;
    try std.testing.expectEqual(@as(usize, 7), steps);
    try std.testing.expectEqual(@as(?usize, 0), move(mask, count, selected, true));
    try std.testing.expectEqual(@as(?usize, count - 1), move(mask, count, 0, false));
    try std.testing.expectEqual(@as(?usize, 5), move(mask, count, 6, false));
}

test "page down and end reach the last row, page up and home the first" {
    const std = @import("std");
    var storage: [windows_uefi_sb.len]bool = undefined;
    const mask = testMask(&storage);
    const count = mask.len;
    const visible: i64 = 6;
    var selected: usize = 0;
    selected = jump(mask, count, selected, visible);
    try std.testing.expectEqual(@as(usize, 6), selected);
    selected = jump(mask, count, selected, visible);
    try std.testing.expectEqual(@as(usize, 12), selected);
    selected = jump(mask, count, selected, visible);
    try std.testing.expectEqual(count - 1, selected);
    try std.testing.expectEqual(@as(usize, 0), jump(mask, count, selected, -@as(i64, @intCast(count))));
    try std.testing.expectEqual(count - 1, jump(mask, count, 0, @intCast(count)));
    try std.testing.expectEqual(@as(usize, 6), jump(mask, count, 12, -visible));
}

test "wheel scrolling reaches the last row and keeps it selected" {
    const std = @import("std");
    const input_map = @import("input_map.zig");
    var storage: [windows_uefi_sb.len]bool = undefined;
    const mask = testMask(&storage);
    const count = mask.len;
    const visible: usize = 7;
    // A list that overflows: the view scrolls, the selection follows it.
    var view_first: usize = 0;
    var selected: usize = 6;
    var notch: usize = 0;
    while (notch < count) : (notch += 1) {
        view_first = input_map.scrollFirst(view_first, 1, count, visible);
        selected = input_map.clampSelection(selected, view_first, visible, count, mask);
    }
    try std.testing.expectEqual(count - visible, view_first);
    try std.testing.expect(selected >= view_first and selected < count);
    try std.testing.expectEqual(count - 1, stepLinearBy(mask, count, selected, true, count));
    // A list that fits: each notch moves the selection, up to the last row.
    try std.testing.expectEqual(count - 1, stepLinearBy(mask, count, 6, true, 100));
    try std.testing.expectEqual(@as(usize, 7), stepLinearBy(mask, count, 6, true, 1));
    try std.testing.expectEqual(@as(usize, 0), stepLinearBy(mask, count, 3, false, 5));
}

test "activating a row that needs BIOS or Secure Boot off is blocked" {
    const std = @import("std");
    const Activation = @import("menu_policy.zig").Activation;
    try std.testing.expectEqual(Activation.open, testAccess(windows_uefi_sb[0]).activation());
    try std.testing.expectEqual(Activation.secure_boot_off_required, testAccess(windows_uefi_sb[6]).activation());
    for (windows_uefi_sb[7..]) |row| {
        try std.testing.expectEqual(Activation.firmware_mismatch, testAccess(row).activation());
        try std.testing.expect(testAccess(row).activation().blocked());
    }
}

test "null mask treats every row as selectable" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?usize, 0), move(null, 3, 2, true));
    try std.testing.expectEqual(@as(?usize, 2), move(null, 3, 0, false));
    try std.testing.expectEqual(@as(usize, 2), jump(null, 3, 0, 10));
    try std.testing.expectEqual(@as(usize, 2), stepLinearBy(null, 3, 1, true, 4));
}
