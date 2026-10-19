//! Answer profiles and renderers (refactor M5, docs/answer-profiles.md).
const std = @import("std");

pub const tables = @import("tables.zig");
pub const profile = @import("profile.zig");
pub const target = @import("target.zig");
pub const nt5 = @import("nt5.zig");
pub const autounattend = @import("autounattend.zig");
pub const xml_check = @import("xml_check.zig");
pub const schema = @import("schema.zig");
pub const plan_file = @import("plan_file.zig");
pub const editions = @import("editions.zig");
pub const sha512crypt = @import("sha512crypt.zig");
pub const linux = @import("linux.zig");
pub const applies = @import("applies.zig");
pub const msbatch = @import("msbatch.zig");
pub const nt4 = @import("nt4.zig");
pub const nt3 = @import("nt3.zig");
pub const posready = @import("posready.zig");
pub const options = @import("options.zig");
pub const logon = @import("logon.zig");

pub const Profile = profile.Profile;
pub const display_profile = @import("display_profile.zig");
pub const Arch = target.Arch;
pub const Family = target.Family;

pub const Rendered = struct {
    format: plan_file.Format,
    bytes: []const u8,
};

/// The profile's edition for a system against the chosen media's images.
pub const EditionMatch = union(enum) {
    /// The profile names no edition for this system.
    none,
    /// Found: this image is installed (/IMAGE/INDEX).
    found: *const editions.Image,
    /// Named but not on the media (or the image list is unknown): the
    /// answer has no edition and Setup asks.
    missing: []const u8,
};

/// Windows Server without an edition in the profile (and no key, which
/// would name one): Standard with the full GUI (Desktop Experience / Full
/// Installation) when the media has it, so an unattended Server install
/// does not stop on the edition list. Media without it: Setup asks.
pub const server_default_edition = "ServerStandard";

pub fn matchEdition(p: *const Profile, system_id: []const u8, images: ?*const editions.List) EditionMatch {
    const wanted = p.editionFor(system_id);
    if (wanted.len == 0) {
        const family = target.familyFor(system_id) orelse return .none;
        if (family.nt5()) return .none;
        const list = images orelse return .none;
        // One image (Embedded 8.1 Industry Pro): 8.1 Setup still showed its
        // one-line edition list (QEMU e2e 2026-10-08); name it.
        if (list.len == 1) return .{ .found = &list.items[0] };
        if (!family.server() or p.keyFor(system_id).len > 0) return .none;
        const image = editions.match(server_default_edition, list) orelse return .none;
        return .{ .found = image };
    }
    const list = images orelse return .{ .missing = wanted };
    const image = editions.match(wanted, list) orelse return .{ .missing = wanted };
    return .{ .found = image };
}

/// Renders `p` for a catalog system (null: that system has no generated
/// answer). `key` overrides the profile's key for this system (a key typed
/// at start); null uses the profile's. `images`: the install images of the
/// chosen media, for the profile's edition (null: no edition written).
pub fn render(p: *const Profile, system_id: []const u8, arch: Arch, key: ?[]const u8, images: ?*const editions.List, buffer: []u8) !?Rendered {
    const use_key = key orelse p.keyFor(system_id);
    if (nt4.isNt4(system_id)) return .{ .format = .nt4_sif, .bytes = try displayMetadata(p, system_id, try nt4.render(p, use_key, buffer), buffer) };
    if (nt3.isNt3(system_id)) return .{ .format = .nt4_sif, .bytes = try displayMetadata(p, system_id, try nt3.render(p, buffer), buffer) };
    // POSReady 2009: POSR.SIF (staged like WINNT.SIF; posready.zig).
    if (posready.isPosReady(system_id)) return .{ .format = .nt4_sif, .bytes = try posready.render(p, use_key, buffer) };
    if (msbatch.releaseFor(system_id)) |release| return .{ .format = .msbatch_inf, .bytes = try displayMetadata(p, system_id, try msbatch.render(p, release, use_key, buffer), buffer) };
    const family = target.familyFor(system_id) orelse return null;
    // NT keys are 5x5 only (a Windows 95 key in the profile's `key=` is not theirs).
    const nt_key = if (profile.keyShape(use_key) == .five_by_five) use_key else "";
    if (family.nt5()) return .{ .format = .nt5_settings, .bytes = try nt5.render(p, family, nt_key, buffer) };
    const image_index: ?u16 = switch (matchEdition(p, system_id, images)) {
        .found => |image| image.index,
        else => null,
    };
    const xml = try autounattend.render(.{ .profile = p, .family = family, .arch = arch, .key = nt_key, .image_index = image_index }, buffer);
    try xml_check.wellFormed(xml);
    try schema.check(xml, family, null);
    return .{ .format = .autounattend_xml, .bytes = xml };
}

