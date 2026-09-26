//! usos-plan.ini: how the UEFI menu hands the chosen answer to the
//! preparation (docs/answer-profiles.md, refactor M5).
//!
//! The menu renders the answer just in time and writes both files to the
//! ESP (\EFI\USOS\answer\), which the micro-Linux mounts read-write:
//!
//!   usos-plan.ini            [plan] profile/system, [answer] source, format,
//!                            file (ESP-relative), architecture, whether a
//!                            key is inside (never the key itself)
//!   nt5-settings.ini         NT5: read by the XP staging (kernel option
//!                            usos.xp_settings=plan), merged into WINNT.SIF
//!   autounattend.xml         6.x+ via WORK: copied as WORK:\Autounattend.xml
//!                            (install-state.ini answer_plan=...)
//!
//! The preparation deletes the rendered file after reading it (it may
//! carry a key or a password). The native wimboot starts (Vista/7, 10/11
//! from DATA) put the rendered XML straight into the RAM disk as
//! usos-unattend.xml together with a copy of usos-plan.ini.
const std = @import("std");
const Arch = @import("target.zig").Arch;

pub const directory = "\\EFI\\USOS\\answer";
pub const plan_path = "\\EFI\\USOS\\answer\\usos-plan.ini";
/// ESP-relative, forward slashes (as the micro-Linux sees /mnt/esp/...).
pub const plan_path_posix = "EFI/USOS/answer/usos-plan.ini";

pub const Format = enum {
    nt5_settings,
    autounattend_xml,

    pub fn fileName(self: Format) []const u8 {
        return switch (self) {
            .nt5_settings => "nt5-settings.ini",
            .autounattend_xml => "autounattend.xml",
        };
    }
};

pub const Source = enum { none, file, profile };

pub const Plan = struct {
    os_profile: []const u8,
    system_id: []const u8,
    source: Source,
    /// Answer profile name (source=profile) or the Unattended file name.
    name: []const u8 = "",
    format: Format = .autounattend_xml,
    arch: ?Arch = null,
    key: bool = false,
};

pub fn filePathPosix(format: Format, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "EFI/USOS/answer/{s}", .{format.fileName()});
}

pub fn filePathEsp(format: Format, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ directory, format.fileName() });
}

pub fn write(plan: Plan, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; USOS plan, written by the boot menu for one preparation (docs/answer-profiles.md)\r\n");
    try w.print("[plan]\r\nversion=1\r\nprofile={s}\r\nsystem={s}\r\n", .{ plan.os_profile, plan.system_id });
    try w.print("[answer]\r\nsource={s}\r\n", .{@tagName(plan.source)});
    if (plan.source != .none) {
        for (plan.name) |c| if (c < 0x20 or c == 0x7f) return error.InvalidName;
        try w.print("name={s}\r\nformat={s}\r\n", .{ plan.name, @tagName(plan.format) });
        if (plan.source == .profile) {
            var path: [64]u8 = undefined;
            try w.print("file={s}\r\n", .{try filePathPosix(plan.format, &path)});
        }
        if (plan.arch) |arch| try w.print("arch={s}\r\n", .{@tagName(arch)});
        try w.print("key={s}\r\n", .{if (plan.key) "yes" else "no"});
    }
    return w.buffered();
}

test "plan file carries the profile, never the key" {
    var buffer: [512]u8 = undefined;
    const text = try write(.{ .os_profile = "xp-x86-sp3-uefi-csm", .system_id = "windows-xp", .source = .profile, .name = "Dom", .format = .nt5_settings, .arch = .x86, .key = true }, &buffer);
    try std.testing.expectEqualStrings(
        "; USOS plan, written by the boot menu for one preparation (docs/answer-profiles.md)\r\n[plan]\r\nversion=1\r\nprofile=xp-x86-sp3-uefi-csm\r\nsystem=windows-xp\r\n[answer]\r\nsource=profile\r\nname=Dom\r\nformat=nt5_settings\r\nfile=EFI/USOS/answer/nt5-settings.ini\r\narch=x86\r\nkey=yes\r\n",
        text,
    );
    const none = try write(.{ .os_profile = "windows-work", .system_id = "windows-10", .source = .none }, &buffer);
    try std.testing.expect(std.mem.endsWith(u8, none, "[answer]\r\nsource=none\r\n"));
}
