const console = @import("console.zig");

pub fn writeAscii(text: []const u8) void {
    console.writeAscii(text);
}