fn displayMetadata(p: *const Profile, id: []const u8, bytes: []const u8, buffer: []u8) ![]const u8 {
    if (!display_profile.supportsSystem(id) or !display_profile.requested(p)) return bytes;
    var writer: std.Io.Writer = .fixed(buffer[bytes.len..]);
    try display_profile.comment(p, &writer);
    return buffer[0 .. bytes.len + writer.buffered().len];
}

test "display metadata reaches supported legacy targets only and preserves missing request" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Bob");
    var buffer: [autounattend.max_size]u8 = undefined;
    for ([_][]const u8{ "windows-nt-4", "windows-nt-3-51", "windows-nt-3-5", "windows-95", "windows-98-se", "windows-me" }) |id| {
        p.display_explicit = false;
        const plain = (try render(&p, id, .x86, null, null, &buffer)).?;
        try std.testing.expect(std.mem.indexOf(u8, plain.bytes, "USOS-DISPLAY=") == null);
        p.display_explicit = true;
        const chosen = (try render(&p, id, .x86, null, null, &buffer)).?;
        try std.testing.expect(std.mem.endsWith(u8, chosen.bytes, ";USOS-DISPLAY=autoxauto\r\n"));
    }
    for ([_][]const u8{ "windows-xp", "windows-server-2003", "windows-nt-3-1", "windows-vista" }) |id| {
        const out = (try render(&p, id, .x86, null, null, &buffer)).?;
        try std.testing.expect(std.mem.indexOf(u8, out.bytes, "USOS-DISPLAY=") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.bytes, "display_bpp=") == null);
    }
}

test {
    _ = tables;
    _ = profile;
    _ = target;
    _ = nt5;
    _ = autounattend;
    _ = xml_check;
    _ = schema;
    _ = plan_file;
    _ = editions;
    _ = sha512crypt;
    _ = linux;
    _ = applies;
    _ = msbatch;
    _ = nt4;
    _ = nt3;
    _ = posready;
    _ = options;
    _ = logon;
}

