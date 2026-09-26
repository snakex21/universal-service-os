//! USB gamepad protocols for the UEFI menu, independent of the firmware:
//! interface classification, report parsing for XInput (Xbox 360 wired and
//! the Xbox 360 wireless receiver), GIP (Xbox One / Series wired, ROG Ally X)
//! and generic HID gamepads (minimal report descriptor parser), the GIP
//! start-up packets, and the mapping of pad state to menu actions with the
//! same layout as the micro-Linux menu (fb_menu_input.zig):
//!
//!   D-pad or left stick = move (deadzone + hysteresis, repeat on hold)
//!   A = OK, B = back, Start = OK (primary action), Back/View = back,
//!   LB/RB = page up/down.
//!
//! The UEFI side (src/platform/uefi/usb_gamepad.zig) talks to the pads
//! through EFI_USB_IO_PROTOCOL and feeds the reports into this module.
const std = @import("std");
const input_map = @import("input_map.zig");

pub const Kind = enum {
    xinput,
    xinput_wireless,
    gip,
    hid,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .xinput => "XInput (Xbox 360 wired)",
            .xinput_wireless => "XInput (Xbox 360 wireless receiver)",
            .gip => "GIP (Xbox One/Series wired)",
            .hid => "HID gamepad",
        };
    }

    pub fn short(self: Kind) []const u8 {
        return switch (self) {
            .xinput => "XInput",
            .xinput_wireless => "XInput-W",
            .gip => "GIP",
            .hid => "HID",
        };
    }
};

pub const Buttons = packed struct(u16) {
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    lb: bool = false,
    rb: bool = false,
    back: bool = false,
    start: bool = false,
    guide: bool = false,
    ls: bool = false,
    rs: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u1 = 0,

    pub fn bits(self: Buttons) u16 {
        return @bitCast(self);
    }
};

/// Normalised pad state. The left stick is -stick_range..stick_range with
/// y positive = down (screen direction), whatever the device reports.
pub const State = struct {
    buttons: Buttons = .{},
    x: i32 = 0,
    y: i32 = 0,
};

pub const stick_range: i32 = 32767;

// ------------------------------------------------------------ classification

pub const Interface = struct {
    class: u8,
    subclass: u8,
    protocol: u8,
    number: u8,
};

pub const Candidate = enum {
    none,
    xinput,
    xinput_wireless,
    gip,
    /// Class 3 that is not a boot keyboard/mouse: the report descriptor
    /// decides (gamepad/joystick application usage).
    hid_probe,
    hid_keyboard,
    hid_mouse,
};

/// What an interface is, from its descriptor alone (Linux xpad matches the
/// same class/subclass/protocol triples for every vendor).
pub fn classify(interface: Interface) Candidate {
    if (interface.class == 0xFF and interface.subclass == 0x5D) {
        return switch (interface.protocol) {
            0x01 => .xinput,
            0x81 => .xinput_wireless,
            else => .none, // 0x02/0x03 headset/chatpad, 0x82 receiver audio
        };
    }
    // GIP: only interface 0 carries input; 1 and 2 are audio (xpad does the same).
    if (interface.class == 0xFF and interface.subclass == 0x47 and interface.protocol == 0xD0) {
        return if (interface.number == 0) .gip else .none;
    }
    if (interface.class == 0x03) {
        if (interface.subclass == 0x01 and interface.protocol == 0x01) return .hid_keyboard;
        if (interface.subclass == 0x01 and interface.protocol == 0x02) return .hid_mouse;
        return .hid_probe;
    }
    return .none;
}

/// Friendly names for known pads (report and input test only).
pub fn productName(vid: u16, pid: u16) ?[]const u8 {
    return switch (vid) {
        0x045E => switch (pid) {
            0x028E => "Xbox 360 Controller (or a built-in XInput pad)",
            0x028F => "Xbox 360 Wireless Controller (plug-and-charge cable)",
            0x0719 => "Xbox 360 Wireless Receiver",
            0x02D1, 0x02DD => "Xbox One Controller",
            0x02E3 => "Xbox One Elite Controller",
            0x02EA => "Xbox One S Controller",
            0x0B00 => "Xbox Elite Series 2 Controller",
            0x0B12 => "Xbox Series X|S Controller",
            0x02E6, 0x02FE, 0x091E => "Xbox Wireless Adapter (unsupported: needs the Wi-Fi dongle driver)",
            else => null,
        },
        0x0B05 => switch (pid) {
            0x1ABE => "ASUS ROG Ally (controller MCU)",
            0x1B4C => "ASUS ROG Ally X (controller MCU)",
            else => null,
        },
        0x054C => switch (pid) {
            0x05C4, 0x09CC => "Sony DualShock 4",
            0x0CE6 => "Sony DualSense",
            0x0DF2 => "Sony DualSense Edge",
            else => null,
        },
        0x057E => switch (pid) {
            0x2009 => "Nintendo Switch Pro Controller (needs a handshake, not supported)",
            else => null,
        },
        else => null,
    };
}

pub fn isRogAlly(vid: u16, pid: u16) bool {
    return vid == 0x0B05 and (pid == 0x1ABE or pid == 0x1B4C);
}

// ------------------------------------------------------------ XInput

fn le16(bytes: []const u8, offset: usize) i16 {
    return @bitCast(@as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8));
}

/// A device axis with positive = up (XInput, GIP) to screen y.
fn flipY(value: i16) i32 {
    return @min(stick_range, -@as(i32, value));
}

fn clampX(value: i16) i32 {
    return @max(-stick_range, @as(i32, value));
}

/// Xbox 360 button block (wired bytes 2..13, wireless bytes 6..17).
fn decode360(data: []const u8) State {
    const b2 = data[2];
    const b3 = data[3];
    return .{
        .buttons = .{
            .up = b2 & 0x01 != 0,
            .down = b2 & 0x02 != 0,
            .left = b2 & 0x04 != 0,
            .right = b2 & 0x08 != 0,
            .start = b2 & 0x10 != 0,
            .back = b2 & 0x20 != 0,
            .ls = b2 & 0x40 != 0,
            .rs = b2 & 0x80 != 0,
            .lb = b3 & 0x01 != 0,
            .rb = b3 & 0x02 != 0,
            .guide = b3 & 0x04 != 0,
            .a = b3 & 0x10 != 0,
            .b = b3 & 0x20 != 0,
            .x = b3 & 0x40 != 0,
            .y = b3 & 0x80 != 0,
        },
        .x = clampX(le16(data, 6)),
        .y = flipY(le16(data, 8)),
    };
}

