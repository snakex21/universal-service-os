// No-GOP recovery of the Int10 dispatcher (docs/design/win7-vista-no-csm.md 8.5).
//
// On the X470 (2026-09-26) boot 2 of a Windows 7 install found no GOP right
// after the specialize restart, even after one ConnectController pass, and
// the dispatcher returned to the firmware; the next start (about 4.5 min
// later) worked. UefiSeven cannot start without a framebuffer and the
// original boot manager hangs without an Int10 handler, so:
//
//   1. connect every handle recursively, stall, look again (`passes` times);
//   2. still none: cold reset (the firmware re-initialises the GPU), counted
//      in usos-nogop-resets.txt beside the dispatcher, at most `max_resets`
//      times in a row;
//   3. after that: return to the firmware as before (it tries the next boot
//      option) and clear the counter, so a machine without any display never
//      loops through resets.
// A boot that finds a GOP (or a firmware Int10) clears the counter.
const std = @import("std");

pub const passes = 3;
pub const stall_us = 1_000_000;
pub const max_resets = 2;
pub const counter_name = "usos-nogop-resets.txt";

pub const Action = enum { cold_reset, return_to_firmware };

/// What to do after every connect pass failed; `resets` is the number of
/// cold resets already done in a row. Returns the action and the counter
/// value to store before it.
pub fn decide(resets: u32) struct { action: Action, store: u32 } {
    if (resets < max_resets) return .{ .action = .cold_reset, .store = resets + 1 };
    return .{ .action = .return_to_firmware, .store = 0 };
}

/// Counter file text -> value (anything unreadable counts as 0).
pub fn parseCounter(text: []const u8) u32 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

test "no-GOP recovery: two cold resets in a row, then back to the firmware" {
    var resets: u32 = 0;
    var actions: [4]Action = undefined;
    for (&actions) |*a| {
        const step = decide(resets);
        a.* = step.action;
        resets = step.store;
    }
    try std.testing.expectEqualSlices(Action, &.{ .cold_reset, .cold_reset, .return_to_firmware, .cold_reset }, &actions);
    try std.testing.expectEqual(@as(u32, 2), parseCounter("2\r\n"));
    try std.testing.expectEqual(@as(u32, 0), parseCounter("garbage"));
    try std.testing.expectEqual(@as(u32, 0), parseCounter(""));
}
