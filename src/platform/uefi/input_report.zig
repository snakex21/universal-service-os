//! Writes EFI\USOS\Logs\input-devices.txt once per boot: every pointer,
//! absolute-pointer (touch) and text-input handle the firmware exposes,
//! with device paths, ranges, resolutions and attributes, plus what the
//! menu polls. Running USOS once on a new machine (e.g. a handheld) shows
//! exactly which touch/controller inputs its firmware offers pre-boot.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const pointer = @import("pointer.zig");
const serial = @import("serial.zig");

const capacity = 16 * 1024;

var buffer: [capacity]u8 = undefined;
var used: usize = 0;

const DevicePathToText = extern struct {
    node_to_text: *const fn (*const uefi.protocol.DevicePath, bool, bool) callconv(uefi.cc) ?[*:0]u16,
    path_to_text: *const fn (*const uefi.protocol.DevicePath, bool, bool) callconv(uefi.cc) ?[*:0]u16,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x8b843e20,
        .time_mid = 0x8132,
        .time_high_and_version = 0x4852,
        .clock_seq_high_and_reserved = 0x90,
        .clock_seq_low = 0xcc,
        .node = [_]u8{ 0x55, 0x1a, 0x4e, 0x4a, 0x7f, 0x1c },
    };
};

pub fn write(root: *uefi.protocol.File, width: u32, height: u32) void {
    build(width, height);
    save(root) catch |err| {
        serial.writeAscii("[INPUT_REPORT] save failed: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
    };
    // The same report on the serial console (QEMU tests, headless boards).
    serial.writeAscii("[INPUT_REPORT BEGIN]\n");
    serial.writeAscii(text());
    serial.writeAscii("[INPUT_REPORT END]\n");
}

/// The report text (also shown on the input test screen).
pub fn text() []const u8 {
    return buffer[0..used];
}

fn build(width: u32, height: u32) void {
    used = 0;
    const services = uefi.system_table.boot_services orelse return;
    const to_text = services.locateProtocol(DevicePathToText, null) catch null;
    const console_in = uefi.system_table.console_in_handle;

    print("USOS input devices report\nbuild={s}\nscreen={d}x{d}\n", .{ usos.build_info.id, width, height });
    print("console_in_handle=0x{x}\n", .{if (console_in) |h| @intFromPtr(h) else 0});
    print("polled: simple={d} absolute={d} ps2_direct={s} ps2_wheel={s} ps2_skipped_firmware_driver={s}\n", .{
        pointer.Report.simpleCount(),
        pointer.Report.absoluteCount(),
        yesNo(pointer.Report.ps2Direct()),
        yesNo(pointer.Report.ps2Wheel()),
        yesNo(pointer.Report.ps2SkippedForFirmware()),
    });
    print("settings: wheel_invert={s}\n\n", .{yesNo(pointer.Report.wheelInverted())});

    if (services.locateHandleBuffer(.{ .by_protocol = &pointer.SimplePointer.guid }) catch null) |handles| {
        defer services.freePool(@ptrCast(handles.ptr)) catch {};
        print("[EFI_SIMPLE_POINTER_PROTOCOL] handles={d}\n", .{handles.len});
        for (handles) |handle| {
            print("- handle=0x{x}{s}\n", .{ @intFromPtr(handle), if (console_in != null and handle == console_in.?) " (ConIn console splitter)" else "" });
            devicePath(services, to_text, handle);
            if (services.handleProtocol(pointer.SimplePointer, handle) catch null) |protocol| {
                const mode = protocol.mode.*;
                print("  resolution x={d} y={d} z={d} (z=0: no wheel per spec) buttons left={s} right={s}\n", .{ mode.resolution_x, mode.resolution_y, mode.resolution_z, yesNo(mode.left_button), yesNo(mode.right_button) });
            }
            print("  polled={s}\n", .{yesNo(polledSimple(handle))});
        }
    } else print("[EFI_SIMPLE_POINTER_PROTOCOL] handles=0\n", .{});
    print("\n", .{});

    if (services.locateHandleBuffer(.{ .by_protocol = &pointer.AbsolutePointer.guid }) catch null) |handles| {
        defer services.freePool(@ptrCast(handles.ptr)) catch {};
        print("[EFI_ABSOLUTE_POINTER_PROTOCOL] handles={d}\n", .{handles.len});
        for (handles) |handle| {
            print("- handle=0x{x}{s}\n", .{ @intFromPtr(handle), if (console_in != null and handle == console_in.?) " (ConIn console splitter)" else "" });
            devicePath(services, to_text, handle);
            if (services.handleProtocol(pointer.AbsolutePointer, handle) catch null) |protocol| {
                const mode = protocol.mode.*;
                print("  range x={d}..{d} y={d}..{d} z={d}..{d}\n", .{ mode.absolute_min_x, mode.absolute_max_x, mode.absolute_min_y, mode.absolute_max_y, mode.absolute_min_z, mode.absolute_max_z });
                print("  attributes=0x{x} supports_alt_active={s} supports_pressure_as_z={s}\n", .{ @as(u32, @bitCast(mode.attributes)), yesNo(mode.attributes.supports_alt_active), yesNo(mode.attributes.supports_pressure_as_z) });
            }
            if (polledAbsolute(handle)) |index| {
                print("  polled=yes rotation={d} z_as_wheel={s}\n", .{ pointer.Report.absoluteRotation(index), yesNo(pointer.Report.absoluteWheel(index)) });
            } else print("  polled=no\n", .{});
        }
    } else print("[EFI_ABSOLUTE_POINTER_PROTOCOL] handles=0 (no firmware touchscreen/tablet driver)\n", .{});
    print("\n", .{});

    if (services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.SimpleTextInput.guid }) catch null) |handles| {
        defer services.freePool(@ptrCast(handles.ptr)) catch {};
        print("[EFI_SIMPLE_TEXT_INPUT_PROTOCOL] handles={d}\n", .{handles.len});
        for (handles) |handle| {
            const ex = (services.handleProtocol(uefi.protocol.SimpleTextInputEx, handle) catch null) != null;
            print("- handle=0x{x}{s} text_input_ex={s}\n", .{ @intFromPtr(handle), if (console_in != null and handle == console_in.?) " (ConIn console splitter)" else "", yesNo(ex) });
            devicePath(services, to_text, handle);
        }
    } else print("[EFI_SIMPLE_TEXT_INPUT_PROTOCOL] handles=0\n", .{});
    print("\nGamepads have no UEFI protocol; handheld firmware that supports its\ncontrols pre-boot presents them as a keyboard (arrows/Enter/Esc) or a\npointer, which appear above.\n", .{});
}

