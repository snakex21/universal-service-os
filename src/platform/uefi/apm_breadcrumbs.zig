//! CSMWrap 3.1.2-usos8 APM power-off breadcrumbs (patch 0009, SeaBIOS
//! apm.c "USOS 0009"): SeaBIOS records every step of an APM 5307h power-off
//! in battery-backed CMOS, the RTC alarm bytes 01h/03h/05h, so a machine
//! that hangs on the way off (Windows 98 SE on the X470, 2026-10-15) still
//! tells what happened. The next boot of the USOS stick appends the decoded
//! record to EFI\USOS\Logs\apm-off.txt (the same firmware FAT write path as
//! input-devices.txt) and clears the bytes.
//!
//! Every value is a valid alarm time in the RTC's format (Status B DM: BCD
//! or binary), because edk2 PcRtcInit resets an invalid alarm to 00:00:00
//! at every boot:
//!   01h seconds  40 + last step (0-15)            40 = armed, never called
//!   03h minutes  path of the last 5307h off call * 15 + call count (0-14)
//!   05h hours    1 + bitmap (bit0 32-bit PM connect, bit1 real-mode or
//!                16-bit PM connect, bit2 other runtime calls)
//!
//! A record = seconds 40-55 and hours 1-8. A machine that never ran usos8
//! has 00:00:00 there (edk2 default, and what this module writes back), so
//! it is left alone; a user-set alarm in that range would read as a record
//! (the alarm is not armed by anything in USOS). The CMOS index keeps the
//! firmware's NMI bit (as edk2 PcRtc does) and the accesses run at
//! TPL_HIGH_LEVEL, so no firmware RTC access comes in between an index and
//! its data byte.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const serial = @import("serial.zig");

/// The three raw CMOS bytes and Status B (for BCD vs binary).
pub const Raw = struct {
    seconds: u8,
    minutes: u8,
    hours: u8,
    status_b: u8,
};

pub const Crumbs = struct {
    step: u8,
    path: u8,
    calls: u8,
    fns: u8,
};

fn value(raw: u8, binary: bool) ?u8 {
    if (binary) return raw;
    const hi = raw >> 4;
    const lo = raw & 0x0F;
    if (hi > 9 or lo > 9) return null;
    return hi * 10 + lo;
}

/// The record in `raw`, or null when the bytes hold no usos8 record.
pub fn parse(raw: Raw) ?Crumbs {
    const binary = raw.status_b & 0x04 != 0;
    const s = value(raw.seconds, binary) orelse return null;
    const m = value(raw.minutes, binary) orelse return null;
    const h = value(raw.hours, binary) orelse return null;
    if (s < 40 or s > 55 or h < 1 or h > 8 or m > 59) return null;
    return .{ .step = s - 40, .path = m / 15, .calls = m % 15, .fns = h - 1 };
}

const step_names = [16][]const u8{
    "armed by CSMWrap, 5307h power-off never called",
    "5307h power-off entered",
    "ACPI_ENABLE written to SMI_CMD (stopped there: the SMI did not return)",
    "SCI_EN = 1 (ACPI mode on)",
    "SCI_EN still 0 after 1 s",
    "PM1/GPE0 status cleared, enables 0",
    "S5 written (SLP_TYP|SLP_EN), still on during or after the 2 s wait",
    "helper-core UEFI ResetSystem posted (stopped there: it never returned)",
    "helper-core ResetSystem timed out (2 s)",
    "helper-core ResetSystem returned or unavailable",
    "unknown step 10",
    "unknown step 11",
    "unknown step 12",
    "unknown step 13",
    "unknown step 14",
    "gave up, 5307h returned AH=60h to the caller",
};

const fn_names = [3][]const u8{
    "5303 32-bit PM connect",
    "5301/5302 real-mode/16-bit PM connect",
    "5305/5306/5308/530A/530B/530D/530F runtime calls",
};

const path_names = [4][]const u8{ "none", "INT 15h (real/V86)", "16-bit PM", "32-bit PM" };

pub fn stepName(step: u8) []const u8 {
    return step_names[step & 0x0F];
}

