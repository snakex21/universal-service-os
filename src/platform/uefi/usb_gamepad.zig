//! USB gamepads in the UEFI menu without firmware gamepad support: every
//! EFI_USB_IO_PROTOCOL handle (one per USB interface, installed by the
//! firmware's USB bus driver) is inspected once; XInput, GIP and HID
//! gamepad interfaces that no firmware driver has bound are read with
//! UsbAsyncInterruptTransfer (a callback that queues the reports; polled
//! UsbSyncInterruptTransfer when the firmware refuses async transfers).
//! Protocol parsing and the button mapping live in src/gui/usb_gamepad.zig.
//!
//! The protocol is only opened with GET_PROTOCOL (HandleProtocol): never
//! BY_DRIVER or EXCLUSIVE, so the firmware can still remove an unplugged
//! device, and never DisconnectController. Interfaces a firmware driver
//! holds BY_DRIVER (keyboards, mice) are listed and left alone.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const boot_timing = @import("boot_timing.zig");
const serial = @import("serial.zig");

const pad = usos.gui.usb_gamepad;
const Status = uefi.Status;

pub const UsbIo = extern struct {
    control_transfer: *const fn (*UsbIo, *const DeviceRequest, u32, u32, ?*anyopaque, usize, *u32) callconv(uefi.cc) Status,
    bulk_transfer: *const anyopaque,
    async_interrupt_transfer: *const fn (*UsbIo, u8, bool, usize, usize, ?*const AsyncCallback, ?*anyopaque) callconv(uefi.cc) Status,
    sync_interrupt_transfer: *const fn (*UsbIo, u8, ?*anyopaque, *usize, usize, *u32) callconv(uefi.cc) Status,
    isochronous_transfer: *const anyopaque,
    async_isochronous_transfer: *const anyopaque,
    get_device_descriptor: *const fn (*UsbIo, *DeviceDescriptor) callconv(uefi.cc) Status,
    get_config_descriptor: *const fn (*UsbIo, *ConfigDescriptor) callconv(uefi.cc) Status,
    get_interface_descriptor: *const fn (*UsbIo, *InterfaceDescriptor) callconv(uefi.cc) Status,
    get_endpoint_descriptor: *const fn (*UsbIo, u8, *EndpointDescriptor) callconv(uefi.cc) Status,
    get_string_descriptor: *const anyopaque,
    get_supported_languages: *const anyopaque,
    port_reset: *const anyopaque,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x2B2F68D6,
        .time_mid = 0x0CD2,
        .time_high_and_version = 0x44CF,
        .clock_seq_high_and_reserved = 0x8E,
        .clock_seq_low = 0x8B,
        .node = [_]u8{ 0xBB, 0xA2, 0x0B, 0x1B, 0x5B, 0x75 },
    };

    pub const AsyncCallback = fn (?*anyopaque, usize, ?*anyopaque, u32) callconv(uefi.cc) Status;

    pub const data_in: u32 = 0;
    pub const data_out: u32 = 1;
    pub const no_data: u32 = 2;
};

pub const DeviceRequest = extern struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
};

pub const DeviceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    bcd_usb: u16,
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    max_packet_size0: u8,
    vendor: u16,
    product: u16,
    bcd_device: u16,
    manufacturer: u8,
    product_string: u8,
    serial_number: u8,
    configurations: u8,
};

pub const ConfigDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    total_length: u16,
    interfaces: u8,
    value: u8,
    string: u8,
    attributes: u8,
    max_power: u8,
};

pub const InterfaceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    number: u8,
    alternate: u8,
    endpoints: u8,
    class: u8,
    subclass: u8,
    protocol: u8,
    string: u8,
};

pub const EndpointDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    address: u8,
    attributes: u8,
    max_packet_size: u16,
    interval: u8,
};

comptime {
    std.debug.assert(@sizeOf(DeviceRequest) == 8);
    std.debug.assert(@sizeOf(DeviceDescriptor) == 18);
    std.debug.assert(@offsetOf(DeviceDescriptor, "vendor") == 8);
    std.debug.assert(@offsetOf(DeviceDescriptor, "configurations") == 17);
    std.debug.assert(@offsetOf(ConfigDescriptor, "total_length") == 2);
    std.debug.assert(@sizeOf(InterfaceDescriptor) == 9);
    std.debug.assert(@offsetOf(EndpointDescriptor, "max_packet_size") == 4);
    std.debug.assert(@offsetOf(EndpointDescriptor, "interval") == 6);
}

