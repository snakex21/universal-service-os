const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const boot_next = @import("boot_next.zig");
const case_path = @import("case_path.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const persistent_state_file = @import("persistent_state_file.zig");
const serial = @import("serial.zig");
const work_chainload = @import("work_chainload.zig");
const work_volume = @import("work_volume.zig");

const linux_loader_path = "EFI/USOS/systemd-bootx64.efi";
const PreparationStage = usos.flow.preparation_boot_progress.Stage;
const ProgressFn = *const fn (PreparationStage) void;

pub const ResumeStage = enum {
    starting_windows_setup,
    loading_ntfs_driver,
    locating_work_partition,
    verifying_windows_media,
    loading_windows_boot_manager,
    committing_windows_handoff,
    transferring_to_windows,
    starting_chainload,
};
const ResumeProgressFn = *const fn (ResumeStage) void;

fn say(text: []const u8) void {
    serial.writeAscii(text);
}

pub fn resumePersistent(root: *uefi.protocol.File, progress: ?ResumeProgressFn) bool {
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
            say("PERSISTENT PHASE PREPARE-REQUESTED RECOVERY: PREVIOUS PREPARATION DID NOT COMMIT PREPARED; RESETTING TO PENDING\n");
            persistent_state_file.write(root, .pending, null, null, null) catch |err| {
                say("PERSISTENT RECOVERY RESET FAIL: ");
                say(@errorName(err));
                say("\n");
                return true;
            };
            return false;
        },
        .prepared => {
            say("PERSISTENT PHASE PREPARED\n");
            const method = persistedMethod(state.selected_method) orelse .direct_iso;
            if (method == .chainload or method == .wimboot or method == .vhdboot) {
                if (progress) |callback| callback(.starting_chainload);
                handoffChainload(root, method) catch |err| {
                    say("CHAINLOAD HANDOFF FAIL: ");
                    say(@errorName(err));
                    say("\n");
                };
            } else {
                reportResumeProgress(progress, .starting_windows_setup);
                say("WINDOWS HANDOFF UI PRESENTED BEFORE NTFS/WORK DISCOVERY\n");
                handoffWindows(root, method, progress) catch |err| {
                    say("WINDOWS HANDOFF FAIL: ");
                    say(@errorName(err));
                    say("\n");
                };
            }
            return true;
        },
        .handoff => {
            say("PERSISTENT PHASE HANDOFF RECOVERY TO PREPARED\n");
            const method = persistedMethod(state.selected_method) orelse .direct_iso;
            persistent_state_file.write(root, .prepared, null, null, method.persistedValue()) catch return true;
            if (method == .chainload or method == .wimboot or method == .vhdboot) {
                handoffChainload(root, method) catch |err| {
                    say("CHAINLOAD HANDOFF RETRY FAIL: ");
                    say(@errorName(err));
                    say("\n");
                };
            } else {
                reportResumeProgress(progress, .starting_windows_setup);
                say("WINDOWS HANDOFF RETRY UI PRESENTED BEFORE NTFS/WORK DISCOVERY\n");
                handoffWindows(root, method, progress) catch |err| {
                    say("WINDOWS HANDOFF RETRY FAIL: ");
                    say(@errorName(err));
                    say("\n");
                };
            }
            return true;
        },
    }
}

pub fn requestPreparation(
    root: *uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    method: usos.catalog.BootMethod,
    unattended: ?[]const u8,
    progress: ?ProgressFn,
) !void {
    try usos.flow.preparation_capability.validate(system.id, image.kind, method);
    const resolved_method = usos.flow.preparation_capability.resolve(system.id, image.kind, method) orelse return error.UnsupportedMethod;
    if (resolved_method == .direct_efi) return error.DirectEfiDoesNotUsePreparation;

    var iso_path_storage: [512]u8 = undefined;
    const iso_path = try dataPath(&iso_path_storage, system.image_directory, image.name.slice());
    var unattended_path_storage: [512]u8 = undefined;
    const unattended_path = if (unattended) |name| blk: {
        const directory = system.unattended_directory orelse return error.UnattendedDirectoryMissing;
        break :blk try dataPath(&unattended_path_storage, directory, name);
    } else null;

    try persistent_state_file.write(root, .prepare_requested, iso_path, unattended_path, resolved_method.persistedValue());
    reportProgress(progress, .request_saved);
    say("PERSISTENT PHASE PREPARE-REQUESTED PASS\n");
    const current = boot_next.prepareReturnToCurrentBoot() catch |err| {
        persistent_state_file.write(root, .pending, null, null, null) catch {};
        return err;
    };
    _ = current;
    reportProgress(progress, .return_boot_configured);
    say("BOOTORDER BACKUP PASS\n");
    say("BOOTNEXT CURRENT PASS\n");
    startMicroLinux(progress) catch |err| {
        persistent_state_file.write(root, .pending, null, null, null) catch {};
        return err;
    };
}

