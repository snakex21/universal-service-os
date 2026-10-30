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
//! Server / Enterprise Server / Terminal Server Edition: micro-Linux adds [GuiUnattended]
//! AdvServerType = SERVERNT and [LicenseFilePrintData] AutoMode = PerServer,
//! AutoUsers = 5 when the CD's TXTSETUP.SIF ProductType is not 0
//! (nt4_server_answer); without them GUI Setup waits on its Server Type and
//! Licensing Mode pages (X470 2026-10-07). The CD decides, not the menu entry.
//!
//! Manual Setup (profile win9x_setup=manual, the same row as Windows 9x;
//! native install only, tools/nt4_csmwrap_target.sh refuses it for the VM
//! path): text mode stays automatic (USOS prepared the disk, its one disk
//! question was asked in the menu), GUI Setup shows the pages whose answers
//! are left out: Welcome, Name and Organization, the product key (only when
//! the profile has none), Computer Name and Date/Time, and since
//! 2026-10-30 also the licence agreement (no OemSkipEula), the Administrator
//! password (no OEMBlankAdminPassword; with a password USOSNT4 /early turns
//! the automatic logon off and the post step / add-on chain continue after
//! the user's own logon) and the display page with its test (no
//! [Display]). The workgroup stays answered (the profile's or WORKGROUP):
//! NT 4.0's network wizard in unattended mode presses Next on its join page
//! by itself and, without JoinWorkgroup, shows "Join\Workgroup is missing or
//! invalid" first (netsetup wjoin.cpp; X470 2026-10-30); only [Network]
//! Attended = Yes would make the page plain, and that hands the whole
//! network wizard (adapter, protocols) to the user, which the loopback
//! takeover cannot survive. Control Panel > Network changes it later. Kept for the modern-PC
//! path: [Data], [Unattended] text mode (local source, MPS HAL, the USOS
//! disk, OemPreinstall for CMDLINES.TXT and POST.CMD) and the network
//! adapter and protocol ([Network] InstallAdapters: the MS Loopback adapter
//! usosnet4 takes over, TCP/IP that POST.CMD switches to the profile's LAN
//! settings), add-ons and options. ";USOS-SETUP=manual" marks it for
//! micro-Linux.
//!
//! NT 4.0 takes the time zone as the CD's own display string (localised,
//! "(GMT+01:00) Warszawa, Praga, Budapeszt" on the Polish CD), so the
//! renderer writes ";USOS-TZ=<9x zone key>" and micro-Linux replaces it for
//! a CD language it knows (else Setup shows the time zone page).
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const msbatch = @import("msbatch.zig");
const options = @import("options.zig");

pub const file_name = "WINNT.SIF";

/// Rendered files the UEFI menu leaves for micro-Linux (\EFI\USOS\answer\<file>).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "windows-nt-4", .file = "NT4.SIF" },
    .{ .system_id = "windows-nt-4-server", .file = "NT4S.SIF" },
    // Terminal Server Edition: the Server answer (micro-Linux adds the
    // Server pages for the CD's ProductType 1).
    .{ .system_id = "windows-nt-4-tse", .file = "NT4T.SIF" },
    .{ .system_id = "windows-nt-4-beta", .file = "NT4B.SIF" },
    .{ .system_id = "windows-cairo", .file = "CAIRO.SIF" },
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
    const manual = p.win9x_setup == .manual;
    try w.writeAll("; WINNT.SIF rendered by USOS for Windows NT 4.0 (docs/nt4-2026-10-07.md)\r\n");
    if (manual) try w.writeAll(";USOS-SETUP=manual\r\n");
    try w.writeAll("[Data]\r\nMsDosInitiated = 1\r\nFloppyless = 1\r\nUnattendedInstall = \"Yes\"\r\n\r\n");
    try w.writeAll("[Unattended]\r\nOemPreinstall = Yes\r\n");
    if (!manual) try w.writeAll("OemSkipEula = Yes\r\n");
    try w.writeAll("NoWaitAfterTextMode = 1\r\nNoWaitAfterGUIMode = 1\r\n");
    try w.writeAll("FileSystem = LeaveAlone\r\nExtendOemPartition = 0\r\nConfirmHardware = No\r\nNtUpgrade = No\r\nWin31Upgrade = No\r\n");
    try w.writeAll("TargetPath = \\WINNT\r\nOverwriteOemFilesOnUpgrade = No\r\nComputerType = \"MPS Multiprocessor PC\", Retail\r\n\r\n");
    try w.writeAll("[UserData]\r\n");
    if (!manual) {
        try w.writeAll("FullName = ");
        try quoted(&w, p.user.slice(), "USOS");
        try w.writeAll("\r\nOrgName = ");
        try quoted(&w, p.org.slice(), "USOS");
        var name: [15]u8 = undefined;
        try w.print("\r\nComputerName = {s}\r\n", .{netbiosName(p.computer.slice(), &name)});
    }
    if (validKey(key)) {
        try w.writeAll("ProductId = \"");
        for (key) |c| try w.writeByte(std.ascii.toUpper(c));
        try w.writeAll("\"\r\n");
    }
    try w.writeAll("\r\n[GuiUnattended]\r\n");
    if (!manual) try w.writeAll("OemSkipWelcome = 1\r\n");
    if (!manual) try w.writeAll("OEMBlankAdminPassword = 1\r\n");
    if (!manual) {
        if (p.timeZone()) |zone| {
            if (msbatch.timeZoneName(zone)) |name98| try w.print(";USOS-TZ={s}\r\n", .{name98});
        }
    }
    if (!manual) try w.writeAll("\r\n[Display]\r\nConfigureAtLogon = 0\r\nAutoConfirm = 1\r\nBitsPerPel = 8\r\nXResolution = 640\r\nYResolution = 480\r\nVRefresh = 60\r\n");
    try @import("addons_profile.zig").metadata(p, &w);
    try optionLines(p, &w);
    try @import("network_defaults.zig").nt4(p, if (p.workgroup.len > 0) p.workgroup.slice() else "WORKGROUP", &w);
    return w.buffered();
}

