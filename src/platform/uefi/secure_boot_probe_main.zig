//! QEMU probe for the Secure Boot chain (tools/tests/secure_boot). shim
//! starts it as the MOK-signed second stage instead of USOS; it exercises
//! the same verified_image.zig paths USOS uses and reports on the serial
//! port, then hands over to systemd-boot -> micro-Linux like a real
//! preparation start.
const std = @import("std");
const uefi = std.os.uefi;
const esp_image_start = @import("esp_image_start.zig");
const filesystem = @import("filesystem.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const secure_boot = @import("secure_boot.zig");
const serial = @import("serial.zig");

fn say(text: []const u8) void {
    serial.writeAscii(text);
}

fn sayError(prefix: []const u8, err: anyerror) void {
    say(prefix);
    say(@errorName(err));
    say("\n");
}

fn startChild(root: *uefi.protocol.File, label: []const u8, path: []const u8) void {
    say("[SB_PROBE] ");
    say(label);
    const image = esp_image_start.load(root, path) catch |err| {
        sayError(" LOAD REJECTED error=", err);
        return;
    };
    say(" LOAD PASS\n");
    const code = @import("verified_image.zig").start(image) catch |err| {
        serial.init();
        sayError("[SB_PROBE] START FAIL error=", err);
        return;
    };
    // The child may have reset the serial port.
    serial.init();
    say(if (code == .success) "[SB_PROBE] START PASS\n" else "[SB_PROBE] START RETURNED ERROR\n");
}

pub fn main() uefi.Status {
    serial.init();
    say("[SB_PROBE] begin state=");
    say(secure_boot.label(secure_boot.state()));
    say(if (secure_boot.shimLock() != null) " shim_lock=yes" else " shim_lock=no");
    say(if (secure_boot.shimOwnsLoadImage()) " shim_loader=yes\n" else " shim_loader=no\n");
    const root = filesystem.openBootVolume() orelse {
        say("[SB_PROBE] ESP OPEN FAIL\n");
        return .not_found;
    };
    defer root.close() catch {};

    startChild(root, "unsigned-child", "\\EFI\\USOS\\probe\\unsigned-child.efi");

    if (ntfs_driver.loadAndConnect(root)) |_| {
        say("[SB_PROBE] ntfs-driver START PASS\n");
    } else |err| sayError("[SB_PROBE] ntfs-driver FAIL error=", err);

    const bs = uefi.system_table.boot_services orelse return .load_error;
    if (esp_image_start.load(root, "\\EFI\\USOS\\micro-linux\\vmlinuz-virt")) |kernel| {
        say("[SB_PROBE] kernel LOAD PASS\n");
        _ = bs.unloadImage(kernel) catch .load_error;
    } else |err| sayError("[SB_PROBE] kernel LOAD REJECTED error=", err);

    // Microsoft-signed (UEFI CA), not re-signed: verified against db by shim.
    if (esp_image_start.load(root, "\\EFI\\USOS\\windows-native\\wimboot")) |wimboot| {
        say("[SB_PROBE] wimboot LOAD PASS\n");
        _ = bs.unloadImage(wimboot) catch .load_error;
    } else |err| sayError("[SB_PROBE] wimboot LOAD REJECTED error=", err);

    startChild(root, "signed-child", "\\EFI\\USOS\\probe\\signed-child.efi");
    say("[SB_PROBE] systemd-boot handover\n");
    startChild(root, "systemd-boot", "\\EFI\\USOS\\systemd-bootx64.efi");
    say("[SB_PROBE] end\n");
    return .success;
}
