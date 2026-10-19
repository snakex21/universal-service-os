const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const esp_image = @import("esp_image_start.zig");
const usos = @import("usos");
const Stage = usos.flow.preparation_boot_progress.XpStage;
const answer_screen = usos.flow.answer_screen;

fn mark(root: *uefi.protocol.File, stage: []const u8, name: []const u8) !void {
    var data: [2048]u8 = @splat('\n');
    _ = try std.fmt.bufPrint(&data, "phase={s}\nimage={s}\n", .{ stage, name });
    const file = try root.open(wide("\\EFI\\USOS-XP\\uefi-start.txt"), .read_write_create, .{});
    defer file.close() catch {};
    try file.setPosition(0);
    if (try file.write(&data) != data.len) return error.ShortWrite;
    try file.flush();
}

/// No firmware CSM: profile xp-x86-sp3-uefi-csmwrap (experimental). The
/// micro-Linux preparation is the UEFI-CSM one plus a CSMWrap ESP on the
/// target (tools/xp_csmwrap_esp.sh). With a CSM the command line is unchanged.
fn csmwrapActive() bool {
    return !@import("secure_boot.zig").csm().likelyOn();
}

pub const lang_initrd_option = " initrd=\\EFI\\USOS\\lang.cpio";

/// The NT5 system prepared from UEFI: its micro-Linux action and OS profile
/// (src/catalog/os_profiles.zig). Windows 2000 shares the XP package.
pub const Nt5System = enum {
    windows_xp,
    windows_2000,
    /// Windows 2000 Server: the Windows 2000 action and profile; the
    /// micro-Linux takes the Server DATA folder (usos.w2k_edition=server).
    windows_2000_server,
    windows_server_2003,
    windows_xp_x64,
    /// XP Media Center Edition 2005: the XP action and profile; the
    /// micro-Linux takes the Media Center DATA folder (usos.xp_edition=mce).
    windows_xp_mce,
    /// XP Tablet PC Edition 2005: the XP action and profile; the micro-Linux
    /// takes the Tablet PC DATA folder (usos.xp_edition=tablet).
    windows_xp_tablet,
    windows_whistler,
    windows_neptune,
    windows_2000_beta,

    pub fn fromId(system_id: []const u8) ?Nt5System {
        if (std.mem.eql(u8, system_id, "windows-xp")) return .windows_xp;
        if (std.mem.eql(u8, system_id, "windows-2000")) return .windows_2000;
        if (std.mem.eql(u8, system_id, "windows-2000-server")) return .windows_2000_server;
        if (std.mem.eql(u8, system_id, "windows-server-2003")) return .windows_server_2003;
        if (std.mem.eql(u8, system_id, "windows-xp-x64")) return .windows_xp_x64;
        if (std.mem.eql(u8, system_id, "windows-xp-mce")) return .windows_xp_mce;
        if (std.mem.eql(u8, system_id, "windows-xp-tablet")) return .windows_xp_tablet;
        if (std.mem.eql(u8, system_id, "windows-whistler")) return .windows_whistler;
        if (std.mem.eql(u8, system_id, "windows-neptune")) return .windows_neptune;
        if (std.mem.eql(u8, system_id, "windows-2000-beta")) return .windows_2000_beta;
        return null;
    }

    pub fn action(self: Nt5System) []const u8 {
        return switch (self) {
            .windows_xp, .windows_xp_mce, .windows_xp_tablet, .windows_whistler => "xp-staging",
            .windows_2000, .windows_2000_server, .windows_neptune, .windows_2000_beta => "windows2000-staging",
            .windows_server_2003 => "windows2003-staging",
            .windows_xp_x64 => "xp64-staging",
        };
    }

    pub fn planProfile(self: Nt5System) []const u8 {
        return switch (self) {
            .windows_xp, .windows_xp_mce, .windows_xp_tablet, .windows_whistler => "xp-x86-sp3-uefi-csm",
            .windows_2000, .windows_2000_server, .windows_neptune, .windows_2000_beta => "w2k-x86-sp4-uefi-csm",
            .windows_server_2003 => "w2k3-x86-sp2-uefi-csm",
            .windows_xp_x64 => "xp-x64-sp2-uefi-csm",
        };
    }

    /// Extra micro-Linux argument: the edition whose DATA folder is used.
    pub fn editionOption(self: Nt5System) []const u8 {
        return switch (self) {
            .windows_2000_server => " usos.w2k_edition=server",
            .windows_xp_mce => " usos.xp_edition=mce",
            .windows_xp_tablet => " usos.xp_edition=tablet",
            .windows_whistler => " usos.nt5_variant=whistler",
            .windows_neptune => " usos.nt5_variant=neptune",
            .windows_2000_beta => " usos.nt5_variant=w2k-beta",
            else => "",
        };
    }

    /// Answer-profile architecture of the staged system.
    pub fn arch(self: Nt5System) usos.flow.answer.target.Arch {
        return if (self == .windows_xp_x64) .amd64 else .x86;
    }
};

