const std = @import("std");
const uefi = std.os.uefi;
const pointer = @import("pointer.zig");

const idle_hook_interval_ticks: u16 = 250;
var idle_hook: ?*const fn () void = null;
var idle_ticks: u16 = 0;

pub const Event = union(enum) {
    up,
    down,
    left,
    right,
    enter,
    back,
    pointer: pointer.Event,
    other,
};

pub fn hasPointer() bool {
    return pointer.available();
}

pub fn setIdleHook(hook: ?*const fn () void) void {
    idle_hook = hook;
    idle_ticks = 0;
}

pub fn readBlocking() Event {
    const keyboard = uefi.system_table.con_in;

    while (true) {
        if (pointer.poll()) |mouse| {
            if (mouse.moved or mouse.scroll != 0 or mouse.left_click or mouse.right_click) return .{ .pointer = mouse };
        }

        if (keyboard) |device| {
            const key = device.readKeyStroke() catch |err| switch (err) {
                error.NotReady => {
                    stall();
                    continue;
                },
                else => return .other,
            };

            return switch (key.scan_code) {
                0x01 => .up,
                0x02 => .down,
                0x03 => .right,
                0x04 => .left,
                0x17 => .back,
                else => if (key.unicode_char == 13) .enter else .other,
            };
        }

        stall();
    }
}

fn stall() void {
    if (uefi.system_table.boot_services) |services| services.stall(2_000) catch {};

    idle_ticks +%= 1;
    if (idle_ticks < idle_hook_interval_ticks) return;
    idle_ticks = 0;
    if (idle_hook) |hook| hook();
}