/// EFI_OPEN_PROTOCOL_INFORMATION_ENTRY with a plain integer attribute
/// (firmware may combine bits, which std's exhaustive enum cannot hold).
const OpenInfo = extern struct {
    agent: ?uefi.Handle,
    controller: ?uefi.Handle,
    attributes: u32,
    open_count: u32,
};
const open_by_driver: u32 = 0x10;
const open_exclusive: u32 = 0x20;

// ------------------------------------------------------------ state

/// Why an interface is or is not used (input-devices.txt).
pub const Verdict = enum {
    claimed,
    keyboard_or_mouse,
    bound_by_firmware,
    not_a_gamepad,
    hid_not_a_gamepad,
    hid_descriptor_failed,
    no_interrupt_in,
    start_failed,
    no_free_slot,
    unsupported_adapter,

    pub fn text(self: Verdict) []const u8 {
        return switch (self) {
            .claimed => "claimed by USOS",
            .keyboard_or_mouse => "not claimed (HID boot keyboard/mouse: left to the firmware)",
            .bound_by_firmware => "not claimed (a firmware driver has it open BY_DRIVER)",
            .not_a_gamepad => "not claimed (not a gamepad interface)",
            .hid_not_a_gamepad => "not claimed (HID, not a joystick/gamepad usage)",
            .hid_descriptor_failed => "not claimed (HID report descriptor could not be read)",
            .no_interrupt_in => "not claimed (no interrupt IN endpoint)",
            .start_failed => "not claimed (the firmware refused async and sync interrupt transfers)",
            .no_free_slot => "not claimed (too many pads)",
            .unsupported_adapter => "not claimed (Xbox Wireless Adapter: proprietary Wi-Fi protocol, unsupported)",
        };
    }
};

pub const Entry = struct {
    handle: uefi.Handle,
    io: *UsbIo,
    vid: u16 = 0,
    pid: u16 = 0,
    device_class: [3]u8 = .{ 0, 0, 0 },
    interface: pad.Interface = .{ .class = 0, .subclass = 0, .protocol = 0, .number = 0 },
    endpoints: u8 = 0,
    bound: bool = false,
    verdict: Verdict = .not_a_gamepad,
    kind: ?pad.Kind = null,
    hid_application: u32 = 0,
    in_endpoint: u8 = 0,
    out_endpoint: u8 = 0,
    async_mode: bool = false,
};

const ring_size = 16;
const report_capacity = 64;

const Slot = struct {
    used: bool = false,
    handle: uefi.Handle = undefined,
    io: *UsbIo = undefined,
    kind: pad.Kind = .hid,
    vid: u16 = 0,
    pid: u16 = 0,
    in_endpoint: u8 = 0,
    out_endpoint: u8 = 0,
    packet_size: usize = 0,
    interval: usize = 8,
    async_mode: bool = false,
    // Written by the transfer callback (TPL_CALLBACK/NOTIFY); read with the
    // TPL raised to NOTIFY.
    ring: [ring_size][report_capacity]u8 = undefined,
    ring_len: [ring_size]u8 = undefined,
    head: usize = 0,
    count: usize = 0,
    failed: bool = false,
    reports: u32 = 0,
    // Main loop only.
    errors: u8 = 0,
    retry_ms: u64 = 0,
    next_sync_ms: u64 = 0,
    mapper: pad.Mapper = .{},
    hid: pad.HidLayout = .{},
    hid_order: pad.ButtonOrder = .joystick,
    gip_sequence: u8 = 0,
    gip_input_seen: bool = false,
    gip_tries: u8 = 0,
    gip_next_ms: u64 = 0,
    connected: bool = true,
};

pub const max_entries = 32;
const max_slots = 6;
const rescan_ms = 2000;

var entries: [max_entries]Entry = undefined;
var entry_count: usize = 0;
var entries_dropped: usize = 0;
var slots: [max_slots]Slot = @splat(.{});
var queue: pad.Queue = .{};
var scanned = false;
var last_scan_ms: u64 = 0;
var fallback_ms: u64 = 0;
var changed = false;
var total_handles: usize = 0;
var ally_present = false;

var config_buffer: [1024]u8 align(8) = undefined;
var descriptor_buffer: [1024]u8 align(8) = undefined;

