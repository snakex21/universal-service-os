// Regression test: remove QEMU's actual graphics driver and recover its GOP.
const std = @import("std");
const uefi = std.os.uefi;
const graphics = @import("windows7_uefi_graphics.zig");
const pci_io = uefi.Guid{ .time_low = 0x4cf5b200, .time_mid = 0x68b8, .time_high_and_version = 0x4ca5, .clock_seq_high_and_reserved = 0x9e, .clock_seq_low = 0xec, .node = .{ 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a } };
fn run() !void {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    if (try graphics.ensure() != .present) return error.InitialGopMissing;
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &pci_io })) orelse return error.NoPci;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    var removed = false;
    for (handles) |handle| {
        bs.disconnectController(handle, null, null) catch continue;
        if (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null) == null) {
            removed = true;
            break;
        }
        bs.connectController(handle, null, null, true) catch {};
    }
    if (!removed) return error.CouldNotDisconnectGop;
    if (try graphics.ensure() != .connected) return error.GopNotRecovered;
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse return error.NoRecoveredGop;
    const info = try gop.queryMode(gop.mode.mode);
    if (info.horizontal_resolution == 0 or info.vertical_resolution == 0) return error.InvalidRecoveredMode;
    if (try graphics.ensure() != .present) return error.ExistingGopNotPreserved;
}
pub fn main() noreturn {
    var result: u32 = 0x10;
    run() catch {
        result = 0x11;
    };
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (result),
          [port] "{dx}" (@as(u16, 0xf4)),
    );
    while (true) asm volatile ("hlt");
}