pub const CommandParts = struct {
    system: Nt5System = .windows_xp,
    /// lang_initrd_option, or "" on installs from before lang.cpio.
    lang_initrd: []const u8,
    esp_partuuid: []const u8,
    image_hex: []const u8,
    answer_option: []const u8 = "",
    settings_option: []const u8 = "",
    csmwrap: bool = false,
    /// usos.theme= of the menu theme (src/gui/theme_cmdline.zig), or "".
    theme_option: []const u8 = "",
    console_options: []const u8 = "",
};

/// The kernel command line of the XP preparation. CSMWrap mode only adds
/// usos.xp_boot=csmwrap: the language (lang.cpio) and everything else are
/// the default path's.
pub fn formatCommand(buffer: []u8, parts: CommandParts) ![]const u8 {
    return std.fmt.bufPrint(buffer, "initrd=\\EFI\\USOS-XP\\initramfs-xp{s} rdinit=/usos-init usos.esp_partuuid={s} usos.legacy_action={s} usos.legacy_image_hex={s}{s}{s} usos.plan_profile={s}{s}{s}{s} {s}", .{ parts.lang_initrd, parts.esp_partuuid, parts.system.action(), parts.image_hex, parts.answer_option, parts.settings_option, parts.system.planProfile(), parts.system.editionOption(), if (parts.csmwrap) " usos.xp_boot=csmwrap" else "", parts.theme_option, parts.console_options });
}

/// `answer`: the answer-file screen's choice (src/flow/answer_screen.zig):
/// a .sif (usos.legacy_unattended_hex=) or the manual installation
/// (usos.xp_settings=off: the staging ignores usos-xp.ini).
pub fn start(root: *uefi.protocol.File, system_id: []const u8, name: []const u8, answer: answer_screen.Choice, progress: *const fn (Stage) void) !void {
    const system = Nt5System.fromId(system_id) orelse return error.UnsupportedNt5System;
    var answer_buffer: [300]u8 = undefined;
    const answer_option = try answer_screen.xpAnswerOption(&answer_buffer, answer.path);
    const settings_option = answer_screen.xpSettingsOption(answer);
    if (name.len == 0 or name.len > 512 or std.mem.indexOfAny(u8, name, "\\/\r\n") != null) return error.InvalidXpImageName;
    // Require the isolated payload before creating any diagnostics.
    const initrd = try root.open(wide("\\EFI\\USOS-XP\\initramfs-xp"), .read, .{});
    try initrd.close();
    try mark(root, "uefi-entry", name);
    const config = try root.open(wide("\\EFI\\USOS\\usos-device.ini"), .read, .{});
    defer config.close() catch {};
    var bytes: [4096]u8 = undefined;
    const used = try config.read(&bytes);
    var lines = std.mem.splitScalar(u8, bytes[0..used], '\n');
    var uuid: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "esp_partuuid=")) uuid = line[13..];
    }
    const id = uuid orelse return error.EspIdentityMissing;
    if (id.len != 36) return error.InvalidEspIdentity;
    for (id, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return error.InvalidEspIdentity;
        } else if (!std.ascii.isHex(c)) return error.InvalidEspIdentity;
    }
    var hex: [1024]u8 = undefined;
    for (name, 0..) |c, i| {
        hex[i * 2] = "0123456789abcdef"[c >> 4];
        hex[i * 2 + 1] = "0123456789abcdef"[c & 15];
    }
    var cmd: [2048]u8 = undefined;
    const diagnostic = @import("diagnostic_boot.zig");
    // lang.cpio (written by the installer) gives usos-fb-ui the chosen
    // language; installs from before it existed boot without it.
    const lang_initrd = if (root.open(wide("\\EFI\\USOS\\lang.cpio"), .read, .{})) |file| blk: {
        file.close() catch {};
        break :blk lang_initrd_option;
    } else |_| "";
    // usos-fb-ui keeps the menu theme (src/gui/theme_cmdline.zig).
    var theme_buffer: [usos.gui.theme_cmdline.option_len]u8 = undefined;
    const command = try formatCommand(&cmd, .{
        .system = system,
        .theme_option = usos.gui.theme_cmdline.option(&theme_buffer, @import("manual_view.zig").currentTheme()),
        .lang_initrd = lang_initrd,
        .esp_partuuid = id,
        .image_hex = hex[0 .. name.len * 2],
        .answer_option = answer_option,
        .settings_option = settings_option,
        .csmwrap = csmwrapActive(),
        .console_options = diagnostic.xpConsoleOptions(diagnostic.requested(root)),
    });
    // Serial trace of the handover (QEMU tests read it; no secrets in it).
    const serial = @import("serial.zig");
    serial.writeAscii("[XP_CMDLINE] ");
    serial.writeAscii(command);
    serial.writeAscii("\n");
    var options: [2049]u16 = @splat(0);
    for (command, 0..) |c, i| options[i] = c;
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    try bs.setWatchdogTimer(0, 0, null);
    progress(.loading);
    const image = try esp_image.load(root, "\\EFI\\USOS-XP\\vmlinuz.efi");
    defer _ = bs.unloadImage(image) catch .load_error;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, image)) orelse return error.NoLoadedImage;
    loaded.load_options = &options;
    loaded.load_options_size = @intCast((command.len + 1) * 2);
    // Initrd is loaded by the kernel's EFI stub, not by LoadImage above.
    try mark(root, "kernel-loaded-before-start", name);
    progress(.starting);
    const code = @import("verified_image.zig").start(image) catch |err| {
        mark(root, @errorName(err), name) catch {};
        return err;
    };
    try mark(root, "kernel-returned", name);
    if (code != .success) return error.XpKernelReturnedError;
    return error.XpKernelReturned;
}

