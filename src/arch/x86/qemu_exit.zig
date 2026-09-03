const io = @import("io_port.zig");

const port: u16 = 0xf4;

pub const Result = enum(u8) {
    pass = 0x10,
    fail = 0x11,
};

pub fn exit(result: Result) noreturn {
    io.write8(port, @intFromEnum(result));
    while (true) {
        asm volatile ("hlt");
    }
}
