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

pub const Profile = profile.Profile;
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

pub fn matchEdition(p: *const Profile, system_id: []const u8, images: ?*const editions.List) EditionMatch {
    const wanted = p.editionFor(system_id);
    if (wanted.len == 0) return .none;
    const list = images orelse return .{ .missing = wanted };
    const image = editions.match(wanted, list) orelse return .{ .missing = wanted };
    return .{ .found = image };
}

/// Renders `p` for a catalog system (null: that system has no generated
/// answer). `key` overrides the profile's key for this system (a key typed
/// at start); null uses the profile's. `images`: the install images of the
/// chosen media, for the profile's edition (null: no edition written).
pub fn render(p: *const Profile, system_id: []const u8, arch: Arch, key: ?[]const u8, images: ?*const editions.List, buffer: []u8) !?Rendered {
    const family = target.familyFor(system_id) orelse return null;
    const use_key = key orelse p.keyFor(system_id);
    if (family.nt5()) return .{ .format = .nt5_settings, .bytes = try nt5.render(p, family, use_key, buffer) };
    const image_index: ?u16 = switch (matchEdition(p, system_id, images)) {
        .found => |image| image.index,
        else => null,
    };
    const xml = try autounattend.render(.{ .profile = p, .family = family, .arch = arch, .key = use_key, .image_index = image_index }, buffer);
    try xml_check.wellFormed(xml);
    try schema.check(xml, family, null);
    return .{ .format = .autounattend_xml, .bytes = xml };
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
    try std.testing.expect((try render(&p, "windows-98-se", .x86, null, null, &buffer)) == null);
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
    try std.testing.expect(matchEdition(&p, "windows-10", &list) == .none);
}
