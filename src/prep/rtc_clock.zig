//! Bounded, read-only RTC wall time for firmware progress boundaries.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Port selection/NMI restoration belongs to the existing platform callback.
//! This module neither writes RTC data nor depends on interrupts or BDA ticks.
const std = @import("std");

pub const Reader = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u32) ?u32,
    fn byte(self: Reader, index: u8) ?u8 {
        const value = self.read_fn(self.context, index) orelse return null;
        if (value > 255) return null;
        return @intCast(value);
    }
};
pub const Options = struct {
    max_attempts: u8 = 8,
    /// Supply a platform-known CMOS century register (QEMU PC:0x32), or null.
    /// There is no blind probing of arbitrary CMOS locations.
    century_register: ?u8 = null,
    /// Without a century register, YY selects this explicit100-year window.
    /// Default:1970..2069. It is a policy, not a claimed century observation.
    year_window_start: u16 = 1970,
};
pub const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };
const Snapshot = struct {
    second: u8, minute: u8, hour: u8, day: u8, month: u8, year: u8,
    century: ?u8, mode: u8,
};

fn snapshot(reader: Reader, options: Options) ?Snapshot {
    // Never spin waiting for UIP; the bounded outer attempts retry it.
    if ((reader.byte(0x0a) orelse return null) & 0x80 != 0) return null;
    const mode = reader.byte(0x0b) orelse return null;
    if (mode & 0x80 != 0) return null; // SET: updates deliberately inhibited.
    if ((reader.byte(0x0d) orelse return null) & 0x80 == 0) return null; // VRT.
    const result: Snapshot = .{
        .second = reader.byte(0x00) orelse return null,
        .minute = reader.byte(0x02) orelse return null,
        .hour = reader.byte(0x04) orelse return null,
        .day = reader.byte(0x07) orelse return null,
        .month = reader.byte(0x08) orelse return null,
        .year = reader.byte(0x09) orelse return null,
        .century = if (options.century_register) |index| reader.byte(index) orelse return null else null,
        .mode = mode,
    };
    if ((reader.byte(0x0a) orelse return null) & 0x80 != 0) return null;
    return result;
}
fn number(raw: u8, binary: bool, maximum: u8) ?u8 {
    const value: u8 = if (binary) raw else blk: {
        const hi = raw >> 4;
        const lo = raw & 15;
        if (hi > 9 or lo > 9) return null;
        break :blk hi * 10 + lo;
    };
    return if (value <= maximum) value else null;
}
fn date(raw: Snapshot, options: Options) ?DateTime {
    const binary = raw.mode & 4 != 0;
    const yy = number(raw.year, binary, 99) orelse return null;
    const year: u16 = if (raw.century) |cc| blk: {
        const decoded_century = number(cc, binary, 99) orelse return null;
        break :blk @as(u16, decoded_century) * 100 + yy;
    } else blk: {
        const base = options.year_window_start;
        var candidate = base / 100 * 100 + yy;
        if (candidate < base) candidate += 100;
        break :blk candidate;
    };
    var hour: u8 = undefined;
    if (raw.mode & 2 != 0) {
        hour = number(raw.hour, binary, 23) orelse return null;
    } else {
        const twelve = number(raw.hour & 0x7f, binary, 12) orelse return null;
        if (twelve == 0) return null;
        hour = twelve % 12 + @as(u8, if (raw.hour & 0x80 != 0) 12 else 0);
    }
    return .{ .year = year,
        .month = number(raw.month, binary, 12) orelse return null,
        .day = number(raw.day, binary, 31) orelse return null,
        .hour = hour,
        .minute = number(raw.minute, binary, 59) orelse return null,
        .second = number(raw.second, binary, 59) orelse return null };
}
pub fn leap(year: u16) bool { return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0); }
fn leapDaysBefore(year: u16) u64 {
    const previous: u64 = @as(u64, year) - 1;
    return previous / 4 - previous / 100 + previous / 400;
}
pub fn secondsFromDate(value: DateTime) ?u64 {
    if (value.year < 1970 or value.year > 9999 or value.month < 1 or value.month > 12 or
        value.day < 1 or value.hour > 23 or value.minute > 59 or value.second > 59) return null;
    const months = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const last_day = months[value.month - 1] + @as(u8, if (value.month == 2 and leap(value.year)) 1 else 0);
    if (value.day > last_day) return null;
    var days: u64 = @as(u64, value.year - 1970) * 365 + leapDaysBefore(value.year) - leapDaysBefore(1970);
    var month: usize = 0;
    while (month + 1 < value.month) : (month += 1) days += months[month] + @as(u8, if (month == 1 and leap(value.year)) 1 else 0);
    days += value.day - 1;
    return days * 86400 + @as(u64, value.hour) * 3600 + @as(u64, value.minute) * 60 + value.second;
}

