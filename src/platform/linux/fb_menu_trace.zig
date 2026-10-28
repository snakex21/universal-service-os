const std = @import("std");
const linux = std.os.linux;

// tmpfs only: the renderer runs while the stick ESP is read-only (the menu
// wait, tools/stick_write.sh). usos_xp_menu (tools/xp_menu_ui.sh) creates the
// file before the menu and appends it to EFI/USOS-XP/menu-events.log through
// usos_stick_write afterwards; without the file nothing is traced.
pub fn write(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", args) catch return;
    const opened = linux.open("/run/usos-menu-events.log", .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    _ = linux.write(fd, line.ptr, line.len);
}
