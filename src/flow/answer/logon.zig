//! How to log on after a Windows installation USOS prepared
//! (docs/logon-after-install.md). The UEFI menu derives it from the answer
//! it really hands over (an answer profile, DATA's usos-xp.ini, the user's
//! own answer file or none) and the flow's built-in defaults, and writes
//! \EFI\USOS\answer\logon.ini (never a password). micro-Linux shows its
//! `line=` on the last preparation page before the restart and copies the
//! file without secrets to DATA as Systems\...\<folder>\last-install-login.txt
//! (tools/micro_linux_ui.sh usos_logon_take / usos_logon_save). The native
//! wimboot starts show the line on the UEFI progress page.
//!
//! Defaults per flow (what the renderers and the staging scripts really do):
//!   NT 3.x      Administrator, blank password (WINNT.SIF sets none); with a
//!               profile the own account (usosnt3.exe ACCOUNT.TXT, also the
//!               Administrator's password) and optional automatic logon. NT 3.1
//!               Advanced Server is the controller of the domain USOSDOMAIN.
//!   NT 4.0      Administrator, blank password (OEMBlankAdminPassword = 1; the
//!               profile's account and password are not applied, the one
//!               automatic logon is the install VM's own).
//!   2000/XP/2003 (MCE, Tablet, XP x64 too): the profile's or usos-xp.ini's
//!               first account (local administrator, the same password for
//!               Administrator); without an answer Setup asks.
//!   POSReady    Administrator with the profile's AdminPassword (blank without).
//!   Vista+      the profile's first account (LocalAccounts, Administrators);
//!               without an answer Setup/OOBE asks.
//!   9x/Me       with the default LAN client: automatic blank-password logon
//!               as the profile user (USOS without a profile). network=off
//!               keeps the previous no-client flow; custom files own their policy.
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const target = @import("target.zig");
const options = @import("options.zig");
const nt3 = @import("nt3.zig");
const nt4 = @import("nt4.zig");
const posready = @import("posready.zig");
const msbatch = @import("msbatch.zig");

pub const file_name = "logon.ini";
pub const path = "\\EFI\\USOS\\answer\\logon.ini";
/// The text file micro-Linux writes into the system's DATA folder.
pub const data_file_name = "last-install-login.txt";

/// NT 3.1 Advanced Server: the domain the install VM creates.
pub const nt31_domain = "USOSDOMAIN";
pub const administrator = "Administrator";

/// English sentences; every one is a catalog value (boot.lx.logon_*), so
/// usos-fb-ui and the UEFI menu translate them by their English text.
/// Their literal parts never overlap: the first matching template wins.
pub const Template = struct {
    pub const no_password = "After the installation log on as {0} (no password).";
    pub const profile_password = "After the installation log on as {0} with the password set in the answer profile.";
    pub const file_password = "After the installation log on as {0}; the password is the one in {1}.";
    pub const domain_no_password = "After the installation log on to the domain {1} as {0} (no password).";
    pub const domain_profile_password = "After the installation log on to the domain {1} as {0} with the password set in the answer profile.";
    pub const autologon = "After the installation Windows logs on automatically as {0}.";
    pub const setup_asks = "Windows Setup asks for the user name and password during the installation; USOS does not set them.";
    pub const answer_file = "After the installation log on with the account from your answer file {0}.";

    pub const all = [_][]const u8{ no_password, profile_password, file_password, domain_no_password, domain_profile_password, autologon, setup_asks, answer_file };
};

pub const Kind = enum {
    /// A known account: `user` (and `domain`).
    account,
    /// Setup asks for the account (no answer chosen).
    setup_asks,
    /// The user's own answer file decides (`file`).
    answer_file,
    /// No logon prompt (Windows 9x/Me, non-Windows systems).
    no_logon,
};

pub const Password = enum {
    /// Blank password.
    none,
    /// Set in the chosen answer profile.
    profile,
    /// Set in a settings file on DATA (`file`, usos-xp.ini).
    file,
};

