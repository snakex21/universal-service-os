const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const path = @import("path.zig");

pub fn scan(root: *uefi.protocol.File, directory_path: []const u8) usos.catalog.ImageList {
    var result = usos.catalog.ImageList{};
    var path_buffer: [path.max_path_units + 1]u16 = undefined;
    const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return result;
    const directory = root.open(directory_name, .read, .{}) catch return result;
    defer directory.close() catch {};

    var entry_buffer: [2048]u8 align(8) = undefined;
    while (result.len < usos.catalog.image_list_max_items) {
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
                var name = usos.catalog.FixedText{};
                if (name.setAsciiFromUtf16(utf16_name)) {
                    const ascii_name = name.slice();
                    if (usos.catalog.ImageKind.fromFilename(ascii_name)) |kind| {
                        if (!result.append(.{ .name = name, .kind = kind })) break;
                    }
                }
            }
            if (entry_size == 0) break;
            offset += entry_size;
        }
        if (!progressed) break;
    }

    return result;
}