pub const Event = struct {
    action: pad.Action,
    button: pad.Button,
    kind: pad.Kind,
    vid: u16,
    pid: u16,
};

// ------------------------------------------------------------ clock

/// Milliseconds from the TSC (x86); elsewhere the 2 ms input stall ticks.
pub fn nowMs() u64 {
    const ticks = boot_timing.now();
    if (ticks != 0) {
        const per_ms = boot_timing.calibrate();
        if (per_ms > 1) return ticks / per_ms;
    }
    return fallback_ms;
}

/// Advances the fallback clock (called by the input loop's stall).
pub fn advance(ms: u64) void {
    fallback_ms +%= ms;
}

// ------------------------------------------------------------ polling

/// One pass: rescans every 2 s (hot-plug), drains the report queues and
/// returns the next menu action, if any.
pub fn poll() ?Event {
    const services = uefi.system_table.boot_services orelse return null;
    const now = nowMs();
    if (!scanned or now -| last_scan_ms >= rescan_ms) scan(services, now);
    if (take()) |event| return event;

    for (&slots, 0..) |*slot, index| {
        if (!slot.used) continue;
        drain(services, slot, index, now);
        service(services, slot, index, now);
        if (!slot.used) continue;
        slot.mapper.tick(now, &queue);
        collect(index);
    }
    return take();
}

// The mapper queue is shared; `pending` remembers which pad each output
// came from (input test screen).
var pending: [32]struct { output: pad.Output, slot: usize } = undefined;
var pending_head: usize = 0;
var pending_len: usize = 0;

fn collect(index: usize) void {
    while (queue.pop()) |output| {
        if (pending_len == pending.len) {
            pending_head = (pending_head + 1) % pending.len;
            pending_len -= 1;
        }
        pending[(pending_head + pending_len) % pending.len] = .{ .output = output, .slot = index };
        pending_len += 1;
    }
}

fn take() ?Event {
    if (pending_len == 0) return null;
    const item = pending[pending_head];
    pending_head = (pending_head + 1) % pending.len;
    pending_len -= 1;
    const slot = &slots[item.slot];
    return .{ .action = item.output.action, .button = item.output.button, .kind = slot.kind, .vid = slot.vid, .pid = slot.pid };
}

fn drain(services: *uefi.tables.BootServices, slot: *Slot, index: usize, now: u64) void {
    var report: [report_capacity]u8 = undefined;
    while (true) {
        const old = services.raiseTpl(.notify);
        if (slot.count == 0) {
            services.restoreTpl(old);
            break;
        }
        const at = slot.head;
        const len = slot.ring_len[at];
        @memcpy(report[0..len], slot.ring[at][0..len]);
        slot.head = (slot.head + 1) % ring_size;
        slot.count -= 1;
        services.restoreTpl(old);
        handleReport(slot, index, report[0..len], now);
    }
    collect(index);
}

fn handleReport(slot: *Slot, index: usize, report: []const u8, now: u64) void {
    switch (slot.kind) {
        .xinput => if (pad.parseXInput(report)) |state| slot.mapper.feed(state, now, &queue),
        .xinput_wireless => if (pad.parseXInputWireless(report)) |parsed| switch (parsed) {
            .connection => |connected| {
                slot.connected = connected;
                if (!connected) slot.mapper.reset();
                changed = true;
            },
            .input => |state| {
                slot.connected = true;
                slot.mapper.feed(state, now, &queue);
            },
            .other => {},
        },
        .gip => if (pad.parseGip(report)) |packet| {
            switch (packet) {
                .input => |state| {
                    slot.gip_input_seen = true;
                    slot.mapper.feed(state, now, &queue);
                },
                .guide => if (pad.gipNeedsAck(report)) {
                    var ack = pad.gipAck(report[2]);
                    send(slot, &ack);
                },
                .announce => {
                    // A pad that (re)announces itself wants power-on again.
                    slot.gip_input_seen = false;
                    slot.gip_tries = 0;
                    slot.gip_next_ms = now;
                },
                .other => {},
            }
        },
        .hid => if (pad.parseHidReport(&slot.hid, slot.hid_order, report)) |state| slot.mapper.feed(state, now, &queue),
    }
    collect(index);
}

