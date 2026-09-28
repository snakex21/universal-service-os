//! NT5 renderer (2000, XP, 2003): the profile as the normalized settings
//! file of tools/xp_user_settings.sh. The staging validates it again
//! (usos_xp_settings_load ... profile) and merges it into the automatic
//! WINNT.SIF with the same code that handles DATA's usos-xp.ini
//! (usos_xp_settings_sif), so the proven merge stays the one renderer of
//! WINNT.SIF. The extra keys (family, locale, input_locale,
//! language_group) are accepted only in that profile mode; for XP with
//! automatic language and no extras the merged WINNT.SIF is byte for byte
//! the usos-xp.ini result (tools/tests/test_answer_render.py).
//!
//! Tweaks (profile mode only, written only when on and schema.tweak_support
//! has them for the family): `tweaks=` a comma-separated list of the tokens
//! below, `display=WxH`. The staging turns them into [Components], [Shell]
//! and [Display] of WINNT.SIF and registry lines of the setup-end script.
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const Family = @import("target.zig").Family;
const schema = @import("schema.zig");

/// Staging token of each NT5 tweak (tools/xp_user_settings.sh).
pub const Token = struct { tweak: schema.Tweak, token: []const u8, only: ?Family = null };
pub const tokens = [_]Token{
    .{ .tweak = .skip_games, .token = "games" },
    .{ .tweak = .skip_msn, .token = "msn_explorer", .only = .windows_xp },
    .{ .tweak = .skip_msn, .token = "messenger" },
    .{ .tweak = .hide_outlook_express, .token = "outlook_express" },
    .{ .tweak = .classic_start, .token = "classic_start" },
    .{ .tweak = .theme_classic, .token = "classic_theme" },
    .{ .tweak = .no_balloon_tips, .token = "balloons" },
    .{ .tweak = .no_balloon_tips, .token = "tour", .only = .windows_xp },
    .{ .tweak = .show_extensions, .token = "extensions" },
    .{ .tweak = .show_hidden, .token = "hidden" },
    .{ .tweak = .no_autorun, .token = "autorun" },
};

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
        if (keyboard_group != null and keyboard_group.? != locale.group) {
            const g = keyboard_group.?;
            try w.print("language_group={d},{d}\n", .{ @min(g, locale.group), @max(g, locale.group) });
        } else try w.print("language_group={d}\n", .{locale.group});
    }
    try tweakLines(p, family, &w);
    return w.buffered();
}

fn tweakLines(p: *const Profile, family: Family, w: *std.Io.Writer) !void {
    var first = true;
    for (tokens) |entry| {
        if (!schema.tweakOn(p, entry.tweak, family)) continue;
        if (entry.only) |only| if (only != family) continue;
        try w.writeAll(if (first) "tweaks=" else ",");
        try w.writeAll(entry.token);
        first = false;
    }
    if (!first) try w.writeAll("\n");
    if (schema.tweakOn(p, .display, family)) try w.print("display={s}\n", .{@tagName(p.display)});
}

test "NT5 render: automatic language keeps the usos-xp.ini keys" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    const text = try render(&p, .windows_xp, "", &buffer_for_test);
    try std.testing.expectEqualStrings("user=Tester\nuser2=\ncomputer=\norg=\nkey=\ntimezone=\npassword=\nfamily=xp\n", text);
}

var buffer_for_test: [1024]u8 = undefined;

test "NT5 render: tweaks per family, none for 2000" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    for (@import("profile.zig").tweak_fields) |field| p.flag(field).?.* = true;
    p.theme = .classic;
    p.display = .@"1280x1024";
    const xp = try render(&p, .windows_xp, "", &buffer_for_test);
    try std.testing.expect(std.mem.endsWith(u8, xp, "family=xp\ntweaks=games,msn_explorer,messenger,outlook_express,classic_start,classic_theme,balloons,tour,extensions,hidden,autorun\ndisplay=1280x1024\n"));
    const w2k3 = try render(&p, .windows_2003, "", &buffer_for_test);
    try std.testing.expect(std.mem.endsWith(u8, w2k3, "family=2003\ntweaks=messenger,outlook_express,balloons,extensions,hidden,autorun\ndisplay=1280x1024\n"));
    const w2k = try render(&p, .windows_2000, "", &buffer_for_test);
    try std.testing.expect(std.mem.indexOf(u8, w2k, "tweaks") == null and std.mem.indexOf(u8, w2k, "display") == null);
    p.theme = .basic;
    const basic = try render(&p, .windows_xp, "", &buffer_for_test);
    try std.testing.expect(std.mem.indexOf(u8, basic, "classic_theme") == null);
}

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
