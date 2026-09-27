//! Vista SP2 x64 on UEFI: USOS prepares the target disk first
//! (docs/windows-vista-existing-esp-2026-09-26.md). The base micro-Linux
//! starts with usos.legacy_action=vista-disk; its pipeline step 600 shows the
//! XP disk picker and wipe confirmation, writes a fresh GPT (ESP + MSR) and
//! records the disk in EFI\USOS\vista-target.ini, then reboots into USOS.
//! The next Vista start sees the record and boots WinPE (the Vista installer
//! pins that ESP and consumes the record).
const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const esp_image = @import("esp_image_start.zig");

pub const record_path = wide("\\EFI\\USOS\\vista-target.ini");

/// Off by default (user decision 2026-09-27: Vista Setup's own delete/format
/// on the disk page is enough). To re-enable, put an empty file
/// EFI\USOS\vista-disk-prep.flag on the USOS ESP; nothing else changes.
pub const enable_flag_path = wide("\\EFI\\USOS\\vista-disk-prep.flag");

pub fn enabled(root: *uefi.protocol.File) bool {
    const file = root.open(enable_flag_path, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

/// True when micro-Linux prepared a disk and WinPE has not consumed it yet.
pub fn prepared(root: *uefi.protocol.File) bool {
    const file = root.open(record_path, .read, .{}) catch return false;
    defer file.close() catch {};
    var bytes: [512]u8 = undefined;
    const used = file.read(&bytes) catch return false;
    return std.mem.indexOf(u8, bytes[0..used], "state=prepared") != null;
}

fn espPartuuid(root: *uefi.protocol.File, out: *[36]u8) !void {
    const config = try root.open(wide("\\EFI\\USOS\\usos-device.ini"), .read, .{});
    defer config.close() catch {};
    var bytes: [4096]u8 = undefined;
    const used = try config.read(&bytes);
    var lines = std.mem.splitScalar(u8, bytes[0..used], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, "esp_partuuid=")) continue;
        const id = line[13..];
        if (id.len != 36) return error.InvalidEspIdentity;
        for (id, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (c != '-') return error.InvalidEspIdentity;
            } else if (!std.ascii.isHex(c)) return error.InvalidEspIdentity;
        }
        @memcpy(out, id);
        return;
    }
    return error.EspIdentityMissing;
}

pub fn start(root: *uefi.protocol.File) !void {
    var id: [36]u8 = undefined;
    try espPartuuid(root, &id);
    const lang_initrd = if (root.open(wide("\\EFI\\USOS\\lang.cpio"), .read, .{})) |file| blk: {
        file.close() catch {};
        break :blk " initrd=\\EFI\\USOS\\lang.cpio";
    } else |_| "";
    var cmd: [1024]u8 = undefined;
    const command = try std.fmt.bufPrint(&cmd, "initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos{s} rdinit=/usos-init quiet loglevel=3 vt.global_cursor_default=0 usos.esp_partuuid={s} usos.legacy_action=vista-disk usos.plan_profile=vista-uefi-disk", .{ lang_initrd, &id });
    const serial = @import("serial.zig");
    serial.writeAscii("[VISTA_DISK_CMDLINE] ");
    serial.writeAscii(command);
    serial.writeAscii("\n");
    var options: [1025]u16 = @splat(0);
    for (command, 0..) |c, i| options[i] = c;
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    try bs.setWatchdogTimer(0, 0, null);
    const image = try esp_image.load(root, "\\EFI\\USOS\\micro-linux\\vmlinuz-virt");
    defer _ = bs.unloadImage(image) catch .load_error;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, image)) orelse return error.NoLoadedImage;
    loaded.load_options = &options;
    loaded.load_options_size = @intCast((command.len + 1) * 2);
    const code = try @import("verified_image.zig").start(image);
    if (code != .success) return error.VistaDiskKernelReturnedError;
    return error.VistaDiskKernelReturned;
}
