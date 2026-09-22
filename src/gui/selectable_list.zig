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