/// Error recovery, sync polling and GIP power-on retries.
fn service(services: *uefi.tables.BootServices, slot: *Slot, index: usize, now: u64) void {
    if (slot.failed and now >= slot.retry_ms) {
        // The device may be gone: only touch the protocol while the handle
        // still carries the same interface.
        if (!stillPresent(services, slot)) {
            slot.used = false;
            changed = true;
            return;
        }
        slot.failed = false;
        slot.errors +|= 1;
        slot.retry_ms = now + 500;
        if (slot.errors > 5) {
            stopSlot(slot);
            slot.used = false;
            changed = true;
            serial.writeAscii("[USB_PAD] giving up after repeated transfer errors\n");
            return;
        }
        if (slot.async_mode) _ = slot.io.async_interrupt_transfer(slot.io, slot.in_endpoint, false, 0, 0, null, null);
        clearHalt(slot.io, slot.in_endpoint);
        if (slot.async_mode) {
            if (slot.io.async_interrupt_transfer(slot.io, slot.in_endpoint, true, slot.interval, slot.packet_size, &onReport, slot) != .success) slot.async_mode = false;
        }
    }
    if (!slot.async_mode and now >= slot.next_sync_ms) {
        slot.next_sync_ms = now + @max(slot.interval, 8);
        var buffer: [report_capacity]u8 = undefined;
        var length: usize = slot.packet_size;
        var result: u32 = 0;
        // 1 ms: EDK2 treats a zero timeout as "wait forever".
        const status = slot.io.sync_interrupt_transfer(slot.io, slot.in_endpoint, &buffer, &length, 1, &result);
        if (status == .success and length > 0) {
            slot.reports +%= 1;
            handleReport(slot, index, buffer[0..@min(length, buffer.len)], now);
        } else if (status == .device_error and result & 0x02 != 0) {
            // EFI_USB_ERR_STALL: the endpoint halted.
            clearHalt(slot.io, slot.in_endpoint);
        }
    }
    if (slot.kind == .gip and !slot.gip_input_seen and slot.gip_tries < 4 and now >= slot.gip_next_ms) {
        slot.gip_tries += 1;
        slot.gip_next_ms = now + 1500;
        gipStart(slot);
    }
}

fn onReport(data: ?*anyopaque, length: usize, context: ?*anyopaque, result: u32) callconv(uefi.cc) Status {
    const slot: *Slot = @ptrCast(@alignCast(context orelse return .success));
    if (result != 0) {
        slot.failed = true;
        return .success;
    }
    const bytes: [*]const u8 = @ptrCast(data orelse return .success);
    if (length == 0) return .success;
    const n = @min(length, report_capacity);
    if (slot.count == ring_size) {
        // Keep the newest reports.
        slot.head = (slot.head + 1) % ring_size;
        slot.count -= 1;
    }
    const at = (slot.head + slot.count) % ring_size;
    @memcpy(slot.ring[at][0..n], bytes[0..n]);
    slot.ring_len[at] = @intCast(n);
    slot.count += 1;
    slot.reports +%= 1;
    return .success;
}

// ------------------------------------------------------------ scanning

fn scan(services: *uefi.tables.BootServices, now: u64) void {
    scanned = true;
    last_scan_ms = now;
    const handles = (services.locateHandleBuffer(.{ .by_protocol = &UsbIo.guid }) catch null) orelse {
        forgetAbsent(&.{});
        total_handles = 0;
        return;
    };
    defer services.freePool(@ptrCast(handles.ptr)) catch {};
    total_handles = handles.len;
    forgetAbsent(handles);
    for (handles) |handle| {
        if (known(handle)) continue;
        const io = (services.handleProtocol(UsbIo, handle) catch null) orelse continue;
        if (entry_count == max_entries) {
            entries_dropped += 1;
            continue;
        }
        entries[entry_count] = inspect(services, handle, io);
        entry_count += 1;
        changed = true;
    }
}

fn known(handle: uefi.Handle) bool {
    for (entries[0..entry_count]) |entry| {
        if (entry.handle == handle) return true;
    }
    return false;
}