fn startMicroLinux(progress: ?ProgressFn) !void {
    const image = try loadEspImage(linux_loader_path);
    reportProgress(progress, .loader_ready);
    say("MICRO-LINUX EFI LOADIMAGE PASS\n");
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    reportProgress(progress, .transferring_control);
    say("MICRO-LINUX STARTIMAGE BEGIN\n");
    const result = try boot_services.startImage(image);
    if (result.code != .success) return error.MicroLinuxReturnedError;
    return error.MicroLinuxReturned;
}

fn reportProgress(progress: ?ProgressFn, stage: PreparationStage) void {
    if (progress) |callback| callback(stage);
}

fn reportResumeProgress(progress: ?ResumeProgressFn, stage: ResumeStage) void {
    if (progress) |callback| callback(stage);
}

fn handoffWindows(root: *uefi.protocol.File, method: usos.catalog.BootMethod, progress: ?ResumeProgressFn) !void {
    reportResumeProgress(progress, .loading_ntfs_driver);
    ntfs_driver.loadAndConnect(root) catch |err| {
        say("NTFS DRIVER FAIL: ");
        say(@errorName(err));
        say("\n");
        return err;
    };
    say("NTFS DRIVER PASS\n");
    reportResumeProgress(progress, .locating_work_partition);
    const work = work_volume.find() orelse return error.WorkNotFound;
    say("WORK FOUND\n");
    reportResumeProgress(progress, .verifying_windows_media);
    if (!work.has_install_wim) return error.InstallWimMissing;
    say("INSTALL.WIM VISIBLE ON WORK\n");
    if (!work.has_windows_boot) return error.WindowsBootMissing;
    say("EFI BOOT FILE VISIBLE ON WORK\n");

    reportResumeProgress(progress, .loading_windows_boot_manager);
    const windows_image = try work_chainload.load(work.handle);
    say("WINDOWS LOADIMAGE PASS\n");
    _ = try work_chainload.checkLoadedImage(windows_image, work.handle);
    say("WINDOWS LOADEDIMAGE CHECK PASS\n");

    reportResumeProgress(progress, .committing_windows_handoff);
    try persistent_state_file.write(root, .handoff, null, null, method.persistedValue());
    say("PERSISTENT PHASE HANDOFF PASS\n");
    try persistent_state_file.write(root, .pending, null, null, null);
    say("ONE-SHOT PHASE PENDING PASS\n");

    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    reportResumeProgress(progress, .transferring_to_windows);
    say("WINDOWS STARTIMAGE BEGIN\n");
    const result = boot_services.startImage(windows_image) catch |err| {
        persistent_state_file.write(root, .prepared, null, null, method.persistedValue()) catch {};
        say("WINDOWS STARTIMAGE ERROR; PHASE PREPARED RESTORED\n");
        return err;
    };
    if (result.code != .success) {
        persistent_state_file.write(root, .prepared, null, null, method.persistedValue()) catch {};
        return error.WindowsReturnedError;
    }
}

fn handoffChainload(root: *uefi.protocol.File, method: usos.catalog.BootMethod) !void {
    ntfs_driver.loadAndConnect(root) catch |err| {
        say("NTFS DRIVER FAIL: ");
        say(@errorName(err));
        say("\n");
        return err;
    };
    say("NTFS DRIVER PASS\n");
    const work = work_volume.find() orelse return error.WorkNotFound;
    say("WORK FOUND\n");
    if (!work.has_windows_boot) return error.EfiBootFileMissing;
    say("EFI BOOT FILE VISIBLE ON WORK\n");

    const chained_image = try work_chainload.load(work.handle);
    say("CHAINLOAD LOADIMAGE PASS\n");
    _ = try work_chainload.checkLoadedImage(chained_image, work.handle);
    say("CHAINLOAD LOADEDIMAGE CHECK PASS\n");

    try persistent_state_file.write(root, .handoff, null, null, method.persistedValue());
    try persistent_state_file.write(root, .pending, null, null, null);
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    say("CHAINLOAD STARTIMAGE BEGIN\n");
    const result = boot_services.startImage(chained_image) catch |err| {
        persistent_state_file.write(root, .prepared, null, null, method.persistedValue()) catch {};
        return err;
    };
    if (result.code != .success) {
        persistent_state_file.write(root, .prepared, null, null, method.persistedValue()) catch {};
        return error.ChainloadedImageReturnedError;
    }
}

fn persistedMethod(value: ?[]const u8) ?usos.catalog.BootMethod {
    const text = value orelse return null;
    return usos.catalog.BootMethod.fromPersistedValue(text);
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