/// Wired Xbox 360 (XInput) interrupt IN report: type 0x00, length 0x14.
/// Other types (0x01 LED status, 0x02/0x03 rumble/headset) are not input.
pub fn parseXInput(report: []const u8) ?State {
    if (report.len < 14 or report[0] != 0x00 or report[1] < 0x0E) return null;
    return decode360(report);
}

pub const WirelessReport = union(enum) {
    /// Presence change of the pad paired to this receiver slot.
    connection: bool,
    input: State,
    other,
};

/// Xbox 360 wireless receiver slot report (29 bytes): presence packets
/// have bit 3 of byte 0 set; input has byte 1 = 0x01 and the wired layout
/// from byte 4.
pub fn parseXInputWireless(report: []const u8) ?WirelessReport {
    if (report.len < 2) return null;
    if (report[0] & 0x08 != 0) return .{ .connection = report[1] & 0x80 != 0 };
    if (report[1] == 0x01 and report.len >= 18) return .{ .input = decode360(report[4..]) };
    return .other;
}

/// XInput output report: player LED (0x02 = "1" flashes, then stays on).
pub const xinput_led = [_]u8{ 0x01, 0x03, 0x02 };

// ------------------------------------------------------------ GIP

pub const gip = struct {
    pub const cmd_ack: u8 = 0x01;
    pub const cmd_announce: u8 = 0x02;
    pub const cmd_identify: u8 = 0x04;
    pub const cmd_power: u8 = 0x05;
    pub const cmd_virtual_key: u8 = 0x07;
    pub const cmd_input: u8 = 0x20;
    pub const opt_ack: u8 = 0x10;
    pub const opt_internal: u8 = 0x20;
};

pub const GipPacket = union(enum) {
    input: State,
    /// Guide (Xbox) button state; the packet may ask for an ACK.
    guide: bool,
    announce,
    other: u8,
};

/// A GIP packet from the interrupt IN endpoint: command, options,
/// sequence, payload length, payload.
pub fn parseGip(packet: []const u8) ?GipPacket {
    if (packet.len < 4) return null;
    switch (packet[0]) {
        gip.cmd_input => {
            if (packet.len < 18) return null;
            const b4 = packet[4];
            const b5 = packet[5];
            return .{ .input = .{
                .buttons = .{
                    .start = b4 & 0x04 != 0,
                    .back = b4 & 0x08 != 0,
                    .a = b4 & 0x10 != 0,
                    .b = b4 & 0x20 != 0,
                    .x = b4 & 0x40 != 0,
                    .y = b4 & 0x80 != 0,
                    .up = b5 & 0x01 != 0,
                    .down = b5 & 0x02 != 0,
                    .left = b5 & 0x04 != 0,
                    .right = b5 & 0x08 != 0,
                    .lb = b5 & 0x10 != 0,
                    .rb = b5 & 0x20 != 0,
                    .ls = b5 & 0x40 != 0,
                    .rs = b5 & 0x80 != 0,
                },
                .x = clampX(le16(packet, 10)),
                .y = flipY(le16(packet, 12)),
            } };
        },
        gip.cmd_virtual_key => return if (packet.len >= 5) .{ .guide = packet[4] & 0x01 != 0 } else null,
        gip.cmd_announce => return .announce,
        else => return .{ .other = packet[0] },
    }
}

/// The guide-button packet asks for an acknowledgement (xpad acks it; an
/// unacknowledged packet is resent by the controller).
pub fn gipNeedsAck(packet: []const u8) bool {
    return packet.len >= 3 and packet[0] == gip.cmd_virtual_key and packet[1] == (gip.opt_ack | gip.opt_internal);
}

