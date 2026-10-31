//! The PC's RTC holds LOCAL time (Windows' convention; the X470 does), while
//! the MiniOS writers stamp NTFS times in UTC. 2026-10-31: MiniOS took the
//! firmware time as UTC, so every file it wrote was one hour ahead in Poland.
//! The USOS menu knows the flow's time zone (profile / answer Windows zone,
//! or the media language's default); it hands MiniOS `rtc_shift=` = local
//! minus UTC in seconds for "now", DST included, and usosprep subtracts it.
//! Without a known zone: EFI_TIME.TimeZone when it is not 2047
//! (EFI_UNSPECIFIED_TIMEZONE; UEFI 2.7+: Localtime = UTC + TimeZone),
//! otherwise 0 (as before).
//!
//! DST rules: the EU rule (last Sunday of March / October, 01:00 UTC) for
//! European zones that observe it, the US / Canada rule (second Sunday of
//! March 02:00 local, first Sunday of November 02:00 local daylight) for
//! North American zones; every other zone uses its standard offset only.
const std = @import("std");
const tables = @import("answer/tables.zig");

pub const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };
pub const Rule = enum { none, eu, us };

/// "(UTC+01:00) ..." / "(UTC-03:30) ..." / "(UTC) ..." -> minutes east of UTC.
pub fn standardOffsetMinutes(label: []const u8) ?i32 {
    if (!std.mem.startsWith(u8, label, "(UTC")) return null;
    if (label.len > 4 and label[4] == ')') return 0;
    if (label.len < 11 or (label[4] != '+' and label[4] != '-') or label[7] != ':' or label[10] != ')') return null;
    const h = std.fmt.parseInt(i32, label[5..7], 10) catch return null;
    const m = std.fmt.parseInt(i32, label[8..10], 10) catch return null;
    const v = h * 60 + m;
    return if (label[4] == '-') -v else v;
}

const no_dst_europe = [_][]const u8{ "Europe/Moscow", "Europe/Istanbul", "Europe/Minsk", "Europe/Kaliningrad", "Europe/Samara", "Europe/Volgograd", "Europe/Astrakhan", "Europe/Saratov", "Europe/Ulyanovsk", "Europe/Kirov" };
const us_zones = [_][]const u8{ "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Halifax", "America/St_Johns", "America/Toronto", "America/Vancouver", "America/Winnipeg", "America/Edmonton", "America/Indiana/Indianapolis", "America/Detroit" };

pub fn ruleFor(id: []const u8) Rule {
    for (us_zones) |z| if (std.mem.eql(u8, id, z)) return .us;
    if (std.mem.startsWith(u8, id, "Europe/")) {
        for (no_dst_europe) |z| if (std.mem.eql(u8, id, z)) return .none;
        return .eu;
    }
    if (std.mem.eql(u8, id, "Atlantic/Azores") or std.mem.eql(u8, id, "Atlantic/Canary") or std.mem.eql(u8, id, "Atlantic/Faroe")) return .eu;
    return .none;
}

/// Days since 1970-01-01 (proleptic Gregorian).
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The date/time read as if it were UTC, in Unix seconds.
pub fn asUnix(t: DateTime) i64 {
    return daysFromCivil(t.year, t.month, t.day) * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}

fn weekday(days: i64) i64 { return @mod(days + 4, 7); } // 1970-01-01 was a Thursday; 0 = Sunday
fn lastSunday(year: i64, month: u8) i64 {
    const next = if (month == 12) daysFromCivil(year + 1, 1, 1) else daysFromCivil(year, month + 1, 1);
    const last = next - 1;
    return last - weekday(last);
}
fn nthSunday(year: i64, month: u8, n: i64) i64 {
    const first = daysFromCivil(year, month, 1);
    return first + @mod(7 - weekday(first), 7) + (n - 1) * 7;
}

/// Local minus UTC in seconds for the local RTC time `local` in `zone`.
pub fn shiftSeconds(zone: *const tables.TimeZone, local: DateTime) ?i32 {
    const standard = (standardOffsetMinutes(zone.label) orelse return null) * 60;
    const l = asUnix(local);
    const dst = switch (ruleFor(zone.id)) {
        .none => false,
        .eu => blk: {
            // In UTC; the local time is taken as daylight time for the test,
            // so the ambiguous hour at the October change counts as DST.
            const utc = l - standard - 3600;
            const start = lastSunday(local.year, 3) * 86400 + 3600;
            const end = lastSunday(local.year, 10) * 86400 + 3600;
            break :blk utc >= start and utc < end;
        },
        .us => blk: {
            const start = nthSunday(local.year, 3, 2) * 86400 + 2 * 3600;
            const end = nthSunday(local.year, 11, 1) * 86400 + 1 * 3600;
            break :blk l >= start and l < end;
        },
    };
    return standard + @as(i32, if (dst) 3600 else 0);
}