/// Drops entries and slots whose handle disappeared (unplugged). Their
/// protocol is never called again; the firmware already removed the
/// device's transfers.
fn forgetAbsent(handles: []const uefi.Handle) void {
    var index: usize = 0;
    while (index < entry_count) {
        const handle = entries[index].handle;
        const present = for (handles) |candidate| {
            if (candidate == handle) break true;
        } else false;
        if (present) {
            index += 1;
            continue;
        }
        for (&slots) |*slot| {
            if (slot.used and slot.handle == handle) slot.used = false;
        }
        entries[index] = entries[entry_count - 1];
        entry_count -= 1;
        changed = true;
    }
    ally_present = false;
    for (entries[0..entry_count]) |entry| {
        if (pad.isRogAlly(entry.vid, entry.pid)) ally_present = true;
    }
}

fn stillPresent(services: *uefi.tables.BootServices, slot: *const Slot) bool {
    const io = (services.handleProtocol(UsbIo, slot.handle) catch null) orelse return false;
    return io == slot.io;
}

fn boundByDriver(services: *uefi.tables.BootServices, handle: uefi.Handle) bool {
    const raw: *const fn (uefi.Handle, *const uefi.Guid, *[*]OpenInfo, *usize) callconv(uefi.cc) Status = @ptrCast(services._openProtocolInformation);
    var list: [*]OpenInfo = undefined;
    var count: usize = 0;
    if (raw(handle, &UsbIo.guid, &list, &count) != .success) return false;
    defer services.freePool(@ptrCast(@alignCast(list))) catch {};
    for (list[0..count]) |info| {
        if (info.attributes & (open_by_driver | open_exclusive) != 0) return true;
    }
    return false;
}

fn inspect(services: *uefi.tables.BootServices, handle: uefi.Handle, io: *UsbIo) Entry {
    var entry = Entry{ .handle = handle, .io = io };
    var device: DeviceDescriptor = undefined;
    if (io.get_device_descriptor(io, &device) == .success) {
        entry.vid = device.vendor;
        entry.pid = device.product;
        entry.device_class = .{ device.device_class, device.device_subclass, device.device_protocol };
    }
    var interface: InterfaceDescriptor = undefined;
    if (io.get_interface_descriptor(io, &interface) != .success) return entry;
    entry.interface = .{ .class = interface.class, .subclass = interface.subclass, .protocol = interface.protocol, .number = interface.number };
    entry.endpoints = interface.endpoints;
    entry.bound = boundByDriver(services, handle);
    if (pad.isRogAlly(entry.vid, entry.pid)) ally_present = true;

    if (entry.vid == 0x045E and (entry.pid == 0x02E6 or entry.pid == 0x02FE or entry.pid == 0x091E)) {
        entry.verdict = .unsupported_adapter;
        return entry;
    }
    const kind: pad.Kind = switch (pad.classify(entry.interface)) {
        .none => return entry,
        .hid_keyboard, .hid_mouse => {
            entry.verdict = .keyboard_or_mouse;
            return entry;
        },
        .xinput => .xinput,
        .xinput_wireless => .xinput_wireless,
        .gip => .gip,
        .hid_probe => .hid,
    };
    if (entry.bound) {
        entry.verdict = .bound_by_firmware;
        entry.kind = kind;
        return entry;
    }

    var layout = pad.HidLayout{};
    if (kind == .hid) {
        const descriptor = readReportDescriptor(io, interface.number) orelse {
            entry.verdict = .hid_descriptor_failed;
            return entry;
        };
        layout = pad.parseHidDescriptor(descriptor);
        entry.hid_application = layout.first_application;
        if (!layout.isGamepad()) {
            entry.verdict = .hid_not_a_gamepad;
            return entry;
        }
    }
    entry.kind = kind;

    var in_endpoint: ?EndpointDescriptor = null;
    var out_endpoint: ?EndpointDescriptor = null;
    var index: u8 = 0;
    while (index < interface.endpoints) : (index += 1) {
        var endpoint: EndpointDescriptor = undefined;
        if (io.get_endpoint_descriptor(io, index, &endpoint) != .success) continue;
        if (endpoint.attributes & 0x03 != 0x03) continue; // interrupt only
        if (endpoint.address & 0x80 != 0) {
            if (in_endpoint == null) in_endpoint = endpoint;
        } else if (out_endpoint == null) out_endpoint = endpoint;
    }
    const input = in_endpoint orelse {
        entry.verdict = .no_interrupt_in;
        return entry;
    };
    entry.in_endpoint = input.address;
    if (out_endpoint) |output| entry.out_endpoint = output.address;

    const slot = for (&slots) |*candidate| {
        if (!candidate.used) break candidate;
    } else {
        entry.verdict = .no_free_slot;
        return entry;
    };
    slot.* = .{
        .used = true,
        .handle = handle,
        .io = io,
        .kind = kind,
        .vid = entry.vid,
        .pid = entry.pid,
        .in_endpoint = input.address,
        .out_endpoint = entry.out_endpoint,
        .packet_size = std.math.clamp(@as(usize, input.max_packet_size & 0x7FF), 8, report_capacity),
        .interval = std.math.clamp(@as(usize, input.interval), 1, 16),
        .hid = layout,
        .hid_order = pad.hidButtonOrder(entry.vid, entry.pid, &layout),
        // A receiver slot counts once a pad reports presence or input.
        .connected = kind != .xinput_wireless,
    };

    // Xbox 360 clones need this vendor request before they report (xpad).
    if (kind == .xinput) {
        var scratch: [20]u8 = undefined;
        _ = control(io, .{ .request_type = 0xC1, .request = 0x01, .value = 0x0100, .index = 0, .length = scratch.len }, UsbIo.data_in, &scratch);
    }

    slot.async_mode = io.async_interrupt_transfer(io, input.address, true, slot.interval, slot.packet_size, &onReport, slot) == .success;
    if (!slot.async_mode) {
        // Probe one sync transfer; a hard error (not a timeout) means the
        // firmware cannot drive this endpoint at all.
        var buffer: [report_capacity]u8 = undefined;
        var length: usize = slot.packet_size;
        var result: u32 = 0;
        const status = io.sync_interrupt_transfer(io, input.address, &buffer, &length, 1, &result);
        if (status != .success and status != .timeout and status != .device_error) {
            slot.used = false;
            entry.verdict = .start_failed;
            return entry;
        }
    }
    entry.async_mode = slot.async_mode;

    switch (kind) {
        .xinput => send(slot, &pad.xinput_led),
        // Ask the receiver which of its pads are connected (xpad's inquiry).
        .xinput_wireless => send(slot, &[_]u8{ 0x08, 0x00, 0x0F, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }),
        .gip => {
            slot.gip_tries = 1;
            slot.gip_next_ms = nowMs() + 1500;
            gipStart(slot);
        },
        else => {},
    }
    entry.verdict = .claimed;
    trace(entry);
    return entry;
}