/// ACK for a guide-button packet; `sequence` is the received packet's.
pub fn gipAck(sequence: u8) [13]u8 {
    return .{ gip.cmd_ack, gip.opt_internal, sequence, 0x09, 0x00, gip.cmd_virtual_key, gip.opt_internal, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
}

const gip_power_on = [_]u8{ gip.cmd_power, gip.opt_internal, 0x00, 0x01, 0x00 };
const gip_s_init = [_]u8{ gip.cmd_power, gip.opt_internal, 0x00, 0x0F, 0x06 };
const gip_hori_ack_id = [_]u8{ gip.cmd_ack, gip.opt_internal, 0x00, 0x09, 0x00, gip.cmd_identify, gip.opt_internal, 0x3A, 0x00, 0x00, 0x00, 0x80, 0x00 };
const gip_pdp_led_on = [_]u8{ 0x0A, gip.opt_internal, 0x00, 0x03, 0x00, 0x01, 0x14 };
const gip_pdp_auth = [_]u8{ 0x06, gip.opt_internal, 0x00, 0x02, 0x01, 0x00 };
const gip_rumble_begin = [_]u8{ 0x09, 0x00, 0x00, 0x09, 0x00, 0x0F, 0x00, 0x00, 0x1D, 0x1D, 0xFF, 0x00, 0x00 };
const gip_rumble_end = [_]u8{ 0x09, 0x00, 0x00, 0x09, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

/// Start-up packets for a GIP pad, in order (Linux xpad's
/// xboxone_init_packets): the power-on command for everyone plus the
/// vendor quirks. Byte 2 is the sequence number, filled in by the sender.
pub fn gipInitPackets(vid: u16, pid: u16, buffer: *[6][]const u8) []const []const u8 {
    var count: usize = 0;
    if (vid == 0x0F0D) {
        buffer[count] = &gip_hori_ack_id;
        count += 1;
    }
    buffer[count] = &gip_power_on;
    count += 1;
    if (vid == 0x045E and (pid == 0x02EA or pid == 0x0B00)) {
        buffer[count] = &gip_s_init;
        count += 1;
    }
    if (vid == 0x0E6F) {
        buffer[count] = &gip_pdp_led_on;
        buffer[count + 1] = &gip_pdp_auth;
        count += 2;
    }
    if (vid == 0x24C6 and (pid == 0x541A or pid == 0x542A or pid == 0x543A)) {
        buffer[count] = &gip_rumble_begin;
        buffer[count + 1] = &gip_rumble_end;
        count += 2;
    }
    return buffer[0..count];
}

/// GIP sequence numbers run 1..255 (0 is skipped).
pub fn nextGipSequence(sequence: *u8) u8 {
    sequence.* +%= 1;
    if (sequence.* == 0) sequence.* = 1;
    return sequence.*;
}

// ------------------------------------------------------------ HID

pub const HidField = struct {
    report_id: u8 = 0,
    /// Bit offset after the report ID byte.
    bit: u16 = 0,
    size: u8 = 0,
    minimum: i32 = 0,
    maximum: i32 = 0,
};

pub const ButtonOrder = enum {
    /// Linux BTN_GAMEPAD order for the Gamepad usage (8BitDo and others
    /// built for it): 1 A, 2 B, 4 X, 5 Y, 7 LB, 8 RB, 11 Back, 12 Start.
    gamepad,
    /// DirectInput-style Joystick order: 1 A, 2 B, 3 X, 4 Y, 5 LB, 6 RB,
    /// 9 Back, 10 Start.
    joystick,
    /// Square first (Sony DualShock/DualSense, Logitech D-mode):
    /// 1 X, 2 A (Cross), 3 B (Circle), 4 Y, 5 LB, 6 RB, 9 Back, 10 Start.
    square_first,
};

pub const max_hid_buttons = 16;

pub const HidLayout = struct {
    /// Generic Desktop usage of the first application collection that is a
    /// joystick (0x04), gamepad (0x05) or multi-axis controller (0x08).
    application: u16 = 0,
    /// Usage of the first application collection of any kind (report).
    first_application: u32 = 0,
    uses_report_ids: bool = false,
    buttons: [max_hid_buttons]?HidField = @splat(null),
    x: ?HidField = null,
    y: ?HidField = null,
    hat: ?HidField = null,
    /// Generic Desktop D-pad usages 0x90..0x93 (up, down, right, left).
    dpad: [4]?HidField = @splat(null),
    order: ButtonOrder = .joystick,

    pub fn isGamepad(self: *const HidLayout) bool {
        if (self.application == 0) return false;
        return self.buttonCount() > 0 or self.x != null or self.hat != null;
    }

    pub fn buttonCount(self: *const HidLayout) usize {
        var count: usize = 0;
        for (self.buttons) |field| {
            if (field != null) count += 1;
        }
        return count;
    }
};

const page_generic_desktop: u16 = 0x01;
const page_button: u16 = 0x09;

const Globals = struct {
    usage_page: u16 = 0,
    logical_min: i32 = 0,
    logical_max: i32 = 0,
    logical_max_unsigned: u32 = 0,
    report_size: u32 = 0,
    report_count: u32 = 0,
    report_id: u8 = 0,
};

/// Minimal HID report descriptor parser: finds the buttons, X/Y, hat
/// switch and D-pad usages of a joystick/gamepad application collection
/// and their bit positions per report ID. Arrays, outputs and features are
/// skipped (their bits still count). Malformed input stops parsing.
pub fn parseHidDescriptor(descriptor: []const u8) HidLayout {
    var layout = HidLayout{};
    var globals = Globals{};
    var stack: [4]Globals = undefined;
    var stack_len: usize = 0;
    var usages: [24]u32 = undefined;
    var usage_count: usize = 0;
    var usage_min: ?u32 = null;
    var usage_max: ?u32 = null;
    var offsets: [256]u32 = @splat(0);
    var depth: u32 = 0;
    var pad_depth: ?u32 = null;

    var index: usize = 0;
    while (index < descriptor.len) {
        const prefix = descriptor[index];
        if (prefix == 0xFE) {
            // Long item: bDataSize, bLongItemTag, data.
            if (index + 1 >= descriptor.len) break;
            index += 3 + @as(usize, descriptor[index + 1]);
            continue;
        }
        const size: usize = switch (prefix & 0x03) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 4,
        };
        if (index + 1 + size > descriptor.len) break;
        const data = descriptor[index + 1 .. index + 1 + size];
        index += 1 + size;
        const item_type = (prefix >> 2) & 0x03;
        const tag = prefix >> 4;
        const unsigned = unsignedValue(data);
        const signed = signedValue(data);

        switch (item_type) {
            // Main
            0 => {
                switch (tag) {
                    0x8 => { // Input
                        const constant = unsigned & 0x01 != 0;
                        const variable = unsigned & 0x02 != 0;
                        const bit_size = globals.report_size;
                        var element: u32 = 0;
                        while (element < globals.report_count) : (element += 1) {
                            if (pad_depth == null or constant or !variable or bit_size == 0 or bit_size > 32) break;
                            const usage = usageAt(usages[0..usage_count], usage_min, usage_max, element) orelse break;
                            const field = HidField{
                                .report_id = globals.report_id,
                                .bit = @intCast(@min(offsets[globals.report_id] + element * bit_size, std.math.maxInt(u16))),
                                .size = @intCast(bit_size),
                                .minimum = globals.logical_min,
                                .maximum = logicalMax(globals),
                            };
                            record(&layout, usage, field);
                        }
                        offsets[globals.report_id] +|= globals.report_size *| globals.report_count;
                    },
                    0x9, 0xB => {}, // Output, Feature: separate reports
                    0xA => { // Collection
                        depth += 1;
                        if (data.len > 0 and unsigned == 0x01) {
                            const usage = if (usage_count > 0) usages[0] else (usage_min orelse 0);
                            if (layout.first_application == 0) layout.first_application = usage;
                            const page: u16 = @intCast(usage >> 16);
                            const id: u16 = @truncate(usage);
                            if (pad_depth == null and layout.application == 0 and page == page_generic_desktop and (id == 0x04 or id == 0x05 or id == 0x08)) {
                                layout.application = id;
                                pad_depth = depth;
                            }
                        }
                    },
                    0xC => { // End Collection
                        if (pad_depth) |value| {
                            if (value == depth) pad_depth = null;
                        }
                        depth -|= 1;
                    },
                    else => {},
                }
                usage_count = 0;
                usage_min = null;
                usage_max = null;
            },
            // Global
            1 => switch (tag) {
                0x0 => globals.usage_page = @truncate(unsigned),
                0x1 => globals.logical_min = signed,
                0x2 => {
                    globals.logical_max = signed;
                    globals.logical_max_unsigned = unsigned;
                },
                0x7 => globals.report_size = unsigned,
                0x8 => {
                    globals.report_id = @truncate(unsigned);
                    layout.uses_report_ids = true;
                },
                0x9 => globals.report_count = unsigned,
                0xA => if (stack_len < stack.len) {
                    stack[stack_len] = globals;
                    stack_len += 1;
                },
                0xB => if (stack_len > 0) {
                    stack_len -= 1;
                    globals = stack[stack_len];
                },
                else => {},
            },
            // Local
            2 => {
                const full: u32 = if (size == 4) unsigned else (@as(u32, globals.usage_page) << 16) | (unsigned & 0xFFFF);
                switch (tag) {
                    0x0 => if (usage_count < usages.len) {
                        usages[usage_count] = full;
                        usage_count += 1;
                    },
                    0x1 => usage_min = full,
                    0x2 => usage_max = full,
                    else => {},
                }
            },
            else => {},
        }
    }
    layout.order = switch (layout.application) {
        0x05 => .gamepad,
        else => .joystick,
    };
    return layout;
}

fn unsignedValue(data: []const u8) u32 {
    var value: u32 = 0;
    for (data, 0..) |byte, shift| value |= @as(u32, byte) << @intCast(shift * 8);
    return value;
}

fn signedValue(data: []const u8) i32 {
    return switch (data.len) {
        0 => 0,
        1 => @as(i8, @bitCast(data[0])),
        2 => @as(i16, @bitCast(@as(u16, data[0]) | (@as(u16, data[1]) << 8))),
        else => @bitCast(unsignedValue(data)),
    };
}

/// Many descriptors write Logical Maximum 255 as the one byte 0xFF (-1 when
/// sign-extended) next to a non-negative minimum: read it unsigned then.
fn logicalMax(globals: Globals) i32 {
    if (globals.logical_min >= 0 and globals.logical_max < globals.logical_min) {
        return @intCast(@min(globals.logical_max_unsigned, std.math.maxInt(i32)));
    }
    return globals.logical_max;
}

fn usageAt(list: []const u32, minimum: ?u32, maximum: ?u32, element: u32) ?u32 {
    if (list.len > 0) return list[@min(element, list.len - 1)];
    const low = minimum orelse return null;
    const usage = low +| element;
    if (maximum) |high| {
        if (usage > high) return null;
    }
    return usage;
}

fn record(layout: *HidLayout, usage: u32, field: HidField) void {
    const page: u16 = @intCast(usage >> 16);
    const id: u16 = @truncate(usage);
    if (page == page_button) {
        if (id >= 1 and id <= max_hid_buttons and layout.buttons[id - 1] == null) layout.buttons[id - 1] = field;
        return;
    }
    if (page != page_generic_desktop) return;
    switch (id) {
        0x30 => if (layout.x == null) {
            layout.x = field;
        },
        0x31 => if (layout.y == null) {
            layout.y = field;
        },
        0x39 => if (layout.hat == null) {
            layout.hat = field;
        },
        0x90...0x93 => if (layout.dpad[id - 0x90] == null) {
            layout.dpad[id - 0x90] = field;
        },
        else => {},
    }
}

/// Square-first pads (see ButtonOrder) by vendor/product.
pub fn hidButtonOrder(vid: u16, pid: u16, layout: *const HidLayout) ButtonOrder {
    if (vid == 0x054C) return .square_first;
    if (vid == 0x046D and (pid == 0xC216 or pid == 0xC218 or pid == 0xC219)) return .square_first;
    return layout.order;
}

fn readBits(data: []const u8, bit: u32, size: u8) ?u32 {
    if (size == 0 or size > 32) return null;
    if (bit + size > data.len * 8) return null;
    var value: u64 = 0;
    var index: u32 = 0;
    while (index < size) : (index += 1) {
        const position = bit + index;
        if (data[position / 8] & (@as(u8, 1) << @intCast(position % 8)) != 0) value |= @as(u64, 1) << @intCast(index);
    }
    return @intCast(value);
}

fn fieldValue(data: []const u8, field: HidField) ?i32 {
    const raw = readBits(data, field.bit, field.size) orelse return null;
    if (field.minimum < 0 and field.size < 32) {
        const shift: u5 = @intCast(32 - @as(u32, field.size));
        return @as(i32, @bitCast(raw << shift)) >> shift;
    }
    return @bitCast(raw);
}

fn buttonTarget(order: ButtonOrder, number: usize) ?std.meta.FieldEnum(Buttons) {
    return switch (order) {
        .gamepad => switch (number) {
            1 => .a,
            2 => .b,
            4 => .x,
            5 => .y,
            7 => .lb,
            8 => .rb,
            11 => .back,
            12 => .start,
            13 => .guide,
            14 => .ls,
            15 => .rs,
            else => null,
        },
        .joystick => switch (number) {
            1 => .a,
            2 => .b,
            3 => .x,
            4 => .y,
            5 => .lb,
            6 => .rb,
            9 => .back,
            10 => .start,
            11 => .ls,
            12 => .rs,
            13 => .guide,
            else => null,
        },
        .square_first => switch (number) {
            1 => .x,
            2 => .a,
            3 => .b,
            4 => .y,
            5 => .lb,
            6 => .rb,
            9 => .back,
            10 => .start,
            11 => .ls,
            12 => .rs,
            13 => .guide,
            else => null,
        },
    };
}

fn setButton(buttons: *Buttons, which: std.meta.FieldEnum(Buttons)) void {
    switch (which) {
        inline else => |tag| if (comptime tag != ._pad) {
            @field(buttons, @tagName(tag)) = true;
        },
    }
}

/// One input report of a HID gamepad (with the report ID byte, if the
/// descriptor uses IDs). Null when the report carries none of the pad's
/// fields (another report ID).
pub fn parseHidReport(layout: *const HidLayout, order: ButtonOrder, report: []const u8) ?State {
    var data = report;
    var id: u8 = 0;
    if (layout.uses_report_ids) {
        if (report.len == 0) return null;
        id = report[0];
        data = report[1..];
    }
    var state = State{};
    var matched = false;
    for (layout.buttons, 1..) |maybe, number| {
        const field = maybe orelse continue;
        if (field.report_id != id) continue;
        matched = true;
        const value = fieldValue(data, field) orelse continue;
        if (value == 0) continue;
        if (buttonTarget(order, number)) |target| setButton(&state.buttons, target);
    }
    if (layout.x) |field| {
        if (field.report_id == id) {
            matched = true;
            if (fieldValue(data, field)) |value| state.x = input_map.centreAxis(value, field.minimum, field.maximum, stick_range);
        }
    }
    if (layout.y) |field| {
        if (field.report_id == id) {
            matched = true;
            if (fieldValue(data, field)) |value| state.y = input_map.centreAxis(value, field.minimum, field.maximum, stick_range);
        }
    }
    if (layout.hat) |field| {
        if (field.report_id == id) {
            matched = true;
            if (fieldValue(data, field)) |value| applyHat(&state.buttons, value, field);
        }
    }
    for (layout.dpad, 0..) |maybe, index| {
        const field = maybe orelse continue;
        if (field.report_id != id) continue;
        matched = true;
        const value = fieldValue(data, field) orelse continue;
        if (value == 0) continue;
        switch (index) {
            0 => state.buttons.up = true,
            1 => state.buttons.down = true,
            2 => state.buttons.right = true,
            else => state.buttons.left = true,
        }
    }
    return if (matched) state else null;
}

/// Hat switch: 8 positions clockwise from up (4 positions: up, right, down,
/// left); anything outside the logical range is the centre (null state).
fn applyHat(buttons: *Buttons, value: i32, field: HidField) void {
    if (value < field.minimum or value > field.maximum) return;
    const positions = field.maximum - field.minimum + 1;
    const step = value - field.minimum;
    const eighth: i32 = if (positions == 4) step * 2 else step;
    switch (eighth) {
        0 => buttons.up = true,
        1 => {
            buttons.up = true;
            buttons.right = true;
        },
        2 => buttons.right = true,
        3 => {
            buttons.down = true;
            buttons.right = true;
        },
        4 => buttons.down = true,
        5 => {
            buttons.down = true;
            buttons.left = true;
        },
        6 => buttons.left = true,
        7 => {
            buttons.up = true;
            buttons.left = true;
        },
        else => {},
    }
}

/// Length of the HID report descriptor of `interface_number`, from the HID
/// class descriptor (0x21) that follows its interface descriptor in the
/// full configuration descriptor.
pub fn hidReportDescriptorLength(configuration: []const u8, interface_number: u8) ?u16 {
    var index: usize = 0;
    var in_interface = false;
    while (index + 2 <= configuration.len) {
        const length = configuration[index];
        if (length < 2 or index + length > configuration.len) return null;
        const descriptor = configuration[index .. index + length];
        switch (descriptor[1]) {
            0x04 => in_interface = length >= 9 and descriptor[2] == interface_number and descriptor[3] == 0,
            0x21 => if (in_interface and length >= 9) {
                const count = descriptor[5];
                var entry: usize = 0;
                while (entry < count and 6 + entry * 3 + 3 <= length) : (entry += 1) {
                    const at = 6 + entry * 3;
                    if (descriptor[at] == 0x22) return @as(u16, descriptor[at + 1]) | (@as(u16, descriptor[at + 2]) << 8);
                }
            },
            else => {},
        }
        index += length;
    }
    return null;
}

// ------------------------------------------------------------ mapping

/// X and Y are the secondary actions of a screen (edit, delete, backspace,
/// shift on the on-screen keyboard); most screens ignore them.
pub const Action = enum { up, down, left, right, accept, back, page_up, page_down, action_x, action_y };

pub const Button = enum { a, b, x, y, lb, rb, back, start, guide, ls, rs, dpad, stick };

pub const Output = struct {
    action: Action,
    /// The control that produced it (input test screen).
    button: Button,
};

pub const Queue = struct {
    items: [16]Output = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *Queue, item: Output) void {
        if (self.len == self.items.len) {
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
        }
        self.items[(self.head + self.len) % self.items.len] = item;
        self.len += 1;
    }

    pub fn pop(self: *Queue) ?Output {
        if (self.len == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return item;
    }
};

/// Pad state to menu actions: button presses on the rising edge; D-pad
/// (priority up, down, left, right) or the left stick move with
/// hold-to-repeat, like the micro-Linux menu.
pub const Mapper = struct {
    previous: Buttons = .{},
    stick: input_map.Stick = .{},
    repeat: input_map.Repeat = .{},
    source: Button = .dpad,

    pub fn feed(self: *Mapper, state: State, now_ms: u64, queue: *Queue) void {
        const pressed: Buttons = @bitCast(state.buttons.bits() & ~self.previous.bits());
        self.previous = state.buttons;
        if (pressed.a) queue.push(.{ .action = .accept, .button = .a });
        if (pressed.start) queue.push(.{ .action = .accept, .button = .start });
        if (pressed.b) queue.push(.{ .action = .back, .button = .b });
        if (pressed.back) queue.push(.{ .action = .back, .button = .back });
        if (pressed.lb) queue.push(.{ .action = .page_up, .button = .lb });
        if (pressed.rb) queue.push(.{ .action = .page_down, .button = .rb });
        if (pressed.x) queue.push(.{ .action = .action_x, .button = .x });
        if (pressed.y) queue.push(.{ .action = .action_y, .button = .y });

        const buttons = state.buttons;
        var direction: ?input_map.Direction = if (buttons.up) .up else if (buttons.down) .down else if (buttons.left) .left else if (buttons.right) .right else null;
        const stick = self.stick.update(state.x, state.y, stick_range);
        if (direction != null) {
            self.source = .dpad;
        } else if (stick != null) {
            direction = stick;
            self.source = .stick;
        }
        if (self.repeat.set(direction, now_ms)) |fire| queue.push(.{ .action = directionAction(fire), .button = self.source });
    }

    /// Due repeats of a held direction (call on every poll).
    pub fn tick(self: *Mapper, now_ms: u64, queue: *Queue) void {
        if (self.repeat.tick(now_ms)) |fire| queue.push(.{ .action = directionAction(fire), .button = self.source });
    }

    pub fn reset(self: *Mapper) void {
        self.* = .{};
    }
};

fn directionAction(direction: input_map.Direction) Action {
    return switch (direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    };
}

/// Suppresses the same action arriving from a second source within a short
/// window. Handheld firmware (ROG Ally) may emit keyboard arrows/Enter/Esc
/// for its controls while the XInput interface reports the same press.
pub const Dedupe = struct {
    window_ms: u64 = 150,
    last_source: u8 = 0xFF,
    last_action: u8 = 0,
    last_ms: u64 = 0,

    /// True when the event should be delivered.
    pub fn accept(self: *Dedupe, source: u8, action: u8, now_ms: u64) bool {
        if (self.last_source != 0xFF and source != self.last_source and action == self.last_action and now_ms -| self.last_ms < self.window_ms) return false;
        self.last_source = source;
        self.last_action = action;
        self.last_ms = now_ms;
        return true;
    }
};

// ------------------------------------------------------------ tests

fn xinputReport(b2: u8, b3: u8, lx: i16, ly: i16) [20]u8 {
    var report = [_]u8{0} ** 20;
    report[0] = 0x00;
    report[1] = 0x14;
    report[2] = b2;
    report[3] = b3;
    std.mem.writeInt(i16, report[6..8], lx, .little);
    std.mem.writeInt(i16, report[8..10], ly, .little);
    return report;
}

test "interfaces are classified like Linux xpad and USB HID boot devices" {
    try std.testing.expectEqual(Candidate.xinput, classify(.{ .class = 0xFF, .subclass = 0x5D, .protocol = 0x01, .number = 0 }));
    try std.testing.expectEqual(Candidate.xinput_wireless, classify(.{ .class = 0xFF, .subclass = 0x5D, .protocol = 0x81, .number = 2 }));
    try std.testing.expectEqual(Candidate.none, classify(.{ .class = 0xFF, .subclass = 0x5D, .protocol = 0x03, .number = 1 }));
    try std.testing.expectEqual(Candidate.gip, classify(.{ .class = 0xFF, .subclass = 0x47, .protocol = 0xD0, .number = 0 }));
    try std.testing.expectEqual(Candidate.none, classify(.{ .class = 0xFF, .subclass = 0x47, .protocol = 0xD0, .number = 1 }));
    try std.testing.expectEqual(Candidate.hid_keyboard, classify(.{ .class = 0x03, .subclass = 0x01, .protocol = 0x01, .number = 0 }));
    try std.testing.expectEqual(Candidate.hid_mouse, classify(.{ .class = 0x03, .subclass = 0x01, .protocol = 0x02, .number = 0 }));
    try std.testing.expectEqual(Candidate.hid_probe, classify(.{ .class = 0x03, .subclass = 0x00, .protocol = 0x00, .number = 0 }));
    try std.testing.expectEqual(Candidate.none, classify(.{ .class = 0x08, .subclass = 0x06, .protocol = 0x50, .number = 0 }));
    try std.testing.expect(isRogAlly(0x0B05, 0x1ABE));
    try std.testing.expect(isRogAlly(0x0B05, 0x1B4C));
    try std.testing.expect(!isRogAlly(0x0B05, 0x1A38));
    try std.testing.expect(productName(0x045E, 0x0B12) != null);
}

test "XInput 20-byte reports: buttons, D-pad and sticks (y flipped to screen)" {
    const report = xinputReport(0x01 | 0x10, 0x10 | 0x02, 12000, 30000);
    const state = parseXInput(&report).?;
    try std.testing.expect(state.buttons.up and state.buttons.start and state.buttons.a and state.buttons.rb);
    try std.testing.expect(!state.buttons.b and !state.buttons.down and !state.buttons.lb);
    try std.testing.expectEqual(@as(i32, 12000), state.x);
    try std.testing.expectEqual(@as(i32, -30000), state.y);
    const extremes = parseXInput(&xinputReport(0x20 | 0x08, 0x20 | 0x01 | 0x04, -32768, -32768)).?;
    try std.testing.expect(extremes.buttons.back and extremes.buttons.right and extremes.buttons.b and extremes.buttons.lb and extremes.buttons.guide);
    try std.testing.expectEqual(@as(i32, -32767), extremes.x);
    try std.testing.expectEqual(@as(i32, 32767), extremes.y);
    // LED status (type 0x01) and rumble acks are not input.
    try std.testing.expect(parseXInput(&[_]u8{ 0x01, 0x03, 0x06 }) == null);
    var short = xinputReport(0, 0, 0, 0);
    short[0] = 0x03;
    try std.testing.expect(parseXInput(&short) == null);
}

test "Xbox 360 wireless receiver: presence and input packets" {
    try std.testing.expectEqual(WirelessReport{ .connection = true }, parseXInputWireless(&[_]u8{ 0x08, 0x80 }).?);
    try std.testing.expectEqual(WirelessReport{ .connection = false }, parseXInputWireless(&[_]u8{ 0x08, 0x00 }).?);
    var report = [_]u8{0} ** 29;
    report[1] = 0x01;
    report[3] = 0xF0;
    report[5] = 0x13;
    report[6] = 0x02; // D-pad down
    report[7] = 0x20; // B
    std.mem.writeInt(i16, report[10..12], -20000, .little);
    const parsed = parseXInputWireless(&report).?;
    try std.testing.expect(parsed == .input);
    try std.testing.expect(parsed.input.buttons.down and parsed.input.buttons.b);
    try std.testing.expectEqual(@as(i32, -20000), parsed.input.x);
    report[1] = 0x00;
    try std.testing.expect(parseXInputWireless(&report).? == .other);
}

test "GIP input, guide and announce packets; ACK and start-up packets" {
    var packet = [_]u8{0} ** 18;
    packet[0] = gip.cmd_input;
    packet[1] = 0x00;
    packet[2] = 0x05;
    packet[3] = 0x0E;
    packet[4] = 0x10 | 0x04; // A, Menu (Start)
    packet[5] = 0x02 | 0x20; // D-pad down, RB
    std.mem.writeInt(i16, packet[10..12], -32768, .little);
    std.mem.writeInt(i16, packet[12..14], 20000, .little);
    const state = parseGip(&packet).?.input;
    try std.testing.expect(state.buttons.a and state.buttons.start and state.buttons.down and state.buttons.rb);
    try std.testing.expect(!state.buttons.b and !state.buttons.back and !state.buttons.lb);
    try std.testing.expectEqual(@as(i32, -32767), state.x);
    try std.testing.expectEqual(@as(i32, -20000), state.y);
    packet[4] = 0x08 | 0x20; // View (Back), B
    packet[5] = 0x04 | 0x10; // left, LB
    const other = parseGip(&packet).?.input;
    try std.testing.expect(other.buttons.back and other.buttons.b and other.buttons.left and other.buttons.lb);
    try std.testing.expect(parseGip(packet[0..10]) == null);

    const guide = [_]u8{ gip.cmd_virtual_key, 0x30, 0x07, 0x02, 0x01, 0x5B };
    try std.testing.expectEqual(GipPacket{ .guide = true }, parseGip(&guide).?);
    try std.testing.expect(gipNeedsAck(&guide));
    try std.testing.expect(!gipNeedsAck(&packet));
    const ack = gipAck(0x07);
    try std.testing.expectEqual(@as(u8, 0x01), ack[0]);
    try std.testing.expectEqual(@as(u8, 0x07), ack[2]);
    try std.testing.expectEqual(@as(u8, 0x07), ack[5]);
    try std.testing.expect(parseGip(&[_]u8{ 0x02, 0x20, 0x01, 0x1C }).? == .announce);

    var buffer: [6][]const u8 = undefined;
    const series = gipInitPackets(0x045E, 0x0B12, &buffer);
    try std.testing.expectEqual(@as(usize, 1), series.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x05, 0x20, 0x00, 0x01, 0x00 }, series[0]);
    try std.testing.expectEqual(@as(usize, 2), gipInitPackets(0x045E, 0x02EA, &buffer).len);
    try std.testing.expectEqual(@as(usize, 3), gipInitPackets(0x0E6F, 0x02A4, &buffer).len);
    const hori = gipInitPackets(0x0F0D, 0x0067, &buffer);
    try std.testing.expectEqual(@as(u8, gip.cmd_ack), hori[0][0]);
    try std.testing.expectEqual(@as(u8, gip.cmd_power), hori[1][0]);
    var sequence: u8 = 254;
    try std.testing.expectEqual(@as(u8, 255), nextGipSequence(&sequence));
    try std.testing.expectEqual(@as(u8, 1), nextGipSequence(&sequence));
}

