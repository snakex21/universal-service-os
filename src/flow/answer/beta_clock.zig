//! Date selection only. Writing/restoring a motherboard RTC is a separate
//! integration step; this module never reads or changes a host clock.
const std = @import("std");

pub fn validDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    const y = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const m = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const d = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    for (value, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    if (y < 1980 or y > 2099 or m == 0 or m > 12) return false;
    const leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
    const days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return d > 0 and d <= days[m - 1];
}

pub fn validSetting(value: []const u8) bool {
    return value.len == 0 or std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "auto") or validDate(value);
}

const Entry = struct { system: []const u8, build: u32, date: []const u8 };
// Dates for these particular builds, not general expiry dates. Provenance and
// the Windows 7 Beta expiry correction are documented in the support matrix.
pub const dates = [_]Entry{
    .{ .system = "windows-whistler", .build = 2542, .date = "2001-08-15" },
    .{ .system = "windows-neptune", .build = 5111, .date = "1999-12-11" },
    .{ .system = "windows-longhorn", .build = 5048, .date = "2005-05-01" },
    .{ .system = "windows-7-beta", .build = 7000, .date = "2009-01-15" },
    .{ .system = "windows-millennium", .build = 2525, .date = "2000-02-01" },
    .{ .system = "windows-nashville", .build = 999, .date = "1995-12-01" },
};

pub fn select(system: []const u8, build: u32, setting: []const u8) !?[]const u8 {
    if (setting.len == 0 or std.mem.eql(u8, setting, "off")) return null;
    if (!validSetting(setting)) return error.InvalidBetaClock;
    if (!std.mem.eql(u8, setting, "auto")) return setting;
    for (dates) |entry| if (entry.build == build and std.mem.eql(u8, entry.system, system)) return entry.date;
    return error.UnknownBetaClockBuild;
}

pub fn qemuRtc(buffer: []u8, date: ?[]const u8) ![]const u8 {
    const value = date orelse return "base=localtime";
    if (!validDate(value)) return error.InvalidBetaClock;
    return std.fmt.bufPrint(buffer, "base={s}T12:00:00", .{value});
}

test "beta clock validates real calendar dates and keeps default clocks" {
    for ([_][]const u8{ "1980-01-01", "2000-02-29", "2009-01-15", "2099-12-31" }) |v| try std.testing.expect(validDate(v));
    for ([_][]const u8{ "1900-02-29", "2001-02-29", "2005-04-31", "2009-00-01", "2009-01-00", "2009-1-15", "2009-01-15;id" }) |v| try std.testing.expect(!validDate(v));
    try std.testing.expect((try select("windows-7", 7601, "")) == null);
    try std.testing.expect((try select("windows-7-beta", 7000, "off")) == null);
    try std.testing.expectEqualStrings("2009-01-15", (try select("windows-7-beta", 7000, "auto")).?);
    try std.testing.expectError(error.UnknownBetaClockBuild, select("windows-whistler", 2257, "auto"));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("base=localtime", try qemuRtc(&b, null));
    try std.testing.expectEqualStrings("base=1999-12-11T12:00:00", try qemuRtc(&b, "1999-12-11"));
}
