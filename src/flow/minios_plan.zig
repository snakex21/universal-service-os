//! MiniOS instead of the default preparation (profile option
//! prep_env=minios): the pure decisions of src/platform/uefi/minios_start.zig,
//! host-tested.
//!
//! Routes:
//! * `.gpt_uefi`: Windows 10/11 x64 native UEFI (replaces the ISO's WinPE
//!   and Windows Setup);
//! * `.mbr_csmwrap`: 32-bit Windows 10 without CSM (win-x86-uefi-csmwrap;
//!   replaces the Alpine micro-Linux step 610 and the ISO's x86 WinPE +
//!   Setup): MBR disk, BIOS boot files, CSMWrap ESP at the end.
const std = @import("std");
const answer = @import("answer/root.zig");
const capability = @import("preparation_capability.zig");

pub const Route = enum { gpt_uefi, mbr_csmwrap };

pub fn wanted(p: ?*const answer.Profile, system_id: []const u8) bool {
    const profile = p orelse return false;
    if (profile.prep_env != .minios) return false;
    return capability.nativeModernNt(system_id);
}

/// The 32-bit CSMWrap route: Windows 10 only for now (8.1 / Embedded 8.1 and
/// the NT 6.0 / 6.1 PE10-donor route stay on Alpine).
pub fn wantedX86Csmwrap(p: ?*const answer.Profile, system_id: []const u8) bool {
    const profile = p orelse return false;
    return profile.prep_env == .minios and std.mem.eql(u8, system_id, "windows-10");
}

pub const Source = struct { disk_bytes: u64, start: u64, size: u64, serial: u64 };

/// USOSPREP_HW_V1 text, parsed by src/prep/uefi_main.zig config().
pub fn formatConfig(buffer: []u8, route: Route, token: [64]u8, index: u16, source: Source, iso_path: []const u8, build: []const u8, locale: []const u8, unattend: bool) ![]const u8 {
    for (iso_path) |c| if (c == '\r' or c == '\n' or c == 0) return error.InvalidImageName;
    if (index == 0) return error.InvalidImageIndex;
    const mode = if (route == .mbr_csmwrap) "mbr" else "gpt";
    const csmwrap = if (route == .mbr_csmwrap) "csmwrap=on\r\n" else "";
    return std.fmt.bufPrint(buffer, "USOSPREP_HW_V1\r\nmode={s}\r\ntoken={s}\r\nprofile=install\r\nwim_index={d}\r\nsource_bytes={d}\r\nsource_start={d}\r\nsource_size={d}\r\nsource_serial={x}\r\nsource_iso={s}\r\nbuild={s}\r\nlocale={s}\r\nunattend={s}\r\nboot_entry=on\r\n{s}", .{
        mode, token, index, source.disk_bytes, source.start, source.size, source.serial, iso_path, build, locale, if (unattend) "on" else "off", csmwrap,
    });
}

/// The install image MiniOS applies: the profile's edition on this ISO
/// (MiniOS has no edition list of its own).
pub fn imageIndex(p: *const answer.Profile, system_id: []const u8, images: ?*const answer.editions.List) ?u16 {
    return switch (answer.matchEdition(p, system_id, images)) {
        .found => |image| image.index,
        else => null,
    };
}

pub fn localeTag(p: *const answer.Profile) []const u8 {
    const index = p.language orelse return "en-US";
    if (index >= answer.tables.languages.len) return "en-US";
    return answer.tables.languages[index].tag;
}

test "MiniOS config matches the MiniOS hardware parser keys" {
    var buffer: [1024]u8 = undefined;
    const token: [64]u8 = @splat('a');
    const text = try formatConfig(&buffer, .gpt_uefi, token, 6, .{ .disk_bytes = 128043712512, .start = 17179869184, .size = 110863843328, .serial = 0x12345678abcdef01 }, "Systems/Windows/Windows 11/Images/Win11.iso", "B261028-200000-ABCDEF01", "pl-PL", true);
    try std.testing.expect(std.mem.startsWith(u8, text, "USOSPREP_HW_V1\r\nmode=gpt\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "wim_index=6\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "source_serial=12345678abcdef01\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unattend=on\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "target_sectors") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "csmwrap") == null);
    const mbr = try formatConfig(&buffer, .mbr_csmwrap, token, 2, .{ .disk_bytes = 1 << 40, .start = 1 << 20, .size = 1 << 30, .serial = 7 }, "Systems/Windows/Windows 10/Images/Win10 x86.iso", "B1", "pl-PL", true);
    try std.testing.expect(std.mem.startsWith(u8, mbr, "USOSPREP_HW_V1\r\nmode=mbr\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, mbr, "boot_entry=on\r\ncsmwrap=on\r\n"));
    try std.testing.expectError(error.InvalidImageName, formatConfig(&buffer, .gpt_uefi, token, 6, .{ .disk_bytes = 1, .start = 1, .size = 1, .serial = 1 }, "a\r\nmode=mbr", "B", "en-US", false));
    try std.testing.expectError(error.InvalidImageIndex, formatConfig(&buffer, .gpt_uefi, token, 0, .{ .disk_bytes = 1, .start = 1, .size = 1, .serial = 1 }, "a.iso", "B", "en-US", false));
}

test "only Windows 10/11 profiles with prep_env=minios select MiniOS" {
    var p = answer.Profile{};
    try std.testing.expect(!wanted(&p, "windows-11"));
    try std.testing.expect(!wantedX86Csmwrap(&p, "windows-10"));
    p.prep_env = .minios;
    try std.testing.expect(wanted(&p, "windows-11") and wanted(&p, "windows-10"));
    try std.testing.expect(!wanted(&p, "windows-7") and !wanted(&p, "windows-xp"));
    try std.testing.expect(!wanted(null, "windows-11"));
    // 32-bit CSMWrap route: Windows 10 only.
    try std.testing.expect(wantedX86Csmwrap(&p, "windows-10"));
    try std.testing.expect(!wantedX86Csmwrap(&p, "windows-8-1") and !wantedX86Csmwrap(&p, "windows-7") and !wantedX86Csmwrap(null, "windows-10"));
    try std.testing.expectEqualStrings("en-US", localeTag(&p));
    // No edition in the profile and more than one image: no index (Setup).
    try std.testing.expect(imageIndex(&p, "windows-11", null) == null);
}