/// The typed options (options.zig) as ";USOS-REG=<usos-reg set line>"
/// comments (Setup skips them): micro-Linux (nt4_csmwrap_target.sh) writes
/// them to C:\USOS\NT4\USOS-REG.TXT and POST.CMD applies them with
/// usos-reg.exe at the automatic Administrator logon (HKLM, HKU\.DEFAULT,
/// the Default User hive and the Administrator's own HKCU).
fn optionLines(p: *const Profile, w: *std.Io.Writer) !void {
    var values: [options.count]u8 = undefined;
    var it = options.iterate(p, &values, .{ .os = .nt4 });
    while (it.next()) |rule| switch (rule.action) {
        .reg => |r| {
            try w.writeAll(";USOS-REG=");
            try options.writeSetLine(w, r, p);
            try w.writeAll("\r\n");
        },
        else => {},
    };
}

test "NT 4.0 WINNT.SIF: typed options as USOS-REG comments, nothing by default" {
    var p = Profile{};
    p.addons_preset = .none;
    try p.name.set("A");
    try p.user.set("Jan");
    p.network = .off;
    var buffer: [4096]u8 = undefined;
    const plain = try render(&p, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, plain, "USOS-REG") == null);
    p.no_autorun = true;
    p.opts[@intFromEnum(options.Opt.numlock)] = 1;
    p.opts[@intFromEnum(options.Opt.no_tips)] = 1;
    const text = try render(&p, "", &buffer);
    try std.testing.expect(std.mem.endsWith(u8, text, "VRefresh = 60\r\n" ++
        ";USOS-REG=HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer|NoDriveTypeAutoRun|dword|255\r\n" ++
        ";USOS-REG=HKLM\\SYSTEM\\CurrentControlSet\\Services\\Cdrom|Autorun|dword|0\r\n" ++
        ";USOS-REG=USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips|Show|dword|0\r\n" ++
        ";USOS-REG=DEFAULT\\Control Panel\\Keyboard|InitialKeyboardIndicators|sz|2\r\n" ++
        ";USOS-REG=USER\\Control Panel\\Keyboard|InitialKeyboardIndicators|sz|2\r\n"));
}

test "NT 4.0 WINNT.SIF: manual Setup leaves the GUI pages to the user, keeps the modern-PC path" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Jan Kowalski");
    try p.computer.set("pracownia");
    p.win9x_setup = .manual;
    var buffer: [4096]u8 = undefined;
    const text = try render(&p, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, ";USOS-SETUP=manual\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FullName") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OrgName") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ComputerName") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ProductId") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OemSkipWelcome") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, ";USOS-TZ=") == null);
    // 2026-10-30: the licence, password, display and workgroup pages too
    try std.testing.expect(std.mem.indexOf(u8, text, "OemSkipEula") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OEMBlankAdminPassword") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Display]") == null);
    // the workgroup stays answered (no "Join\\Workgroup" warning box)
    try std.testing.expect(std.mem.indexOf(u8, text, "[Network]\r\nJoinWorkgroup=WORKGROUP\r\n") != null);
    // kept: local source, unattended text mode, OEM preinstall, the loopback adapter + TCP/IP
    try std.testing.expect(std.mem.indexOf(u8, text, "MsDosInitiated = 1\r\nFloppyless = 1\r\nUnattendedInstall = \"Yes\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OemPreinstall = Yes\r\nNoWaitAfterTextMode = 1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "JoinWorkgroup=WORKGROUP\r\nInstallAdapters=USOS.Adapters\r\n") != null);
    // a profile key still skips the key page
    const keyed = try render(&p, "12345-oem-0012345-12345", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, keyed, "ProductId = \"12345-OEM-0012345-12345\"\r\n") != null);
    // automatic stays as it was
    p.win9x_setup = .auto;
    const auto = try render(&p, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, auto, "USOS-SETUP") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "OemSkipWelcome = 1\r\nOEMBlankAdminPassword = 1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "FullName = \"Jan Kowalski\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "OemPreinstall = Yes\r\nOemSkipEula = Yes\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "[Display]\r\nConfigureAtLogon = 0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "[Network]\r\nJoinWorkgroup=WORKGROUP\r\n") != null);
}

test "NT 4.0 ids and key shapes" {
    try std.testing.expect(isNt4("windows-nt-4") and isNt4("Windows-NT-4-Server") and isNt4("windows-nt-4-tse") and !isNt4("windows-2000"));
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
