//! Windows NT 4.0 Workstation / Server renderer: the WINNT.SIF of the
//! winnt /b style local-source install that micro-Linux writes to the target
//! disk and runs in QEMU (tools/nt4_csmwrap_target.sh, nt4_qemu_install.sh;
//! docs/nt4-2026-10-07.md). Hands-free: no Setup page waits.
//!
//!   [Data]          MsDosInitiated / Floppyless: the local source in
//!                   C:\$WIN_NT$.~LS (a CD start with any partition on the
//!                   disk stops in setupdd.sys, QEMU 2026-10-07)
//!   [Unattended]    FAT16 C: kept, the MPS multiprocessor HAL pinned (the
//!                   X470 starts it with /NUMPROC=2), OemPreinstall=Yes so
//!                   $OEM$\CMDLINES.TXT runs (one automatic logon with
//!                   C:\USOS\NT4\POST.CMD: AHCINT, usosrst, SP6a)
//!   [UserData]      owner, organisation, computer name, ProductId (the NT4
//!                   key: OEM ddddd-OEM-ddddddd-ddddd or retail ddd-ddddddd)
//!   [GuiUnattended] blank Administrator password, time zone marker
//!   [Display]       640x480 (vga.sys)
//!
//! NT 4.0 takes the time zone as the CD's own display string (localised,
//! "(GMT+01:00) Warszawa, Praga, Budapeszt" on the Polish CD), so the
//! renderer writes ";USOS-TZ=<9x zone key>" and micro-Linux replaces it for
//! a CD language it knows (else Setup shows the time zone page).
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const msbatch = @import("msbatch.zig");

pub const file_name = "WINNT.SIF";

/// Rendered files the UEFI menu leaves for micro-Linux (\EFI\USOS\answer\<file>).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "windows-nt-4", .file = "NT4.SIF" },
    .{ .system_id = "windows-nt-4-server", .file = "NT4S.SIF" },
};

pub fn isNt4(system_id: []const u8) bool {
    for (staged) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.system_id, system_id)) return true;
    }
    return false;
}

/// The key NT 4.0 Setup takes ([UserData] ProductId): the Windows 95 shapes.
pub fn validKey(key: []const u8) bool {
    const shape = profile_mod.keyShape(key) orelse return false;
    return shape != .five_by_five;
}

fn netbiosName(source: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (source) |c| {
        if (n == out.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '-') {
            out[n] = std.ascii.toUpper(c);
            n += 1;
        }
    }
    if (n == 0) {
        const fallback = "USOS-NT4";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    return out[0..n];
}

fn quoted(w: *std.Io.Writer, value: []const u8, fallback: []const u8) !void {
    const text = if (value.len > 0) value else fallback;
    try w.writeByte('"');
    for (text) |c| try w.writeByte(if (c == '"' or c < 0x20) '\'' else c);
    try w.writeByte('"');
}

/// WINNT.SIF (CRLF). `key`: the product key to use (the profile's or one
/// typed at start); left out unless it has an NT 4.0 shape.
pub fn render(p: *const Profile, key: []const u8, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; WINNT.SIF rendered by USOS for Windows NT 4.0 (docs/nt4-2026-10-07.md)\r\n");
    try w.writeAll("[Data]\r\nMsDosInitiated = 1\r\nFloppyless = 1\r\nUnattendedInstall = \"Yes\"\r\n\r\n");
    try w.writeAll("[Unattended]\r\nOemPreinstall = Yes\r\nOemSkipEula = Yes\r\nNoWaitAfterTextMode = 1\r\nNoWaitAfterGUIMode = 1\r\n");
    try w.writeAll("FileSystem = LeaveAlone\r\nExtendOemPartition = 0\r\nConfirmHardware = No\r\nNtUpgrade = No\r\nWin31Upgrade = No\r\n");
    try w.writeAll("TargetPath = \\WINNT\r\nOverwriteOemFilesOnUpgrade = No\r\nComputerType = \"MPS Multiprocessor PC\", Retail\r\n\r\n");
    try w.writeAll("[UserData]\r\nFullName = ");
    try quoted(&w, p.user.slice(), "USOS");
    try w.writeAll("\r\nOrgName = ");
    try quoted(&w, p.org.slice(), "USOS");
    var name: [15]u8 = undefined;
    try w.print("\r\nComputerName = {s}\r\n", .{netbiosName(p.computer.slice(), &name)});
    if (validKey(key)) {
        try w.writeAll("ProductId = \"");
        for (key) |c| try w.writeByte(std.ascii.toUpper(c));
        try w.writeAll("\"\r\n");
    }
    try w.writeAll("\r\n[GuiUnattended]\r\nOemSkipWelcome = 1\r\nOEMBlankAdminPassword = 1\r\n");
    if (p.timeZone()) |zone| {
        if (msbatch.timeZoneName(zone)) |name98| try w.print(";USOS-TZ={s}\r\n", .{name98});
    }
    try w.writeAll("\r\n[Display]\r\nConfigureAtLogon = 0\r\nAutoConfirm = 1\r\nBitsPerPel = 8\r\nXResolution = 640\r\nYResolution = 480\r\nVRefresh = 60\r\n");
    return w.buffered();
}

test "NT 4.0 ids and key shapes" {
    try std.testing.expect(isNt4("windows-nt-4") and isNt4("Windows-NT-4-Server") and !isNt4("windows-2000"));
    try std.testing.expect(validKey("12345-OEM-0012345-12345") and validKey("123-4567890"));
    try std.testing.expect(!validKey("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") and !validKey(""));
}

test "NT 4.0 WINNT.SIF: local source, HAL pin, owner, key, time zone marker" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Jan Kowalski");
    try p.computer.set("pracownia_1 x");
    var buffer: [4096]u8 = undefined;
    const text = try render(&p, "12345-oem-0012345-12345", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "MsDosInitiated = 1\r\nFloppyless = 1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OemPreinstall = Yes\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ComputerType = \"MPS Multiprocessor PC\", Retail\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FullName = \"Jan Kowalski\"\r\nOrgName = \"USOS\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ComputerName = PRACOWNIA1X\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ProductId = \"12345-OEM-0012345-12345\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n\n") == null);
    // A 5x5 key is not an NT 4.0 key: Setup would reject it.
    const no_key = try render(&p, "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, no_key, "ProductId") == null);
}
