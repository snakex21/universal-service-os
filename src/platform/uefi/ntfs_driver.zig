const std = @import("std");
const uefi = std.os.uefi;
const file_read = @import("file_read.zig");
const verified_image = @import("verified_image.zig");
const partition_handles = @import("partition_handles.zig");
const log = @import("log.zig");
const serial = @import("serial.zig");

var driver_buffer: [128 * 1024]u8 = undefined;

pub const Error = error{
    DriverFileMissing,
    BootServicesUnavailable,
    DriverStartFailed,
    NoBlockHandles,
} || uefi.UnexpectedError || verified_image.Error || uefi.tables.BootServices.StartImageError || uefi.tables.BootServices.LocateHandleBufferError;

/// The driver stays resident once started; a second call (the UEFI Shell
/// row and then a Windows handoff) only connects it again.
var started = false;

pub fn loadAndConnect(root: *uefi.protocol.File) !void {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    if (!started) {
        const bytes = file_read.into(root, "\\EFI\\USOS\\ntfs_x64.efi", &driver_buffer) orelse return error.DriverFileMissing;
        // Signed with the USOS key; under Secure Boot it is verified through shim.
        try verified_image.startDriver(bytes, null);
        started = true;
    }

    // DATA/WORK marked with GPT bit 1 (no firmware boot-menu entry) have no
    // firmware partition handle; give them ours before connecting drivers.
    const report = partition_handles.installHidden();
    if (report.installed != 0) say("USOS PARTITION HANDLES INSTALLED\n");
    if (report.firmware_present != 0) say("USOS PARTITION HANDLES: FIRMWARE IGNORED GPT BIT 1\n");

    const handles = (try boot_services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.NoBlockHandles;
    for (handles) |handle| {
        boot_services.connectController(handle, null, null, true) catch {};
    }
    boot_services.stall(100_000) catch {};
}

fn say(text: []const u8) void {
    log.writeAscii(text);
    serial.writeAscii(text);
}
