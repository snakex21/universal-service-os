//! Per-version placement check of a rendered autounattend.xml: every
//! setting the renderer can write, with its pass, component and the
//! Windows versions whose unattend schema has it (Microsoft unattend
//! reference: "Applies to" and "Valid passes" of each setting). Setup
//! refuses the whole file for one element its version does not know
//! ("Windows could not parse or process the unattend answer file"), so a
//! rendered file is checked before it is handed on (root.render) and every
//! version is covered by the unit test below and the goldens.
//!
//! The table lists only what autounattend.zig writes; it is a guard for the
//! renderer, not a full schema. The input must be well-formed
//! (xml_check.wellFormed) and in the renderer's shape: no comments or CDATA
//! inside <unattend>.
const std = @import("std");
const target = @import("target.zig");
const Family = target.Family;

/// Schema level: the client release a family's Setup/OOBE schema follows.
pub const Level = enum(u8) {
    vista,
    windows_7,
    windows_8,
    windows_8_1,
    windows_10,
    windows_11,

    pub fn of(family: Family) Level {
        return switch (family.client()) {
            .vista => .vista,
            .windows_7 => .windows_7,
            .windows_8 => .windows_8,
            .windows_8_1 => .windows_8_1,
            .windows_10 => .windows_10,
            .windows_11 => .windows_11,
            else => unreachable,
        };
    }
};

pub const Pass = enum { windowsPE, specialize, oobeSystem };

pub const Setting = struct {
    pass: Pass,
    component: []const u8,
    /// Leaf path inside the component, '/'-separated.
    path: []const u8,
    since: Level = .vista,
    until: Level = .windows_11,
    /// Only on client editions (not in the Server shell of that level).
    client_only: bool = false,
};

const winpe_intl = "Microsoft-Windows-International-Core-WinPE";
const intl = "Microsoft-Windows-International-Core";
const setup = "Microsoft-Windows-Setup";
const shell = "Microsoft-Windows-Shell-Setup";
const deployment = "Microsoft-Windows-Deployment";
const wer = "Microsoft-Windows-ErrorReportingCore";

pub const settings = [_]Setting{
    // windowsPE
    .{ .pass = .windowsPE, .component = winpe_intl, .path = "SetupUILanguage/UILanguage" },
    .{ .pass = .windowsPE, .component = winpe_intl, .path = "InputLocale" },
    .{ .pass = .windowsPE, .component = winpe_intl, .path = "SystemLocale" },
    .{ .pass = .windowsPE, .component = winpe_intl, .path = "UILanguage" },
    .{ .pass = .windowsPE, .component = winpe_intl, .path = "UserLocale" },
    .{ .pass = .windowsPE, .component = setup, .path = "RunSynchronous/RunSynchronousCommand/Order" },
    .{ .pass = .windowsPE, .component = setup, .path = "RunSynchronous/RunSynchronousCommand/Path" },
    .{ .pass = .windowsPE, .component = setup, .path = "UserData/ProductKey/Key" },
    .{ .pass = .windowsPE, .component = setup, .path = "UserData/ProductKey/WillShowUI" },
    .{ .pass = .windowsPE, .component = setup, .path = "UserData/AcceptEula" },
    .{ .pass = .windowsPE, .component = setup, .path = "UserData/FullName" },
    .{ .pass = .windowsPE, .component = setup, .path = "UserData/Organization" },
    // specialize
    .{ .pass = .specialize, .component = shell, .path = "ComputerName" },
    .{ .pass = .specialize, .component = shell, .path = "RegisteredOwner" },
    .{ .pass = .specialize, .component = shell, .path = "RegisteredOrganization" },
    .{ .pass = .specialize, .component = shell, .path = "TimeZone" },
    .{ .pass = .specialize, .component = shell, .path = "ShowWindowsLive", .since = .windows_7, .until = .windows_7, .client_only = true },
    .{ .pass = .specialize, .component = deployment, .path = "RunSynchronous/RunSynchronousCommand/Order" },
    .{ .pass = .specialize, .component = deployment, .path = "RunSynchronous/RunSynchronousCommand/Path" },
    .{ .pass = .specialize, .component = wer, .path = "DisableWER" },
    // oobeSystem
    .{ .pass = .oobeSystem, .component = intl, .path = "InputLocale" },
    .{ .pass = .oobeSystem, .component = intl, .path = "SystemLocale" },
    .{ .pass = .oobeSystem, .component = intl, .path = "UILanguage" },
    .{ .pass = .oobeSystem, .component = intl, .path = "UserLocale" },
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/HideEULAPage" },
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/HideWirelessSetupInOOBE", .since = .windows_7 },
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/HideOEMRegistrationScreen", .since = .windows_8 },
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/HideOnlineAccountScreens", .since = .windows_8 },
    // Still accepted by 8+, but without effect there; the renderer keeps it to Vista/7.
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/NetworkLocation", .until = .windows_7 },
    .{ .pass = .oobeSystem, .component = shell, .path = "OOBE/ProtectYourPC" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/AdministratorPassword/Value" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/AdministratorPassword/PlainText" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/LocalAccounts/LocalAccount/Password/Value" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/LocalAccounts/LocalAccount/Password/PlainText" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/LocalAccounts/LocalAccount/DisplayName" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/LocalAccounts/LocalAccount/Group" },
    .{ .pass = .oobeSystem, .component = shell, .path = "UserAccounts/LocalAccounts/LocalAccount/Name" },
};

