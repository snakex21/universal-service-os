// Some firmware boot paths leave graphics controllers unconnected.
// Use the UEFI ConnectController mechanism before starting the video shim.
const std = @import("std");
const uefi = std.os.uefi;
const UgaDraw = opaque {
    pub const guid = uefi.Guid{ .time_low = 0x982c298b, .time_mid = 0xf4fa, .time_high_and_version = 0x41cb, .clock_seq_high_and_reserved = 0xb8, .clock_seq_low = 0x38, .node = .{ 0x77, 0xaa, 0x68, 0x8f, 0xb8, 0x39 } };
};
pub const Result = enum { present, connected, uga_present, unavailable };
pub fn ensure() !Result {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    if (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null) != null) return .present;
    if (try bs.locateProtocol(UgaDraw, null) != null) return .uga_present;
    // One bounded pass over the existing handle database, as specified by UEFI
    // 7.3.12. Never disconnect existing devices or synthesize framebuffer data.
    const handles = (try bs.locateHandleBuffer(.all_handles)) orelse return .unavailable;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    for (handles) |handle| {
        bs.connectController(handle, null, null, true) catch {};
        if (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null) != null) return .connected;
        if (try bs.locateProtocol(UgaDraw, null) != null) return .uga_present;
    }
    return .unavailable;
}