test "render dispatch per system" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.setSystemKey("windows-xp", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    var buffer: [autounattend.max_size]u8 = undefined;
    const xp = (try render(&p, "windows-xp", .x86, null, null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.nt5_settings, xp.format);
    try std.testing.expect(std.mem.indexOf(u8, xp.bytes, "key=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") != null);
    const ten = (try render(&p, "windows-10", .amd64, null, null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.autounattend_xml, ten.format);
    try std.testing.expect(std.mem.indexOf(u8, ten.bytes, "AAAAA") == null);
    const ninety_eight = (try render(&p, "windows-98-se", .x86, null, null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.msbatch_inf, ninety_eight.format);
    try std.testing.expect(std.mem.indexOf(u8, ninety_eight.bytes, "Name=\"Tester\"") != null);
    try std.testing.expect((try render(&p, "windows-3-1", .x86, null, null, &buffer)) == null);
    // NT 3.51: WINNT.SIF without a key, even when the profile holds one.
    const nt351 = (try render(&p, "windows-nt-3-51-server", .x86, "123-4567890", null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.nt4_sif, nt351.format);
    try std.testing.expect(std.mem.indexOf(u8, nt351.bytes, "for Windows NT 3.51") != null);
    try std.testing.expect(std.mem.indexOf(u8, nt351.bytes, "123-4567890") == null);
}

test "a key typed without dashes renders dashed in WINNT.SIF settings and autounattend.xml" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    var key: [29]u8 = undefined;
    const typed = profile.normalizeKey("abcde 12345fghij-67890klmno", &key);
    try p.setSystemKey("windows-xp", typed);
    try p.setSystemKey("windows-10", typed);
    try std.testing.expect(profile.validate(&p) == null);
    var buffer: [autounattend.max_size]u8 = undefined;
    const xp = (try render(&p, "windows-xp", .x86, null, null, &buffer)).?;
    try std.testing.expect(std.mem.indexOf(u8, xp.bytes, "key=ABCDE-12345-FGHIJ-67890-KLMNO\n") != null);
    const ten = (try render(&p, "windows-10", .amd64, null, null, &buffer)).?;
    try std.testing.expect(std.mem.indexOf(u8, ten.bytes, "<Key>ABCDE-12345-FGHIJ-67890-KLMNO</Key>") != null);
}

test "edition from the media: found, missing, per system" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.edition.set("Professional");
    var list = editions.List{};
    var image = editions.Image{ .index = 3 };
    image.edition_id.set("Professional");
    list.items[0] = image;
    list.len = 1;
    var buffer: [autounattend.max_size]u8 = undefined;
    const seven = (try render(&p, "windows-7", .amd64, null, &list, &buffer)).?;
    try std.testing.expect(std.mem.indexOf(u8, seven.bytes, "<Value>3</Value>") != null);
    const unknown = (try render(&p, "windows-7", .amd64, null, null, &buffer)).?;
    try std.testing.expect(std.mem.indexOf(u8, unknown.bytes, "ImageInstall") == null);
    try std.testing.expect(matchEdition(&p, "windows-7", null) == .missing);
    try p.setSystemEdition("windows-7", "Ultimate");
    try std.testing.expect(matchEdition(&p, "windows-7", &list) == .missing);
    try std.testing.expect(matchEdition(&p, "windows-10", &list) == .found);
    p.edition = .{};
    // No edition named: a one-image ISO still gets its image.
    try std.testing.expect(matchEdition(&p, "windows-10", &list) == .found);
    try std.testing.expect(matchEdition(&p, "windows-10", null) == .none);
}

test "Server without an edition: Standard full installation by default" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    // Server 2008 R2 SP1 VL pl (install.wim order of the X470 library ISO).
    var list = editions.List{};
    const images = [_]struct { []const u8, bool }{
        .{ "ServerStandard", false },   .{ "ServerStandard", true },   .{ "ServerEnterprise", false }, .{ "ServerEnterprise", true },
        .{ "ServerDatacenter", false }, .{ "ServerDatacenter", true }, .{ "ServerWeb", false },        .{ "ServerWeb", true },
    };
    for (images, 0..) |entry, i| {
        var image = editions.Image{ .index = @intCast(i + 1), .server = true, .core = entry[1] };
        image.edition_id.set(entry[0]);
        list.items[i] = image;
    }
    list.len = images.len;
    try std.testing.expectEqual(@as(u16, 1), matchEdition(&p, "windows-server-2008-r2", &list).found.index);
    var buffer: [autounattend.max_size]u8 = undefined;
    const r2 = (try render(&p, "windows-server-2008-r2", .amd64, null, &list, &buffer)).?;
    try std.testing.expect(std.mem.indexOf(u8, r2.bytes, "<Value>1</Value>") != null);
    // A chosen edition wins; Core on request.
    try p.setSystemEdition("windows-server-2008-r2", "Datacenter Core");
    try std.testing.expectEqual(@as(u16, 6), matchEdition(&p, "windows-server-2008-r2", &list).found.index);
    try p.setSystemEdition("windows-server-2008-r2", "");
    // Clients and keyed profiles: no default (the key names the edition).
    try std.testing.expect(matchEdition(&p, "windows-7", &list) == .none);
    try p.setSystemKey("windows-server-2008-r2", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(matchEdition(&p, "windows-server-2008-r2", &list) == .none);
    // Media without Standard (2012 R2 Foundation / Storage Server): Setup asks.
    var foundation = editions.List{};
    var image = editions.Image{ .index = 1, .server = true };
    image.edition_id.set("ServerWinFoundation");
    foundation.items[0] = image;
    foundation.len = 1;
    // A single image is always named (the 8.1 Setup listed it otherwise).
    try std.testing.expectEqual(@as(u16, 1), matchEdition(&p, "windows-server-2012-r2", &foundation).found.index);
    try std.testing.expectEqual(@as(u16, 1), matchEdition(&p, "windows-embedded-8-1-industry", &foundation).found.index);
    image.index = 2;
    image.edition_id.set("ServerStorageStandard");
    foundation.items[1] = image;
    foundation.len = 2;
    try std.testing.expect(matchEdition(&p, "windows-server-2012-r2", &foundation) == .none);
}
