//! Answer profiles and renderers (refactor M5, docs/answer-profiles.md).
const std = @import("std");

pub const tables = @import("tables.zig");
pub const profile = @import("profile.zig");
pub const target = @import("target.zig");
pub const nt5 = @import("nt5.zig");
pub const autounattend = @import("autounattend.zig");
pub const xml_check = @import("xml_check.zig");
pub const plan_file = @import("plan_file.zig");

pub const Profile = profile.Profile;
pub const Arch = target.Arch;
pub const Family = target.Family;

pub const Rendered = struct {
    format: plan_file.Format,
    bytes: []const u8,
};

/// Renders `p` for a catalog system (null: that system has no generated
/// answer). `key` overrides the profile's key for this system (a key typed
/// at start); null uses the profile's.
pub fn render(p: *const Profile, system_id: []const u8, arch: Arch, key: ?[]const u8, buffer: []u8) !?Rendered {
    const family = target.familyFor(system_id) orelse return null;
    const use_key = key orelse p.keyFor(system_id);
    if (family.nt5()) return .{ .format = .nt5_settings, .bytes = try nt5.render(p, family, use_key, buffer) };
    const xml = try autounattend.render(.{ .profile = p, .family = family, .arch = arch, .key = use_key }, buffer);
    try xml_check.wellFormed(xml);
    return .{ .format = .autounattend_xml, .bytes = xml };
}

test {
    _ = tables;
    _ = profile;
    _ = target;
    _ = nt5;
    _ = autounattend;
    _ = xml_check;
    _ = plan_file;
}

test "render dispatch per system" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.setSystemKey("windows-xp", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    var buffer: [autounattend.max_size]u8 = undefined;
    const xp = (try render(&p, "windows-xp", .x86, null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.nt5_settings, xp.format);
    try std.testing.expect(std.mem.indexOf(u8, xp.bytes, "key=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") != null);
    const ten = (try render(&p, "windows-10", .amd64, null, &buffer)).?;
    try std.testing.expectEqual(plan_file.Format.autounattend_xml, ten.format);
    try std.testing.expect(std.mem.indexOf(u8, ten.bytes, "AAAAA") == null);
    try std.testing.expect((try render(&p, "windows-98-se", .x86, null, &buffer)) == null);
}
