const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const boot_next = @import("boot_next.zig");
const case_path = @import("case_path.zig");
const log = @import("log.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const persistent_state_file = @import("persistent_state_file.zig");
const serial = @import("serial.zig");
const work_chainload = @import("work_chainload.zig");
const work_volume = @import("work_volume.zig");

const linux_loader_path = "EFI/USOS/systemd-bootx64.efi";

fn say(text: []const u8) void {
    log.writeAscii(text);
    serial.writeAscii(text);
}

pub fn resumePersistent(root: *uefi.protocol.File) bool {
    var state_storage: [persistent_state_file.max_state_bytes]u8 = undefined;
    const state = persistent_state_file.read(root, &state_storage) catch |err| {
        say("PERSISTENT STATE READ FAIL: ");
        say(@errorName(err));
        say("\n");
        return false;
    };
    switch (state.phase) {
        .pending => return false,
        .prepare_requested => {
            say("PERSISTENT PHASE PREPARE-REQUESTED\n");
            startMicroLinux() catch |err| {
                say("MICRO-LINUX CHAINLOAD FAIL: ");
                say(@errorName(err));
                say("\n");
            };
            return true;
        },
        .prepared => {
            say("PERSISTENT PHASE PREPARED\n");
            handoffWindows(root) catch |err| {
                say("WINDOWS HANDOFF FAIL: ");
                say(@errorName(err));
                say("\n");
            };
            return true;
        },
        .handoff => {
            say("PERSISTENT PHASE HANDOFF RECOVERY TO PREPARED\n");
            persistent_state_file.write(root, .prepared, null, null) catch return true;
            handoffWindows(root) catch |err| {
                say("WINDOWS HANDOFF RETRY FAIL: ");
                say(@errorName(err));
                say("\n");
            };
            return true;
        },
    }
}

pub fn requestPreparation(
    root: *uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    unattended: ?[]const u8,
) !void {
    if (!std.mem.eql(u8, system.id, "windows-11")) return error.UnsupportedSystem;
    if (image.kind != .iso) return error.UnsupportedImage;

    var iso_path_storage: [512]u8 = undefined;
    const iso_path = try dataPath(&iso_path_storage, system.image_directory, image.name.slice());
    var unattended_path_storage: [512]u8 = undefined;
    const unattended_path = if (unattended) |name| blk: {
        const directory = system.unattended_directory orelse return error.UnattendedDirectoryMissing;
        break :blk try dataPath(&unattended_path_storage, directory, name);
    } else null;

    try persistent_state_file.write(root, .prepare_requested, iso_path, unattended_path);
    say("PERSISTENT PHASE PREPARE-REQUESTED PASS\n");
    const current = boot_next.prepareReturnToCurrentBoot() catch |err| {
        persistent_state_file.write(root, .pending, null, null) catch {};
        return err;
    };
    _ = current;
    say("BOOTORDER BACKUP PASS\n");
    say("BOOTNEXT CURRENT PASS\n");
    startMicroLinux() catch |err| {
        persistent_state_file.write(root, .pending, null, null) catch {};
        return err;
    };
}

fn startMicroLinux() !void {
    const image = try loadEspImage(linux_loader_path);
    say("MICRO-LINUX EFI LOADIMAGE PASS\n");
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    say("MICRO-LINUX STARTIMAGE BEGIN\n");
    const result = try boot_services.startImage(image);
    if (result.code != .success) return error.MicroLinuxReturnedError;
    return error.MicroLinuxReturned;
}

fn handoffWindows(root: *uefi.protocol.File) !void {
    ntfs_driver.loadAndConnect(root) catch |err| {
        say("NTFS DRIVER FAIL: ");
        say(@errorName(err));
        say("\n");
        return err;
    };
    say("NTFS DRIVER PASS\n");
    const work = work_volume.find() orelse return error.WorkNotFound;
    say("WORK FOUND\n");
    if (!work.has_install_wim) return error.InstallWimMissing;
    say("INSTALL.WIM VISIBLE ON WORK\n");
    if (!work.has_windows_boot) return error.WindowsBootMissing;
    say("BOOTX64.EFI VISIBLE ON WORK\n");

    const windows_image = try work_chainload.load(work.handle);
    say("WINDOWS LOADIMAGE PASS\n");
    _ = try work_chainload.checkLoadedImage(windows_image, work.handle);
    say("WINDOWS LOADEDIMAGE CHECK PASS\n");

    try persistent_state_file.write(root, .handoff, null, null);
    say("PERSISTENT PHASE HANDOFF PASS\n");
    // StartImage does not return after a successful Windows boot. Publish the
    // one-shot reset immediately before transferring control; any returned
    // error restores prepared below so extraction is never repeated.
    try persistent_state_file.write(root, .pending, null, null);
    say("ONE-SHOT PHASE PENDING PASS\n");

    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    say("WINDOWS STARTIMAGE BEGIN\n");
    const result = boot_services.startImage(windows_image) catch |err| {
        persistent_state_file.write(root, .prepared, null, null) catch {};
        say("WINDOWS STARTIMAGE ERROR; PHASE PREPARED RESTORED\n");
        return err;
    };
    if (result.code != .success) {
        persistent_state_file.write(root, .prepared, null, null) catch {};
        return error.WindowsReturnedError;
    }
}

fn loadEspImage(path: []const u8) !uefi.Handle {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const loaded_self = (try boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse
        return error.LoadedImageUnavailable;
    const esp_handle = loaded_self.device_handle orelse return error.DeviceHandleUnavailable;
    const file_system = (try boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, esp_handle)) orelse
        return error.FileSystemUnavailable;
    const root = try file_system.openVolume();
    defer root.close() catch {};
    var resolved_storage: [case_path.max_path_units + 1:0]u16 = undefined;
    const resolved = try case_path.resolve(root, path, &resolved_storage);
    const device_path = (try boot_services.handleProtocol(uefi.protocol.DevicePath, esp_handle)) orelse
        return error.DevicePathUnavailable;
    var path_storage: [2048]u8 = undefined;
    var allocator_state = std.heap.FixedBufferAllocator.init(&path_storage);
    const image_path = try device_path.createFileDevicePath(allocator_state.allocator(), resolved);
    return boot_services.loadImage(false, uefi.handle, .{ .device_path = image_path });
}

fn dataPath(storage: *[512]u8, directory: []const u8, name: []const u8) ![]const u8 {
    var used: usize = 0;
    for (directory) |byte| {
        if (byte == '\\' and used == 0) continue;
        if (used == storage.len) return error.PathTooLong;
        storage[used] = if (byte == '\\') '/' else byte;
        used += 1;
    }
    if (used > 0 and storage[used - 1] != '/') {
        if (used == storage.len) return error.PathTooLong;
        storage[used] = '/';
        used += 1;
    }
    if (used + name.len > storage.len) return error.PathTooLong;
    @memcpy(storage[used .. used + name.len], name);
    used += name.len;
    return storage[0..used];
}
