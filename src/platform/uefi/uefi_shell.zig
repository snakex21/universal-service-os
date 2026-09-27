//! Built-in EDK2 UEFI Shell (Utilities -> "UEFI Shell", UEFI only).
//!
//! The release puts the unmodified edk2-stable202002 ShellBinPkg X64
//! Shell.efi (tools/vendor/uefi-shell) into EFI\USOS\shell, with the USOS MOK
//! signature, next to startup.nsh
//! (assets/uefi-shell/startup.nsh). It is started like a user .efi image
//! (esp_image_start/verified_image), so Secure Boot with the USOS MOK
//! applies unchanged.
//!
//! DATA is NTFS and the USOS menu reads it with its own parser, so no
//! firmware file system exists for it at that point. Before the Shell
//! starts, the bundled read-only NTFS driver (efifs ntfs_x64.efi, the one
//! the Windows handoff uses) is loaded and connected; it stays resident, so
//! the Shell maps DATA (and WORK) as fsN: next to the FAT32 ESP.
const std = @import("std");
const uefi = std.os.uefi;
const esp_image_start = @import("esp_image_start.zig");
const ntfs_driver = @import("ntfs_driver.zig");
const verified_image = @import("verified_image.zig");
const serial = @import("serial.zig");
const secure_boot = @import("secure_boot.zig");

pub const image_path = "\\EFI\\USOS\\shell\\Shell.efi";

/// Shell command line (Argv[0] is the image name). "-delay 0" skips the
/// five-second "Press ESC ... startup.nsh" countdown; the Shell looks for
/// startup.nsh next to Shell.efi, and that script finds DATA and changes
/// to DATA\Utilities\UEFI Shell\Tools.
pub const command_line = "Shell.efi -delay 0";
const load_options = std.unicode.utf8ToUtf16LeStringLiteral(command_line);

pub const Outcome = struct {
    /// False when the NTFS driver could not be started: the Shell still
    /// runs, but only FAT file systems (the ESP) are mapped.
    data_driver: bool,
};

/// Starts the Shell and returns once the user types `exit`.
pub fn run(root: *uefi.protocol.File) !Outcome {
    var data_driver = true;
    ntfs_driver.loadAndConnect(root) catch |err| {
        data_driver = false;
        serial.writeAscii("[UEFI_SHELL] NTFS driver not started: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
    };
    serial.writeAscii(if (data_driver) "[UEFI_SHELL] NTFS driver connected; starting Shell.efi\n" else "[UEFI_SHELL] starting Shell.efi without DATA\n");
    publishSecureBoot(secure_boot.enforced());
    const image = try esp_image_start.load(root, image_path);
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    if (boot_services.handleProtocol(uefi.protocol.LoadedImage, image) catch null) |loaded| {
        loaded.load_options = @ptrCast(@constCast(load_options.ptr));
        loaded.load_options_size = @intCast(load_options.len * 2);
    }
    if (uefi.system_table.con_out) |out| {
        out.clearScreen() catch {};
        out.enableCursor(true) catch {};
    }
    const code = verified_image.start(image) catch |err| {
        hideCursor();
        return err;
    };
    hideCursor();
    // `exit` returns success; an explicit `exit <code>` is not an error for
    // the menu either, only a failure to start is.
    _ = code;
    return .{ .data_driver = data_driver };
}

/// gShellVariableGuid: the Shell imports every UEFI variable of this GUID as
/// an environment variable when it starts.
const shell_variable_guid = uefi.Guid{
    .time_low = 0x158def5a,
    .time_mid = 0xf656,
    .time_high_and_version = 0x419c,
    .clock_seq_high_and_reserved = 0xb0,
    .clock_seq_low = 0x27,
    .node = .{ 0x7a, 0x31, 0x92, 0xc0, 0x79, 0xd2 },
};
const secure_boot_variable = std.unicode.utf8ToUtf16LeStringLiteral("usossecureboot");
const value_on = std.unicode.utf8ToUtf16LeStringLiteral("on");
const value_off = std.unicode.utf8ToUtf16LeStringLiteral("off");

/// Volatile Shell variable %usossecureboot% (on/off) for startup.nsh: with
/// Secure Boot on, shim 16 owns gBS->LoadImage and the Shell refuses every
/// image it loads through it ("The image is not an application"), so the
/// script tells the user before they try a tool.
fn publishSecureBoot(on: bool) void {
    const value = if (on) value_on else value_off;
    const bytes = std.mem.sliceAsBytes(value.ptr[0 .. value.len + 1]);
    uefi.system_table.runtime_services.setVariable(secure_boot_variable, &shell_variable_guid, .{ .bootservice_access = true }, bytes) catch {};
}

fn hideCursor() void {
    if (uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
}

test "Shell command line skips the startup.nsh countdown" {
    try std.testing.expectEqualStrings("Shell.efi", command_line[0..std.mem.indexOfScalar(u8, command_line, ' ').?]);
    try std.testing.expect(std.mem.endsWith(u8, command_line, " -delay 0"));
    try std.testing.expectEqual(command_line.len, load_options.len);
    try std.testing.expectEqual(@as(u16, 0), load_options[load_options.len]);
}

test "Shell image lives in the ESP shell folder the release stages" {
    try std.testing.expectEqualStrings("\\EFI\\USOS\\shell\\Shell.efi", image_path);
}
