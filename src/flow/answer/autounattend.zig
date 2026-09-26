//! Windows 6.x+ renderer (Vista, 7, 8, 8.1, 10, 11, Server 2008-2025): the
//! profile as autounattend.xml for one version and architecture.
//!
//! Disk selection always stays in Setup: no DiskConfiguration, no
//! ImageInstall/InstallTo, never WillWipeDisk (docs/design/
//! answer-file-generator.md section 5). The shape of the passes and
//! components follows Microsoft's unattend reference; the choice of the
//! common settings follows the catalogue of Christoph Schneegans'
//! unattend-generator (MIT, knowledge reuse only, no code or templates
//! copied; attribution in docs/answer-profiles.md).
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const target = @import("target.zig");
const tables = @import("tables.zig");

pub const Arch = target.Arch;
pub const Family = target.Family;

pub const Input = struct {
    profile: *const Profile,
    family: Family,
    arch: Arch,
    /// Product key (the profile's for this system or one typed at start);
    /// empty: Setup asks (or selects the edition itself).
    key: []const u8 = "",
};

const W = std.Io.Writer;

fn text(w: *W, value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

fn element(w: *W, depth: usize, name: []const u8, value: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s}>", .{name});
    try text(w, value);
    try w.print("</{s}>\n", .{name});
}

fn indent(w: *W, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

fn open(w: *W, depth: usize, name: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s}>\n", .{name});
}

fn close(w: *W, depth: usize, name: []const u8) !void {
    try indent(w, depth);
    try w.print("</{s}>\n", .{name});
}

fn component(w: *W, name: []const u8, arch: Arch) !void {
    try w.print("    <component name=\"{s}\" processorArchitecture=\"{s}\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n", .{ name, @tagName(arch) });
}

fn endComponent(w: *W) !void {
    try w.writeAll("    </component>\n");
}

fn languageTag(entry: *const tables.Language, family: Family) []const u8 {
    if (family.legacyNt6()) if (entry.tag_legacy) |legacy| return legacy;
    return entry.tag;
}

fn international(w: *W, input: Input, winpe: bool) !void {
    const p = input.profile;
    const lang = p.languageEntry();
    const locale = p.localeEntry() orelse return;
    try component(w, if (winpe) "Microsoft-Windows-International-Core-WinPE" else "Microsoft-Windows-International-Core", input.arch);
    if (winpe) {
        if (lang) |l| {
            try open(w, 3, "SetupUILanguage");
            try element(w, 4, "UILanguage", languageTag(l, input.family));
            try close(w, 3, "SetupUILanguage");
        }
    }
    var buffer: [16]u8 = undefined;
    const kb = p.inputProfile().?;
    try element(w, 3, "InputLocale", try std.fmt.bufPrint(&buffer, "{x:0>4}:{x:0>8}", .{ kb.lcid, kb.klid }));
    try element(w, 3, "SystemLocale", languageTag(locale, input.family));
    if (lang) |l| try element(w, 3, "UILanguage", languageTag(l, input.family));
    try element(w, 3, "UserLocale", languageTag(locale, input.family));
    try endComponent(w);
}

fn runCommand(w: *W, depth: usize, element_name: []const u8, order: usize, path: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s} wcm:action=\"add\">\n", .{element_name});
    var buffer: [8]u8 = undefined;
    try element(w, depth + 1, "Order", try std.fmt.bufPrint(&buffer, "{d}", .{order}));
    try element(w, depth + 1, "Path", path);
    try close(w, depth, element_name);
}

const lab_config = "reg.exe add \"HKLM\\SYSTEM\\Setup\\LabConfig\" /v {s} /t REG_DWORD /d 1 /f";

fn windows11(family: Family) bool {
    return family == .windows_11;
}