/// Unix seconds from two identical, individually UIP-clear snapshots.
/// No cache, allocation, IRQ dependency, write callback or unbounded wait.
/// Invalid/unreadable/battery-invalid RTC always returns null.
pub fn read(reader: Reader, options: Options) ?u64 {
    if (options.max_attempts == 0 or options.max_attempts > 32 or
        options.year_window_start < 1970 or options.year_window_start > 9900) return null;
    if (options.century_register) |index| if (index < 0x0e or index > 0x7f) return null;
    var attempt: u8 = 0;
    while (attempt < options.max_attempts) : (attempt += 1) {
        const first = snapshot(reader, options) orelse continue;
        const second = snapshot(reader, options) orelse continue;
        if (!std.meta.eql(first, second)) continue;
        return secondsFromDate(date(second, options) orelse return null);
    }
    return null;
}

const Fake = struct {
    bytes: [128]u8 = @splat(0),
    calls: usize = 0,
    seconds_reads: usize = 0,
    unavailable: bool = false,
    oversized: bool = false,
    change_seconds: bool = false,
    first_uip: bool = false,
    fn init() Fake {
        var f: Fake = .{};
        f.bytes[0] = 0x56; f.bytes[2] = 0x34; f.bytes[4] = 0x12;
        f.bytes[7] = 0x29; f.bytes[8] = 0x02; f.bytes[9] = 0x24;
        f.bytes[0x0a] = 0x26; f.bytes[0x0b] = 0x02; f.bytes[0x0d] = 0x80; f.bytes[0x32] = 0x20;
        return f;
    }
    fn get(context: *anyopaque, index: u32) ?u32 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.unavailable or index >= self.bytes.len) return null;
        if (self.oversized) return 0x100;
        if (index == 0x0a and self.first_uip and self.calls == 1) return 0x80;
        if (index == 0) {
            self.seconds_reads += 1;
            if (self.change_seconds) return @as(u32, @intCast(self.seconds_reads % 59));
        }
        return self.bytes[index];
    }
    fn reader(self: *Fake) Reader { return .{ .context = self, .read_fn = get }; }
};
const century: Options = .{ .century_register = 0x32 };

