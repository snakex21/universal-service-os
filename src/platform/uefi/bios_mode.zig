//! Utilities -> "Legacy BIOS mode (CSMWrap)" (docs/design/bios-via-csmwrap.md,
//! option A): on a UEFI PC without a firmware CSM, start the stick's own
//! CSMWrap (EFI\USOS\csmwrap\csmwrapx64.efi, 3.1.2-usos3). CSMWrap turns the
//! machine into a BIOS PC until the next reset; its SeaBIOS boots the stick
//! it was loaded from (patch 0004) and the stick's BIOS MBR opens the USOS
//! BIOS menu (FreeDOS, MS-DOS, Windows 3.x). Any restart returns to UEFI.
//!
//! CSMWrap is unsigned (LGPL, rebuilt by USOS), so with Secure Boot on the
//! entry stays visible but greyed out with the reason. With a firmware CSM
//! the entry is hidden: the firmware's own legacy boot is the proven path.
const std = @import("std");
const uefi = std.os.uefi;
const esp_image_start = @import("esp_image_start.zig");
const verified_image = @import("verified_image.zig");
const serial = @import("serial.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const image_path = "\\EFI\\USOS\\csmwrap\\csmwrapx64.efi";
/// CSMWrap reads csmwrap.ini next to itself. The release has none (quiet
/// defaults); the same diagnostic flag file as for XP/Vista targets turns
/// CSMWrap's log back on.
const ini_path = wide("\\EFI\\USOS\\csmwrap\\csmwrap.ini");
const verbose_flag_path = wide("\\EFI\\USOS\\csmwrap-verbose.flag");
const ini_verbose = "serial = false\r\nverbose = true\r\n";
const ini_quiet = "serial = false\r\nverbose = false\r\n";

pub const Availability = enum {
    /// A firmware CSM is present: no entry (its own legacy boot is better).
    hidden,
    /// Shown greyed out: CSMWrap is unsigned and Secure Boot would reject it.
    secure_boot_on,
    available,
};

pub fn availability(csm_likely_on: bool, secure_boot_enforced: bool) Availability {
    if (csm_likely_on) return .hidden;
    if (secure_boot_enforced) return .secure_boot_on;
    return .available;
}

/// Starts CSMWrap. On success it never returns: CSMWrap calls
/// ExitBootServices and hands the machine to SeaBIOS.
pub fn start(root: *uefi.protocol.File) !void {
    writeIni(root);
    serial.writeAscii("[BIOS_MODE] starting " ++ image_path ++ "\n");
    const image = try esp_image_start.load(root, image_path);
    _ = try verified_image.start(image);
    return error.CsmwrapReturned;
}

fn exists(root: *uefi.protocol.File, path: [*:0]const u16) bool {
    const file = root.open(path, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

/// With the flag: csmwrap.ini with verbose = true. Without it, an ini left
/// by an earlier verbose start is reset to quiet; otherwise nothing is
/// written (the release ESP stays as installed).
fn writeIni(root: *uefi.protocol.File) void {
    const verbose = exists(root, verbose_flag_path);
    if (!verbose and !exists(root, ini_path)) return;
    const text = if (verbose) ini_verbose else ini_quiet;
    if (root.open(ini_path, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = root.open(ini_path, .read_write_create, .{}) catch return;
    defer file.close() catch {};
    _ = file.write(text) catch return;
    file.flush() catch {};
    serial.writeAscii(if (verbose) "[BIOS_MODE] csmwrap.ini verbose = true\n" else "[BIOS_MODE] csmwrap.ini verbose = false\n");
}

test "BIOS mode entry: hidden with a CSM, greyed with Secure Boot, else available" {
    try std.testing.expectEqual(Availability.hidden, availability(true, false));
    try std.testing.expectEqual(Availability.hidden, availability(true, true));
    try std.testing.expectEqual(Availability.secure_boot_on, availability(false, true));
    try std.testing.expectEqual(Availability.available, availability(false, false));
}

test "BIOS mode starts the CSMWrap binary the release stages" {
    try std.testing.expectEqualStrings("\\EFI\\USOS\\csmwrap\\csmwrapx64.efi", image_path);
    try std.testing.expect(std.mem.indexOf(u8, ini_verbose, "verbose = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ini_quiet, "verbose = false") != null);
}
