const std = @import("std");
const uefi = std.os.uefi;

pub const max_path_units: usize = 511;
const max_component_units: usize = 255;
const dir_buffer_size: usize = 1024;

pub const ResolveError = error{
    NotFound,
    PathTooLong,
    ComponentTooLong,
    NonAsciiRequest,
} || uefi.protocol.File.ReadError || uefi.protocol.File.OpenError || uefi.protocol.File.SeekError;

pub fn resolve(root: *uefi.protocol.File, requested_path: []const u8, output: *[max_path_units + 1:0]u16) ResolveError![:0]const u16 {
    var current = root;
    var current_owned = false;
    defer if (current_owned) current.close() catch {};

    var used: usize = 0;
    var components = std.mem.tokenizeAny(u8, requested_path, "\\/");
    while (components.next()) |wanted| {
        var actual: [max_component_units + 1:0]u16 = undefined;
        const actual_name = try findComponent(current, wanted, &actual);

        if (used + 1 + actual_name.len > max_path_units) return error.PathTooLong;
        output[used] = '\\';
        used += 1;
        @memcpy(output[used .. used + actual_name.len], actual_name);
        used += actual_name.len;
        output[used] = 0;

        if (components.peek() != null) {
            const child = try current.open(actual_name.ptr, .read, .{});
            if (current_owned) current.close() catch {};
            current = child;
            current_owned = true;
        }
    }

    output[used] = 0;
    return output[0..used :0];
}

fn findComponent(directory: *uefi.protocol.File, wanted: []const u8, output: *[max_component_units + 1:0]u16) ResolveError![:0]const u16 {
    if (wanted.len > max_component_units) return error.ComponentTooLong;
    for (wanted) |byte| if (byte > 0x7f) return error.NonAsciiRequest;

    try directory.setPosition(0);
    var raw: [dir_buffer_size]u8 align(8) = undefined;

    while (true) {
        const read_len = try directory.read(&raw);
        if (read_len == 0) return error.NotFound;
        if (read_len < @sizeOf(uefi.protocol.File.Info.File)) continue;

        const info: *const uefi.protocol.File.Info.File = @ptrCast(&raw);
        const name_z = info.getFileName();
        const name = std.mem.sliceTo(name_z, 0);
        if (!asciiUtf16EqlIgnoreCase(name, wanted)) continue;
        if (name.len > max_component_units) return error.ComponentTooLong;

        @memcpy(output[0..name.len], name);
        output[name.len] = 0;
        return output[0..name.len :0];
    }
}

fn asciiUtf16EqlIgnoreCase(actual: []const u16, wanted: []const u8) bool {
    if (actual.len != wanted.len) return false;
    for (actual, wanted) |left, right| {
        if (left > 0x7f) return false;
        if (std.ascii.toLower(@as(u8, @intCast(left))) != std.ascii.toLower(right)) return false;
    }
    return true;
}

test "ASCII UTF-16 matching is case insensitive" {
    const upper = [_]u16{ 'B', 'O', 'O', 'T', 'X', '6', '4', '.', 'E', 'F', 'I' };
    try std.testing.expect(asciiUtf16EqlIgnoreCase(&upper, "bootx64.efi"));
    try std.testing.expect(!asciiUtf16EqlIgnoreCase(&upper, "bootaa64.efi"));
}

test "ASCII UTF-16 matching preserves exact directory names while comparing without case" {
    const mixed = [_]u16{ 'e', 'F', 'i', '-', 'P', 'L' };
    try std.testing.expect(asciiUtf16EqlIgnoreCase(&mixed, "EFI-pl"));
    try std.testing.expect(!asciiUtf16EqlIgnoreCase(&mixed, "efi"));
}

test "ASCII UTF-16 matching rejects non-ASCII media names for an ASCII request" {
    const non_ascii = [_]u16{ 'b', 0x00f3, 'o', 't' };
    try std.testing.expect(!asciiUtf16EqlIgnoreCase(&non_ascii, "boot"));
}
