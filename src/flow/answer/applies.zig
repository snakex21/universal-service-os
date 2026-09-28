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
    if (std.mem.eql(u8, token, "windows")) return family != null;
    if (std.mem.eql(u8, token, "windows-nt5")) return if (family) |f| f.nt5() else false;
    if (std.mem.eql(u8, token, "windows-nt6")) return if (family) |f| !f.nt5() else false;
    if (std.mem.eql(u8, token, "linux")) return isLinux(system_id);
    return false;
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
    const family = target.familyFor(system_id) orelse return null;
    if (family.nt5()) return if (p.keyFor(system_id).len == 0) .product_key else null;
    if (family.server() and !complexPassword(p.password.slice())) return .server_password;
    return null;
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