// A generic USB gamepad (DragonRise-style): Joystick application, X/Y
// bytes 0..255, 12 buttons, 4 padding bits, 4-bit hat with null state.
const dragonrise_descriptor = [_]u8{
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x04, // Usage (Joystick)
    0xA1, 0x01, // Collection (Application)
    0xA1, 0x02, //   Collection (Logical)
    0x75, 0x08,
    0x95, 0x02,
    0x15, 0x00,
    0x26, 0xFF,
    0x00, 0x35,
    0x00, 0x46,
    0xFF, 0x00,
    0x09, 0x30, 0x09, 0x31, 0x81, 0x02, //   X, Y: Input (Data,Var,Abs)
    0x75, 0x04, 0x95, 0x01, 0x25, 0x07,
    0x46, 0x3B, 0x01, 0x65, 0x14,
    0x09, 0x39, 0x81, 0x42, //   Hat switch: Input (Data,Var,Abs,Null)
    0x65, 0x00, 0x75, 0x01,
    0x95, 0x0C, 0x25, 0x01,
    0x45, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0C, 0x81, 0x02, //   Buttons 1-12
    0x06, 0x00, 0xFF, 0x75, 0x01, 0x95, 0x08, 0x25, 0x01, 0x45, 0x01, 0x09, 0x01, 0x81, 0x02, // vendor bits
    0xC0, //   End Collection
    0xA1, 0x02, 0x75, 0x08, 0x95, 0x04, 0x46, 0xFF, 0x00, 0x26, 0xFF, 0x00, 0x09, 0x02, 0x91, 0x02, 0xC0, // output
    0xC0, // End Collection
};

