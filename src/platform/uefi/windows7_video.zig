// Shared Int10 validation for the native ISO path and the installed EFI loader.
const builtin = @import("builtin");

pub fn handlerValid() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    const vector = @as(*volatile u32, @ptrFromInt(0x40)).*;
    const handler = ((vector >> 16) << 4) + (vector & 0xffff);
    if (handler < 0xc0000 or handler >= 0xf0000) return false;
    const opcode = @as(*volatile u8, @ptrFromInt(handler)).*;
    return opcode != 0 and opcode != 0xff;
}

fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]" : : [v] "{eax}" (value), [p] "{dx}" (port));
}
fn in32(port: u16) u32 {
    return asm volatile ("inl %[p], %[v]" : [v] "={eax}" (-> u32) : [p] "{dx}" (port));
}
fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]" : : [v] "{al}" (value), [p] "{dx}" (port));
}
fn in8(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]" : [v] "={al}" (-> u8) : [p] "{dx}" (port));
}

pub fn prepareEmulatedVga() void {
    if (builtin.cpu.arch != .x86_64) return;
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [aout] "={eax}" (a), [b] "={ebx}" (b), [c] "={ecx}" (c), [d] "={edx}" (d),
        : [a] "{eax}" (@as(u32, 0x40000000)),
    );
    if (b != 0x54474354 or c != 0x43544743 or d != 0x47435447) return;
    out32(0xcf8, 0x80000000);
    const offset: u8 = switch (in32(0xcfc)) {
        0x12378086 => 0x5a,
        0x29c08086 => 0x91,
        else => return,
    };
    for (0..2) |i| {
        const reg = @as(u32, offset) + @as(u32, @intCast(i));
        out32(0xcf8, 0x80000000 | (reg & ~@as(u32, 3)));
        const port = @as(u16, 0xcfc) + @as(u16, @intCast(reg & 3));
        out8(port, in8(port) | 0x33);
    }
}
