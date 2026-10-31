//! Which systems offer a profile (`systems=`, docs/answer-profiles.md) and
//! which required answers a profile lacks for a system (the answer screen
//! and the summary warn before the start).
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const target = @import("target.zig");

pub fn isLinux(system_id: []const u8) bool {
    for (profile_mod.linux_systems) |id| {
        if (std.ascii.eqlIgnoreCase(id, system_id)) return true;
    }
    return false;
}

/// The systems list in effect. Explicit `systems=` wins. A profile saved
/// before the field existed: when its only per-system edition names one
/// Windows (the editor stores the edition of the system it was opened
/// from, e.g. vista-ultimate.ini: edition.windows-vista=Ultimate), it was
/// made for that system; otherwise every Windows (never Linux).
pub fn effective(p: *const Profile) []const u8 {
    if (p.systems.len > 0) return p.systems.slice();
    if (p.system_edition_count == 1) {
        const id = p.system_editions[0].system.slice();
        if (target.familyFor(id) != null) return id;
    }
    return "windows";
}

/// The profile is offered for this catalog system.
pub fn appliesTo(p: *const Profile, system_id: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, effective(p), ',');
    while (tokens.next()) |token| {
        if (tokenMatches(token, system_id)) return true;
    }
    return false;
}

fn tokenMatches(token: []const u8, system_id: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, system_id)) return true;
    const family = target.familyFor(system_id);
    // Windows 95/98/Me render MSBATCH.INF (msbatch.zig) without an NT family.
    const win9x = @import("msbatch.zig").releaseFor(system_id) != null;
    // Windows NT 4.0 renders WINNT.SIF (nt4.zig) without an NT5/NT6 family.
    // Windows NT 3.51 too (nt3.zig).
    const nt4 = @import("nt4.zig").isNt4(system_id) or @import("nt3.zig").isNt3(system_id) or @import("posready.zig").isPosReady(system_id);
    // MS-DOS and Windows 1.x-3.x take the regional settings (dos.zig).
    const dos = @import("dos.zig").isDos(system_id);
    if (std.mem.eql(u8, token, "windows")) return family != null or win9x or nt4 or dos;
    if (std.mem.eql(u8, token, "windows-9x")) return win9x;
    if (std.mem.eql(u8, token, "windows-nt5")) return if (family) |f| f.nt5() else false;
    if (std.mem.eql(u8, token, "windows-nt6")) return if (family) |f| !f.nt5() else false;
    if (std.mem.eql(u8, token, "linux")) return isLinux(system_id);
    return false;
}

/// Some system offers both profiles (their effective `systems=` lists
/// share a system). Profile names need to be unique only then: the answer
/// screen of one system never lists two profiles with the same name.
pub fn overlaps(a: *const Profile, b: *const Profile) bool {
    return scopesOverlap(effective(a), effective(b));
}

pub fn scopesOverlap(a: []const u8, b: []const u8) bool {
    var left = std.mem.splitScalar(u8, a, ',');
    while (left.next()) |x| {
        var right = std.mem.splitScalar(u8, b, ',');
        while (right.next()) |y| {
            if (tokensOverlap(std.mem.trim(u8, x, " "), std.mem.trim(u8, y, " "))) return true;
        }
    }
    return false;
}

fn isGroup(token: []const u8) bool {
    for (profile_mod.system_groups) |group| {
        if (std.mem.eql(u8, group, token)) return true;
    }
    return false;
}

fn tokensOverlap(x: []const u8, y: []const u8) bool {
    if (x.len == 0 or y.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(x, y)) return true;
    const x_group = isGroup(x);
    const y_group = isGroup(y);
    // A group and a system id: the group holds the system.
    if (x_group and !y_group) return tokenMatches(x, y);
    if (y_group and !x_group) return tokenMatches(y, x);
    if (!x_group) return false;
    // Two different groups: "windows" holds the windows-* groups; the
    // windows-* groups are disjoint and "linux" shares nothing with them.
    const windows_x = std.mem.eql(u8, x, "windows");
    const windows_y = std.mem.eql(u8, y, "windows");
    return (windows_x and std.mem.startsWith(u8, y, "windows-")) or (windows_y and std.mem.startsWith(u8, x, "windows-"));
}

