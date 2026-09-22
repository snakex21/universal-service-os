// One bounded diagnostic record beside the loader, overwritten on each boot.
const std = @import("std");
const uefi = std.os.uefi;
pub fn record(device: uefi.Handle, directory: []const u16, message: []const u8) void {
    recordNamed(device, directory, std.unicode.utf8ToUtf16LeStringLiteral("usos-boot.log"), message);
}
pub fn recordNamed(device: uefi.Handle, directory: []const u16, name: []const u16, message: []const u8) void {
    const bs = uefi.system_table.boot_services orelse return;
    const fs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};
    var path: [512:0]u16 = undefined;
    if (directory.len + name.len >= path.len) return;
    @memcpy(path[0..directory.len], directory);
    @memcpy(path[directory.len..][0..name.len], name);
    path[directory.len + name.len] = 0;
    const file = root.open(path[0 .. directory.len + name.len :0], .read_write_create, .{}) catch return;
    defer file.close() catch {};
    var bytes = [_]u8{' '} ** 2048;
    const size = @min(message.len, bytes.len - 2);
    @memcpy(bytes[0..size], message[0..size]);
    bytes[bytes.len - 2] = '\r';
    bytes[bytes.len - 1] = '\n';
    _ = file.write(&bytes) catch return;
    file.flush() catch {};
}
