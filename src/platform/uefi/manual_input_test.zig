//! Hidden input test screen (Power -> Input test): shows every pointer,
//! touch, wheel, key and USB gamepad event live (with the pad's type), so a new machine (e.g. a handheld)
//! can be checked for what its firmware delivers to UEFI applications.
//! Esc (or a tap on the Esc hint) twice in a row leaves.
const std = @import("std");
const uefi = std.os.uefi;
const input = @import("input.zig");
const pointer = @import("pointer.zig");
const usb_gamepad = @import("usb_gamepad.zig");
const view = @import("manual_view.zig");

const max_log = 6;

pub fn show() void {
    var log: [max_log][96]u8 = undefined;
    var log_len: [max_log]usize = @splat(0);
    var log_count: usize = 0;
    var backs: u8 = 0;
    var marker: ?[2]u32 = null;
    var dragging = false;
    var wheel_total: i32 = 0;
    var drag_total: i32 = 0;
    var events: u32 = 0;
    var dirty = true;
    var quiet_ticks: u32 = 0;

    while (true) {
        if (input.readPending()) |event| {
            events +%= 1;
            var line: [96]u8 = undefined;
            const text: []const u8 = switch (event) {
                .pointer => |mouse| blk: {
                    wheel_total += mouse.scroll;
                    drag_total += mouse.drag_dy;
                    dragging = mouse.dragging;
                    if (mouse.left_click or mouse.right_click) marker = .{ mouse.x, mouse.y };
                    if (mouse.dragging) marker = .{ mouse.x, mouse.y };
                    // Plain hover moves update the header line only.
                    if (!mouse.left_click and !mouse.right_click and mouse.scroll == 0 and mouse.drag_dy == 0) break :blk "";
                    break :blk std.fmt.bufPrint(&line, "{s} {s} x={d} y={d} wheel={d} drag_dy={d}", .{
                        if (mouse.touch) "absolute" else "relative",
                        if (mouse.left_click) (if (mouse.touch) "TAP" else "CLICK") else if (mouse.right_click) "RIGHT-CLICK" else if (mouse.scroll != 0) "WHEEL" else "DRAG",
                        mouse.x,
                        mouse.y,
                        mouse.scroll,
                        mouse.drag_dy,
                    }) catch "";
                },
                else => if (input.lastSource() == .pad and input.lastPad() != null) blk: {
                    const pad = input.lastPad().?;
                    var name: [96]u8 = undefined;
                    break :blk std.fmt.bufPrint(&line, "pad {s}: {s} -> {s}", .{ usb_gamepad.describe(&name, pad.kind, pad.vid, pad.pid), @tagName(pad.button), @tagName(event) }) catch "";
                } else blk: {
                    const key = input.lastKey();
                    break :blk std.fmt.bufPrint(&line, "key {s} scan=0x{x:0>2} char=0x{x:0>4}", .{ @tagName(event), key.scan, key.unicode }) catch "";
                },
            };
            if (event == .back) {
                backs += 1;
                if (backs >= 2) return;
            } else if (event != .pointer or text.len > 0) {
                backs = 0;
            }
            if (text.len > 0) {
                if (log_count == max_log) {
                    var index: usize = 1;
                    while (index < max_log) : (index += 1) {
                        log[index - 1] = log[index];
                        log_len[index - 1] = log_len[index];
                    }
                    log_count -= 1;
                }
                @memcpy(log[log_count][0..text.len], text);
                log_len[log_count] = text.len;
                log_count += 1;
            }
            dirty = true;
            quiet_ticks = 0;
            continue;
        }
        if (uefi.system_table.boot_services) |services| services.stall(5_000) catch {};
        quiet_ticks += 1;
        // Redraw at most ~20 times a second while input keeps arriving.
        if (dirty and quiet_ticks >= 2) {
            dirty = false;
            var status: [4][128]u8 = undefined;
            var pads: [256]u8 = undefined;
            var lines: [5 + max_log][]const u8 = undefined;
            const pos = pointer.position();
            lines[0] = std.fmt.bufPrint(&status[0], "Pointer: {s}  simple={d} absolute={d}  position {d},{d}", .{ pointer.backendLabel(), pointer.Report.simpleCount(), pointer.Report.absoluteCount(), pos.x, pos.y }) catch "";
            lines[1] = std.fmt.bufPrint(&status[1], "Wheel notches total: {d}   drag pixels total: {d}   events: {d}", .{ wheel_total, drag_total, events }) catch "";
            lines[2] = std.fmt.bufPrint(&status[2], "PS/2 direct: {s}  wheel: {s}   Report: EFI\\USOS\\Logs\\input-devices.txt", .{ if (pointer.Report.ps2Direct()) "yes" else "no", if (pointer.Report.ps2Wheel()) "yes" else "no" }) catch "";
            lines[3] = usb_gamepad.padsLine(&pads);
            lines[4] = if (backs == 1) (if (input.padActive()) "Press B once more to leave." else "Press Esc once more to leave.") else "";
            for (0..log_count) |index| lines[5 + index] = log[index][0..log_len[index]];
            view.inputTestFrame(lines[0 .. 5 + log_count], marker, dragging);
        }
    }
}