pub const Logon = struct {
    kind: Kind,
    user: []const u8 = "",
    domain: []const u8 = "",
    password: Password = .none,
    autologon: bool = false,
    /// Answer file name (answer_file) or the settings file of `.file` passwords.
    file: []const u8 = "",

    /// The English sentence (a Template with its values); empty for no_logon.
    pub fn sentence(self: Logon, buffer: []u8) []const u8 {
        const args = [_][]const u8{ self.user, if (self.domain.len > 0) self.domain else self.file };
        const template: []const u8 = switch (self.kind) {
            .no_logon => return "",
            .setup_asks => Template.setup_asks,
            .answer_file => return fill(buffer, Template.answer_file, &.{self.file}),
            .account => if (self.autologon)
                Template.autologon
            else if (self.domain.len > 0) switch (self.password) {
                .none => Template.domain_no_password,
                else => Template.domain_profile_password,
            } else switch (self.password) {
                .none => Template.no_password,
                .profile => Template.profile_password,
                .file => Template.file_password,
            },
        };
        return fill(buffer, template, &args);
    }
};

/// What the menu hands to the preparation.
pub const Source = union(enum) {
    /// No answer: the flow's own default (Setup asks where it has one).
    none,
    /// A USOS answer profile.
    profile: *const Profile,
    /// An answer file from the system's Unattended folder on DATA.
    file: []const u8,
    /// NT5: DATA's usos-xp.ini (active: its first account).
    xp_settings: struct { user: []const u8, password_set: bool },
};

pub const Flow = enum { nt3, nt4, nt5, posready, nt6, win9x, other };

pub fn flowFor(system_id: []const u8) Flow {
    if (nt3.isNt3(system_id)) return .nt3;
    if (nt4.isNt4(system_id)) return .nt4;
    if (posready.isPosReady(system_id)) return .posready;
    if (msbatch.releaseFor(system_id) != null) return .win9x;
    const family = target.familyFor(system_id) orelse return .other;
    return if (family.nt5()) .nt5 else .nt6;
}

fn autologonOn(p: *const Profile) bool {
    return p.opt(options.Opt.autologon) == 1;
}

/// The logon after installing `system_id` with the answer `source`.
pub fn derive(system_id: []const u8, source: Source) Logon {
    const flow = flowFor(system_id);
    switch (flow) {
        .win9x => return switch (source) {
            .profile => |p| if (p.network == .on) .{ .kind = .account, .user = if (p.user.len > 0) p.user.slice() else "USOS", .autologon = true } else .{ .kind = .no_logon },
            .none => .{ .kind = .account, .user = "USOS", .autologon = true },
            else => .{ .kind = .no_logon },
        },
        .other => return .{ .kind = .no_logon },
        else => {},
    }
    if (source == .file) return .{ .kind = .answer_file, .file = source.file };
    return switch (flow) {
        .nt3 => blk: {
            const domain: []const u8 = if (std.ascii.eqlIgnoreCase(system_id, "windows-nt-3-1-server")) nt31_domain else "";
            switch (source) {
                .profile => |p| {
                    // usosnt3.exe ignores Administrator / Guest as own account names.
                    const own = p.user.slice();
                    const builtin = own.len == 0 or std.ascii.eqlIgnoreCase(own, administrator) or std.ascii.eqlIgnoreCase(own, "Guest");
                    break :blk .{
                        .kind = .account,
                        .user = if (builtin) administrator else own,
                        .domain = domain,
                        .password = if (p.password.slice().len > 0) .profile else .none,
                        .autologon = autologonOn(p),
                    };
                },
                else => break :blk .{ .kind = .account, .user = administrator, .domain = domain },
            }
        },
        // NT 4.0 renders no account and no Administrator password.
        .nt4 => .{ .kind = .account, .user = administrator },
        .posready => switch (source) {
            .profile => |p| .{ .kind = .account, .user = administrator, .password = if (p.password.slice().len > 0) .profile else .none },
            else => .{ .kind = .account, .user = administrator },
        },
        .nt5 => switch (source) {
            .profile => |p| account(p),
            .xp_settings => |s| if (s.user.len == 0)
                .{ .kind = .setup_asks }
            else
                .{ .kind = .account, .user = s.user, .password = if (s.password_set) .file else .none, .file = "usos-xp.ini" },
            else => .{ .kind = .setup_asks },
        },
        .nt6 => switch (source) {
            .profile => |p| account(p),
            else => .{ .kind = .setup_asks },
        },
        .win9x, .other => unreachable,
    };
}

