// QEMU regression fixture: a returned EFI app has changed the GOP geometry.
const std = @import("std");
const uefi = std.os.uefi;
const Gop = uefi.protocol.GraphicsOutput;
const view = @import("manual_view.zig");
const framebuffer = @import("framebuffer.zig");
const serial = @import("serial.zig");
var original_blt: @FieldType(Gop, "_blt") = undefined;
var invalid_geometry = false;
var full_frames: usize = 0;
fn checkedBlt(gop: *Gop, pixels: ?[*]Gop.BltPixel, op: Gop.BltOperation, sx: usize, sy: usize, dx: usize, dy: usize, width: usize, height: usize, delta: usize) callconv(uefi.cc) uefi.Status {
    if (op == .blt_buffer_to_video) {
        if (dx + width > gop.mode.info.horizontal_resolution or dy + height > gop.mode.info.vertical_resolution) invalid_geometry = true;
        if (width == gop.mode.info.horizontal_resolution and height == gop.mode.info.vertical_resolution) full_frames += 1;
    }
    return original_blt(gop, pixels, op, sx, sy, dx, dy, width, height, delta);
}
fn run() !void {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const gop = (try bs.locateProtocol(Gop, null)) orelse return error.NoGop;
    var large: ?u32 = null;
    var small: ?u32 = null;
    for (0..gop.mode.max_mode) |i| {
        const info = try gop.queryMode(@intCast(i));
        defer bs.freePool(@ptrCast(@alignCast(info))) catch {};
        if (info.horizontal_resolution == 1280 and info.vertical_resolution == 1024) large = @intCast(i);
        if (info.horizontal_resolution == 1024 and info.vertical_resolution == 768) small = @intCast(i);
    }
    try gop.setMode(large orelse return error.LargeModeMissing);
    const root = @import("filesystem.zig").openBootVolume() orelse return error.NoRoot;
    defer root.close() catch {};
    view.init(root, .{ .architecture = .x86_64, .firmware = .uefi, .framebuffer = try framebuffer.locate(), .memory = .{ .descriptor_count = 0, .conventional_bytes = 0 } });
    view.windowsIsoStatus(.validating, "Before firmware graphics mode change");
    try gop.setMode(small orelse return error.SmallModeMissing);
    original_blt = gop._blt;
    gop._blt = checkedBlt;
    defer gop._blt = original_blt;
    view.refreshFramebuffer();
    view.windowsIsoStatus(.validating, "Recovered after graphics mode change");
    if (invalid_geometry or full_frames == 0) return error.StaleGraphicsGeometry;
    serial.writeAscii("GRAPHICS_REFRESH_PASS: 1280x1024 -> 1024x768; renderer uses new geometry\r\n");
}
pub fn main() noreturn {
    serial.init();
    var result: u32 = 0x10;
    run() catch |err| {
        serial.writeAscii(@errorName(err));
        result = 0x11;
    };
    asm volatile ("outl %[value], %[port]" : : [value] "{eax}" (result), [port] "{dx}" (@as(u16, 0xf4)));
    while (true) asm volatile ("hlt");
}
