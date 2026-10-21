//! Prep-time monitor EDID (docs/display-policy.md). Called by the
//! preparation starts right before the micro-Linux kernel is loaded
//! (xp_preparation.zig, vista_preparation.zig). Shared reader: other
//! paths (e.g. the Win7 x64 GOP mode work) can reuse `nativeSize`.
//!
//! EDID Active (what the GOP driver is driving) first, else EDID
//! Discovered. A known size is written to \EFI\USOS\display-native.txt;
//! otherwise that file is deleted so a value from another monitor never
//! survives. Every error is ignored: the preparation must not depend on it
//! (no file = USOSRES picks the highest mode).
const std = @import("std");
const uefi = std.os.uefi;
const edid = @import("usos").flow.display_edid;

fn wide(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

fn block(comptime T: type) ?[]const u8 {
    const bs = uefi.system_table.boot_services orelse return null;
    const protocol = (bs.locateProtocol(T, null) catch return null) orelse return null;
    const bytes = protocol.edid orelse return null;
    if (protocol.size_of_edid < 128) return null;
    return bytes[0..protocol.size_of_edid];
}

/// The monitor's native size from the firmware's EDID protocols, or null.
pub fn nativeSize() ?edid.Size {
    if (block(uefi.protocol.edid.Active)) |bytes| if (edid.native(bytes)) |size| return size;
    if (block(uefi.protocol.edid.Discovered)) |bytes| if (edid.native(bytes)) |size| return size;
    return null;
}

pub fn record(root: *uefi.protocol.File) void {
    const size = nativeSize();
    const serial = @import("serial.zig");
    if (size) |s| {
        var buffer: [16]u8 = undefined;
        const text = edid.record(s, &buffer) catch return;
        serial.writeAscii("[DISPLAY_NATIVE] ");
        serial.writeAscii(text);
        // A shorter record than an old one: delete and recreate (EFI Delete
        // closes the handle in every case).
        if (root.open(wide(edid.record_path), .read_write, .{})) |old| {
            _ = old.delete() catch {};
        } else |_| {}
        const fresh = root.open(wide(edid.record_path), .read_write_create, .{}) catch return;
        defer fresh.close() catch {};
        _ = fresh.write(text) catch return;
        fresh.flush() catch {};
    } else {
        serial.writeAscii("[DISPLAY_NATIVE] unknown\n");
        const file = root.open(wide(edid.record_path), .read_write, .{}) catch return;
        _ = file.delete() catch {};
    }
}