// DualShock 4 style: Gamepad application, report ID 1, X/Y/Z/Rz bytes,
// 4-bit hat, 14 buttons, 6-bit counter.
const ds4_descriptor = [_]u8{
    0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
    0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95,
    0x04, 0x81, 0x02, 0x09, 0x39, 0x15, 0x00, 0x25,
    0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x65, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0E, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x0E, 0x81, 0x02,
    0x06, 0x00, 0xFF, 0x09, 0x20, 0x75, 0x06, 0x95,
    0x01, 0x15, 0x00, 0x25, 0x7F, 0x81, 0x02, 0xC0,
};

// A keyboard + mouse composite (not a pad).
const keyboard_descriptor = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xC0,
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x81, 0x02, 0xC0, 0xC0,
};

test "HID descriptor: generic joystick with hat, X/Y and 12 buttons" {
    const layout = parseHidDescriptor(&dragonrise_descriptor);
    try std.testing.expect(layout.isGamepad());
    try std.testing.expectEqual(@as(u16, 0x04), layout.application);
    try std.testing.expect(!layout.uses_report_ids);
    try std.testing.expectEqual(@as(usize, 12), layout.buttonCount());
    try std.testing.expectEqual(@as(u16, 0), layout.x.?.bit);
    try std.testing.expectEqual(@as(u16, 8), layout.y.?.bit);
    try std.testing.expectEqual(@as(i32, 255), layout.x.?.maximum);
    try std.testing.expectEqual(@as(u16, 16), layout.hat.?.bit);
    try std.testing.expectEqual(@as(u16, 20), layout.buttons[0].?.bit);
    try std.testing.expectEqual(ButtonOrder.joystick, hidButtonOrder(0x0079, 0x0006, &layout));

    // Centred, hat null (8), button 1 (A) and 10 (Start) down.
    const report = [_]u8{ 0x7F, 0x7F, 0x08 | (0x01 << 4), 0x20, 0x00, 0x00 };
    const state = parseHidReport(&layout, .joystick, &report).?;
    try std.testing.expect(state.buttons.a and state.buttons.start);
    try std.testing.expect(!state.buttons.up and !state.buttons.down and !state.buttons.b);
    try std.testing.expect(@abs(state.x) < 400 and @abs(state.y) < 400);
    // Hat 2 = right; X fully left (digital pads use X/Y as the D-pad).
    const right = parseHidReport(&layout, .joystick, &[_]u8{ 0x00, 0x7F, 0x02, 0x00, 0x00, 0x00 }).?;
    try std.testing.expect(right.buttons.right and !right.buttons.up);
    try std.testing.expectEqual(-stick_range, right.x);
    // Hat 7 = up-left.
    const diagonal = parseHidReport(&layout, .joystick, &[_]u8{ 0x7F, 0x7F, 0x07, 0x00, 0x00, 0x00 }).?;
    try std.testing.expect(diagonal.buttons.up and diagonal.buttons.left);
}

