//! Windows NT 3.51 Workstation / Server renderer: the WINNT.SIF of the
//! winnt /b style local-source install that micro-Linux writes to the target
//! disk and runs in QEMU, the NT 4.0 flow with NT_MAJOR=3
//! (tools/nt4_csmwrap_target.sh, nt4_qemu_install.sh; docs/nt351-2026-10-08.md).
//!
//!   [Data]          MsDosInitiated / Floppyless: the local source in
//!                   C:\$WIN_NT$.~LS
//!   [Unattended]    express Setup, no hardware confirmation, \WINNT
//!   [GuiUnattended] no network, no application search, time zone marker
//!   [UserData]      owner, organisation, computer name ("!"-prefixed: the
//!                   GUI-mode keys of the 3.51 INITIAL.INF)
//!   empty [LicenseFilePrintData], [NetworkAdapterData], [TransportData],
//!   [DomainData]
//!
//! No product key: the 3.51 INITIAL.INF has DisplayPidDlg = NO, so nothing
//! is asked. No OemPreinstall (NT 3.51 has no CMDLINES.TXT), no HAL pin and
//! no [Display] (VGA only). micro-Linux adds [GuiUnattended]
//! !DetachedProgram (C:\USOS\NT3\USOSNT3.EXE /setup) and, for a Server CD
//! (TXTSETUP.SIF ProductType not 0), !AdvServerType and the licensing keys
//! (nt4_server_answer), and resolves ";USOS-TZ=" to "!TimeZone" for a CD
//! language it knows.
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const msbatch = @import("msbatch.zig");

pub const file_name = "WINNT.SIF";

/// Rendered files the UEFI menu leaves for micro-Linux (\EFI\USOS\answer\<file>).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "windows-nt-3-51", .file = "NT351.SIF" },
    .{ .system_id = "windows-nt-3-51-server", .file = "NT351S.SIF" },
    // NT 3.5 (docs/nt35-2026-10-09.md): the same INITIAL.INF keys, so the
    // same WINNT.SIF; micro-Linux checks MinorVersion 50 on the CD.
    .{ .system_id = "windows-nt-3-5", .file = "NT35.SIF" },
    .{ .system_id = "windows-nt-3-5-server", .file = "NT35S.SIF" },
};

pub fn isNt3(system_id: []const u8) bool {
    for (staged) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.system_id, system_id)) return true;
    }
    return false;
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
        const fallback = "USOS-NT351";
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

/// WINNT.SIF (CRLF). NT 3.51 takes no product key.
pub fn render(p: *const Profile, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; WINNT.SIF rendered by USOS for Windows NT 3.51 (docs/nt351-2026-10-08.md)\r\n");
    try w.writeAll("[Data]\r\nMsDosInitiated = 1\r\nFloppyless = 1\r\n\r\n");
    try w.writeAll("[Unattended]\r\nMethod = express\r\nConfirmHardware = no\r\nNtUpgrade = no\r\nWin31Upgrade = no\r\n");
    try w.writeAll("TargetPath = \\WINNT\r\nOverwriteOemFilesOnUpgrade = no\r\n\r\n");
    try w.writeAll("[GuiUnattended]\r\n!SetupNetwork = NO\r\n!SetupApplications = NO\r\n");
    if (p.timeZone()) |zone| {
        if (msbatch.timeZoneName(zone)) |name98| try w.print(";USOS-TZ={s}\r\n", .{name98});
    }
    try w.writeAll("\r\n[UserData]\r\n!FullName = ");
    try quoted(&w, p.user.slice(), "USOS");
    try w.writeAll("\r\n!OrgName = ");
    try quoted(&w, p.org.slice(), "USOS");
    var name: [15]u8 = undefined;
    try w.print("\r\n!ComputerName = {s}\r\n", .{netbiosName(p.computer.slice(), &name)});
    try w.writeAll("\r\n[LicenseFilePrintData]\r\n\r\n[NetworkAdapterData]\r\n\r\n[TransportData]\r\n\r\n[DomainData]\r\n");
    return w.buffered();
}

test "NT 3.51 / 3.5 ids" {
    try std.testing.expect(isNt3("windows-nt-3-51") and isNt3("Windows-NT-3-51-Server"));
    try std.testing.expect(isNt3("windows-nt-3-5") and isNt3("windows-nt-3-5-server"));
    try std.testing.expect(!isNt3("windows-nt-4") and !isNt3("windows-nt-3-1"));
}

test "NT 3.51 WINNT.SIF: the default profile" {
    var p = Profile{};
    try p.name.set("A");
    var buffer: [4096]u8 = undefined;
    // The same bytes as the micro-Linux default (w9x_csmwrap_prepare.sh
    // w9x_nt3_default_sif, tools/tests/test_nt3_flow.py).
    try std.testing.expect(p.timeZone() == null);
    try std.testing.expectEqualStrings(@embedFile("testdata/golden/default.windows-nt-3-51.WINNT.SIF"), try render(&p, &buffer));
}

test "NT 3.51 WINNT.SIF: the time zone marker" {
    var p = Profile{};
    try p.name.set("A");
    for (msbatch_zone_probe, 0..) |_, i| {
        p.timezone = @intCast(i);
        const zone = p.timeZone().?;
        const name98 = msbatch.timeZoneName(zone) orelse continue;
        var buffer: [4096]u8 = undefined;
        var line: [96]u8 = undefined;
        const text = try render(&p, &buffer);
        const marker = try std.fmt.bufPrint(&line, "!SetupApplications = NO\r\n;USOS-TZ={s}\r\n\r\n[UserData]", .{name98});
        try std.testing.expect(std.mem.indexOf(u8, text, marker) != null);
        return;
    }
    return error.NoZoneWith9xName;
}

const msbatch_zone_probe = @import("tables.zig").time_zones;

test "NT 3.51 WINNT.SIF: owner, computer name, no key, no OEM preinstall" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Jan \"K\" Kowalski");
    try p.org.set("Szkola");
    try p.computer.set("pracownia_1 x");
    try p.setSystemKey("windows-nt-3-51", "123-4567890");
    var buffer: [4096]u8 = undefined;
    const text = try render(&p, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "!FullName = \"Jan 'K' Kowalski\"\r\n!OrgName = \"Szkola\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "!ComputerName = PRACOWNIA1X\r\n") != null);
    for ([_][]const u8{ "ProductId", "OemPreinstall", "ComputerType", "[Display]", "123-4567890" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, text, absent) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "\n\n") == null);
}
