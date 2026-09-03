const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const path = @import("path.zig");

pub fn countFilesWithExtension(root: *uefi.protocol.File, directory_path: []const u8, extension: []const u8) usize {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return 0;
    const directory = root.open(directory_name, .read, .{}) catch return 0;
    defer directory.close() catch {};

    var count: usize = 0;
    var entry_buffer: [2048]u8 align(8) = undefined;

    while (true) {
        const bytes_read = directory.read(&entry_buffer) catch return count;
        if (bytes_read == 0) break;
        var offset: usize = 0;
        var progressed = false;
        while (offset + @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 <= bytes_read) {
            const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&entry_buffer[offset]));
            const entry_size: usize = @intCast(info.size);
            if (entry_size < @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 or entry_size > bytes_read - offset) break;
            progressed = true;
            if (!info.attribute.directory) {
                if (endsWithAsciiIgnoreCase(std.mem.span(info.getFileName()), extension)) count += 1;
            }
            if (entry_size == 0) break;
            offset += entry_size;
        }
        if (!progressed) break;
    }

    return count;
}

pub fn countFiles(root: *uefi.protocol.File, directory_path: []const u8) usize {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return 0;
    const directory = root.open(directory_name, .read, .{}) catch return 0;
    defer directory.close() catch {};

    var count: usize = 0;
    var entry_buffer: [2048]u8 align(8) = undefined;

    while (true) {
        const bytes_read = directory.read(&entry_buffer) catch return count;
        if (bytes_read == 0) break;
        var offset: usize = 0;
        var progressed = false;
        while (offset + @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 <= bytes_read) {
            const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&entry_buffer[offset]));
            const entry_size: usize = @intCast(info.size);
            if (entry_size < @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 or entry_size > bytes_read - offset) break;
            progressed = true;
            if (!info.attribute.directory) count += 1;
            if (entry_size == 0) break;
            offset += entry_size;
        }
        if (!progressed) break;
    }

    return count;
}

pub fn listDirectories(root: *uefi.protocol.File, directory_path: []const u8, out: []usos.catalog.FixedText) usize {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return 0;
    const directory = root.open(directory_name, .read, .{}) catch return 0;
    defer directory.close() catch {};

    var count: usize = 0;
    var entry_buffer: [2048]u8 align(8) = undefined;

    while (count < out.len) {
        const bytes_read = directory.read(&entry_buffer) catch break;
        if (bytes_read == 0) break;
        var offset: usize = 0;
        var progressed = false;
        while (offset + @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 <= bytes_read) {
            const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&entry_buffer[offset]));
            const entry_size: usize = @intCast(info.size);
            if (entry_size < @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 or entry_size > bytes_read - offset) break;
            progressed = true;
            if (info.attribute.directory) {
                const utf16_name = std.mem.span(info.getFileName());
                if (!isDotDirectory(utf16_name)) {
                    var name = usos.catalog.FixedText{};
                    if (name.setAsciiFromUtf16(utf16_name)) {
                        out[count] = name;
                        count += 1;
                        if (count >= out.len) break;
                    }
                }
            }
            if (entry_size == 0) break;
            offset += entry_size;
        }
        if (!progressed) break;
    }

    return count;
}

pub fn listXmlFiles(root: *uefi.protocol.File, directory_path: []const u8, out: []usos.catalog.FixedText) usize {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return 0;
    const directory = root.open(directory_name, .read, .{}) catch return 0;
    defer directory.close() catch {};

    var count: usize = 0;
    var entry_buffer: [2048]u8 align(8) = undefined;

    while (count < out.len) {
        const bytes_read = directory.read(&entry_buffer) catch break;
        if (bytes_read == 0) break;
        var offset: usize = 0;
        var progressed = false;
        while (offset + @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 <= bytes_read) {
            const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&entry_buffer[offset]));
            const entry_size: usize = @intCast(info.size);
            if (entry_size < @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 or entry_size > bytes_read - offset) break;
            progressed = true;
            if (!info.attribute.directory) {
                const utf16_name = std.mem.span(info.getFileName());
                if (endsWithAsciiIgnoreCase(utf16_name, ".xml")) {
                    var name = usos.catalog.FixedText{};
                    if (name.setAsciiFromUtf16(utf16_name)) {
                        out[count] = name;
                        count += 1;
                        if (count >= out.len) break;
                    }
                }
            }
            if (entry_size == 0) break;
            offset += entry_size;
        }
        if (!progressed) break;
    }

    return count;
}

pub fn exists(root: *uefi.protocol.File, file_path: []const u8) bool {
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const file_name = path.asciiZ(file_path, &path_buffer) orelse return false;
    const file = root.open(file_name, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

pub fn existsInDirectory(root: *uefi.protocol.File, directory_path: []const u8, file_name_ascii: []const u8) bool {
    var directory_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &directory_buffer) orelse return false;
    const directory = root.open(directory_name, .read, .{}) catch return false;
    defer directory.close() catch {};

    var file_buffer: [path.max_path_units + 1]u16 = undefined;
    const file_name = path.asciiZ(file_name_ascii, &file_buffer) orelse return false;
    const file = directory.open(file_name, .read, .{}) catch return false;
    file.close() catch {};
    return true;
}

fn isDotDirectory(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.');
}

fn endsWithAsciiIgnoreCase(name: []const u16, suffix: []const u8) bool {
    if (suffix.len > name.len) return false;
    const start = name.len - suffix.len;
    for (suffix, 0..) |expected, index| {
        const actual = name[start + index];
        if (actual > 0x7f) return false;
        if (asciiLower(@intCast(actual)) != asciiLower(expected)) return false;
    }
    return true;
}

fn asciiLower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + ('a' - 'A') else value;
}

test "dot directories are ignored" {
    const dot = [_]u16{'.'};
    const dotdot = [_]u16{ '.', '.' };
    const normal = [_]u16{ 'T', 'o', 'o', 'l' };
    try std.testing.expect(isDotDirectory(&dot));
    try std.testing.expect(isDotDirectory(&dotdot));
    try std.testing.expect(!isDotDirectory(&normal));
}

test "extension matching is ASCII case insensitive" {
    const std_testing = std.testing;
    const name = [_]u16{ 'W', 'i', 'n', '1', '1', '.', 'I', 'S', 'O' };
    try std_testing.expect(endsWithAsciiIgnoreCase(&name, ".iso"));
}