test "HID descriptor: DualShock-style gamepad with a report ID and square-first buttons" {
    const layout = parseHidDescriptor(&ds4_descriptor);
    try std.testing.expect(layout.isGamepad());
    try std.testing.expect(layout.uses_report_ids);
    try std.testing.expectEqual(@as(u16, 0x05), layout.application);
    try std.testing.expectEqual(@as(u16, 32), layout.hat.?.bit);
    try std.testing.expectEqual(@as(u16, 36), layout.buttons[0].?.bit);
    const order = hidButtonOrder(0x054C, 0x09CC, &layout);
    try std.testing.expectEqual(ButtonOrder.square_first, order);
    // Report 1: sticks centred, hat 4 (down), Cross (button 2) and Options (10).
    const bits: u16 = (1 << 1) | (1 << 9);
    const report = [_]u8{ 0x01, 0x80, 0x80, 0x80, 0x80, 0x04 | @as(u8, @truncate(bits << 4)), @truncate(bits >> 4), @truncate(bits >> 12), 0x00 };
    const state = parseHidReport(&layout, order, &report).?;
    try std.testing.expect(state.buttons.a and state.buttons.start and state.buttons.down);
    try std.testing.expect(!state.buttons.x and !state.buttons.b);
    // Another report ID carries none of the pad's fields.
    try std.testing.expect(parseHidReport(&layout, order, &[_]u8{ 0x05, 0x00, 0x00 }) == null);
    // Gamepad usage without a vendor override: Linux BTN_GAMEPAD order.
    try std.testing.expectEqual(ButtonOrder.gamepad, hidButtonOrder(0x2DC8, 0x3106, &layout));
}

