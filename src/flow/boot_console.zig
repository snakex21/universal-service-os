const std = @import("std");

/// wimboot prints its banner, every injected file and the BCD/boot manager
/// patching unless `quiet` is given.
pub fn wimbootOptions(buffer: []u8, index: u32, verbose: bool) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}index={d}", .{ if (verbose) "" else "quiet ", index });
}

/// Kernel options for the isolated XP micro-Linux. Quiet mode keeps
/// /dev/console on serial (last console=) so script output never reaches the
/// screen, and restricts printk to emergencies. Verbose mode restores the
/// earlier on-screen console and full kernel logging.
pub fn xpConsoleOptions(verbose: bool) []const u8 {
    return if (verbose)
        "console=ttyS0,115200n8 console=tty0 rw loglevel=7"
    else
        "console=tty0 console=ttyS0,115200n8 rw quiet loglevel=1 fbcon=nodefer vt.global_cursor_default=0";
}

test "quiet boots hide wimboot output and keep the XP console on serial" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("quiet index=2", try wimbootOptions(&buffer, 2, false));
    try std.testing.expectEqualStrings("index=2", try wimbootOptions(&buffer, 2, true));
    const quiet = xpConsoleOptions(false);
    // /dev/console follows the LAST console= argument.
    try std.testing.expect(std.mem.lastIndexOf(u8, quiet, "console=ttyS0").? > std.mem.lastIndexOf(u8, quiet, "console=tty0").?);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, xpConsoleOptions(true), "quiet") == null);
}
