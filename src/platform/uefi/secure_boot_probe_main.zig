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
const touch_driver = @import("touch_driver.zig");
const secure_boot = @import("secure_boot.zig");
const serial = @import("serial.zig");
const mok_key = @import("mok_key.zig");
const mok_list = @import("usos").flow.mok_list;

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

    // Secure Boot off (PK present): the "Add the key" path of the menu.
    if (secure_boot.state() == .disabled) return mokSave(root);

    startChild(root, "unsigned-child", "\\EFI\\USOS\\probe\\unsigned-child.efi");

    if (ntfs_driver.loadAndConnect(root)) |_| {
        say("[SB_PROBE] ntfs-driver START PASS\n");
    } else |err| sayError("[SB_PROBE] ntfs-driver FAIL error=", err);

    // The MOK-signed touch driver, without the SMBIOS gate: it must verify
    // and start through shim, then fail closed (QEMU has no FCH I2C).
    touch_driver.startUngated(root);
    const touch = touch_driver.report();
    if (touch.outcome == .started) {
        say("[SB_PROBE] touch-driver START PASS\n");
    } else if (touch.err) |err| {
        sayError("[SB_PROBE] touch-driver FAIL error=", err);
    } else say("[SB_PROBE] touch-driver FAIL (file missing)\n");

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

fn countLists(name: [*:0]const u16) usize {
    var buffer: [16384]u8 = undefined;
    const guid align(8) = secure_boot.ShimLock.guid;
    const found = (uefi.system_table.runtime_services.getVariable(name, &guid, &buffer) catch return 0) orelse return 0;
    var offset: usize = 0;
    var count: usize = 0;
    while (offset + mok_list.list_header_size <= found[0].len) : (count += 1) {
        const size = std.mem.readInt(u32, found[0][offset + 16 ..][0..4], .little);
        if (size < mok_list.list_header_size) break;
        offset += size;
    }
    return count;
}

/// The same mok_key.save() the Tools -> Secure Boot page and the home offer
/// call, reported on the serial port.
fn mokSave(root: *uefi.protocol.File) uefi.Status {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("MokList");
    var line: [160]u8 = undefined;
    const before = mok_key.status(root);
    say(std.fmt.bufPrint(&line, "[SB_PROBE] mok-save before key={s} lists={d} cert={s} can_save={s}\n", .{ @tagName(before.key), countLists(name), if (before.certificate) "yes" else "no", if (before.canSave()) "yes" else "no" }) catch "");
    mok_key.save(root) catch |err| {
        sayError("[SB_PROBE] mok-save FAIL error=", err);
        return .success;
    };
    const after = mok_key.refresh(root);
    say(std.fmt.bufPrint(&line, "[SB_PROBE] mok-save PASS key={s} lists={d}\n", .{ @tagName(after.key), countLists(name) }) catch "");
    // A second save must be refused (already saved) and add nothing.
    if (mok_key.save(root)) |_| {
        say("[SB_PROBE] mok-save second UNEXPECTED PASS\n");
    } else |err| sayError("[SB_PROBE] mok-save second refused error=", err);
    say(std.fmt.bufPrint(&line, "[SB_PROBE] mok-save end lists={d}\n", .{countLists(name)}) catch "");
    return .success;
}
