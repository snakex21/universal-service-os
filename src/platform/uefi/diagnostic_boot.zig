const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

/// Presence of this ESP file selects verbose/diagnostic boots: wimboot and the
/// XP micro-Linux show their technical output again instead of only the USOS
/// screens. Create an empty `EFI\USOS\diagnostic-boot.flag` to enable it.
pub const flag_path = "\\EFI\\USOS\\diagnostic-boot.flag";

pub fn requested(root: *uefi.protocol.File) bool {
    const file = root.open(wide(flag_path), .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

pub const wimbootOptions = @import("usos").flow.boot_console.wimbootOptions;
pub const xpConsoleOptions = @import("usos").flow.boot_console.xpConsoleOptions;