test "HID descriptor: keyboards and mice are not gamepads; truncated input is safe" {
    const layout = parseHidDescriptor(&keyboard_descriptor);
    try std.testing.expect(!layout.isGamepad());
    try std.testing.expectEqual(@as(u32, 0x00010006), layout.first_application);
    for (0..dragonrise_descriptor.len) |cut| _ = parseHidDescriptor(dragonrise_descriptor[0..cut]);
    try std.testing.expect(!parseHidDescriptor(&[_]u8{ 0xFE, 0xFF }).isGamepad());
    const pad = parseHidDescriptor(&dragonrise_descriptor);
    try std.testing.expect(parseHidReport(&pad, .joystick, &[_]u8{0x7F}) != null);
}

test "HID report descriptor length comes from the class descriptor" {
    const configuration = [_]u8{
        0x09, 0x02, 0x29, 0x00, 0x02, 0x01, 0x00, 0x80, 0xFA,
        0x09, 0x04, 0x00, 0x00, 0x02, 0x03, 0x01, 0x01, 0x00, // interface 0: boot keyboard
        0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 0x3F, 0x00,
        0x07, 0x05, 0x81, 0x03, 0x08, 0x00, 0x0A,
        0x09, 0x04, 0x01, 0x00, 0x01, 0x03, 0x00, 0x00, 0x00, // interface 1: pad
        0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 0x89, 0x01,
    };
    try std.testing.expectEqual(@as(?u16, 0x3F), hidReportDescriptorLength(&configuration, 0));
    try std.testing.expectEqual(@as(?u16, 0x189), hidReportDescriptorLength(&configuration, 1));
    try std.testing.expectEqual(@as(?u16, null), hidReportDescriptorLength(&configuration, 2));
    try std.testing.expectEqual(@as(?u16, null), hidReportDescriptorLength(configuration[0..20], 1));
}

