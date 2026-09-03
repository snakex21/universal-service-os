const std = @import("std");
const uefi = std.os.uefi;
const case_path = @import("case_path.zig");

const boot_path = "EFI/BOOT/BOOTX64.EFI";

pub const LoadedImageCheck = struct {
    file_path: []align(1) const u16,
};

pub fn load(work_handle: uefi.Handle) !uefi.Handle {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const file_system = (try boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, work_handle)) orelse return error.FileSystemUnavailable;
    const root = try file_system.openVolume();
    defer root.close() catch {};

    var resolved_storage: [case_path.max_path_units + 1:0]u16 = undefined;
    const resolved_path = try case_path.resolve(root, boot_path, &resolved_storage);

    const device_path = (try boot_services.handleProtocol(uefi.protocol.DevicePath, work_handle)) orelse return error.DevicePathUnavailable;
    var path_storage: [2048]u8 = undefined;
    var allocator_state = std.heap.FixedBufferAllocator.init(&path_storage);
    const image_path = try device_path.createFileDevicePath(allocator_state.allocator(), resolved_path);
    return boot_services.loadImage(false, uefi.handle, .{ .device_path = image_path });
}

pub fn checkLoadedImage(image_handle: uefi.Handle, work_handle: uefi.Handle) !LoadedImageCheck {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const loaded = (try boot_services.handleProtocol(uefi.protocol.LoadedImage, image_handle)) orelse
        return error.LoadedImageProtocolUnavailable;

    if (loaded.device_handle != work_handle) return error.DeviceHandleMismatch;
    if (loaded.parent_handle != uefi.handle) return error.ParentHandleMismatch;

    const device_path = loaded.file_path.getDevicePath() orelse return error.FilePathNodeMissing;
    const file_path_node = switch (device_path) {
        .media => |media| switch (media) {
            .file_path => |node| node,
            else => return error.FilePathNodeMissing,
        },
        else => return error.FilePathNodeMissing,
    };
    const header_size = @sizeOf(uefi.DevicePath.Media.FilePathDevicePath);
    if (file_path_node.length < header_size + @sizeOf(u16)) return error.FilePathNodeMissing;
    const path_bytes = file_path_node.length - header_size;
    if (path_bytes % @sizeOf(u16) != 0) return error.FilePathNodeMissing;
    const path_units_with_nul = path_bytes / @sizeOf(u16);
    const path_z = file_path_node.getPath();
    if (path_z[path_units_with_nul - 1] != 0) return error.FilePathNodeMissing;
    const actual_path = path_z[0 .. path_units_with_nul - 1];

    const file_system = (try boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, work_handle)) orelse
        return error.FilePathNodeMissing;
    const root = try file_system.openVolume();
    defer root.close() catch {};
    var resolved_storage: [case_path.max_path_units + 1:0]u16 = undefined;
    const expected_path = try case_path.resolve(root, boot_path, &resolved_storage);
    if (expected_path.len != actual_path.len) return error.FilePathMismatch;
    for (expected_path, 0..) |unit, index| {
        if (unit != actual_path[index]) return error.FilePathMismatch;
    }

    return .{ .file_path = actual_path };
}
