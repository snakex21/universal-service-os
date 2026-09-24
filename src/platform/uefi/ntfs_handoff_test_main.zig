const std = @import("std");
const uefi = std.os.uefi;
const filesystem = @import("filesystem.zig");
const log = @import("log.zig");
const serial = @import("serial.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const work_volume = @import("work_volume.zig");
const work_chainload = @import("work_chainload.zig");

fn say(text: []const u8) void {
    log.writeAscii(text);
    serial.writeAscii(text);
}

fn sayPathLine(prefix: []const u8, text: []align(1) const u16) void {
    var storage: [case_path_max_ascii + 64]u8 = undefined;
    if (prefix.len + text.len + 1 > storage.len) {
        say("WINDOWS LOADEDIMAGE FILE PATH FAIL: path too long\n");
        return;
    }
    @memcpy(storage[0..prefix.len], prefix);
    for (text, 0..) |unit, index| {
        if (unit > 0x7f) {
            say("WINDOWS LOADEDIMAGE FILE PATH FAIL: non-ASCII path\n");
            return;
        }
        storage[prefix.len + index] = @intCast(unit);
    }
    const used = prefix.len + text.len;
    storage[used] = '\n';
    say(storage[0 .. used + 1]);
}

const case_path_max_ascii = 511;

pub fn main() uefi.Status {
    serial.init();
    say("USOS NTFS HANDOFF TEST\n");

    const root = filesystem.openBootVolume() orelse {
        say("ESP OPEN FAIL\n");
        return .not_found;
    };
    defer root.close() catch {};

    const boot_services = uefi.system_table.boot_services orelse return .load_error;
    const loaded_self = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse {
        say("SELF LOADEDIMAGE PROTOCOL FAIL\n");
        return .load_error;
    };
    const esp_handle = loaded_self.device_handle orelse {
        say("ESP HANDLE FAIL\n");
        return .load_error;
    };
    _ = work_chainload.load(esp_handle) catch |err| {
        say("ESP LOADIMAGE DEVICE PATH FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };
    say("ESP LOADIMAGE DEVICE PATH PASS\n");

    ntfs_driver.loadAndConnect(root) catch |err| {
        say("NTFS DRIVER FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };
    say("NTFS DRIVER PASS\n");

    const work = work_volume.find() orelse {
        say("WORK NOT FOUND\n");
        return .not_found;
    };
    say("WORK FOUND\n");
    if (work.install_image == null) {
        say("INSTALL.WIM NOT FOUND ON WORK\n");
        return .not_found;
    }
    say("INSTALL.WIM VISIBLE ON WORK\n");
    if (!work.has_windows_boot) {
        say("BOOTX64.EFI NOT VISIBLE ON WORK\n");
        return .not_found;
    }
    say("BOOTX64.EFI VISIBLE ON WORK\n");

    const windows_image = work_chainload.load(work.handle) catch |err| {
        say("WINDOWS LOADIMAGE FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };
    say("WINDOWS LOADIMAGE PASS\n");

    const loaded_check = work_chainload.checkLoadedImage(windows_image, work.handle) catch |err| {
        say("WINDOWS LOADEDIMAGE CHECK FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };
    say("WINDOWS LOADEDIMAGE DEVICE HANDLE PASS\n");
    say("WINDOWS LOADEDIMAGE PARENT HANDLE PASS\n");
    sayPathLine("WINDOWS LOADEDIMAGE FILE PATH PASS: ", loaded_check.file_path);
    say("WINDOWS STARTIMAGE BEGIN\n");

    const result = boot_services.startImage(windows_image) catch |err| {
        say("WINDOWS STARTIMAGE FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };

    if (result.code == .success) {
        say("WINDOWS STARTIMAGE RETURNED SUCCESS\n");
        return .success;
    }
    say("WINDOWS STARTIMAGE RETURNED ERROR\n");
    return result.code;
}
