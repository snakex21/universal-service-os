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
const touch_driver = @import("touch_driver.zig");

const max_log = 6;
/// Recent touch points drawn as a trail (oldest first).
const max_points = 12;

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
    var points: [max_points][2]u32 = undefined;
    var point_count: usize = 0;
    var seen_touch: u32 = pointer.lastTouch().serial;

    while (true) {
        if (input.readPending()) |event| {
            events +%= 1;
            var line: [96]u8 = undefined;
            const text: []const u8 = switch (event) {
                .pointer => |mouse| blk: {
                    // Touch points (absolute reports while the finger is down).
                    const touch = pointer.lastTouch();
                    if (mouse.touch and touch.serial != seen_touch) {
                        seen_touch = touch.serial;
                        if (touch.active) {
                            if (point_count == max_points) {
                                std.mem.copyForwards([2]u32, points[0 .. max_points - 1], points[1..max_points]);
                                point_count -= 1;
                            }
                            points[point_count] = .{ touch.x, touch.y };
                            point_count += 1;
                        }
                    }
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
            var status: [6][160]u8 = undefined;
            var pads: [256]u8 = undefined;
            var lines: [7 + max_log][]const u8 = undefined;
            const pos = pointer.position();
            lines[0] = std.fmt.bufPrint(&status[0], "Pointer: {s}  simple={d} absolute={d}  position {d},{d}", .{ pointer.backendLabel(), pointer.Report.simpleCount(), pointer.Report.absoluteCount(), pos.x, pos.y }) catch "";
            lines[1] = std.fmt.bufPrint(&status[1], "Wheel notches total: {d}   drag pixels total: {d}   events: {d}", .{ wheel_total, drag_total, events }) catch "";
            lines[2] = std.fmt.bufPrint(&status[2], "PS/2 direct: {s}  wheel: {s}   Report: EFI\\USOS\\Logs\\input-devices.txt", .{ if (pointer.Report.ps2Direct()) "yes" else "no", if (pointer.Report.ps2Wheel()) "yes" else "no" }) catch "";
            lines[3] = usb_gamepad.padsLine(&pads);
            lines[4] = touchDriverLine(&status[3]);
            lines[5] = touchPointsLine(&status[4], points[0..point_count]);
            lines[6] = if (backs == 1) (if (input.padActive()) "Press B once more to leave." else "Press Esc once more to leave.") else "";
            for (0..log_count) |index| lines[7 + index] = log[index][0..log_len[index]];
            view.inputTestFrame(lines[0 .. 7 + log_count], marker, dragging, points[0..point_count]);
        }
    }
}

/// "Touch driver: started, range 0..1920 x 0..1080" (or why it is not loaded).
fn touchDriverLine(buffer: []u8) []const u8 {
    const status = touch_driver.report();
    if (status.outcome != .started) {
        return std.fmt.bufPrint(buffer, "Touch driver: {s} ({s})", .{ status.outcome.text(), status.decision.text() }) catch "";
    }
    const services = uefi.system_table.boot_services orelse return "";
    for (status.new_handles) |candidate| {
        const handle = candidate orelse continue;
        const protocol = (services.handleProtocol(pointer.AbsolutePointer, handle) catch null) orelse continue;
        const mode = protocol.mode.*;
        const live = !(mode.absolute_max_x == 0xFFFF and mode.absolute_max_y == 0xFFFF);
        return std.fmt.bufPrint(buffer, "Touch driver: started, range {d}..{d} x {d}..{d} ({s})", .{ mode.absolute_min_x, mode.absolute_max_x, mode.absolute_min_y, mode.absolute_max_y, if (live) "panel live" else "waiting for the panel" }) catch "";
    }
    return "Touch driver: started, no AbsolutePointer handle";
}

/// The last raw report and the most recent touch points on screen.
fn touchPointsLine(buffer: []u8, points: []const [2]u32) []const u8 {
    const touch = pointer.lastTouch();
    if (touch.serial == 0) return "Touch: no absolute reports yet";
    const head = std.fmt.bufPrint(buffer, "Touch raw {d},{d} -> {d},{d} {s}; points:", .{ touch.raw_x, touch.raw_y, touch.x, touch.y, if (touch.active) "down" else "up" }) catch return "";
    var used = head.len;
    const shown = points[points.len -| 4 ..];
    for (shown) |point| {
        const item = std.fmt.bufPrint(buffer[used..], " {d},{d}", .{ point[0], point[1] }) catch break;
        used += item.len;
    }
    return buffer[0..used];
}