pub const Error = error{ UnknownPass, UnknownSetting, NotForThisVersion, BadShape };

pub const Finding = struct {
    pass: []const u8 = "",
    component: []const u8 = "",
    path: []const u8 = "",
};

fn allowed(pass: Pass, component: []const u8, path: []const u8, family: Family) Error!void {
    const level = Level.of(family);
    var known = false;
    for (settings) |s| {
        if (s.pass != pass or !std.mem.eql(u8, s.component, component) or !std.mem.eql(u8, s.path, path)) continue;
        known = true;
        if (@intFromEnum(level) < @intFromEnum(s.since) or @intFromEnum(level) > @intFromEnum(s.until)) continue;
        if (s.client_only and family.server()) continue;
        return;
    }
    return if (known) error.NotForThisVersion else error.UnknownSetting;
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var buffer: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, " {s}=\"", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, tag, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, tag, start, '"') orelse return null;
    return tag[start..end];
}

/// Checks every leaf element of `xml` against the table for `family`.
/// `finding` (optional) receives the offending pass, component and path.
pub fn check(xml: []const u8, family: Family, finding: ?*Finding) Error!void {
    var names: [16][]const u8 = undefined;
    var depth: usize = 0;
    var pass: ?Pass = null;
    var pass_text: []const u8 = "";
    var component: []const u8 = "";
    var last_open: ?usize = null;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, xml, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse return error.BadShape;
        const tag = xml[lt + 1 .. gt];
        i = gt + 1;
        if (tag.len == 0 or tag[0] == '?' or tag[0] == '!') continue;
        if (tag[0] == '/') {
            if (depth == 0) return error.BadShape;
            depth -= 1;
            // A leaf: closed right after its opening. Depth 0 unattend,
            // 1 settings, 2 component, 3.. the setting path.
            if (last_open != null and last_open.? == depth and depth >= 3) {
                var path_buffer: [160]u8 = undefined;
                var w: std.Io.Writer = .fixed(&path_buffer);
                for (names[3 .. depth + 1], 0..) |n, k| {
                    if (k > 0) w.writeByte('/') catch return error.BadShape;
                    w.writeAll(n) catch return error.BadShape;
                }
                const path = w.buffered();
                allowed(pass orelse return error.BadShape, component, path, family) catch |err| {
                    // The leaf name (the joined path lives in this stack frame).
                    if (finding) |f| f.* = .{ .pass = pass_text, .component = component, .path = names[depth] };
                    return err;
                };
            }
            last_open = null;
            continue;
        }
        const self_closing = tag[tag.len - 1] == '/';
        const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n/") orelse tag.len;
        const name = tag[0..name_end];
        if (depth == names.len) return error.BadShape;
        if (depth == 1) {
            if (!std.mem.eql(u8, name, "settings")) return error.BadShape;
            pass_text = attribute(tag, "pass") orelse return error.BadShape;
            pass = std.meta.stringToEnum(Pass, pass_text) orelse {
                if (finding) |f| f.* = .{ .pass = pass_text };
                return error.UnknownPass;
            };
        }
        if (depth == 2) {
            if (!std.mem.eql(u8, name, "component")) return error.BadShape;
            component = attribute(tag, "name") orelse return error.BadShape;
        }
        if (self_closing) continue;
        names[depth] = name;
        last_open = depth;
        depth += 1;
    }
    if (depth != 0) return error.BadShape;
}

