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

    fn tokens(self: Mode) []const u8 {
        return switch (self) {
            .disk => "usos.legacy_action=vista-disk usos.plan_profile=vista-uefi-disk",
            .csmwrap => "usos.legacy_action=vista-csmwrap usos.plan_profile=vista-x64-sp2-uefi-csmwrap",
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
        .csmwrap => @import("usos").flow.boot_console.xpConsoleOptions(verbose),
    };
    return std.fmt.bufPrint(buffer, "initrd=\\EFI\\USOS\\micro-linux\\initramfs-usos{s} rdinit=/usos-init {s} usos.esp_partuuid={s} {s}{s}", .{ lang_initrd, console, esp_partuuid, mode.tokens(), theme_option });
}

pub fn start(root: *uefi.protocol.File) !void {
    return startMode(root, .disk);
}

pub fn startCsmwrap(root: *uefi.protocol.File) !void {
    return startMode(root, .csmwrap);
}

fn startMode(root: *uefi.protocol.File, mode: Mode) !void {
    var id: [36]u8 = undefined;
    try espPartuuid(root, &id);
    const lang_initrd = if (root.open(wide("\\EFI\\USOS\\lang.cpio"), .read, .{})) |file| blk: {
        file.close() catch {};
        break :blk " initrd=\\EFI\\USOS\\lang.cpio";
    } else |_| "";
    var cmd: [1024]u8 = undefined;
    var theme_buffer: [@import("usos").gui.theme_cmdline.option_len]u8 = undefined;
    const theme_option = @import("usos").gui.theme_cmdline.option(&theme_buffer, @import("manual_view.zig").currentTheme());
    const command = try formatCommand(&cmd, lang_initrd, &id, mode, mode == .csmwrap and @import("diagnostic_boot.zig").requested(root), theme_option);
    const serial = @import("serial.zig");
    serial.writeAscii(if (mode == .csmwrap) "[VISTA_CSMWRAP_CMDLINE] " else "[VISTA_DISK_CMDLINE] ");
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