/// The profile's first account (NT5 and 6.x+ create it; an empty user name
/// means no unattended account: Setup asks).
fn account(p: *const Profile) Logon {
    if (p.user.slice().len == 0) return .{ .kind = .setup_asks };
    return .{
        .kind = .account,
        .user = p.user.slice(),
        .password = if (p.password.slice().len > 0) .profile else .none,
        .autologon = autologonOn(p),
    };
}

/// {0}..{9} of template replaced by args.
fn fill(buffer: []u8, template: []const u8, args: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 2 < template.len and template[i + 2] == '}' and template[i + 1] >= '0' and template[i + 1] <= '9') {
            const n = template[i + 1] - '0';
            if (n < args.len) {
                writeClean(&w, args[n]) catch break;
                i += 3;
                continue;
            }
        }
        w.writeByte(template[i]) catch break;
        i += 1;
    }
    return w.buffered();
}

/// Printable ASCII only (names reach an INI line and a text file).
fn writeClean(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| try w.writeByte(if (c >= 0x20 and c < 0x7f) c else '?');
}

/// logon.ini (CRLF): `english` is Logon.sentence, `local` its translation
/// in the menu language (the same text when English). Never a password.
pub fn writeIni(l: Logon, system_id: []const u8, english: []const u8, local: []const u8, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; USOS: how to log on after this installation (docs/logon-after-install.md). Never holds a password.\r\n[logon]\r\nsystem=");
    try writeClean(&w, system_id);
    try w.print("\r\nkind={s}\r\nuser=", .{@tagName(l.kind)});
    try writeClean(&w, l.user);
    try w.writeAll("\r\ndomain=");
    try writeClean(&w, l.domain);
    try w.print("\r\npassword={s}\r\nautologon={s}\r\nfile=", .{ @tagName(l.password), if (l.autologon) "yes" else "no" });
    try writeClean(&w, l.file);
    try w.writeAll("\r\nline=");
    try writeClean(&w, english);
    try w.writeAll("\r\nline_local=");
    // UTF-8 is kept (the translated sentence); only control bytes go.
    for (local) |c| try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
    try w.writeAll("\r\n");
    return w.buffered();
}

/// `line=` of the [logon] section (usos_logon_value line in
/// tools/micro_linux_ui.sh): the English sentence the micro-Linux pages and
/// MiniOS's restart notice show. Null when absent or empty.
pub fn iniLine(text: []const u8) ?[]const u8 {
    var in_logon = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            in_logon = std.ascii.eqlIgnoreCase(line, "[logon]");
            continue;
        }
        if (!in_logon) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..eq], "line")) continue;
        const value = line[eq + 1 ..];
        return if (value.len > 0) value else null;
    }
    return null;
}

// ------------------------------------------------------------------ tests

test "iniLine reads the [logon] line= as micro_linux_ui.sh does" {
    var buffer: [512]u8 = undefined;
    const ini = try writeIni(.{ .kind = .no_logon }, "windows-10", "Log on as Admin.", "Zaloguj jako Admin.", &buffer);
    try std.testing.expectEqualStrings("Log on as Admin.", iniLine(ini).?);
    try std.testing.expect(iniLine("[other]\r\nline=x\r\n") == null);
    try std.testing.expect(iniLine("[logon]\r\nline=\r\n") == null);
}