fn trace(entry: Entry) void {
    var buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "[USB_PAD] claimed {s} vid={x:0>4} pid={x:0>4} if={d} in=0x{x:0>2} out=0x{x:0>2} async={s}\n", .{
        if (entry.kind) |kind| kind.short() else "?",
        entry.vid,
        entry.pid,
        entry.interface.number,
        entry.in_endpoint,
        entry.out_endpoint,
        if (entry.async_mode) "yes" else "no",
    }) catch return;
    serial.writeAscii(line);
}

fn gipStart(slot: *Slot) void {
    var packets_buffer: [6][]const u8 = undefined;
    for (pad.gipInitPackets(slot.vid, slot.pid, &packets_buffer)) |template| {
        var packet: [16]u8 = undefined;
        const n = @min(template.len, packet.len);
        @memcpy(packet[0..n], template[0..n]);
        packet[2] = pad.nextGipSequence(&slot.gip_sequence);
        send(slot, packet[0..n]);
    }
}

/// Interrupt OUT (LED, GIP commands); ignored when the pad has none.
fn send(slot: *Slot, bytes: []const u8) void {
    if (slot.out_endpoint == 0) return;
    var buffer: [report_capacity]u8 = undefined;
    const n = @min(bytes.len, buffer.len);
    @memcpy(buffer[0..n], bytes[0..n]);
    var length: usize = n;
    var result: u32 = 0;
    _ = slot.io.sync_interrupt_transfer(slot.io, slot.out_endpoint, &buffer, &length, 50, &result);
}

fn control(io: *UsbIo, request: DeviceRequest, direction: u32, data: []u8) bool {
    var result: u32 = 0;
    var copy = request;
    return io.control_transfer(io, &copy, direction, 100, if (data.len > 0) data.ptr else null, data.len, &result) == .success;
}

fn clearHalt(io: *UsbIo, endpoint: u8) void {
    _ = control(io, .{ .request_type = 0x02, .request = 0x01, .value = 0, .index = endpoint, .length = 0 }, UsbIo.no_data, &.{});
}

