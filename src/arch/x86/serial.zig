const io = @import("io_port.zig");

const base: u16 = 0x3f8;

pub fn init() void {
    io.write8(base + 1, 0x00);
    io.write8(base + 3, 0x80);
    io.write8(base + 0, 0x01);
    io.write8(base + 1, 0x00);
    io.write8(base + 3, 0x03);
    io.write8(base + 2, 0xc7);
    io.write8(base + 4, 0x0b);
}

pub fn writeAscii(text: []const u8) void {
    for (text) |byte| {
        if (byte == '\n') writeByte('\r');
        writeByte(byte);
    }
}

fn writeByte(byte: u8) void {
    var spins: usize = 0;
    while ((io.read8(base + 5) & 0x20) == 0) : (spins += 1) {
        if (spins == 100_000) return;
    }
    io.write8(base, byte);
}