/// The log record in `out`; cut short when `out` is too small.
pub fn decode(out: []u8, raw: Raw, c: Crumbs) []const u8 {
    var used: usize = 0;
    const parts = .{
        .{ "CMOS 01h={x:0>2} 03h={x:0>2} 05h={x:0>2} (Status B {x:0>2})\n", .{ raw.seconds, raw.minutes, raw.hours, raw.status_b } },
        .{ "last step: {d} = {s}\n", .{ c.step, stepName(c.step) } },
        .{ "5307h power-off calls: {d}{s} (last from {s})\n", .{ c.calls, if (c.calls == 14) "+" else "", path_names[c.path & 3] } },
        .{ "APM functions seen:", .{} },
    };
    inline for (parts) |part| {
        const r = std.fmt.bufPrint(out[used..], part[0], part[1]) catch return out[0..used];
        used += r.len;
    }
    if (c.fns == 0) {
        const r = std.fmt.bufPrint(out[used..], " none besides 5307", .{}) catch return out[0..used];
        used += r.len;
    }
    for (fn_names, 0..) |name, i| {
        if (c.fns & (@as(u8, 1) << @intCast(i)) == 0) continue;
        const r = std.fmt.bufPrint(out[used..], " [{s}]", .{name}) catch return out[0..used];
        used += r.len;
    }
    const tail = std.fmt.bufPrint(out[used..], "\n", .{}) catch return out[0..used];
    used += tail.len;
    return out[0..used];
}

const io = struct {
    inline fn write8(port: u16, data: u8) void {
        asm volatile ("outb %[data], %[port]"
            :
            : [data] "{al}" (data),
              [port] "{dx}" (port),
            : .{ .memory = true });
    }

    inline fn read8(port: u16) u8 {
        return asm volatile ("inb %[port], %[data]"
            : [data] "={al}" (-> u8),
            : [port] "{dx}" (port),
            : .{ .memory = true });
    }
};

fn cmosRead(index: u8) u8 {
    io.write8(0x70, (io.read8(0x70) & 0x80) | index);
    return io.read8(0x71);
}

fn cmosWrite(index: u8, data: u8) void {
    io.write8(0x70, (io.read8(0x70) & 0x80) | index);
    io.write8(0x71, data);
}

const Taken = struct { raw: Raw, crumbs: Crumbs };

/// Reads the bytes; when they hold a record, writes 00:00:00 back (valid in
/// BCD and binary; the alarm interrupt stays off) and returns the record.
fn take() ?Taken {
    const services = uefi.system_table.boot_services orelse return null;
    const old = services.raiseTpl(.high_level);
    defer services.restoreTpl(old);
    const raw = Raw{ .seconds = cmosRead(0x01), .minutes = cmosRead(0x03), .hours = cmosRead(0x05), .status_b = cmosRead(0x0B) };
    const crumbs = parse(raw) orelse return null;
    cmosWrite(0x01, 0);
    cmosWrite(0x03, 0);
    cmosWrite(0x05, 0);
    return .{ .raw = raw, .crumbs = crumbs };
}

const max_log_bytes = 64 * 1024;

/// Once per boot from the menu (manual_view.afterFirstFrame).
pub fn write(root: *uefi.protocol.File) void {
    const record = take() orelse return;
    var buffer: [768]u8 = undefined;
    const head = blk: {
        if (uefi.system_table.runtime_services.getTime()) |result| {
            const now = result[0];
            break :blk std.fmt.bufPrint(&buffer, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}] USOS {s}: CSMWrap APM power-off record\n", .{ now.year, now.month, now.day, now.hour, now.minute, usos.build_info.id }) catch "";
        } else |_| break :blk std.fmt.bufPrint(&buffer, "[no clock] USOS {s}: CSMWrap APM power-off record\n", .{usos.build_info.id}) catch "";
    };
    var used = head.len;
    used += decode(buffer[used .. buffer.len - 1], record.raw, record.crumbs).len;
    buffer[used] = '\n';
    used += 1;
    serial.writeAscii("[APM_OFF] ");
    serial.writeAscii(buffer[0..used]);
    append(root, buffer[0..used]) catch |err| {
        serial.writeAscii("[APM_OFF] save failed: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
    };
}