fn testProfile(user: []const u8, password: []const u8, auto: bool) !Profile {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set(user);
    try p.password.set(password);
    if (auto) p.opts[@intFromEnum(options.Opt.autologon)] = 1;
    return p;
}

fn expectLine(expected: []const u8, l: Logon) !void {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(expected, l.sentence(&buffer));
}

test "flows of the catalog systems" {
    try std.testing.expectEqual(Flow.nt3, flowFor("windows-nt-3-51"));
    try std.testing.expectEqual(Flow.nt3, flowFor("windows-nt-3-1-server"));
    try std.testing.expectEqual(Flow.nt4, flowFor("windows-nt-4-tse"));
    try std.testing.expectEqual(Flow.nt5, flowFor("windows-2000-server"));
    try std.testing.expectEqual(Flow.nt5, flowFor("windows-xp-tablet"));
    try std.testing.expectEqual(Flow.nt5, flowFor("windows-server-2003"));
    try std.testing.expectEqual(Flow.posready, flowFor("windows-embedded-posready-2009"));
    try std.testing.expectEqual(Flow.nt6, flowFor("windows-vista"));
    try std.testing.expectEqual(Flow.nt6, flowFor("windows-home-server-2011"));
    try std.testing.expectEqual(Flow.win9x, flowFor("windows-98-se"));
    try std.testing.expectEqual(Flow.other, flowFor("windows-3-1"));
    try std.testing.expectEqual(Flow.other, flowFor("freebsd"));
}

test "NT 3.x: Administrator without a password by default, the domain on 3.1 Advanced Server" {
    for ([_][]const u8{ "windows-nt-3-51", "windows-nt-3-51-server", "windows-nt-3-5", "windows-nt-3-5-server", "windows-nt-3-1" }) |id| {
        const l = derive(id, .none);
        try std.testing.expectEqual(Kind.account, l.kind);
        try expectLine("After the installation log on as Administrator (no password).", l);
    }
    try expectLine("After the installation log on to the domain USOSDOMAIN as Administrator (no password).", derive("windows-nt-3-1-server", .none));
}

test "NT 3.x with a profile: the own account, its password, automatic logon" {
    var p = try testProfile("Jan", "tajne", false);
    try expectLine("After the installation log on as Jan with the password set in the answer profile.", derive("windows-nt-3-51", .{ .profile = &p }));
    try expectLine("After the installation log on to the domain USOSDOMAIN as Jan with the password set in the answer profile.", derive("windows-nt-3-1-server", .{ .profile = &p }));
    var q = try testProfile("Jan", "", false);
    try expectLine("After the installation log on as Jan (no password).", derive("windows-nt-3-5", .{ .profile = &q }));
    var r = try testProfile("Jan", "", true);
    const auto = derive("windows-nt-3-51", .{ .profile = &r });
    try std.testing.expect(auto.autologon);
    try expectLine("After the installation Windows logs on automatically as Jan.", auto);
}

test "NT 4.0: Administrator without a password, also with a profile" {
    var p = try testProfile("Jan", "tajne", true);
    for ([_][]const u8{ "windows-nt-4", "windows-nt-4-server", "windows-nt-4-tse" }) |id| {
        try expectLine("After the installation log on as Administrator (no password).", derive(id, .none));
        try expectLine("After the installation log on as Administrator (no password).", derive(id, .{ .profile = &p }));
    }
    try expectLine("After the installation log on with the account from your answer file my.sif.", derive("windows-nt-4", .{ .file = "my.sif" }));
}