fn setupComponent(w: *W, input: Input) !void {
    const p = input.profile;
    try component(w, "Microsoft-Windows-Setup", input.arch);
    if (windows11(input.family) and (p.bypass_tpm or p.bypass_secure_boot or p.bypass_ram)) {
        try open(w, 3, "RunSynchronous");
        var order: usize = 1;
        var buffer: [160]u8 = undefined;
        const checks = [_]struct { on: bool, name: []const u8 }{
            .{ .on = p.bypass_tpm, .name = "BypassTPMCheck" },
            .{ .on = p.bypass_secure_boot, .name = "BypassSecureBootCheck" },
            .{ .on = p.bypass_ram, .name = "BypassRAMCheck" },
        };
        for (checks) |check| {
            if (!check.on) continue;
            try runCommand(w, 4, "RunSynchronousCommand", order, try std.fmt.bufPrint(&buffer, lab_config, .{check.name}));
            order += 1;
        }
        try close(w, 3, "RunSynchronous");
    }
    try open(w, 3, "UserData");
    if (input.key.len > 0) {
        try open(w, 4, "ProductKey");
        var upper: [29]u8 = undefined;
        for (input.key[0..@min(input.key.len, 29)], 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        try element(w, 5, "Key", upper[0..@min(input.key.len, 29)]);
        try element(w, 5, "WillShowUI", "OnError");
        try close(w, 4, "ProductKey");
    }
    try element(w, 4, "AcceptEula", "true");
    try element(w, 4, "FullName", p.user.slice());
    if (p.org.len > 0) try element(w, 4, "Organization", p.org.slice());
    try close(w, 3, "UserData");
    try endComponent(w);
}

fn specialize(w: *W, input: Input) !void {
    const p = input.profile;
    try w.writeAll("  <settings pass=\"specialize\">\n");
    try component(w, "Microsoft-Windows-Shell-Setup", input.arch);
    try element(w, 3, "ComputerName", if (p.computer.len > 0) p.computer.slice() else "*");
    try element(w, 3, "RegisteredOwner", p.user.slice());
    if (p.org.len > 0) try element(w, 3, "RegisteredOrganization", p.org.slice());
    if (p.timeZone()) |zone| {
        const name = if (input.family.legacyNt6()) zone.windows_legacy orelse zone.windows else zone.windows;
        try element(w, 3, "TimeZone", name);
    }
    try endComponent(w);
    if (windows11(input.family) and p.no_network_oobe) {
        try component(w, "Microsoft-Windows-Deployment", input.arch);
        try open(w, 3, "RunSynchronous");
        try runCommand(w, 4, "RunSynchronousCommand", 1, "reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE\" /v BypassNRO /t REG_DWORD /d 1 /f");
        try close(w, 3, "RunSynchronous");
        try endComponent(w);
    }
    try w.writeAll("  </settings>\n");
}

fn account(w: *W, name: []const u8, password: []const u8) !void {
    try indent(w, 5);
    try w.writeAll("<LocalAccount wcm:action=\"add\">\n");
    try open(w, 6, "Password");
    try element(w, 7, "Value", password);
    try element(w, 7, "PlainText", "true");
    try close(w, 6, "Password");
    try element(w, 6, "DisplayName", name);
    try element(w, 6, "Group", "Administrators");
    try element(w, 6, "Name", name);
    try close(w, 5, "LocalAccount");
}

fn oobe(w: *W, input: Input) !void {
    const p = input.profile;
    const family = input.family;
    try w.writeAll("  <settings pass=\"oobeSystem\">\n");
    try international(w, input, false);
    try component(w, "Microsoft-Windows-Shell-Setup", input.arch);
    try open(w, 3, "OOBE");
    try element(w, 4, "HideEULAPage", "true");
    if (family.client() != .vista) try element(w, 4, "HideOEMRegistrationScreen", "true");
    if (family.atLeast8() and p.local_account) try element(w, 4, "HideOnlineAccountScreens", "true");
    // Without it an offline Windows 10 OOBE stops on "Let's connect you to a
    // network" (VirtualBox test 2026-09-26); the page is only the Wi-Fi setup.
    if (family.client() != .vista) try element(w, 4, "HideWirelessSetupInOOBE", "true");
    if (family.legacyNt6()) try element(w, 4, "NetworkLocation", "Work");
    try element(w, 4, "ProtectYourPC", "3");
    try close(w, 3, "OOBE");
    try open(w, 3, "UserAccounts");
    if (family.server() and p.password.len > 0) {
        try open(w, 4, "AdministratorPassword");
        try element(w, 5, "Value", p.password.slice());
        try element(w, 5, "PlainText", "true");
        try close(w, 4, "AdministratorPassword");
    }
    try open(w, 4, "LocalAccounts");
    try account(w, p.user.slice(), p.password.slice());
    if (p.user2.len > 0) try account(w, p.user2.slice(), p.password.slice());
    try close(w, 4, "LocalAccounts");
    try close(w, 3, "UserAccounts");
    try endComponent(w);
    try w.writeAll("  </settings>\n");
}

/// autounattend.xml for `input` (LF line ends, UTF-8, ASCII values).
pub fn render(input: Input, buffer: []u8) ![]const u8 {
    std.debug.assert(!input.family.nt5());
    var w: W = .fixed(buffer);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try w.print("<!-- USOS answer profile rendered for {s} ({s}); the target disk is chosen in Setup. docs/answer-profiles.md -->\n", .{ target.systemId(input.family), @tagName(input.arch) });
    try w.writeAll("<unattend xmlns=\"urn:schemas-microsoft-com:unattend\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");
    try w.writeAll("  <settings pass=\"windowsPE\">\n");
    try international(&w, input, true);
    try setupComponent(&w, input);
    try w.writeAll("  </settings>\n");
    try specialize(&w, input);
    try oobe(&w, input);
    try w.writeAll("</unattend>\n");
    return w.buffered();
}

pub const max_size = 16 * 1024;

test "autounattend: manual disk, escaped values, arch on every component" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.org.set("R'n'D Team");
    var buffer: [max_size]u8 = undefined;
    const xml = try render(.{ .profile = &p, .family = .windows_10, .arch = .x86 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, xml, "DiskConfiguration") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "WillWipeDisk") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "InstallTo") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "processorArchitecture=\"amd64\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "R&apos;n&apos;D Team") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ProductKey>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ComputerName>*</ComputerName>") != null);
    try @import("xml_check.zig").wellFormed(xml);
}

test "autounattend: Windows 11 bypasses only when chosen, only on 11" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    p.bypass_tpm = true;
    p.bypass_ram = true;
    p.no_network_oobe = true;
    var buffer: [max_size]u8 = undefined;
    const eleven = try render(.{ .profile = &p, .family = .windows_11, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassTPMCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassRAMCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassSecureBootCheck") == null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassNRO") != null);
    const ten = try render(.{ .profile = &p, .family = .windows_10, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ten, "LabConfig") == null);
    try std.testing.expect(std.mem.indexOf(u8, ten, "BypassNRO") == null);
}
