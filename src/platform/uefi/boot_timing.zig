//! Boot timing marks for the UEFI menu path. Each mark stores the CPU time
//! stamp counter; nothing is printed or written until `report`, which runs
//! after the first menu frame is on screen (so measuring never delays it).
//! The report goes to the serial console ("[BOOT_TIMING] ...") and to
//! EFI\USOS\Logs\<name> on the USOS ESP.
//!
//! The TSC is calibrated against BootServices.Stall once, inside `report`.
//! The TSC counts from CPU reset on the machines USOS targets, so the first
//! line also shows roughly how long the firmware ran before BOOTX64.EFI.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const serial = @import("serial.zig");

const max_marks = 40;
const calibration_us = 5000;

var labels: [max_marks][]const u8 = undefined;
var stamps: [max_marks]u64 = undefined;
var count: usize = 0;
var ticks_per_ms: u64 = 0;

pub fn now() u64 {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Records a mark; `label` must be static text.
pub fn mark(label: []const u8) void {
    if (count == max_marks) return;
    labels[count] = label;
    stamps[count] = now();
    count += 1;
}

/// Milliseconds since the first mark (0 before calibration).
pub fn elapsedMs() u64 {
    if (count == 0 or ticks_per_ms == 0) return 0;
    return (now() -| stamps[0]) / ticks_per_ms;
}

/// Ticks per millisecond, calibrating on first use (a 5 ms Stall).
pub fn calibrate() u64 {
    if (ticks_per_ms != 0) return ticks_per_ms;
    const bs = uefi.system_table.boot_services orelse return 0;
    const before = now();
    bs.stall(calibration_us) catch return 0;
    const after = now();
    ticks_per_ms = @max((after -| before) / (calibration_us / 1000), 1);
    return ticks_per_ms;
}

/// TSC ticks for a duration in milliseconds (for callers that compare raw
/// stamps without dividing, e.g. timer callbacks). Needs calibration.
pub fn ticksFor(ms: u64) u64 {
    return ms * ticks_per_ms;
}

var text_buffer: [4096]u8 = undefined;

/// Formats every mark relative to the first one, prints it to serial and
/// writes EFI\USOS\Logs\<name>. Marks are kept, so a later report (for a
/// launch) can include the boot marks too.
pub fn report(root: ?*uefi.protocol.File, name: []const u8, serial_bytes_before: usize) void {
    const per_ms = calibrate();
    const text = format(&text_buffer, per_ms, serial_bytes_before);
    serial.writeAscii(text);
    if (root) |volume| save(volume, name, text) catch |err| {
        serial.writeAscii("[BOOT_TIMING] log write failed: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
    };
}

fn format(buffer: []u8, per_ms: u64, serial_bytes_before: usize) []const u8 {
    var used: usize = 0;
    const put = struct {
        fn f(out: []u8, at: *usize, comptime fmt: []const u8, args: anytype) void {
            const written = std.fmt.bufPrint(out[at.*..], fmt, args) catch return;
            at.* += written.len;
        }
    }.f;
    if (count == 0 or per_ms == 0) {
        put(buffer, &used, "[BOOT_TIMING] no calibrated marks\n", .{});
        return buffer[0..used];
    }
    const first = stamps[0];
    put(buffer, &used, "[BOOT_TIMING] tsc_per_ms={d} since_cpu_reset_at_entry={d}.{d:0>1} ms serial_bytes_before_menu={d}\n", .{
        per_ms,
        first / per_ms,
        (first % per_ms) * 10 / per_ms,
        serial_bytes_before,
    });
    var previous = first;
    for (labels[0..count], stamps[0..count]) |label, stamp| {
        const total_us = (stamp -| first) * 1000 / per_ms;
        const step_us = (stamp -| previous) * 1000 / per_ms;
        put(buffer, &used, "[BOOT_TIMING] {d:>6}.{d:0>3} ms  (+{d:>5}.{d:0>3})  {s}\n", .{ total_us / 1000, total_us % 1000, step_us / 1000, step_us % 1000, label });
        previous = stamp;
    }
    return buffer[0..used];
}

fn save(root: *uefi.protocol.File, name: []const u8, text: []const u8) !void {
    var name_buffer: [64:0]u16 = undefined;
    if (name.len >= name_buffer.len) return error.NameTooLong;
    for (name, 0..) |byte, index| name_buffer[index] = byte;
    name_buffer[name.len] = 0;
    const file_name: [*:0]const u16 = &name_buffer;
    const logs = try root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true });
    defer logs.close() catch {};
    // Replace the previous report (UEFI files have no truncate).
    if (logs.open(file_name, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = try logs.open(file_name, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < text.len) {
        const n = try file.write(text[written..]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
}
