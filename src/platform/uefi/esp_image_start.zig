const std = @import("std");
const uefi = std.os.uefi;
const case_path = @import("case_path.zig");
const verified_image = @import("verified_image.zig");

pub fn start(root: *uefi.protocol.File, directory: []const u8, name: []const u8) !void {
    var path_storage: [512]u8 = undefined;
    const path = try joinedPath(&path_storage, directory, name);
    const image = try load(root, path);
    const code = try verified_image.start(image);
    if (code != .success) return error.EfiImageReturnedError;
    return error.EfiImageReturned;
}

pub fn load(root: *uefi.protocol.File, path: []const u8) !uefi.Handle {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const loaded_self = (try boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse
        return error.LoadedImageUnavailable;
    const esp_handle = loaded_self.device_handle orelse return error.DeviceHandleUnavailable;

    var resolved_storage: [case_path.max_path_units + 1:0]u16 = undefined;
    const resolved = try case_path.resolve(root, path, &resolved_storage);
    const device_path = (try boot_services.handleProtocol(uefi.protocol.DevicePath, esp_handle)) orelse
        return error.DevicePathUnavailable;
    var device_path_storage: [2048]u8 = undefined;
    var allocator_state = std.heap.FixedBufferAllocator.init(&device_path_storage);
    const image_path = try device_path.createFileDevicePath(allocator_state.allocator(), resolved);
    const file = try root.open(resolved, .read, .{});
    defer file.close() catch {};
    return verified_image.loadApplication(image_path, file);
}

fn joinedPath(storage: *[512]u8, directory: []const u8, name: []const u8) ![]const u8 {
    var used: usize = 0;
    for (directory) |byte| {
        if (used >= storage.len) return error.PathTooLong;
        storage[used] = if (byte == '/') '\\' else byte;
        used += 1;
    }
    if (used == 0 or storage[used - 1] != '\\') {
        if (used >= storage.len) return error.PathTooLong;
        storage[used] = '\\';
        used += 1;
    }
    if (used + name.len > storage.len) return error.PathTooLong;
    @memcpy(storage[used .. used + name.len], name);
    used += name.len;
    return storage[0..used];
}

test "joined ESP image path keeps UEFI separators" {
    var storage: [512]u8 = undefined;
    const path = try joinedPath(&storage, "\\Utilities\\MemTest86\\Images", "memtest86.efi");
    try std.testing.expectEqualStrings("\\Utilities\\MemTest86\\Images\\memtest86.efi", path);
}