fn append(root: *uefi.protocol.File, text: []const u8) !void {
    const logs = try root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true });
    defer logs.close() catch {};
    const name = std.unicode.utf8ToUtf16LeStringLiteral("apm-off.txt");
    var file = try logs.open(name, .read_write_create, .{});
    try file.setPosition(0xFFFF_FFFF_FFFF_FFFF); // UEFI: end of file
    if (try file.getPosition() > max_log_bytes) {
        // Start over instead of growing without bound (UEFI has no truncate).
        _ = file.delete() catch {};
        file = try logs.open(name, .read_write_create, .{});
    }
    defer file.close() catch {};
    var written: usize = 0;
    while (written < text.len) {
        const n = try file.write(text[written..]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
}

const bcd_b: u8 = 0x02; // 24-hour, BCD (SeaBIOS/edk2/AMI default)
const bin_b: u8 = 0x06; // 24-hour, binary

test "parse: X470-style hang after the S5 write (BCD)" {
    // step 6 -> 46 -> 0x46; 32-bit PM (3) * 15 + 1 call = 46 -> 0x46;
    // 1 + (32-bit connect | runtime calls) = 6 -> 0x06
    const raw = Raw{ .seconds = 0x46, .minutes = 0x46, .hours = 0x06, .status_b = bcd_b };
    const c = parse(raw).?;
    try std.testing.expectEqual(@as(u8, 6), c.step);
    try std.testing.expectEqual(@as(u8, 3), c.path);
    try std.testing.expectEqual(@as(u8, 1), c.calls);
    try std.testing.expectEqual(@as(u8, 5), c.fns);
    var buf: [512]u8 = undefined;
    const text = decode(&buf, raw, c);
    try std.testing.expect(std.mem.indexOf(u8, text, "CMOS 01h=46 03h=46 05h=06 (Status B 02)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last step: 6 = S5 written") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "calls: 1 (last from 32-bit PM)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[5303 32-bit PM connect] [5305/5306/5308/530A/530B/530D/530F runtime calls]\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5301/5302") == null);
}

test "parse: the same record in binary mode" {
    const c = parse(.{ .seconds = 46, .minutes = 46, .hours = 6, .status_b = bin_b }).?;
    try std.testing.expectEqual(@as(u8, 6), c.step);
    try std.testing.expectEqual(@as(u8, 3), c.path);
    try std.testing.expectEqual(@as(u8, 5), c.fns);
    // 0x46 read as binary is 70 seconds: no record
    try std.testing.expect(parse(.{ .seconds = 0x46, .minutes = 0, .hours = 1, .status_b = bin_b }) == null);
}

test "parse: armed only, nothing called" {
    const raw = Raw{ .seconds = 0x40, .minutes = 0x00, .hours = 0x01, .status_b = bcd_b };
    const c = parse(raw).?;
    var buf: [512]u8 = undefined;
    const text = decode(&buf, raw, c);
    try std.testing.expect(std.mem.indexOf(u8, text, "never called") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "calls: 0 (last from none)") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "APM functions seen: none besides 5307\n"));
}

test "parse: no record in edk2 defaults, cleared bytes, invalid BCD or out-of-range values" {
    try std.testing.expect(parse(.{ .seconds = 0, .minutes = 0, .hours = 0, .status_b = bcd_b }) == null);
    try std.testing.expect(parse(.{ .seconds = 0x39, .minutes = 0, .hours = 1, .status_b = bcd_b }) == null);
    try std.testing.expect(parse(.{ .seconds = 0x56, .minutes = 0, .hours = 1, .status_b = bcd_b }) == null);
    try std.testing.expect(parse(.{ .seconds = 0x46, .minutes = 0, .hours = 0x09, .status_b = bcd_b }) == null);
    try std.testing.expect(parse(.{ .seconds = 0x4A, .minutes = 0, .hours = 1, .status_b = bcd_b }) == null);
    try std.testing.expect(parse(.{ .seconds = 0xA6, .minutes = 0x07, .hours = 0x94, .status_b = bcd_b }) == null); // draft encoding
    try std.testing.expect(parse(.{ .seconds = 0x46, .minutes = 0x60, .hours = 1, .status_b = bcd_b }) == null);
}

test "decode: every step and path has a name, call count saturates" {
    for (0..16) |s| try std.testing.expect(stepName(@intCast(s)).len > 0);
    try std.testing.expectEqualStrings("gave up, 5307h returned AH=60h to the caller", stepName(15));
    const raw = Raw{ .seconds = 0x55, .minutes = 0x44, .hours = 0x08, .status_b = bcd_b };
    const c = parse(raw).?; // step 15, path 2 * 15 + 14
    try std.testing.expectEqual(@as(u8, 15), c.step);
    var buf: [512]u8 = undefined;
    const text = decode(&buf, raw, c);
    try std.testing.expect(std.mem.indexOf(u8, text, "calls: 14+ (last from 16-bit PM)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[5301/5302 real-mode/16-bit PM connect]") != null);
}

test "decode: a small buffer cuts the record, never overflows" {
    var buf: [40]u8 = undefined;
    const raw = Raw{ .seconds = 0x46, .minutes = 0x46, .hours = 0x08, .status_b = bcd_b };
    const text = decode(&buf, raw, parse(raw).?);
    try std.testing.expect(text.len <= buf.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "CMOS 01h=46"));
}
