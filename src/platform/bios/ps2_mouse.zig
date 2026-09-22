const std = @import("std");

pub const Event = struct { dx: i16, dy: i16, left: bool, right: bool };
pub const Decoder = struct {
    bytes: [3]u8 = .{ 0, 0, 0 },
    len: u8 = 0,
    buttons: u8 = 0,
    marker: u8 = 1,

    pub fn feed(self: *Decoder, byte: u8) ?Event {
        if (self.len == 0 and (byte & 8 == 0 or byte == 0xfa or byte == 0xfe)) return null;
        self.bytes[self.len] = byte;
        self.len += 1;
        if (self.len != 3) return null;
        self.len = 0;
        const flags = self.bytes[0];
        const buttons = flags & 3;
        const pressed = buttons & ~self.buttons;
        self.buttons = buttons;
        // PS/2 movement is nine-bit signed; overflow must not wrap the cursor.
        const dx: i16 = if (flags & 0x40 != 0) 0 else @as(i16, self.bytes[1]) - (if (flags & 0x10 != 0) @as(i16, 256) else 0);
        const dy: i16 = if (flags & 0x80 != 0) 0 else @as(i16, self.bytes[2]) - (if (flags & 0x20 != 0) @as(i16, 256) else 0);
        return .{ .dx = dx, .dy = -dy, .left = pressed & 1 != 0, .right = pressed & 2 != 0 };
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
pub fn init() bool {
    if (!ready()) return false;
    write(0x64, 0xa8);
    // Defaults select the standard three-byte protocol and stop reporting.
    if (!command(0xf6)) return false;
    return command(0xf4);
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