test "CSMWrap command line keeps the default XP path's language initrd" {
    var default_buffer: [2048]u8 = undefined;
    var csmwrap_buffer: [2048]u8 = undefined;
    const parts = CommandParts{
        .lang_initrd = lang_initrd_option,
        .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5",
        .image_hex = "706c5f78702e69736f",
        .settings_option = " usos.xp_settings=off",
        .console_options = "quiet",
    };
    var with_csmwrap = parts;
    with_csmwrap.csmwrap = true;
    const default_command = try formatCommand(&default_buffer, parts);
    const csmwrap_command = try formatCommand(&csmwrap_buffer, with_csmwrap);
    const initrds = "initrd=\\EFI\\USOS-XP\\initramfs-xp initrd=\\EFI\\USOS\\lang.cpio ";
    try std.testing.expect(std.mem.startsWith(u8, default_command, initrds));
    try std.testing.expect(std.mem.startsWith(u8, csmwrap_command, initrds));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, csmwrap_command, "lang.cpio"));
    try std.testing.expect(std.mem.indexOf(u8, default_command, "usos.xp_boot") == null);
    // The only difference is the CSMWrap token.
    const token = " usos.xp_boot=csmwrap";
    const at = std.mem.indexOf(u8, csmwrap_command, token) orelse return error.TestUnexpectedResult;
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..at], csmwrap_command[0..at]);
    const rest = csmwrap_command[at + token.len ..];
    @memcpy(joined[at .. at + rest.len], rest);
    try std.testing.expectEqualStrings(default_command, joined[0 .. at + rest.len]);
}

test "Windows 2000 from UEFI keeps the XP command line except its action and profile" {
    var xp_buffer: [2048]u8 = undefined;
    var w2k_buffer: [2048]u8 = undefined;
    const xp = try formatCommand(&xp_buffer, .{ .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "77326b2e69736f", .csmwrap = true });
    const w2k = try formatCommand(&w2k_buffer, .{ .system = .windows_2000, .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "77326b2e69736f", .csmwrap = true });
    try std.testing.expect(std.mem.indexOf(u8, w2k, " usos.legacy_action=windows2000-staging ") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2k, " usos.plan_profile=w2k-x86-sp4-uefi-csm usos.xp_boot=csmwrap ") != null);
    try std.testing.expect(std.mem.startsWith(u8, w2k, "initrd=\\EFI\\USOS-XP\\initramfs-xp initrd=\\EFI\\USOS\\lang.cpio "));
    try std.testing.expectEqual(@as(?Nt5System, .windows_2000), Nt5System.fromId("windows-2000"));
    try std.testing.expect(Nt5System.fromId("windows-7") == null);
    try std.testing.expect(std.mem.indexOf(u8, xp, " usos.legacy_action=xp-staging ") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2k, "usos.w2k_edition") == null);
}

test "Windows 2000 Server: the 2000 action and profile plus the Server DATA folder" {
    var w2k_buffer: [2048]u8 = undefined;
    var server_buffer: [2048]u8 = undefined;
    const common = CommandParts{ .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "77326b2e69736f", .csmwrap = true };
    var w2k_parts = common;
    w2k_parts.system = .windows_2000;
    var server_parts = common;
    server_parts.system = Nt5System.fromId("windows-2000-server").?;
    const w2k = try formatCommand(&w2k_buffer, w2k_parts);
    const server = try formatCommand(&server_buffer, server_parts);
    try std.testing.expect(std.mem.indexOf(u8, server, " usos.legacy_action=windows2000-staging ") != null);
    try std.testing.expect(std.mem.indexOf(u8, server, " usos.plan_profile=w2k-x86-sp4-uefi-csm usos.w2k_edition=server usos.xp_boot=csmwrap ") != null);
    // Only the edition token differs.
    const token = " usos.w2k_edition=server";
    const at = std.mem.indexOf(u8, server, token).?;
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..at], server[0..at]);
    const rest = server[at + token.len ..];
    @memcpy(joined[at .. at + rest.len], rest);
    try std.testing.expectEqualStrings(w2k, joined[0 .. at + rest.len]);
}

