//! UEFI menu input: the console keyboard (which is also how some firmware
//! exposes handheld controls, as arrow/Enter/Esc keys), every pointer
//! device (pointer.zig) and USB gamepads read directly through
//! EFI_USB_IO_PROTOCOL (usb_gamepad.zig). A tap on a footer key hint is
//! turned into that key, so touch-only devices can go back and confirm.
const std = @import("std");
const uefi = std.os.uefi;
const pointer = @import("pointer.zig");
const usb_gamepad = @import("usb_gamepad.zig");
const usos = @import("usos");

const idle_hook_interval_ticks: u16 = 250;
var idle_hook: ?*const fn () void = null;
var frame_hook: ?*const fn () void = null;
var idle_ticks: u16 = 0;
var rescan_ticks: u8 = 0;
var hint_hook: ?*const fn (x: u32, y: u32) ?Event = null;
var last_key: Key = .{};
var last_source: Source = .keyboard;
var last_pad: ?usb_gamepad.Event = null;
var pad_active = false;
var mode_hook: ?*const fn () void = null;
var dedupe = usos.gui.usb_gamepad.Dedupe{};

pub const Source = enum(u8) { keyboard, pointer, pad };

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

/// Called on every poll pass (~2 ms) while waiting, e.g. to draw a
/// throttled pointer frame once the pointer stops.
pub fn setFrameHook(hook: ?*const fn () void) void {
    frame_hook = hook;
}

/// Maps a tap/click on the footer to a key event (null = not on a hint).
pub fn setHintHook(hook: ?*const fn (x: u32, y: u32) ?Event) void {
    hint_hook = hook;
}

/// The last raw key stroke (for the input test screen).
pub fn lastKey() Key {
    return last_key;
}

/// Where the last event came from, and the pad event if it was a pad.
pub fn lastSource() Source {
    return last_source;
}

pub fn lastPad() ?usb_gamepad.Event {
    return last_pad;
}

/// A USB gamepad was used last: footers show A/B instead of Enter/Esc.
pub fn padActive() bool {
    return pad_active;
}

/// Called when padActive() changes, to redraw the footer hints.
pub fn setModeHook(hook: ?*const fn () void) void {
    mode_hook = hook;
}

/// Footer key names for the current input device.
pub fn enterKey() []const u8 {
    return if (pad_active) "A" else "Enter";
}

pub fn backKey() []const u8 {
    return if (pad_active) "B" else "Esc";
}

/// Cancels the USB gamepad transfers before another loader starts.
pub fn stopGamepads() void {
    usb_gamepad.stop();
}

fn setPadActive(value: bool) void {
    if (pad_active == value) return;
    pad_active = value;
    if (mode_hook) |hook| hook();
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
                    if (hook(mouse.x, mouse.y)) |event| {
                        last_source = .pointer;
                        return event;
                    }
                }
            }
            if (mouse.moved or mouse.scroll != 0 or mouse.left_click or mouse.right_click or mouse.drag_dy != 0) {
                last_source = .pointer;
                if (mouse.left_click or mouse.right_click or mouse.scroll != 0) setPadActive(false);
                return .{ .pointer = mouse };
            }
        }

        if (keyboard) |device| {
            if (device.readKeyStroke()) |key| {
                last_key = .{ .scan = key.scan_code, .unicode = key.unicode_char };
                const event = mapKey(key.scan_code, key.unicode_char);
                // Handheld firmware may send the same press as a key too.
                if (accept(.keyboard, event)) {
                    last_source = .keyboard;
                    setPadActive(false);
                    return event;
                }
            } else |err| switch (err) {
                error.NotReady => {},
                else => return .{ .other = .{} },
            }
        }

        if (usb_gamepad.poll()) |pad| {
            const event = padEvent(pad.action);
            if (accept(.pad, event)) {
                last_source = .pad;
                last_pad = pad;
                setPadActive(true);
                return event;
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

/// Gamepad actions use the same menu events as the keyboard (micro-Linux
/// layout): A/Start = Enter, B/Back = Esc, LB/RB = Page Up/Down.
pub fn padEvent(action: usos.gui.usb_gamepad.Action) Event {
    return switch (action) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .accept => .enter,
        .back => .back,
        .page_up => .page_up,
        .page_down => .page_down,
    };
}

/// Drops a menu action that another source delivered a moment ago
/// (handheld firmware can report a pad press as a key as well).
fn accept(source: Source, event: Event) bool {
    const code: u8 = switch (event) {
        .pointer, .other => return true,
        else => @intFromEnum(std.meta.activeTag(event)),
    };
    return dedupe.accept(@intFromEnum(source), code, usb_gamepad.nowMs());
}

fn stall() void {
    if (uefi.system_table.boot_services) |services| services.stall(2_000) catch {};
    usb_gamepad.advance(2);
    if (frame_hook) |hook| hook();

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
