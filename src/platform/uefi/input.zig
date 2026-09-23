//! UEFI menu input: the console keyboard (which is also how firmware
//! exposes gamepads and handheld controls, as arrow/Enter/Esc keys) and
//! every pointer device (pointer.zig). A tap on a footer key hint is
//! turned into that key, so touch-only devices can go back and confirm.
const std = @import("std");
const uefi = std.os.uefi;
const pointer = @import("pointer.zig");

const idle_hook_interval_ticks: u16 = 250;
var idle_hook: ?*const fn () void = null;
var idle_ticks: u16 = 0;
var rescan_ticks: u8 = 0;
var hint_hook: ?*const fn (x: u32, y: u32) ?Event = null;
var last_key: Key = .{};

pub const Key = struct { scan: u16 = 0, unicode: u16 = 0 };

pub const Event = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    back,
    page_up,
    page_down,
    home,
    end,
    pointer: pointer.Event,
    other: Key,
};

pub fn hasPointer() bool {
    return pointer.available();
}

pub fn setIdleHook(hook: ?*const fn () void) void {
    idle_hook = hook;
    idle_ticks = 0;
}

/// Maps a tap/click on the footer to a key event (null = not on a hint).
pub fn setHintHook(hook: ?*const fn (x: u32, y: u32) ?Event) void {
    hint_hook = hook;
}

/// The last raw key stroke (for the input test screen).
pub fn lastKey() Key {
    return last_key;
}

pub fn readBlocking() Event {
    return read(true).?;
}

/// Non-blocking read (null when nothing is pending); used by the input
/// test screen, which also redraws on idle.
pub fn readPending() ?Event {
    return read(false);
}

fn read(blocking: bool) ?Event {
    const keyboard = uefi.system_table.con_in;

    while (true) {
        if (pointer.poll()) |mouse| {
            if (mouse.left_click) {
                if (hint_hook) |hook| {
                    if (hook(mouse.x, mouse.y)) |event| return event;
                }
            }
            if (mouse.moved or mouse.scroll != 0 or mouse.left_click or mouse.right_click or mouse.drag_dy != 0) return .{ .pointer = mouse };
        }

        if (keyboard) |device| {
            if (device.readKeyStroke()) |key| {
                last_key = .{ .scan = key.scan_code, .unicode = key.unicode_char };
                return mapKey(key.scan_code, key.unicode_char);
            } else |err| switch (err) {
                error.NotReady => {},
                else => return .{ .other = .{} },
            }
        }

        if (!blocking) return null;
        stall();
    }
}

/// UEFI scan codes and characters to menu events. Enter, LF and Space
/// confirm; Esc and Backspace go back (handheld firmware maps its A/B
/// buttons to these keys).
pub fn mapKey(scan: u16, unicode: u16) Event {
    return switch (scan) {
        0x01 => .up,
        0x02 => .down,
        0x03 => .right,
        0x04 => .left,
        0x05 => .home,
        0x06 => .end,
        0x09 => .page_up,
        0x0A => .page_down,
        0x17 => .back,
        else => switch (unicode) {
            13, 10, ' ' => .enter,
            8, 27 => .back,
            else => .{ .other = .{ .scan = scan, .unicode = unicode } },
        },
    };
}

fn stall() void {
    if (uefi.system_table.boot_services) |services| services.stall(2_000) catch {};

    idle_ticks +%= 1;
    if (idle_ticks < idle_hook_interval_ticks) return;
    idle_ticks = 0;
    rescan_ticks +%= 1;
    if (rescan_ticks % 4 == 0) pointer.rescan();
    if (idle_hook) |hook| hook();
}

test "firmware keys map to menu events" {
    try std.testing.expectEqual(Event.up, mapKey(0x01, 0));
    try std.testing.expectEqual(Event.back, mapKey(0x17, 0));
    try std.testing.expectEqual(Event.back, mapKey(0, 8));
    try std.testing.expectEqual(Event.enter, mapKey(0, 13));
    try std.testing.expectEqual(Event.page_down, mapKey(0x0A, 0));
}