/// GET_DESCRIPTOR(Report) with the exact length from the HID class
/// descriptor in the configuration (512 bytes when it cannot be found).
fn readReportDescriptor(io: *UsbIo, interface_number: u8) ?[]const u8 {
    var length: u16 = 512;
    var config: ConfigDescriptor = undefined;
    if (io.get_config_descriptor(io, &config) == .success and config.total_length >= 9) {
        const total: u16 = @min(config.total_length, config_buffer.len);
        @memset(config_buffer[0..total], 0);
        if (control(io, .{ .request_type = 0x80, .request = 0x06, .value = 0x0200, .index = 0, .length = total }, UsbIo.data_in, config_buffer[0..total])) {
            if (pad.hidReportDescriptorLength(config_buffer[0..total], interface_number)) |exact| length = exact;
        }
    }
    length = @min(length, descriptor_buffer.len);
    if (length == 0) return null;
    @memset(descriptor_buffer[0..length], 0);
    if (!control(io, .{ .request_type = 0x81, .request = 0x06, .value = 0x2200, .index = interface_number, .length = length }, UsbIo.data_in, descriptor_buffer[0..length])) return null;
    return descriptor_buffer[0..length];
}

fn stopSlot(slot: *Slot) void {
    if (slot.async_mode) _ = slot.io.async_interrupt_transfer(slot.io, slot.in_endpoint, false, 0, 0, null, null);
    slot.async_mode = false;
}

/// Cancels every transfer before another loader runs (the callback lives
/// in this image). The next poll rescans and restarts the pads, e.g. when
/// a launch fails and the menu comes back.
pub fn stop() void {
    const services = uefi.system_table.boot_services orelse return;
    for (&slots) |*slot| {
        if (!slot.used) continue;
        if (stillPresent(services, slot)) stopSlot(slot);
        slot.used = false;
    }
    entry_count = 0;
    entries_dropped = 0;
    pending_len = 0;
    scanned = false;
}

/// Scans now if no scan ran yet (the input report is written early).
pub fn ensureScanned() void {
    if (scanned) return;
    const services = uefi.system_table.boot_services orelse return;
    scan(services, nowMs());
}

/// True once after the set of USB interfaces changed (report rewrite).
pub fn takeChanged() bool {
    const value = changed;
    changed = false;
    return value;
}

// ------------------------------------------------------------ report

pub const Report = struct {
    pub fn count() usize {
        return entry_count;
    }

    pub fn entry(index: usize) Entry {
        return entries[index];
    }

    pub fn dropped() usize {
        return entries_dropped;
    }

    pub fn handles() usize {
        return total_handles;
    }

    pub fn activePads() usize {
        var n: usize = 0;
        for (slots) |slot| {
            if (slot.used and slot.connected) n += 1;
        }
        return n;
    }

    pub fn reportsFor(handle: uefi.Handle) ?u32 {
        for (slots) |slot| {
            if (slot.used and slot.handle == handle) return slot.reports;
        }
        return null;
    }

    pub fn allyPresent() bool {
        return ally_present;
    }
};

/// "GIP Xbox Series X|S Controller 045E:0B12" for the input test screen.
pub fn describe(buffer: []u8, kind: pad.Kind, vid: u16, pid: u16) []const u8 {
    const name = if (vid == 0x045E and pid == 0x028E and ally_present)
        "ROG Ally built-in controller"
    else
        pad.productName(vid, pid) orelse kind.label();
    return std.fmt.bufPrint(buffer, "{s} {s} {x:0>4}:{x:0>4}", .{ kind.short(), name, vid, pid }) catch kind.short();
}

/// Summary of the claimed pads for the input test screen.
pub fn padsLine(buffer: []u8) []const u8 {
    var used: usize = 0;
    const head = std.fmt.bufPrint(buffer, "USB: {d} interfaces, gamepads: {d}", .{ total_handles, Report.activePads() }) catch return "";
    used = head.len;
    for (slots) |slot| {
        if (!slot.used) continue;
        var name: [96]u8 = undefined;
        const text = std.fmt.bufPrint(buffer[used..], "  [{s}{s} reports={d}]", .{ describe(&name, slot.kind, slot.vid, slot.pid), if (slot.async_mode) "" else " sync", slot.reports }) catch break;
        used += text.len;
    }
    return buffer[0..used];
}
