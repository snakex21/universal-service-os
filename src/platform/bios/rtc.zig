extern fn core_cmos_read(index: u32) callconv(.c) u32;

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

const Raw = struct {
    second: u8,
    minute: u8,
    hour: u8,
    day: u8,
    month: u8,
    year: u8,
    register_b: u8,
};

pub fn read() ?DateTime {
    var attempts: u8 = 0;
    while (attempts < 4) : (attempts += 1) {
        waitForUpdate();
        const first = snapshot();
        waitForUpdate();
        const second = snapshot();
        if (!sameClock(first, second)) continue;
        return decode(second);
    }
    return null;
}

pub fn formatHeader(out: *[26]u8) ?[]const u8 {
    const current = read() orelse return null;
    return formatDateTime(out, current);
}

fn waitForUpdate() void {
    var guard: u32 = 0;
    while (guard < 100000) : (guard += 1) {
        if ((cmos(0x0A) & 0x80) == 0) return;
    }
}

fn snapshot() Raw {
    return .{
        .second = cmos(0x00),
        .minute = cmos(0x02),
        .hour = cmos(0x04),
        .day = cmos(0x07),
        .month = cmos(0x08),
        .year = cmos(0x09),
        .register_b = cmos(0x0B),
    };
}

fn cmos(index: u8) u8 {
    return @truncate(core_cmos_read(index));
}

fn sameClock(a: Raw, b: Raw) bool {
    return a.second == b.second and a.minute == b.minute and a.hour == b.hour and
        a.day == b.day and a.month == b.month and a.year == b.year and a.register_b == b.register_b;
}

fn decode(raw: Raw) ?DateTime {
    const binary = (raw.register_b & 0x04) != 0;
    const hour24 = (raw.register_b & 0x02) != 0;

    const second = decodeNumber(raw.second, binary);
    const minute = decodeNumber(raw.minute, binary);
    const day = decodeNumber(raw.day, binary);
    const month = decodeNumber(raw.month, binary);
    const year_low = decodeNumber(raw.year, binary);

    var hour_raw = raw.hour;
    const pm = !hour24 and (hour_raw & 0x80) != 0;
    hour_raw &= 0x7F;
    var hour = decodeNumber(hour_raw, binary);
    if (!hour24) {
        if (hour == 12) hour = 0;
        if (pm) hour +|= 12;
    }

    if (second > 59 or minute > 59 or hour > 23) return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    const year: u16 = if (year_low < 70) 2000 + @as(u16, year_low) else 1900 + @as(u16, year_low);
    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
}

fn decodeNumber(value: u8, binary: bool) u8 {
    if (binary) return value;
    return ((value >> 4) * 10) + (value & 0x0F);
}

fn formatDateTime(out: *[26]u8, current: DateTime) []const u8 {
    const day_name = weekdayName(current.year, current.month, current.day);
    var offset: usize = 0;
    for (day_name) |byte| {
        out[offset] = byte;
        offset += 1;
    }
    out[offset] = ' ';
    offset += 1;
    write2(out[offset .. offset + 2], current.day);
    offset += 2;
    out[offset] = '.';
    offset += 1;
    write2(out[offset .. offset + 2], current.month);
    offset += 2;
    out[offset] = '.';
    offset += 1;
    write4(out[offset .. offset + 4], current.year);
    offset += 4;
    out[offset] = ' ';
    offset += 1;
    write2(out[offset .. offset + 2], current.hour);
    offset += 2;
    out[offset] = ':';
    offset += 1;
    write2(out[offset .. offset + 2], current.minute);
    offset += 2;
    return out[0..offset];
}

fn weekdayName(year: u16, month: u8, day: u8) []const u8 {
    const names = [_][]const u8{ "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" };
    return names[weekday(year, month, day)];
}

fn weekday(year: u16, month: u8, day: u8) usize {
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: u32 = year;
    if (month < 3) y -= 1;
    return @intCast((y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7);
}

fn write2(out: []u8, value: u8) void {
    out[0] = '0' + (value / 10);
    out[1] = '0' + (value % 10);
}

fn write4(out: []u8, value: u16) void {
    out[0] = '0' + @as(u8, @intCast((value / 1000) % 10));
    out[1] = '0' + @as(u8, @intCast((value / 100) % 10));
    out[2] = '0' + @as(u8, @intCast((value / 10) % 10));
    out[3] = '0' + @as(u8, @intCast(value % 10));
}

test "weekday and fixed header format include day date year and time" {
    const std = @import("std");
    var buffer: [26]u8 = undefined;
    const value = formatDateTime(&buffer, .{ .year = 2026, .month = 9, .day = 6, .hour = 15, .minute = 42, .second = 0 });
    try std.testing.expectEqualStrings("SUNDAY 06.09.2026 15:42", value);
}

test "BCD and 12 hour RTC values decode" {
    const std = @import("std");
    const value = decode(.{
        .second = 0x58,
        .minute = 0x42,
        .hour = 0x83,
        .day = 0x06,
        .month = 0x09,
        .year = 0x26,
        .register_b = 0x00,
    }).?;
    try std.testing.expectEqual(@as(u16, 2026), value.year);
    try std.testing.expectEqual(@as(u8, 15), value.hour);
    try std.testing.expectEqual(@as(u8, 42), value.minute);
}
