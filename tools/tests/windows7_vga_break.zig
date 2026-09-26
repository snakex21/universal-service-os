// QEMU-only test helper (never shipped): emulate the X470 "CSM off" state by
// clearing VGA Enable on the root port at 00:03.0 and I/O decode on the GPU
// behind it, then chainload \EFI\BOOT\usos-dispatch.efi (the Win7 dispatcher).
// Used by tools/tests/windows7_int10_ab.py (variants *broken).
const std = @import("std");
const uefi = std.os.uefi;

fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "{dx}" (port),
    );
}
fn in32(port: u16) u32 {
    return asm volatile ("inl %[p], %[v]"
        : [v] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}
fn addr(bus: u32, dev: u32, reg: u32) u32 {
    return 0x80000000 | (bus << 16) | (dev << 11) | (reg & 0xfc);
}
fn read(bus: u32, dev: u32, reg: u32) u32 {
    out32(0xcf8, addr(bus, dev, reg));
    return in32(0xcfc);
}
fn write(bus: u32, dev: u32, reg: u32, value: u32) void {
    out32(0xcf8, addr(bus, dev, reg));
    out32(0xcfc, value);
}
fn say(comptime fmt: []const u8, args: anytype) void {
    const con = uefi.system_table.con_out orelse return;
    var text: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&text, fmt ++ "\r\n", args) catch return;
    var wide: [256:0]u16 = undefined;
    for (s, 0..) |c, i| wide[i] = c;
    wide[s.len] = 0;
    _ = con.outputString(&wide) catch {};
}
// With \EFI\BOOT\vga-break-noattr present, the GPU's PciIo.Attributes also
// refuses Enable/Set (EFI_UNSUPPORTED), so the dispatcher must use its raw
// bridge-control/command fallback.
const vga = @import("windows7_vga_routing");
const PciIo = vga.PciIo;
const AttributesFn = @FieldType(PciIo, "attributes");
var original_attributes: ?AttributesFn = null;
fn refusingAttributes(self: *PciIo, op: vga.Operation, value: u64, result: ?*u64) callconv(uefi.cc) uefi.Status {
    if (op == .set or op == .enable) return .unsupported;
    return original_attributes.?(self, op, value, result);
}
fn flagPresent(bs: *uefi.tables.BootServices, device: uefi.Handle, name: [*:0]const u16) bool {
    const fs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return false) orelse return false;
    const root = fs.openVolume() catch return false;
    defer root.close() catch {};
    const file = root.open(name, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}
fn refuseAttributes(bs: *uefi.tables.BootServices) !void {
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.GraphicsOutput.guid })) orelse return error.NoGop;
    for (handles) |h| {
        const dp = (bs.handleProtocol(uefi.protocol.DevicePath, h) catch null) orelse continue;
        const found = (bs.locateDevicePath(dp, PciIo) catch null) orelse continue;
        const io = (bs.handleProtocol(PciIo, found[1]) catch null) orelse continue;
        original_attributes = io.attributes;
        io.attributes = &refusingAttributes;
        say("VGA-BREAK: GPU PciIo.Attributes(Enable/Set) now returns EFI_UNSUPPORTED", .{});
        return;
    }
    return error.NoGpu;
}
fn run() !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const root_port: u32 = 3;
    const bus_regs = read(0, root_port, 0x18);
    const secondary = (bus_regs >> 8) & 0xff;
    const bc = read(0, root_port, 0x3c);
    write(0, root_port, 0x3c, bc & ~@as(u32, 0x08 << 16));
    const cmd = read(secondary, 0, 0x04);
    write(secondary, 0, 0x04, cmd & ~@as(u32, 1));
    say("VGA-BREAK: bridge 00:03.0 ctl {x:0>4}->{x:0>4}; gpu {x:0>2}:00.0 cmd {x:0>4}->{x:0>4}", .{ bc >> 16, read(0, root_port, 0x3c) >> 16, secondary, cmd & 0xffff, read(secondary, 0, 0x04) & 0xffff });
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    if (flagPresent(bs, device, std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\BOOT\\vga-break-noattr"))) try refuseAttributes(bs);
    // With \EFI\BOOT\vga-break-conflict present, an empty second root port at
    // 00:04.0 claims VGA, so the dispatcher must refuse to route and warn.
    if (flagPresent(bs, device, std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\BOOT\\vga-break-conflict"))) {
        const other = read(0, 4, 0x3c);
        write(0, 4, 0x3c, other | (0x08 << 16));
        say("VGA-BREAK: bridge 00:04.0 ctl {x:0>4}->{x:0>4} (foreign VGA owner)", .{ other >> 16, read(0, 4, 0x3c) >> 16 });
    }
    // With \EFI\BOOT\vga-break-fakeint10 present, point IVT 0x10 at a non-empty
    // byte in E0000-EFFFF so the dispatcher takes its CSM path (log check only;
    // Windows cannot run on this fake vector).
    if (flagPresent(bs, device, std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\BOOT\\vga-break-fakeint10"))) {
        // q35 PAM1 (00:00.0 reg 0x91) = C0000-C7FFF read/write DRAM, then an IRET stub.
        const pam = read(0, 0, 0x90);
        write(0, 0, 0x90, pam | (0x33 << 8));
        @as(*volatile u8, @ptrFromInt(0xc0000)).* = 0xcf;
        @as(*volatile u32, @ptrFromInt(0x40)).* = 0xc000 << 16;
        say("VGA-BREAK: fake Int10 vector C000:0000 (IRET stub, byte={x:0>2})", .{@as(*volatile u8, @ptrFromInt(0xc0000)).*});
    }
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var arena: [1024]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&arena);
    const path = try dp.createFileDevicePath(alloc.allocator(), std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\BOOT\\usos-dispatch.efi"));
    const image = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    return (try bs.startImage(image)).code;
}
pub fn main() uefi.Status {
    return run() catch .load_error;
}
