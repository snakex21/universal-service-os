const std = @import("std");
const uefi = std.os.uefi;
const filesystem = @import("filesystem.zig");
const log = @import("log.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const serial = @import("serial.zig");
const work_volume = @import("work_volume.zig");
const work_chainload = @import("work_chainload.zig");

const expected_data = "USOS_DATA";
const expected_work = "USOS_WORK";

fn say(text: []const u8) void {
    log.writeAscii(text);
    serial.writeAscii(text);
}

fn volumeLabelEquals(root: *uefi.protocol.File, expected: []const u8) bool {
    var buffer: [512]u8 align(8) = undefined;
    const info = root.getInfo(.file_system, buffer[0..]) catch return false;
    const label = info.getVolumeLabel();
    var index: usize = 0;
    while (label[index] != 0) : (index += 1) {
        if (index >= expected.len) return false;
        if (label[index] > 0x7f or @as(u8, @intCast(label[index])) != expected[index]) return false;
    }
    return index == expected.len;
}

const data_marker = std.unicode.utf8ToUtf16LeStringLiteral("\\usos-data-marker.txt");
const work_marker = std.unicode.utf8ToUtf16LeStringLiteral("\\.usos-work");

fn hasFile(root: *uefi.protocol.File, path: [*:0]const u16) bool {
    const file = root.open(path, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

fn sayLabel(root: *uefi.protocol.File) void {
    var buffer: [512]u8 align(8) = undefined;
    const info = root.getInfo(.file_system, buffer[0..]) catch |err| {
        say("SIMPLEFS VOLUME (no info: ");
        say(@errorName(err));
        say(")\n");
        return;
    };
    const label = info.getVolumeLabel();
    var text: [40]u8 = undefined;
    var used: usize = 0;
    while (used < text.len and label[used] != 0) : (used += 1) {
        text[used] = if (label[used] <= 0x7f) @intCast(label[used]) else '?';
    }
    say("SIMPLEFS VOLUME label=");
    say(text[0..used]);
    say("\n");
}

pub fn main() uefi.Status {
    serial.init();
    say("USOS GPT NO-BLOCK-IO PROBE\n");

    const esp_root = filesystem.openBootVolume() orelse {
        say("ESP OPEN FAIL\n");
        return .not_found;
    };
    defer esp_root.close() catch {};

    ntfs_driver.loadAndConnect(esp_root) catch |err| {
        say("NTFS DRIVER FAIL: ");
        say(@errorName(err));
        say("\n");
        return .load_error;
    };
    say("NTFS DRIVER PASS\n");

    const boot_services = uefi.system_table.boot_services orelse return .load_error;
    const handles = (boot_services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.SimpleFileSystem.guid }) catch null) orelse {
        say("SIMPLEFS ENUMERATION FAIL\n");
        return .not_found;
    };

    var data_found = false;
    var work_found = false;
    for (handles) |handle| {
        const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, handle) catch continue) orelse continue;
        const root = fs.openVolume() catch continue;
        defer root.close() catch {};
        sayLabel(root);
        // Label (FAT/firmware NTFS) or marker file (efifs NTFS may not
        // report EFI_FILE_SYSTEM_INFO).
        if (volumeLabelEquals(root, expected_data) or hasFile(root, data_marker)) data_found = true;
        if (volumeLabelEquals(root, expected_work) or hasFile(root, work_marker)) work_found = true;
    }

    if (data_found) say("DATA SIMPLEFS FOUND\n") else say("DATA SIMPLEFS MISSING\n");
    if (work_found) say("WORK SIMPLEFS FOUND\n") else say("WORK SIMPLEFS MISSING\n");

    if (!data_found or !work_found) {
        say("NO-BLOCK-IO VISIBILITY FAIL\n");
        return .not_found;
    }

    // The WORK handoff path: marker discovery, LoadImage of the WORK boot
    // file through the WORK device path, LoadedImage check (no StartImage).
    const work = work_volume.find() orelse {
        say("WORK HANDOFF DISCOVERY FAIL\n");
        say("NO-BLOCK-IO VISIBILITY FAIL\n");
        return .not_found;
    };
    say("WORK HANDOFF DISCOVERY PASS\n");
    if (work.has_windows_boot) {
        const image = work_chainload.load(work.handle) catch |err| {
            say("WORK LOADIMAGE FAIL: ");
            say(@errorName(err));
            say("\n");
            say("NO-BLOCK-IO VISIBILITY FAIL\n");
            return .load_error;
        };
        _ = work_chainload.checkLoadedImage(image, work.handle) catch |err| {
            say("WORK LOADEDIMAGE CHECK FAIL: ");
            say(@errorName(err));
            say("\n");
            say("NO-BLOCK-IO VISIBILITY FAIL\n");
            return .load_error;
        };
        _ = boot_services.unloadImage(image) catch .load_error;
        say("WORK LOADIMAGE PASS\n");
    } else {
        say("WORK LOADIMAGE SKIPPED (no EFI/USOS-WORK boot file)\n");
    }
    say("NO-BLOCK-IO VISIBILITY PASS\n");
    return .success;
}
