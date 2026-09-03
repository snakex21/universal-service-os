const std = @import("std");
const uefi = std.os.uefi;
const path = @import("path.zig");

pub fn into(root: *uefi.protocol.File, file_path: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const file_name = path.asciiZ(file_path, &path_buffer) orelse return null;
    const file = root.open(file_name, .read, .{}) catch return null;
    defer file.close() catch {};

    const read_len = file.read(buffer) catch return null;
    if (read_len == buffer.len) {
        var probe: [1]u8 = undefined;
        if ((file.read(&probe) catch return null) != 0) return null;
    }
    return buffer[0..read_len];
}
