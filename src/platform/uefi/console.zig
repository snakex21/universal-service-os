const std = @import("std");
const uefi = std.os.uefi;

const buffer_capacity = 192;

pub fn clear() void {
    const out = uefi.system_table.con_out orelse return;
    out.clearScreen() catch return;
}

pub fn writeAscii(text: []const u8) void {
    const out = uefi.system_table.con_out orelse return;
    var buffer: [buffer_capacity:0]u16 = undefined;
    var used: usize = 0;

    for (text) |byte| {
        if (byte == '\n') {
            append(out, &buffer, &used, '\r');
            append(out, &buffer, &used, '\n');
            continue;
        }

        const char: u16 = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
        append(out, &buffer, &used, char);
    }

    flush(out, &buffer, &used);
}

fn append(out: *uefi.protocol.SimpleTextOutput, buffer: *[buffer_capacity:0]u16, used: *usize, char: u16) void {
    if (used.* == buffer_capacity) flush(out, buffer, used);
    buffer[used.*] = char;
    used.* += 1;
}

fn flush(out: *uefi.protocol.SimpleTextOutput, buffer: *[buffer_capacity:0]u16, used: *usize) void {
    if (used.* == 0) return;
    buffer[used.*] = 0;
    _ = out.outputString(buffer) catch {};
    used.* = 0;
}