/// EFI_TIME.TimeZone (minutes, Localtime = UTC + TimeZone) and Daylight
/// (bit 1 EFI_TIME_IN_DAYLIGHT: one more hour); null when unspecified.
pub fn efiShiftSeconds(time_zone: i16, daylight: u8) ?i32 {
    if (time_zone == 2047 or time_zone < -1440 or time_zone > 1440) return null;
    return @as(i32, time_zone) * 60 + @as(i32, if (daylight & 2 != 0) 3600 else 0);
}

test "standard offsets from the menu labels" {
    try std.testing.expectEqual(@as(?i32, 60), standardOffsetMinutes("(UTC+01:00) Sarajevo, Skopje, Warsaw, Zagreb"));
    try std.testing.expectEqual(@as(?i32, -210), standardOffsetMinutes("(UTC-03:30) Newfoundland"));
    try std.testing.expectEqual(@as(?i32, 0), standardOffsetMinutes("(UTC) Coordinated Universal Time"));
    try std.testing.expectEqual(@as(?i32, null), standardOffsetMinutes("Warsaw"));
    // Every table zone has a parsable label.
    for (tables.time_zones) |z| try std.testing.expect(standardOffsetMinutes(z.label) != null);
}

test "Warsaw: CET in winter, CEST in summer, EU change days" {
    const waw = tables.timeZone("Europe/Warsaw").?;
    try std.testing.expectEqual(Rule.eu, ruleFor(waw.id));
    // X470 2026-10-31 evening: winter time already (change 2026-10-25).
    try std.testing.expectEqual(@as(?i32, 3600), shiftSeconds(waw, .{ .year = 2026, .month = 10, .day = 31, .hour = 21, .minute = 0, .second = 0 }));
    try std.testing.expectEqual(@as(?i32, 7200), shiftSeconds(waw, .{ .year = 2026, .month = 7, .day = 1, .hour = 12, .minute = 0, .second = 0 }));
    // 2026-03-29 (last Sunday of March): 01:59 CET, 03:00 CEST.
    try std.testing.expectEqual(@as(?i32, 3600), shiftSeconds(waw, .{ .year = 2026, .month = 3, .day = 29, .hour = 1, .minute = 59, .second = 0 }));
    try std.testing.expectEqual(@as(?i32, 7200), shiftSeconds(waw, .{ .year = 2026, .month = 3, .day = 29, .hour = 3, .minute = 0, .second = 0 }));
    // 2026-10-25: 01:59 CEST, 03:00 CET.
    try std.testing.expectEqual(@as(?i32, 7200), shiftSeconds(waw, .{ .year = 2026, .month = 10, .day = 25, .hour = 1, .minute = 59, .second = 0 }));
    try std.testing.expectEqual(@as(?i32, 3600), shiftSeconds(waw, .{ .year = 2026, .month = 10, .day = 25, .hour = 3, .minute = 0, .second = 0 }));
}

test "US rule, no-DST zones, EFI fallback, civil days" {
    const ny = tables.timeZone("America/New_York") orelse tables.timeZone("America/Chicago").?;
    const base: i32 = standardOffsetMinutes(ny.label).? * 60;
    // 2026-03-08 is the second Sunday of March, 2026-11-01 the first of November.
    try std.testing.expectEqual(@as(?i32, base), shiftSeconds(ny, .{ .year = 2026, .month = 3, .day = 8, .hour = 1, .minute = 59, .second = 0 }));
    try std.testing.expectEqual(@as(?i32, base + 3600), shiftSeconds(ny, .{ .year = 2026, .month = 3, .day = 8, .hour = 3, .minute = 0, .second = 0 }));
    try std.testing.expectEqual(@as(?i32, base), shiftSeconds(ny, .{ .year = 2026, .month = 11, .day = 1, .hour = 1, .minute = 0, .second = 0 }));
    if (tables.timeZone("Asia/Tokyo")) |tokyo| try std.testing.expectEqual(@as(?i32, 9 * 3600), shiftSeconds(tokyo, .{ .year = 2026, .month = 7, .day = 1, .hour = 0, .minute = 0, .second = 0 }));
    if (tables.timeZone("Europe/Moscow")) |m| try std.testing.expectEqual(Rule.none, ruleFor(m.id));
    try std.testing.expectEqual(@as(?i32, null), efiShiftSeconds(2047, 0));
    try std.testing.expectEqual(@as(?i32, 3600), efiShiftSeconds(60, 0));
    try std.testing.expectEqual(@as(?i32, 7200), efiShiftSeconds(60, 3));
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20757), daysFromCivil(2026, 10, 31));
    try std.testing.expectEqual(@as(i64, 4), weekday(daysFromCivil(1970, 1, 1)) + 0);
    try std.testing.expectEqual(daysFromCivil(2026, 3, 29), lastSunday(2026, 3));
    try std.testing.expectEqual(daysFromCivil(2026, 10, 25), lastSunday(2026, 10));
}
