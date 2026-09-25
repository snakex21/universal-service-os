const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const esp_image = @import("esp_image_start.zig");
const Stage = @import("usos").flow.preparation_boot_progress.XpStage;

fn mark(root: *uefi.protocol.File, stage: []const u8, name: []const u8) !void {
    var data: [2048]u8 = @splat('\n');
    _ = try std.fmt.bufPrint(&data, "phase={s}\nimage={s}\n", .{ stage, name });
    const file = try root.open(wide("\\EFI\\USOS-XP\\uefi-start.txt"), .read_write_create, .{});
    defer file.close() catch {};
    try file.setPosition(0);
    if (try file.write(&data) != data.len) return error.ShortWrite;
    try file.flush();
}

/// `usos.legacy_unattended_hex=` for a .sif chosen on the answer screen: the
/// staging merges it into the automatic answer (tools/xp_user_settings.sh).
pub fn unattendedOption(buffer: []u8, unattended: ?[]const u8) ![]const u8 {
    const answer = unattended orelse return "";
    if (answer.len == 0 or answer.len > 120 or std.mem.indexOfAny(u8, answer, "\\/\r\n\"") != null) return error.InvalidXpAnswerName;
    if (answer.len < 4 or !std.ascii.eqlIgnoreCase(answer[answer.len - 4 ..], ".sif")) return error.InvalidXpAnswerName;
    const prefix = " usos.legacy_unattended_hex=";
    if (buffer.len < prefix.len + answer.len * 2) return error.InvalidXpAnswerName;
    @memcpy(buffer[0..prefix.len], prefix);
    for (answer, 0..) |c, i| {
        buffer[prefix.len + i * 2] = "0123456789abcdef"[c >> 4];
        buffer[prefix.len + i * 2 + 1] = "0123456789abcdef"[c & 15];
    }
    return buffer[0 .. prefix.len + answer.len * 2];
}

test "XP answer option carries only a .sif file name" {
    var buffer: [300]u8 = undefined;
    try std.testing.expectEqualStrings("", try unattendedOption(&buffer, null));
    try std.testing.expectEqualStrings(" usos.legacy_unattended_hex=612e534946", try unattendedOption(&buffer, "a.SIF"));
    try std.testing.expectError(error.InvalidXpAnswerName, unattendedOption(&buffer, "a.xml"));
    try std.testing.expectError(error.InvalidXpAnswerName, unattendedOption(&buffer, "dir\\a.sif"));
    try std.testing.expectEqualStrings(" usos.legacy_unattended_hex=6d7920612e736966", try unattendedOption(&buffer, "my a.sif"));
}

pub fn start(root: *uefi.protocol.File, name: []const u8, unattended: ?[]const u8, progress: *const fn (Stage) void) !void {
    var answer_buffer: [300]u8 = undefined;
    const answer_option = try unattendedOption(&answer_buffer, unattended);
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
        break :blk " initrd=\\EFI\\USOS\\lang.cpio";
    } else |_| "";
    const command = try std.fmt.bufPrint(&cmd, "initrd=\\EFI\\USOS-XP\\initramfs-xp{s} rdinit=/usos-init usos.esp_partuuid={s} usos.legacy_action=xp-staging usos.legacy_image_hex={s}{s} usos.plan_profile=xp-x86-sp3-uefi-csm {s}", .{ lang_initrd, id, hex[0 .. name.len * 2], answer_option, diagnostic.xpConsoleOptions(diagnostic.requested(root)) });
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
