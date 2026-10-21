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

pub const Mode = enum {
    /// vista-uefi-disk: fresh GPT (ESP + MSR) for the UEFI Vista install.
    disk,
    /// vista-x64-sp2-uefi-csmwrap: no firmware CSM; PE10 staging partition
    /// and CSMWrap ESP on an MBR disk (tools/vista_csmwrap_prepare.sh), from
    /// the request windows_native_iso.prepareCsmwrap wrote.
    csmwrap,
    /// w9x-uefi-csmwrap: Windows 95/98/Me Setup disk with a CSMWrap ESP
    /// (tools/w9x_csmwrap_prepare.sh), from win9x_preparation's request.
    win9x,

    fn tokens(self: Mode) []const u8 {
        return switch (self) {
            .disk => "usos.legacy_action=vista-disk usos.plan_profile=vista-uefi-disk",
            .csmwrap => "usos.legacy_action=vista-csmwrap usos.plan_profile=vista-x64-sp2-uefi-csmwrap",
            .win9x => "usos.legacy_action=w9x-csmwrap usos.plan_profile=w9x-uefi-csmwrap",
        };
    }
};

/// Console options of the vista-disk start (pinned byte-for-byte by a test).
const disk_console = "quiet loglevel=3 vt.global_cursor_default=0";

/// The base micro-Linux command line of a Vista preparation. `verbose` (the
/// USOS diagnostic flag) matters only for the CSMWrap mode: it uses the XP
/// preparation's console options (/dev/console on serial, printk limited to
/// emergencies, no VT cursor), so no script, tool or kernel text reaches the
/// usos-fb-ui screens; the vista-disk line is unchanged.
/// `theme_option`: usos.theme= of the menu theme (src/gui/theme_cmdline.zig)
/// or "".
pub fn formatCommand(buffer: []u8, lang_initrd: []const u8, esp_partuuid: []const u8, mode: Mode, verbose: bool, theme_option: []const u8) ![]const u8 {
    const console = switch (mode) {
        .disk => disk_console,
        .csmwrap, .win9x => @import("usos").flow.boot_console.xpConsoleOptions(verbose),
    };
    return std.fmt.bufPrint(buffer, "initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos{s} rdinit=/usos-init {s} usos.esp_partuuid={s} {s}{s}", .{ lang_initrd, console, esp_partuuid, mode.tokens(), theme_option });
}

/// The optional Windows 9x phase-1 VM initrd (build_micro_linux.py qemu9x.cpio).
pub const win9x_vm_initrd = " initrd=\\EFI\\USOS\\micro-linux\\qemu9x.cpio";

pub fn start(root: *uefi.protocol.File) !void {
    return startMode(root, .disk, "");
}

pub fn startCsmwrap(root: *uefi.protocol.File) !void {
    return startMode(root, .csmwrap, "");
}

/// The same step 610 for 32-bit Windows 8.1 / 10 (request.ini names
/// win-x86-uefi-csmwrap); `heading`: the DATA folder for the progress page.
pub fn startCsmwrapHeading(root: *uefi.protocol.File, heading: []const u8) !void {
    return startMode(root, .csmwrap, heading);
}

/// Windows 95/98/Me and the DOS family (step 620): the same base micro-Linux
/// start. `heading`: the system's name for the micro-Linux progress page.
pub fn startWin9x(root: *uefi.protocol.File, heading: []const u8) !void {
    return startMode(root, .win9x, heading);
}

/// The longest heading token; a longer name is left out (the page then
/// keeps its generic heading until the request is read).
const heading_max = 64;
pub const heading_option_len = " usos.heading=".len + heading_max;

/// " usos.heading=<name>" for the micro-Linux progress page
/// (tools/micro_linux_ui.sh turns '_' back into spaces), so its first frame
/// already names the chosen system (Windows 3.0, not "Windows 9x"). Empty
/// when the name is empty, too long or has a byte a kernel command line
/// cannot carry.
pub fn headingOption(buffer: []u8, name: []const u8) []const u8 {
    const prefix = " usos.heading=";
    if (name.len == 0 or name.len > heading_max or buffer.len < prefix.len + name.len) return "";
    @memcpy(buffer[0..prefix.len], prefix);
    for (name, 0..) |c, i| {
        if (c == '_' or c == '"' or c == '\\' or c < ' ' or c > '~') return "";
        buffer[prefix.len + i] = if (c == ' ') '_' else c;
    }
    return buffer[0 .. prefix.len + name.len];
}

