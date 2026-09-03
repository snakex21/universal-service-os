pub const Registers = struct {
    ax: u16 = 0,
    bx: u16 = 0,
    cx: u16 = 0,
    dx: u16 = 0,
    si: u16 = 0,
    di: u16 = 0,
    bp: u16 = 0,
    sp: u16 = 0,
    ip: u16 = 0,
    flags: u16 = 0x0200,
    cs: u16 = 0,
    ds: u16 = 0,
    es: u16 = 0,
    ss: u16 = 0,

    pub fn ah(self: Registers) u8 {
        return @truncate(self.ax >> 8);
    }

    pub fn al(self: Registers) u8 {
        return @truncate(self.ax);
    }

    pub fn setAh(self: *Registers, value: u8) void {
        self.ax = (self.ax & 0x00FF) | (@as(u16, value) << 8);
    }

    pub fn setAl(self: *Registers, value: u8) void {
        self.ax = (self.ax & 0xFF00) | value;
    }

    pub fn setCarry(self: *Registers, enabled: bool) void {
        if (enabled) self.flags |= 0x0001 else self.flags &= ~@as(u16, 0x0001);
    }
};

test "register byte access preserves the opposite half" {
    const std = @import("std");
    var registers = Registers{ .ax = 0x1234 };
    registers.setAh(0xAB);
    try std.testing.expectEqual(@as(u16, 0xAB34), registers.ax);
    registers.setAl(0xCD);
    try std.testing.expectEqual(@as(u16, 0xABCD), registers.ax);
}
