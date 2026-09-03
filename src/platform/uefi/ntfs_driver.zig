const std = @import("std");
const uefi = std.os.uefi;
const file_read = @import("file_read.zig");

var driver_buffer: [128 * 1024]u8 = undefined;

pub const Error = error{
    DriverFileMissing,
    BootServicesUnavailable,
    DriverStartFailed,
    NoBlockHandles,
} || uefi.UnexpectedError || uefi.tables.BootServices.LoadImageError || uefi.tables.BootServices.StartImageError || uefi.tables.BootServices.LocateHandleBufferError;

pub fn loadAndConnect(root: *uefi.protocol.File) !void {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const bytes = file_read.into(root, "\\EFI\\USOS\\ntfs_x64.efi", &driver_buffer) orelse return error.DriverFileMissing;
    const image = try boot_services.loadImage(false, uefi.handle, .{ .buffer = bytes });
    const result = try boot_services.startImage(image);
    if (result.code != .success) return error.DriverStartFailed;

    const handles = (try boot_services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.NoBlockHandles;
    for (handles) |handle| {
        boot_services.connectController(handle, null, null, true) catch {};
    }
    boot_services.stall(100_000) catch {};
}