test "RTC BCD24h reads an exact leap-day epoch from two stable snapshots" {
    var f = Fake.init();
    try std.testing.expectEqual(@as(?u64, 1709210096), read(f.reader(), century));
    try std.testing.expectEqual(@as(usize, 2), f.seconds_reads);
    try std.testing.expectEqual(@as(usize, 22), f.calls);
}
test "RTC binary24h and BCD12h midnight noon and PM agree" {
    var f = Fake.init();
    f.bytes[0x0b] = 6; f.bytes[0] = 56; f.bytes[2] = 34; f.bytes[4] = 12;
    f.bytes[7] = 29; f.bytes[8] = 2; f.bytes[9] = 24; f.bytes[0x32] = 20;
    try std.testing.expectEqual(@as(?u64, 1709210096), read(f.reader(), century));
    f = Fake.init(); f.bytes[0x0b] = 0; f.bytes[0] = 0; f.bytes[2] = 0;
    f.bytes[4] = 0x12;
    try std.testing.expectEqual(@as(?u64, 1709164800), read(f.reader(), century));
    f.bytes[4] = 0x92;
    try std.testing.expectEqual(@as(?u64, 1709208000), read(f.reader(), century));
    f.bytes[4] = 0x81;
    try std.testing.expectEqual(@as(?u64, 1709211600), read(f.reader(), century));
    f.bytes[4] = 0;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f.bytes[0x0b] = 4; f.bytes[4] = 0x8c;
    f.bytes[7] = 29; f.bytes[9] = 24; f.bytes[0x32] = 20;
    try std.testing.expectEqual(@as(?u64, 1709208000), read(f.reader(), century));
}
test "RTC UIP retries are bounded and no unstable pair is accepted" {
    var f = Fake.init(); f.first_uip = true;
    try std.testing.expectEqual(@as(?u64, 1709210096), read(f.reader(), century));
    try std.testing.expectEqual(@as(usize, 23), f.calls);
    f = Fake.init(); f.bytes[0x0a] = 0x80;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .max_attempts = 3 }));
    try std.testing.expectEqual(@as(usize, 3), f.calls);
    f = Fake.init(); f.change_seconds = true;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .max_attempts = 3, .century_register = 0x32 }));
    try std.testing.expectEqual(@as(usize, 66), f.calls);
}
test "RTC rejects missing wide battery-invalid inhibited and malformed inputs" {
    var f = Fake.init(); f.unavailable = true;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f = Fake.init(); f.oversized = true;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f = Fake.init(); f.bytes[0x0d] = 0;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f = Fake.init(); f.bytes[0x0b] |= 0x80;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    inline for (.{ @as(usize, 0), @as(usize, 2), @as(usize, 4), @as(usize, 7), @as(usize, 8), @as(usize, 9), @as(usize, 0x32) }) |index| {
        f = Fake.init(); f.bytes[index] = 0xfa;
        try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    }
    f = Fake.init(); f.bytes[0x32] = 0;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f = Fake.init(); f.bytes[8] = 0;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
    f = Fake.init(); f.bytes[7] = 0;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
}
test "RTC year window is explicit and known century overrides it" {
    var f = Fake.init();
    f.bytes[0] = 0; f.bytes[2] = 0; f.bytes[4] = 0; f.bytes[7] = 1; f.bytes[8] = 1;
    f.bytes[9] = 0x70;
    try std.testing.expectEqual(@as(?u64, 0), read(f.reader(), .{}));
    f.bytes[9] = 0;
    try std.testing.expectEqual(@as(?u64, 946684800), read(f.reader(), .{}));
    f.bytes[9] = 0x26;
    try std.testing.expectEqual(@as(?u64, 1767225600), read(f.reader(), .{}));
    f.bytes[9] = 0x69; f.bytes[0x32] = 0x19;
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), century));
}
test "RTC calendar validates Gregorian leap and exact day month hour bounds" {
    const jan1970: DateTime = .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    try std.testing.expectEqual(@as(?u64, 0), secondsFromDate(jan1970));
    var value = jan1970; value.year = 2000;
    try std.testing.expectEqual(@as(?u64, 946684800), secondsFromDate(value));
    value.year = 2024; value.month = 2; value.day = 29;
    try std.testing.expectEqual(@as(?u64, 1709164800), secondsFromDate(value));
    value.year = 2100;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
    value.year = 2400;
    try std.testing.expect(secondsFromDate(value) != null);
    value = jan1970; value.month = 4; value.day = 31;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
    value = jan1970; value.hour = 24;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
    value = jan1970; value.minute = 60;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
    value = jan1970; value.second = 60;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
    value = jan1970; value.year = 1969;
    try std.testing.expectEqual(@as(?u64, null), secondsFromDate(value));
}
test "RTC invalid options do not access CMOS" {
    var f = Fake.init();
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .max_attempts = 0 }));
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .max_attempts = 33 }));
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .century_register = 0x80 }));
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .century_register = 9 }));
    try std.testing.expectEqual(@as(?u64, null), read(f.reader(), .{ .year_window_start = 1969 }));
    try std.testing.expectEqual(@as(usize, 0), f.calls);
}