test "NT5: the profile's account, usos-xp.ini, Setup asks without an answer" {
    var p = try testProfile("Tester", "Haslo1", false);
    for ([_][]const u8{ "windows-2000", "windows-xp", "windows-xp-x64", "windows-xp-mce", "windows-server-2003" }) |id| {
        try expectLine("After the installation log on as Tester with the password set in the answer profile.", derive(id, .{ .profile = &p }));
        try std.testing.expectEqual(Kind.setup_asks, derive(id, .none).kind);
    }
    try expectLine("After the installation log on as Tester; the password is the one in usos-xp.ini.", derive("windows-xp", .{ .xp_settings = .{ .user = "Tester", .password_set = true } }));
    try expectLine("After the installation log on as Tester (no password).", derive("windows-xp", .{ .xp_settings = .{ .user = "Tester", .password_set = false } }));
    try std.testing.expectEqual(Kind.setup_asks, derive("windows-xp", .{ .xp_settings = .{ .user = "", .password_set = false } }).kind);
    try expectLine("Windows Setup asks for the user name and password during the installation; USOS does not set them.", derive("windows-2000", .none));
    var auto = try testProfile("Tester", "", true);
    try expectLine("After the installation Windows logs on automatically as Tester.", derive("windows-xp-tablet", .{ .profile = &auto }));
}

test "POSReady: Administrator with the profile's password" {
    var p = try testProfile("Kasa", "pin", false);
    try expectLine("After the installation log on as Administrator with the password set in the answer profile.", derive(posready.system_id, .{ .profile = &p }));
    var q = try testProfile("Kasa", "", true);
    try expectLine("After the installation log on as Administrator (no password).", derive(posready.system_id, .{ .profile = &q }));
    try expectLine("After the installation log on as Administrator (no password).", derive(posready.system_id, .none));
}

test "Vista and later: the profile's account, Setup asks otherwise" {
    var p = try testProfile("Ola", "x", false);
    for ([_][]const u8{ "windows-vista", "windows-7", "windows-10", "windows-11", "windows-server-2008", "windows-server-2022" }) |id| {
        try expectLine("After the installation log on as Ola with the password set in the answer profile.", derive(id, .{ .profile = &p }));
        try std.testing.expectEqual(Kind.setup_asks, derive(id, .none).kind);
    }
    try expectLine("After the installation log on with the account from your answer file autounattend.xml.", derive("windows-10", .{ .file = "autounattend.xml" }));
}

test "9x network defaults log on automatically; other systems retain policy" {
    var p = try testProfile("Jan", "x", true);
    try std.testing.expect(derive("windows-98-se", .{ .profile = &p }).autologon);
    try std.testing.expect(derive("windows-me", .none).autologon);
    p.network = .off;
    try std.testing.expectEqual(Kind.no_logon, derive("windows-98-se", .{ .profile = &p }).kind);
    try std.testing.expectEqual(Kind.no_logon, derive("ms-dos-6-22", .{ .file = "x.inf" }).kind);
    try expectLine("After the installation Windows logs on automatically as USOS.", derive("windows-95", .none));
}

test "logon.ini: values, never the password" {
    var p = try testProfile("Jan", "Sekret-123", false);
    const l = derive("windows-nt-3-1-server", .{ .profile = &p });
    var line: [256]u8 = undefined;
    const english = l.sentence(&line);
    var buffer: [1024]u8 = undefined;
    const text = try writeIni(l, "windows-nt-3-1-server", english, "Po instalacji zaloguj się\x01", &buffer);
    try std.testing.expectEqualStrings("; USOS: how to log on after this installation (docs/logon-after-install.md). Never holds a password.\r\n" ++
        "[logon]\r\nsystem=windows-nt-3-1-server\r\nkind=account\r\nuser=Jan\r\ndomain=USOSDOMAIN\r\npassword=profile\r\nautologon=no\r\nfile=\r\n" ++
        "line=After the installation log on to the domain USOSDOMAIN as Jan with the password set in the answer profile.\r\n" ++
        "line_local=Po instalacji zaloguj się \r\n", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Sekret") == null);
}

test "every template is a boot catalog value (translated by its English text)" {
    const linux_strings = @import("../../i18n/linux_strings.zig");
    for (Template.all) |template| {
        var found = false;
        for (linux_strings.english) |english| {
            if (std.mem.eql(u8, english, template)) found = true;
        }
        if (!found) {
            std.debug.print("missing catalog value: {s}\n", .{template});
            return error.TemplateNotInCatalog;
        }
    }
}
