const std = @import("std");
const uefi = std.os.uefi;
const SerialIo = uefi.protocol.SerialIo;

var device: ?*SerialIo = null;
/// Bytes sent so far (at 115200 baud a real UART needs ~87 us per byte).
pub var bytes_written: usize = 0;

pub fn init() void {
    const boot_services = uefi.system_table.boot_services orelse return;
    const serial = boot_services.locateProtocol(SerialIo, null) catch return orelse return;

    serial.reset() catch return;
    serial.setAttribute(115_200, 0, 0, .no_parity, 8, .one_stop_bit) catch return;
    device = serial;
}

pub fn writeAscii(text: []const u8) void {
    const serial = device orelse return;
    var start: usize = 0;

    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;
        write(serial, text[start..index]);
        write(serial, "\r\n");
        start = index + 1;
    }

    write(serial, text[start..]);
}

fn write(serial: *SerialIo, bytes: []const u8) void {
    if (bytes.len == 0) return;
    bytes_written += bytes.len;
    _ = serial.write(bytes) catch return;
}