fn startMode(root: *uefi.protocol.File, mode: Mode, heading: []const u8) !void {
    var id: [36]u8 = undefined;
    try espPartuuid(root, &id);
    const lang_initrd = if (root.open(wide("\\EFI\\USOS\\lang.cpio"), .read, .{})) |file| blk: {
        file.close() catch {};
        break :blk " initrd=\\EFI\\USOS\\lang.cpio";
    } else |_| "";
    // Windows 98 Setup phase 1 in a VM (tools/w9x_phase1_qemu.sh): QEMU and
    // KVM come as a second initrd, only on this command line and only when
    // the installer wrote it (else step 620 keeps the native Setup start).
    const qemu_initrd = if (mode == .win9x) if (root.open(wide("\\EFI\\USOS\\micro-linux\\qemu9x.cpio"), .read, .{})) |file| blk: {
        file.close() catch {};
        break :blk win9x_vm_initrd;
    } else |_| "" else "";
    var initrd_buffer: [win9x_vm_initrd.len + 32]u8 = undefined;
    const initrds = try std.fmt.bufPrint(&initrd_buffer, "{s}{s}", .{ qemu_initrd, lang_initrd });
    var cmd: [1024]u8 = undefined;
    var theme_buffer: [@import("usos").gui.theme_cmdline.option_len]u8 = undefined;
    const theme_option = @import("usos").gui.theme_cmdline.option(&theme_buffer, @import("manual_view.zig").currentTheme());
    var heading_buffer: [heading_option_len]u8 = undefined;
    var tail_buffer: [theme_buffer.len + heading_option_len]u8 = undefined;
    const tail = try std.fmt.bufPrint(&tail_buffer, "{s}{s}", .{ theme_option, headingOption(&heading_buffer, heading) });
    const command = try formatCommand(&cmd, initrds, &id, mode, mode != .disk and @import("diagnostic_boot.zig").requested(root), tail);
    const serial = @import("serial.zig");
    serial.writeAscii(switch (mode) {
        .csmwrap => "[VISTA_CSMWRAP_CMDLINE] ",
        .win9x => "[W9X_CSMWRAP_CMDLINE] ",
        .disk => "[VISTA_DISK_CMDLINE] ",
    });
    serial.writeAscii(command);
    serial.writeAscii("\n");
    var options: [1025]u16 = @splat(0);
    for (command, 0..) |c, i| options[i] = c;
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    try bs.setWatchdogTimer(0, 0, null);
    // The monitor's native size for USOSRES (docs/display-policy.md).
    @import("display_native.zig").record(root);
    const image = try esp_image.load(root, "\\EFI\\USOS\\micro-linux\\vmlinuz-virt");
    defer _ = bs.unloadImage(image) catch .load_error;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, image)) orelse return error.NoLoadedImage;
    loaded.load_options = &options;
    loaded.load_options_size = @intCast((command.len + 1) * 2);
    const code = try @import("verified_image.zig").start(image);
    if (code != .success) return error.VistaDiskKernelReturnedError;
    return error.VistaDiskKernelReturned;
}

test "Vista disk preparation command line is unchanged; CSMWrap keeps its console off the screen" {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    const id = "0257E175-1685-4311-91AA-5A83D8EB41E5";
    const disk = try formatCommand(&a, " initrd=\\EFI\\USOS\\lang.cpio", id, .disk, true, "");
    try std.testing.expectEqualStrings("initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos initrd=\\EFI\\USOS\\lang.cpio rdinit=/usos-init quiet loglevel=3 vt.global_cursor_default=0 usos.esp_partuuid=0257E175-1685-4311-91AA-5A83D8EB41E5 usos.legacy_action=vista-disk usos.plan_profile=vista-uefi-disk", disk);
    const csmwrap = try formatCommand(&b, "", id, .csmwrap, false, "");
    try std.testing.expect(std.mem.endsWith(u8, csmwrap, " usos.legacy_action=vista-csmwrap usos.plan_profile=vista-x64-sp2-uefi-csmwrap"));
    // Quiet: /dev/console is the LAST console= (serial), printk emergencies only.
    try std.testing.expectEqualStrings("initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos rdinit=/usos-init console=tty0 console=ttyS0,115200n8 rw quiet loglevel=1 vt.global_cursor_default=0 usos.esp_partuuid=0257E175-1685-4311-91AA-5A83D8EB41E5 usos.legacy_action=vista-csmwrap usos.plan_profile=vista-x64-sp2-uefi-csmwrap", csmwrap);
    var c: [1024]u8 = undefined;
    const verbose = try formatCommand(&c, "", id, .csmwrap, true, "");
    try std.testing.expect(std.mem.indexOf(u8, verbose, " quiet ") == null);
}

test "Windows 9x: the phase-1 VM initrd follows the base initramfs, before the language" {
    var a: [1024]u8 = undefined;
    const command = try formatCommand(&a, win9x_vm_initrd ++ " initrd=\\EFI\\USOS\\lang.cpio", "0257E175-1685-4311-91AA-5A83D8EB41E5", .win9x, false, "");
    try std.testing.expect(std.mem.startsWith(u8, command, "initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos initrd=\\EFI\\USOS\\micro-linux\\qemu9x.cpio initrd=\\EFI\\USOS\\lang.cpio rdinit=/usos-init "));
    try std.testing.expect(std.mem.endsWith(u8, command, " usos.legacy_action=w9x-csmwrap usos.plan_profile=w9x-uefi-csmwrap"));
}

test "the menu theme reaches the Vista micro-Linux command line" {
    const usos = @import("usos");
    const theme_cmdline = usos.gui.theme_cmdline;
    const retro = usos.gui.theme_presets.find("retro").?;
    var theme_buffer: [theme_cmdline.option_len]u8 = undefined;
    for ([_]Mode{ .disk, .csmwrap }) |mode| {
        var buffer: [1024]u8 = undefined;
        const command = try formatCommand(&buffer, "", "0257E175-1685-4311-91AA-5A83D8EB41E5", mode, false, theme_cmdline.option(&theme_buffer, retro));
        try std.testing.expectEqualDeep(retro, theme_cmdline.fromCmdline(command));
    }
}

test "Windows 9x / DOS family heading token: spaces become '_', unsafe names are left out" {
    var buffer: [heading_option_len]u8 = undefined;
    try std.testing.expectEqualStrings(" usos.heading=Windows_for_Workgroups_3.11", headingOption(&buffer, "Windows for Workgroups 3.11"));
    try std.testing.expectEqualStrings(" usos.heading=Windows_2.11_(386)", headingOption(&buffer, "Windows 2.11 (386)"));
    try std.testing.expectEqualStrings("", headingOption(&buffer, ""));
    try std.testing.expectEqualStrings("", headingOption(&buffer, "a_b"));
    try std.testing.expectEqualStrings("", headingOption(&buffer, "Windows \"3\""));
    try std.testing.expectEqualStrings("", headingOption(&buffer, "x" ** (heading_max + 1)));
}
