//! Per-device keyboard input: every EFI_SIMPLE_TEXT_INPUT_EX handle except
//! the ConIn console splitter is read directly (ReadKeyStrokeEx), so each key
//! press is attributed to the device that produced it. input.zig still reads
//! ConIn afterwards for anything else.
//!
//! A handle is classified once: its own EFI_USB_IO_PROTOCOL (EDK2/AMI USB
//! keyboard drivers install text input on the USB interface handle), else
//! the closest EFI_USB_IO_PROTOCOL handle on its device path
//! (LocateDevicePath, exact match only), gives the VID/PID; a built-in
//! handheld controller (src/gui/handheld.zig) is a pad. An ACPI PNP03xx
//! node is the PS/2 (EC) keyboard, which on a handheld may carry built-in
//! buttons as well, so it is ambiguous there. The machine is identified
//! from SMBIOS type 1/2.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const usb_gamepad = @import("usb_gamepad.zig");

const handheld_rules = usos.gui.handheld;
const TextInputEx = uefi.protocol.SimpleTextInputEx;

pub const Class = enum {
    /// A USB keyboard (or another USB HID keyboard interface).
    usb_keyboard,
    /// A handheld controller presented as a keyboard.
    pad,
    /// The PS/2 keyboard (ACPI PNP03xx): a handheld's EC keyboard.
    ps2,
    /// Anything else with a device path (serial terminal, ...).
    other,
    /// No device path: cannot be attributed.
    no_path,

    pub fn text(self: Class) []const u8 {
        return switch (self) {
            .usb_keyboard => "keyboard (USB)",
            .pad => "pad (handheld controller as keyboard)",
            .ps2 => "keyboard (PS/2; ambiguous on a handheld)",
            .other => "keyboard (non-USB)",
            .no_path => "unattributed (no device path)",
        };
    }
};

pub const Device = struct {
    handle: uefi.Handle,
    protocol: *TextInputEx,
    class: Class,
    vid: u16 = 0,
    pid: u16 = 0,
};

pub const Stroke = struct {
    scan: u16,
    unicode: u16,
    origin: handheld_rules.KeyOrigin,
};

const max_devices = 8;

var devices: [max_devices]Device = undefined;
var device_count: usize = 0;
var initialized = false;
var system: handheld_rules.SystemInfo = .{};
var smbios_found = false;
var machine: ?handheld_rules.Handheld = null;

/// Reads SMBIOS and lists the text input handles (once).
pub fn init() void {
    if (initialized) return;
    initialized = true;
    readSmbios();
    rescan();
}

/// The machine is a known handheld (SMBIOS).
pub fn handheld() ?handheld_rules.Handheld {
    init();
    return machine;
}

/// Re-reads the handle list (hot-plugged keyboards); known handles keep
/// their classification.
pub fn rescan() void {
    const services = uefi.system_table.boot_services orelse return;
    const console_in = uefi.system_table.console_in_handle;
    const handles = (services.locateHandleBuffer(.{ .by_protocol = &TextInputEx.guid }) catch null) orelse {
        device_count = 0;
        return;
    };
    defer services.freePool(@ptrCast(handles.ptr)) catch {};

    var index: usize = 0;
    while (index < device_count) {
        const present = for (handles) |handle| {
            if (handle == devices[index].handle) break true;
        } else false;
        if (present) {
            index += 1;
        } else {
            device_count -= 1;
            devices[index] = devices[device_count];
        }
    }
    for (handles) |handle| {
        if (console_in != null and handle == console_in.?) continue;
        if (known(handle) or device_count == max_devices) continue;
        const protocol = (services.handleProtocol(TextInputEx, handle) catch null) orelse continue;
        const info = classify(services, handle);
        devices[device_count] = .{ .handle = handle, .protocol = protocol, .class = info.class, .vid = info.vid, .pid = info.pid };
        device_count += 1;
    }
}

fn known(handle: uefi.Handle) bool {
    for (devices[0..device_count]) |device| {
        if (device.handle == handle) return true;
    }
    return false;
}

/// The next key from a physical keyboard, with its origin.
pub fn read() ?Stroke {
    init();
    const services = uefi.system_table.boot_services orelse return null;
    var index: usize = 0;
    while (index < device_count) {
        const device = &devices[index];
        // An unplugged keyboard's interface is freed: re-check first (the
        // handle database validates stale handles safely).
        const current = services.handleProtocol(TextInputEx, device.handle) catch null;
        if (current == null or current.? != device.protocol) {
            device_count -= 1;
            devices[index] = devices[device_count];
            continue;
        }
        index += 1;
        const key = device.protocol.readKeyStroke() catch continue;
        // Partial keystrokes (toggle/shift state only) carry no key.
        if (key.input.scan_code == 0 and key.input.unicode_char == 0) continue;
        return .{ .scan = key.input.scan_code, .unicode = key.input.unicode_char, .origin = originOf(device.class) };
    }
    return null;
}

