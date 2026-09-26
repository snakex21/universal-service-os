//! NT5 renderer (2000, XP, 2003): the profile as the normalized settings
//! file of tools/xp_user_settings.sh. The staging validates it again
//! (usos_xp_settings_load ... profile) and merges it into the automatic
//! WINNT.SIF with the same code that handles DATA's usos-xp.ini
//! (usos_xp_settings_sif), so the proven merge stays the one renderer of
//! WINNT.SIF. The extra keys (family, locale, input_locale,
//! language_group) are accepted only in that profile mode; for XP with
//! automatic language and no extras the merged WINNT.SIF is byte for byte
//! the usos-xp.ini result (tools/tests/test_answer_render.py).
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const Family = @import("target.zig").Family;

pub const file_name = "nt5-settings.ini";

fn familyName(family: Family) []const u8 {
    return switch (family) {
        .windows_2000 => "2000",
        .windows_2003 => "2003",
        else => "xp",
    };
}

/// Normalized settings for `family` (one key=value per line, LF). `key`
/// is the product key to use (the profile's or one typed at start).
pub fn render(p: *const Profile, family: Family, key: []const u8, buffer: []u8) ![]const u8 {
    std.debug.assert(family.nt5());
    var w: std.Io.Writer = .fixed(buffer);
    try w.print("user={s}\nuser2={s}\ncomputer={s}\norg={s}\n", .{ p.user.slice(), p.user2.slice(), p.computer.slice(), p.org.slice() });
    try w.writeAll("key=");
    for (key) |c| try w.writeByte(std.ascii.toUpper(c));
    try w.writeAll("\n");
    if (p.timeZone()) |zone| try w.print("timezone={d}\n", .{zone.nt5}) else try w.writeAll("timezone=\n");
    try w.print("password={s}\n", .{p.password.slice()});
    try w.print("family={s}\n", .{familyName(family)});
    if (p.localeEntry()) |locale| {
        const lcid: u16 = locale.lcid_nt5 orelse locale.lcid;
        const input = p.inputProfile().?;
        try w.print("locale={X:0>8}\ninput_locale={X:0>4}:{X:0>8}\n", .{ lcid, input.lcid, input.klid });
        // The keyboard's language may need another language group.
        const keyboard_group: ?u8 = blk: {
            for (@import("tables.zig").languages) |entry| {
                if (entry.lcid == input.lcid) break :blk entry.group;
            }
            break :blk null;
        };
        if (keyboard_group) |g| {
            if (g != locale.group) {
                try w.print("language_group={d},{d}\n", .{ @min(g, locale.group), @max(g, locale.group) });
                return w.buffered();
            }
        }
        try w.print("language_group={d}\n", .{locale.group});
    }
    return w.buffered();
}

test "NT5 render: automatic language keeps the usos-xp.ini keys" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    const text = try render(&p, .windows_xp, "", &buffer_for_test);
    try std.testing.expectEqualStrings("user=Tester\nuser2=\ncomputer=\norg=\nkey=\ntimezone=\npassword=\nfamily=xp\n", text);
}

var buffer_for_test: [1024]u8 = undefined;

test "NT5 render: regional settings from the language" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    const tables = @import("tables.zig");
    p.language = @intCast(tables.languageIndex("pl-PL").?);
    p.timezone = @intCast(tables.timeZoneIndex("Europe/Warsaw").?);
    const text = try render(&p, .windows_2000, "abcde-12345-abcde-12345-abcde", &buffer_for_test);
    try std.testing.expect(std.mem.indexOf(u8, text, "key=ABCDE-12345-ABCDE-12345-ABCDE\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timezone=100\npassword=\nfamily=2000\nlocale=00000415\ninput_locale=0415:00000415\nlanguage_group=2\n") != null);
    p.keyboard = .{ .lcid = 0x0419, .klid = 0x00000419 };
    const mixed = try render(&p, .windows_xp, "", &buffer_for_test);
    try std.testing.expect(std.mem.endsWith(u8, mixed, "language_group=2,5\n"));
}
