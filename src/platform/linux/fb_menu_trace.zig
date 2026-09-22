const std = @import("std");
const linux = std.os.linux;

// The isolated XP init creates this directory and resets the log per boot.
// Production BIOS images without it keep their existing behavior.
pub fn write(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", args) catch return;
    const opened = linux.open("/mnt/esp/EFI/USOS-XP/menu-events.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    _ = linux.write(fd, line.ptr, line.len);
    _ = linux.fsync(fd);
}