test "XP Media Center Edition: the XP action and profile plus its DATA folder" {
    var xp_buffer: [2048]u8 = undefined;
    var mce_buffer: [2048]u8 = undefined;
    const common = CommandParts{ .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "6d63652e69736f", .csmwrap = true };
    var xp_parts = common;
    xp_parts.system = .windows_xp;
    var mce_parts = common;
    mce_parts.system = Nt5System.fromId("windows-xp-mce").?;
    const xp = try formatCommand(&xp_buffer, xp_parts);
    const mce = try formatCommand(&mce_buffer, mce_parts);
    try std.testing.expect(std.mem.indexOf(u8, mce, " usos.legacy_action=xp-staging ") != null);
    try std.testing.expect(std.mem.indexOf(u8, mce, " usos.plan_profile=xp-x86-sp3-uefi-csm usos.xp_edition=mce usos.xp_boot=csmwrap ") != null);
    try std.testing.expect(std.mem.indexOf(u8, xp, "usos.xp_edition") == null);
    try std.testing.expectEqual(usos.flow.answer.target.Arch.x86, mce_parts.system.arch());
    // Only the edition token differs.
    const token = " usos.xp_edition=mce";
    const at = std.mem.indexOf(u8, mce, token).?;
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..at], mce[0..at]);
    const rest = mce[at + token.len ..];
    @memcpy(joined[at .. at + rest.len], rest);
    try std.testing.expectEqualStrings(xp, joined[0 .. at + rest.len]);
}

test "XP Tablet PC Edition: the XP action and profile plus its DATA folder" {
    var xp_buffer: [2048]u8 = undefined;
    var tablet_buffer: [2048]u8 = undefined;
    const common = CommandParts{ .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "7470632e69736f", .csmwrap = true };
    var xp_parts = common;
    xp_parts.system = .windows_xp;
    var tablet_parts = common;
    tablet_parts.system = Nt5System.fromId("windows-xp-tablet").?;
    const xp = try formatCommand(&xp_buffer, xp_parts);
    const tablet = try formatCommand(&tablet_buffer, tablet_parts);
    try std.testing.expect(std.mem.indexOf(u8, tablet, " usos.legacy_action=xp-staging ") != null);
    try std.testing.expect(std.mem.indexOf(u8, tablet, " usos.plan_profile=xp-x86-sp3-uefi-csm usos.xp_edition=tablet usos.xp_boot=csmwrap ") != null);
    try std.testing.expectEqual(usos.flow.answer.target.Arch.x86, tablet_parts.system.arch());
    // Only the edition token differs.
    const token = " usos.xp_edition=tablet";
    const at = std.mem.indexOf(u8, tablet, token).?;
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..at], tablet[0..at]);
    const rest = tablet[at + token.len ..];
    @memcpy(joined[at .. at + rest.len], rest);
    try std.testing.expectEqualStrings(xp, joined[0 .. at + rest.len]);
}

test "the menu theme reaches the NT5 micro-Linux command line" {
    const theme_cmdline = usos.gui.theme_cmdline;
    const outcome = usos.gui.theme_file.resolve("base=dark\nbackground=#15100d\nheader=#1d1612\naccent=#ff9e40\n");
    try std.testing.expect(outcome.ok());
    const sunset = outcome.theme;
    var theme_buffer: [theme_cmdline.option_len]u8 = undefined;
    for ([_]Nt5System{ .windows_xp, .windows_2000, .windows_2000_server, .windows_server_2003, .windows_xp_x64, .windows_xp_mce, .windows_xp_tablet }) |system| {
        for ([_]bool{ false, true }) |csmwrap| {
            var buffer: [2048]u8 = undefined;
            const command = try formatCommand(&buffer, .{ .system = system, .lang_initrd = lang_initrd_option, .esp_partuuid = "0257E175-1685-4311-91AA-5A83D8EB41E5", .image_hex = "77326b2e69736f", .csmwrap = csmwrap, .theme_option = theme_cmdline.option(&theme_buffer, sunset), .console_options = "quiet" });
            try std.testing.expectEqualDeep(sunset, theme_cmdline.fromCmdline(command));
            try std.testing.expect(std.mem.endsWith(u8, command, " quiet"));
        }
    }
    // The default theme adds nothing (the command line is unchanged).
    try std.testing.expectEqualStrings("", theme_cmdline.option(&theme_buffer, .{}));
}