test "overlaps: same names allowed only for profiles offered on different systems" {
    const xp = try profileFrom("name=Dom\nuser=Bob\nsystems=windows-xp\n");
    const seven = try profileFrom("name=Dom\nuser=Bob\nsystems=windows-7\n");
    const nt5 = try profileFrom("name=Dom\nuser=Bob\nsystems=windows-nt5\n");
    const nt6 = try profileFrom("name=Dom\nuser=Bob\nsystems=windows-nt6\n");
    const nine = try profileFrom("name=Dom\nuser=Bob\nsystems=windows-9x\n");
    const linux = try profileFrom("name=Dom\nuser=Bob\nsystems=linux\n");
    const ubuntu = try profileFrom("name=Dom\nuser=Bob\nsystems=ubuntu\n");
    const windows = try profileFrom("name=Dom\nuser=Bob\nsystems=windows\n");
    const both = try profileFrom("name=Dom\nuser=Bob\nsystems=windows,linux\n");
    // A profile saved before systems= existed: every Windows.
    const legacy = try profileFrom("name=Dom\nuser=Bob\n");
    // Read-time default: the only per-system edition names Vista.
    const vista = try profileFrom("name=Dom\nuser=Bob\nedition.windows-vista=Ultimate\n");
    try std.testing.expect(!overlaps(&xp, &seven));
    try std.testing.expect(overlaps(&xp, &xp));
    try std.testing.expect(overlaps(&xp, &nt5) and overlaps(&nt5, &xp));
    try std.testing.expect(!overlaps(&xp, &nt6) and overlaps(&seven, &nt6));
    try std.testing.expect(!overlaps(&nt5, &nt6) and !overlaps(&nt5, &nine) and !overlaps(&nt6, &nine));
    try std.testing.expect(overlaps(&windows, &nine) and overlaps(&nt6, &windows) and overlaps(&windows, &xp));
    try std.testing.expect(!overlaps(&windows, &linux) and !overlaps(&xp, &ubuntu));
    try std.testing.expect(overlaps(&linux, &ubuntu) and overlaps(&both, &ubuntu) and overlaps(&both, &seven));
    try std.testing.expect(overlaps(&legacy, &xp) and !overlaps(&legacy, &ubuntu));
    try std.testing.expect(overlaps(&vista, &nt6) and !overlaps(&vista, &seven) and !overlaps(&vista, &xp));
    // Lists: one shared system is enough.
    try std.testing.expect(scopesOverlap("windows-xp,ubuntu", "debian,ubuntu"));
    try std.testing.expect(!scopesOverlap("windows-xp,ubuntu", "debian,windows-7"));
    try std.testing.expect(!scopesOverlap("", "windows"));
}

/// An answer the target needs for a hands-off Setup that the profile lacks.
pub const Missing = enum {
    /// 2000 / XP / 2003: without a key Setup stops on the product key page.
    product_key,
    /// Server 2008 and later: the local password policy wants at least 7
    /// characters of three kinds; without one Setup asks for the
    /// Administrator password (and cannot create the accounts).
    server_password,
};

pub fn missing(p: *const Profile, system_id: []const u8) ?Missing {
    // Windows 95: phase 1 runs in the VM only with a 95 key (the OEM COA
    // page); without one only the native Setup start is left.
    if (std.ascii.eqlIgnoreCase(system_id, "windows-95")) return if (has95Key(p)) null else .product_key;
    // Windows NT 4.0: ProductId (the 95 key shapes); without it GUI Setup waits.
    // Manual Setup (win9x_setup=manual, native): Setup's own key page asks.
    if (@import("nt4.zig").isNt4(system_id)) return if (p.win9x_setup == .manual or @import("nt4.zig").validKey(p.keyFor(system_id))) null else .product_key;
    // POSReady 2009: a 5x5 key; without it Setup stops ("Invalid product key").
    if (@import("posready.zig").isPosReady(system_id)) return if (@import("posready.zig").validKey(p.keyFor(system_id))) null else .product_key;
    // Windows NT 3.x: never reported missing. 3.1 has no PID page; the
    // library 3.5 / 3.51 CDs skip theirs (INITIAL.INF DisplayPidDlg = NO on
    // a DOS-initiated Setup). A retail CD with DisplayPidDlg = YES would show
    // the QueryPid dialog: the profile key is not passed to it yet.
    if (@import("nt3.zig").isNt3(system_id)) return null;
    const family = target.familyFor(system_id) orelse return null;
    if (family.nt5()) return if (p.keyFor(system_id).len == 0) .product_key else null;
    if (family.server() and !complexPassword(p.password.slice())) return .server_password;
    // Windows 8 / 8.1 Setup (also Server 2012 / 2012 R2, Embedded 8.1) has no
    // "I don't have a product key": without one it stops on the key page.
    const client = family.client();
    if ((client == .windows_8 or client == .windows_8_1) and p.keyFor(system_id).len == 0) return .product_key;
    return null;
}

