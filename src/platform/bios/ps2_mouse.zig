const std = @import("std");

/// wheel: IntelliMouse Z, negative = turned away from the user (up).
pub const Event = struct { dx: i16, dy: i16, left: bool, right: bool, wheel: i8 = 0 };
pub const Decoder = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    buttons: u8 = 0,
    /// 3 = standard PS/2, 4 = IntelliMouse (wheel in the fourth byte).
    size: u8 = 3,
    marker: u8 = 1,

    pub fn feed(self: *Decoder, byte: u8) ?Event {
        if (self.len == 0 and (byte & 8 == 0 or byte == 0xfa or byte == 0xfe)) return null;
        self.bytes[self.len] = byte;
        self.len += 1;
        if (self.len < self.size) return null;
        self.len = 0;
        const flags = self.bytes[0];
        const buttons = flags & 3;
        const pressed = buttons & ~self.buttons;
        self.buttons = buttons;
        // PS/2 movement is nine-bit signed; overflow must not wrap the cursor.
        const dx: i16 = if (flags & 0x40 != 0) 0 else @as(i16, self.bytes[1]) - (if (flags & 0x10 != 0) @as(i16, 256) else 0);
        const dy: i16 = if (flags & 0x80 != 0) 0 else @as(i16, self.bytes[2]) - (if (flags & 0x20 != 0) @as(i16, 256) else 0);
        return .{ .dx = dx, .dy = -dy, .left = pressed & 1 != 0, .right = pressed & 2 != 0, .wheel = if (self.size == 4) decodeWheel(self.bytes[3]) else 0 };
    }
};

fn read(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
fn write(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}
fn ready() bool {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const status = read(0x64);
        if (status == 0xff) return false;
        if (status & 2 == 0) return true;
        write(0x80, 0);
    }
    return false;
}
fn command(value: u8) bool {
    if (!ready()) return false;
    write(0x64, 0xd4);
    if (!ready()) return false;
    write(0x60, value);
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const status = read(0x64);
        // Leave keyboard bytes for the keyboard decoder.
        if (status & 0x21 == 0x21) return read(0x60) == 0xfa;
        write(0x80, 0);
    }
    return false;
}
fn decodeWheel(value: u8) i8 {
    const nibble: u8 = value & 0x0F;
    return if ((nibble & 0x08) != 0) @as(i8, @intCast(nibble)) - 16 else @intCast(nibble);
}

/// Reads one byte from the auxiliary (mouse) port, leaving keyboard bytes.
fn readAux() ?u8 {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const status = read(0x64);
        if (status & 0x21 == 0x21) return read(0x60);
        write(0x80, 0);
    }
    return null;
}

/// The IntelliMouse "knock": sample rates 200, 100, 80, then Get ID. A
/// wheel mouse answers ID 3 (4: five-button) and from then on sends
/// four-byte packets. Firmware USB-legacy emulation of the 8042 often
/// answers 0 (no wheel); the standard three-byte protocol stays in use.
fn enableWheel() bool {
    for ([_]u8{ 200, 100, 80 }) |rate| {
        if (!command(0xf3) or !command(rate)) return false;
    }
    if (!command(0xf2)) return false;
    const id = readAux() orelse return false;
    return id == 3 or id == 4;
}

pub const Init = struct { enabled: bool, wheel: bool };

pub fn init() Init {
    if (!ready()) return .{ .enabled = false, .wheel = false };
    write(0x64, 0xa8);
    // Defaults select the standard three-byte protocol and stop reporting.
    if (!command(0xf6)) return .{ .enabled = false, .wheel = false };
    const wheel = enableWheel();
    // A failed knock can leave a non-default sample rate; 100/s is normal.
    if (!wheel) {
        _ = command(0xf6);
    }
    return .{ .enabled = command(0xf4), .wheel = wheel };
}

test "IntelliMouse four-byte packets carry the wheel" {
    var decoder = Decoder{ .size = 4 };
    try std.testing.expect(decoder.feed(0x08) == null);
    try std.testing.expect(decoder.feed(0) == null);
    try std.testing.expect(decoder.feed(0) == null);
    const up = decoder.feed(0x0F).?;
    try std.testing.expectEqual(@as(i8, -1), up.wheel);
    _ = decoder.feed(0x08);
    _ = decoder.feed(0);
    _ = decoder.feed(0);
    try std.testing.expectEqual(@as(i8, 1), decoder.feed(0x01).?.wheel);
    var standard = Decoder{};
    _ = standard.feed(0x08);
    _ = standard.feed(0);
    try std.testing.expectEqual(@as(i8, 0), standard.feed(0).?.wheel);
}

test "mouse framing signed movement overflow and button edges" {
    var decoder = Decoder{};
    try std.testing.expect(decoder.feed(0xfa) == null);
    try std.testing.expect(decoder.feed(0) == null);
    _ = decoder.feed(0x39);
    _ = decoder.feed(0xff);
    const e = decoder.feed(0xfe).?;
    try std.testing.expectEqual(@as(i16, -1), e.dx);
    try std.testing.expectEqual(@as(i16, 2), e.dy);
    try std.testing.expect(e.left);
    _ = decoder.feed(0xc9);
    _ = decoder.feed(120);
    const held = decoder.feed(120).?;
    try std.testing.expect(!held.left);
    try std.testing.expectEqual(@as(i16, 0), held.dx);
    try std.testing.expectEqual(@as(i16, 0), held.dy);
}