test "mapping: A/Start accept, B/Back go back, LB/RB page, D-pad and stick repeat" {
    var mapper = Mapper{};
    var queue = Queue{};
    mapper.feed(.{ .buttons = .{ .a = true } }, 0, &queue);
    try std.testing.expectEqual(Output{ .action = .accept, .button = .a }, queue.pop().?);
    // Held A does not repeat; release then Start.
    mapper.feed(.{ .buttons = .{ .a = true } }, 10, &queue);
    mapper.feed(.{}, 20, &queue);
    mapper.feed(.{ .buttons = .{ .start = true } }, 30, &queue);
    try std.testing.expectEqual(Output{ .action = .accept, .button = .start }, queue.pop().?);
    try std.testing.expect(queue.pop() == null);
    mapper.feed(.{ .buttons = .{ .b = true, .lb = true } }, 40, &queue);
    try std.testing.expectEqual(Action.back, queue.pop().?.action);
    try std.testing.expectEqual(Action.page_up, queue.pop().?.action);
    mapper.feed(.{ .buttons = .{ .back = true, .rb = true } }, 50, &queue);
    try std.testing.expectEqual(Output{ .action = .back, .button = .back }, queue.pop().?);
    try std.testing.expectEqual(Action.page_down, queue.pop().?.action);
    mapper.feed(.{}, 60, &queue);

    // D-pad down: fires at press, after 400 ms, then every 90 ms.
    mapper.feed(.{ .buttons = .{ .down = true } }, 1000, &queue);
    try std.testing.expectEqual(Output{ .action = .down, .button = .dpad }, queue.pop().?);
    mapper.tick(1300, &queue);
    try std.testing.expect(queue.pop() == null);
    mapper.tick(1400, &queue);
    try std.testing.expectEqual(Action.down, queue.pop().?.action);
    mapper.tick(1490, &queue);
    try std.testing.expectEqual(Action.down, queue.pop().?.action);
    mapper.feed(.{}, 1500, &queue);
    mapper.tick(2000, &queue);
    try std.testing.expect(queue.pop() == null);

    // Stick: inside the deadzone nothing, beyond it the dominant axis.
    mapper.feed(.{ .x = 8000, .y = 3000 }, 3000, &queue);
    try std.testing.expect(queue.pop() == null);
    mapper.feed(.{ .x = 3000, .y = -30000 }, 3010, &queue);
    try std.testing.expectEqual(Output{ .action = .up, .button = .stick }, queue.pop().?);
    mapper.feed(.{ .x = 30000, .y = 0 }, 3020, &queue);
    try std.testing.expectEqual(Output{ .action = .right, .button = .stick }, queue.pop().?);
    // The D-pad wins over the stick.
    mapper.feed(.{ .buttons = .{ .left = true }, .x = 30000 }, 3030, &queue);
    try std.testing.expectEqual(Output{ .action = .left, .button = .dpad }, queue.pop().?);
}

test "mapping end to end: XInput and GIP reports to menu actions" {
    var mapper = Mapper{};
    var queue = Queue{};
    mapper.feed(parseXInput(&xinputReport(0x02, 0x00, 0, 0)).?, 0, &queue);
    try std.testing.expectEqual(Action.down, queue.pop().?.action);
    mapper.feed(parseXInput(&xinputReport(0x00, 0x10, 0, 0)).?, 10, &queue);
    try std.testing.expectEqual(Action.accept, queue.pop().?.action);
    var packet = [_]u8{0} ** 18;
    packet[0] = gip.cmd_input;
    packet[4] = 0x20; // B
    mapper.feed(parseGip(&packet).?.input, 20, &queue);
    try std.testing.expectEqual(Action.back, queue.pop().?.action);
    std.mem.writeInt(i16, packet[12..14], 32767, .little); // stick up
    packet[4] = 0;
    mapper.feed(parseGip(&packet).?.input, 30, &queue);
    try std.testing.expectEqual(Action.up, queue.pop().?.action);
}

test "queue keeps the newest entries and dedupe drops a second source's copy" {
    var queue = Queue{};
    for (0..20) |index| queue.push(.{ .action = if (index % 2 == 0) .up else .down, .button = .dpad });
    var count: usize = 0;
    while (queue.pop()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 16), count);

    var dedupe = Dedupe{};
    try std.testing.expect(dedupe.accept(1, 3, 1000)); // pad down
    try std.testing.expect(!dedupe.accept(0, 3, 1010)); // keyboard down (firmware copy)
    try std.testing.expect(dedupe.accept(1, 3, 1100)); // pad repeat
    try std.testing.expect(dedupe.accept(0, 4, 1120)); // a different key
    try std.testing.expect(dedupe.accept(0, 4, 1130)); // same source repeats freely
    try std.testing.expect(dedupe.accept(1, 4, 1400)); // outside the window
}