fn polledSimple(handle: uefi.Handle) bool {
    for (0..pointer.Report.simpleCount()) |index| {
        if (pointer.Report.simpleHandle(index) == handle) return true;
    }
    return false;
}

fn polledAbsolute(handle: uefi.Handle) ?usize {
    for (0..pointer.Report.absoluteCount()) |index| {
        if (pointer.Report.absoluteHandle(index) == handle) return index;
    }
    return null;
}

fn devicePath(services: *uefi.tables.BootServices, to_text: ?*DevicePathToText, handle: uefi.Handle) void {
    const path = (services.handleProtocol(uefi.protocol.DevicePath, handle) catch null) orelse {
        print("  path=(none)\n", .{});
        return;
    };
    if (to_text) |converter| {
        if (converter.path_to_text(path, false, false)) |wide| {
            defer services.freePool(@ptrCast(@alignCast(wide))) catch {};
            print("  path=", .{});
            var index: usize = 0;
            while (wide[index] != 0 and index < 512) : (index += 1) {
                const unit = wide[index];
                append(&.{if (unit >= 0x20 and unit < 0x7f) @as(u8, @intCast(unit)) else '?'});
            }
            print("\n", .{});
            return;
        }
    }
    // No DevicePathToText: list the raw nodes (type/subtype/length + data).
    print("  path_nodes=", .{});
    var node: *const uefi.protocol.DevicePath = path;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        const bytes: [*]const u8 = @ptrCast(node);
        const length = node.length;
        print("{x:0>2}/{x:0>2}", .{ bytes[0], bytes[1] });
        if (length > 4) {
            print(":", .{});
            for (bytes[4..@min(length, 24)]) |byte| print("{x:0>2}", .{byte});
        }
        print(" ", .{});
        if (length < 4) break;
        node = node.next() orelse break;
    }
    print("\n", .{});
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn print(comptime fmt: []const u8, args: anytype) void {
    const result = std.fmt.bufPrint(buffer[used..], fmt, args) catch return;
    used += result.len;
}

fn append(bytes: []const u8) void {
    const n = @min(bytes.len, buffer.len - used);
    @memcpy(buffer[used .. used + n], bytes[0..n]);
    used += n;
}

fn save(root: *uefi.protocol.File) !void {
    const logs = try root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true });
    defer logs.close() catch {};
    const name = std.unicode.utf8ToUtf16LeStringLiteral("input-devices.txt");
    // Replace the previous report (UEFI files have no truncate).
    if (logs.open(name, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = try logs.open(name, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < used) {
        const n = try file.write(buffer[written..used]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
}