pub fn originOf(class: Class) handheld_rules.KeyOrigin {
    return switch (class) {
        .pad => .pad,
        .usb_keyboard, .other => .keyboard,
        .ps2 => if (machine != null) .unattributed else .keyboard,
        .no_path => .unattributed,
    };
}

/// True when `handle` belongs to a handheld controller (e.g. the pointer
/// interface of the ROG Ally MCU, whose right stick moves the cursor).
pub fn isPadHandle(handle: uefi.Handle) bool {
    const services = uefi.system_table.boot_services orelse return false;
    return classify(services, handle).class == .pad;
}

const Classified = struct { class: Class, vid: u16 = 0, pid: u16 = 0 };

fn classify(services: *uefi.tables.BootServices, handle: uefi.Handle) Classified {
    var io: ?*usb_gamepad.UsbIo = services.handleProtocol(usb_gamepad.UsbIo, handle) catch null;
    const path = services.handleProtocol(uefi.protocol.DevicePath, handle) catch null;
    if (io == null) {
        if (path) |start| {
            if (services.locateDevicePath(start, usb_gamepad.UsbIo) catch null) |found| {
                const rest = found[0];
                // Only the USB interface itself, not a hub above it.
                if (rest.type == .end) io = services.handleProtocol(usb_gamepad.UsbIo, found[1]) catch null;
            }
        }
    }
    if (io) |usb| {
        var descriptor: usb_gamepad.DeviceDescriptor = undefined;
        if (usb.get_device_descriptor(usb, &descriptor) != .success) return .{ .class = .usb_keyboard };
        const class: Class = if (handheld_rules.padKeyboard(descriptor.vendor, descriptor.product) != null) .pad else .usb_keyboard;
        return .{ .class = class, .vid = descriptor.vendor, .pid = descriptor.product };
    }
    const start = path orelse return .{ .class = .no_path };
    return .{ .class = if (hasPs2Node(start)) .ps2 else .other };
}

/// An ACPI device path node (type 2, subtype 1) whose _HID is PNP0300..
/// PNP03FF (EISA ID 0xXXXX41D0): a PS/2 or AT keyboard controller.
fn hasPs2Node(path: *const uefi.protocol.DevicePath) bool {
    var node = path;
    var guard: usize = 0;
    while (guard < 32) : (guard += 1) {
        const bytes: [*]const u8 = @ptrCast(node);
        if (bytes[0] == 0x7F) return false;
        if (bytes[0] == 0x02 and bytes[1] == 0x01 and node.length >= 12) {
            const hid = std.mem.readInt(u32, bytes[4..8], .little);
            if (hid & 0xFFFF == 0x41D0 and hid >> 24 == 0x03) return true;
        }
        if (node.length < 4) return false;
        node = node.next() orelse return false;
    }
    return false;
}

fn readSmbios() void {
    const table = uefi.system_table;
    const entries = table.configuration_table[0..table.number_of_table_entries];
    var entry_point: ?[*]const u8 = null;
    // SMBIOS 3 (64-bit address) first, then the 2.x entry point.
    for (entries) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.smbios3_table_guid)) entry_point = @ptrCast(entry.vendor_table);
    }
    if (entry_point == null) for (entries) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.smbios_table_guid)) entry_point = @ptrCast(entry.vendor_table);
    };
    const start = entry_point orelse return;
    const located = handheld_rules.smbiosTable(start[0..0x20]) orelse return;
    if (located.address == 0 or located.address > std.math.maxInt(usize)) return;
    const length = @min(located.length, 64 * 1024);
    if (length == 0) return;
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(located.address)));
    system = handheld_rules.parseSmbios(bytes[0..length]);
    smbios_found = true;
    machine = handheld_rules.fromDmi(system);
}

// ------------------------------------------------------------ report

pub const Report = struct {
    pub fn smbios() ?handheld_rules.SystemInfo {
        init();
        return if (smbios_found) system else null;
    }

    pub fn count() usize {
        return device_count;
    }

    pub fn device(index: usize) Device {
        return devices[index];
    }

    /// The classification of a text input handle (read directly or not).
    pub fn classOf(handle: uefi.Handle) ?Device {
        for (devices[0..device_count]) |item| {
            if (item.handle == handle) return item;
        }
        return null;
    }
};