const Profile = @import("profile.zig").Profile;
const autounattend = @import("autounattend.zig");
const tables = @import("tables.zig");

fn everything() !Profile {
    var p = Profile{};
    try p.name.set("All");
    try p.user.set("Tester");
    try p.user2.set("Drugi");
    try p.computer.set("USOS-PC");
    try p.org.set("USOS");
    try p.password.set("x");
    p.timezone = @intCast(tables.timeZoneIndex("Europe/Warsaw").?);
    p.language = @intCast(tables.languageIndex("pl-PL").?);
    p.bypass_tpm = true;
    p.bypass_secure_boot = true;
    p.bypass_ram = true;
    p.no_network_oobe = true;
    p.disable_wer = true;
    p.protect_pc = .recommended;
    return p;
}

test "schema: every family renders only settings its version has" {
    const p = try everything();
    var buffer: [autounattend.max_size]u8 = undefined;
    inline for (@typeInfo(Family).@"enum".fields) |f| {
        const family: Family = @enumFromInt(f.value);
        if (!family.nt5()) {
            for ([_]target.Arch{ .x86, .amd64 }) |arch| {
                const xml = try autounattend.render(.{ .profile = &p, .family = family, .arch = arch, .key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE" }, &buffer);
                var finding: Finding = .{};
                check(xml, family, &finding) catch |err| {
                    std.debug.print("{s}: {s} {s} {s}: {s}\n", .{ f.name, finding.pass, finding.component, finding.path, @errorName(err) });
                    return err;
                };
            }
        }
    }
}

test "schema: Vista and 7 reject later OOBE settings" {
    const vista_oem =
        \\<unattend><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup">
        \\<OOBE><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen></OOBE></component></settings></unattend>
    ;
    try std.testing.expectError(error.NotForThisVersion, check(vista_oem, .windows_7, null));
    try std.testing.expectError(error.NotForThisVersion, check(vista_oem, .server_2008, null));
    try check(vista_oem, .windows_8, null);
    const wireless =
        \\<unattend><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup">
        \\<OOBE><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE></OOBE></component></settings></unattend>
    ;
    try std.testing.expectError(error.NotForThisVersion, check(wireless, .vista, null));
    try check(wireless, .windows_7, null);
    const live =
        \\<unattend><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup">
        \\<ShowWindowsLive>false</ShowWindowsLive></component></settings></unattend>
    ;
    try check(live, .windows_7, null);
    try std.testing.expectError(error.NotForThisVersion, check(live, .server_2008_r2, null));
    try std.testing.expectError(error.NotForThisVersion, check(live, .vista, null));
    const misplaced =
        \\<unattend><settings pass="windowsPE"><component name="Microsoft-Windows-Shell-Setup">
        \\<ComputerName>A</ComputerName></component></settings></unattend>
    ;
    try std.testing.expectError(error.UnknownSetting, check(misplaced, .windows_10, null));
    const disk =
        \\<unattend><settings pass="windowsPE"><component name="Microsoft-Windows-Setup">
        \\<DiskConfiguration><WillShowUI>Always</WillShowUI></DiskConfiguration></component></settings></unattend>
    ;
    try std.testing.expectError(error.UnknownSetting, check(disk, .windows_10, null));
}