test "missing: NT 4.0 needs a key unless Setup is manual" {
    var p = try profileFrom("name=A\nuser=Bob\n");
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-nt-4").?);
    p.win9x_setup = .manual;
    try std.testing.expect(missing(&p, "windows-nt-4") == null);
}

test "missing: Windows 8.1 family needs a key, Server 2008 R2 does not" {
    var p = try profileFrom("name=A\nuser=Bob\npassword=Usos-2026!\n");
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-8-1").?);
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-server-2012-r2").?);
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-embedded-8-1-industry").?);
    try std.testing.expect(missing(&p, "windows-server-2008-r2") == null);
    try std.testing.expect(missing(&p, "windows-10") == null);
    try p.setSystemKey("windows-embedded-8-1-industry", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(missing(&p, "windows-embedded-8-1-industry") == null);
}

/// The profile holds a Windows 95 key (OEM or retail shape) for windows-95
/// (key.windows-95, else `key=`).
pub fn has95Key(p: *const Profile) bool {
    const shape = profile_mod.keyShape(p.keyFor("windows-95")) orelse return false;
    return shape != .five_by_five;
}

/// Windows Server's default "Password must meet complexity requirements":
/// 7+ characters from three of upper case, lower case, digits, symbols.
/// (The rule's check against the account name is not modelled.)
pub fn complexPassword(password: []const u8) bool {
    if (password.len < 7) return false;
    var kinds = [4]bool{ false, false, false, false };
    for (password) |c| {
        if (std.ascii.isUpper(c)) kinds[0] = true else if (std.ascii.isLower(c)) kinds[1] = true else if (std.ascii.isDigit(c)) kinds[2] = true else kinds[3] = true;
    }
    var n: usize = 0;
    for (kinds) |k| n += @intFromBool(k);
    return n >= 3;
}

fn profileFrom(text: []const u8) !Profile {
    var p: Profile = undefined;
    if (profile_mod.parse(text, &p) != .ok) return error.TestBadProfile;
    return p;
}

test "systems: legacy profiles are Windows only; the Vista edition profile is Vista only" {
    const legacy = try profileFrom("name=A\nuser=Bob\n");
    try std.testing.expect(appliesTo(&legacy, "windows-xp") and appliesTo(&legacy, "windows-11"));
    try std.testing.expect(!appliesTo(&legacy, "ubuntu"));
    // The profile on the X470 stick (Ultimate, user Retro, no key).
    const vista = try profileFrom("name=vista-ultimate\nuser=Retro\nremember_key=no\nedition=\nedition.windows-vista=Ultimate\n");
    try std.testing.expectEqualStrings("windows-vista", effective(&vista));
    try std.testing.expect(appliesTo(&vista, "windows-vista"));
    try std.testing.expect(!appliesTo(&vista, "windows-server-2003") and !appliesTo(&vista, "windows-7") and !appliesTo(&vista, "debian"));
    const two = try profileFrom("name=A\nuser=Bob\nedition.windows-7=Pro\nedition.windows-10=Pro\n");
    try std.testing.expect(appliesTo(&two, "windows-xp"));
}

test "systems: groups and ids" {
    const p = try profileFrom("name=A\nuser=Bob\nsystems=windows-nt5, fedora\n");
    try std.testing.expect(appliesTo(&p, "windows-xp") and appliesTo(&p, "windows-server-2003") and appliesTo(&p, "fedora"));
    try std.testing.expect(!appliesTo(&p, "windows-vista") and !appliesTo(&p, "ubuntu"));
    const nt6 = try profileFrom("name=A\nuser=Bob\nsystems=windows-nt6,linux\nedition.windows-vista=Ultimate\n");
    try std.testing.expect(appliesTo(&nt6, "windows-11") and appliesTo(&nt6, "debian") and !appliesTo(&nt6, "windows-2000"));
    try std.testing.expect(!appliesTo(&nt6, "windows-98-se"));
    const nine = try profileFrom("name=A\nuser=Bob\nsystems=windows-9x\n");
    try std.testing.expect(appliesTo(&nine, "windows-98-se") and appliesTo(&nine, "windows-95") and appliesTo(&nine, "windows-me"));
    try std.testing.expect(!appliesTo(&nine, "windows-xp") and !appliesTo(&nine, "windows-3-1"));
    const every = try profileFrom("name=A\nuser=Bob\n");
    // Every Windows includes the DOS-based ones and MS-DOS (DOS.INI regional
    // settings, 2026-10-24); windows-9x does not.
    try std.testing.expect(appliesTo(&every, "windows-98") and appliesTo(&every, "windows-3-11") and appliesTo(&every, "ms-dos"));
    try std.testing.expect(!appliesTo(&every, "freedos") and !appliesTo(&nine, "ms-dos"));
    const only_dos = try profileFrom("name=A\nuser=Bob\nsystems=ms-dos,windows-3-1\n");
    try std.testing.expect(appliesTo(&only_dos, "windows-3-1") and !appliesTo(&only_dos, "windows-98"));
}

test "missing answers: Windows 95 needs a 95-shaped key" {
    var p = try profileFrom("name=A\nuser=Bob\nsystems=windows-9x\n");
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-95").?);
    // 98/Me keep going without a key (phase 1 runs in the VM anyway).
    try std.testing.expect(missing(&p, "windows-98-se") == null and missing(&p, "windows-me") == null);
    // An XP-style key in key= is not a 95 key.
    try p.key.set("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-95").?);
    try p.setSystemKey("windows-95", "12345-OEM-1234567-12345");
    try std.testing.expect(missing(&p, "windows-95") == null);
    const retail = try profileFrom("name=A\nuser=Bob\nsystems=windows-95\nkey=123-1234567\n");
    try std.testing.expect(missing(&retail, "windows-95") == null);
    try std.testing.expect(appliesTo(&retail, "windows-95") and !appliesTo(&retail, "windows-98-se"));
}

