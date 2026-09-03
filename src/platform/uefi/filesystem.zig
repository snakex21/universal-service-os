const std = @import("std");
const uefi = std.os.uefi;

pub fn openBootVolume() ?*uefi.protocol.File {
    const boot_services = uefi.system_table.boot_services orelse return null;
    const loaded = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return null) orelse return null;
    const device = loaded.device_handle orelse return null;
    const file_system = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return null) orelse return null;
    return file_system.openVolume() catch null;
}
