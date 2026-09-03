const io = @import("io_port.zig");

const data_port: u16 = 0x60;
const status_port: u16 = 0x64;
const command_port: u16 = 0x64;

pub const Event = struct {
    dx: i16 = 0,
    dy: i16 = 0,
    wheel: i8 = 0,
    left: bool = false,
    right: bool = false,
};

var enabled: bool = false;
var has_wheel: bool = false;
var packet: [4]u8 = undefined;
var packet_len: usize = 0;

pub fn init() bool {
    enabled = false;
    has_wheel = false;
    packet_len = 0;

    if (!writeControllerCommand(0xA8)) return false;

    if (writeControllerCommand(0x20)) {
        if (readControllerByte()) |config| {
            if (writeControllerCommand(0x60)) {
                _ = writeControllerData(config & ~@as(u8, 0x20));
            }
        }
    }

    if (!sendMouseCommand(0xF6)) return false;
    has_wheel = enableIntelliMouseWheel();
    if (!sendMouseCommand(0xF4)) return false;

    enabled = true;
    return true;
}

pub fn available() bool {
    return enabled;
}

pub fn wheelAvailable() bool {
    return enabled and has_wheel;
}

pub fn poll() ?Event {
    if (!enabled) return null;

    const expected_len: usize = if (has_wheel) 4 else 3;
    var reads: usize = 0;
    while (reads < 12) : (reads += 1) {
        const status = io.read8(status_port);
        if ((status & 0x01) == 0) break;
        if ((status & 0x20) == 0) break;

        const value = io.read8(data_port);
        if (packet_len == 0 and (value & 0x08) == 0) continue;

        packet[packet_len] = value;
        packet_len += 1;
        if (packet_len < expected_len) continue;

        packet_len = 0;
        if ((packet[0] & 0xC0) != 0) return null;

        const dx8: i8 = @bitCast(packet[1]);
        const dy8: i8 = @bitCast(packet[2]);
        return .{
            .dx = dx8,
            .dy = -@as(i16, dy8),
            .wheel = if (has_wheel) decodeWheel(packet[3]) else 0,
            .left = (packet[0] & 0x01) != 0,
            .right = (packet[0] & 0x02) != 0,
        };
    }

    return null;
}

fn enableIntelliMouseWheel() bool {
    if (!setSampleRate(200)) return false;
    if (!setSampleRate(100)) return false;
    if (!setSampleRate(80)) return false;

    if (!writeMouseByte(0xF2)) return false;
    const ack = readControllerByte() orelse return false;
    if (ack != 0xFA) return false;

    const device_id = readControllerByte() orelse return false;
    return device_id == 0x03 or device_id == 0x04;
}

fn setSampleRate(rate: u8) bool {
    return sendMouseCommand(0xF3) and sendMouseCommand(rate);
}

fn decodeWheel(value: u8) i8 {
    const nibble: u8 = value & 0x0F;
    return if ((nibble & 0x08) != 0)
        @as(i8, @intCast(nibble)) - 16
    else
        @intCast(nibble);
}

fn sendMouseCommand(value: u8) bool {
    if (!writeMouseByte(value)) return false;
    const reply = readControllerByte() orelse return false;
    return reply == 0xFA;
}

fn writeMouseByte(value: u8) bool {
    if (!writeControllerCommand(0xD4)) return false;
    return writeControllerData(value);
}

fn writeControllerCommand(value: u8) bool {
    if (!waitInputEmpty()) return false;
    io.write8(command_port, value);
    return true;
}

fn writeControllerData(value: u8) bool {
    if (!waitInputEmpty()) return false;
    io.write8(data_port, value);
    return true;
}

fn readControllerByte() ?u8 {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        if ((io.read8(status_port) & 0x01) != 0) return io.read8(data_port);
        spinPause();
    }
    return null;
}

fn waitInputEmpty() bool {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        if ((io.read8(status_port) & 0x02) == 0) return true;
        spinPause();
    }
    return false;
}

inline fn spinPause() void {
    asm volatile ("pause");
}

test "IntelliMouse wheel nibble decodes signed movement" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i8, 1), decodeWheel(0x01));
    try std.testing.expectEqual(@as(i8, -1), decodeWheel(0x0F));
    try std.testing.expectEqual(@as(i8, -8), decodeWheel(0x08));
    try std.testing.expectEqual(@as(i8, 7), decodeWheel(0x07));
}