test "missing answers: NT5 key, Server password" {
    var p = try profileFrom("name=A\nuser=Bob\n");
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-server-2003").?);
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp").?);
    try std.testing.expect(missing(&p, "windows-10") == null and missing(&p, "ubuntu") == null);
    try std.testing.expectEqual(Missing.server_password, missing(&p, "windows-server-2019").?);
    try p.setSystemKey("windows-server-2003", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(missing(&p, "windows-server-2003") == null);
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp").?);
    try p.password.set("Test123!");
    try std.testing.expect(missing(&p, "windows-server-2019") == null);
    try p.password.set("test1234");
    try std.testing.expectEqual(Missing.server_password, missing(&p, "windows-server-2008").?);
}

test "Windows 2000 Server: its own key field, the NT5 group, no Server password rule" {
    var p = try profileFrom("name=A\nuser=Bob\nsystems=windows-nt5\n");
    try std.testing.expect(appliesTo(&p, "windows-2000-server") and appliesTo(&p, "windows-2000"));
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-2000-server").?);
    try p.setSystemKey("windows-2000-server", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(missing(&p, "windows-2000-server") == null);
    // The Server key is not the Professional one.
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-2000").?);
    try std.testing.expect(@import("profile.zig").knownSystemToken("windows-2000-server"));
}

test "XP Media Center Edition: its own key field in the NT5 group" {
    var p = try profileFrom("name=A\nuser=Bob\nsystems=windows-nt5\n");
    try std.testing.expect(appliesTo(&p, "windows-xp-mce"));
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp-mce").?);
    try p.setSystemKey("windows-xp-mce", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(missing(&p, "windows-xp-mce") == null);
    // The Media Center key is not the Professional one.
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp").?);
    try std.testing.expect(@import("profile.zig").knownSystemToken("windows-xp-mce"));
}

test "XP Tablet PC Edition: its own key field in the NT5 group" {
    var p = try profileFrom("name=A\nuser=Bob\nsystems=windows-nt5\n");
    try std.testing.expect(appliesTo(&p, "windows-xp-tablet"));
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp-tablet").?);
    try p.setSystemKey("windows-xp-tablet", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(missing(&p, "windows-xp-tablet") == null);
    // The Tablet PC key is neither the Professional nor the Media Center one.
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp").?);
    try std.testing.expectEqual(Missing.product_key, missing(&p, "windows-xp-mce").?);
    try std.testing.expect(@import("profile.zig").knownSystemToken("windows-xp-tablet"));
}
