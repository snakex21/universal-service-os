const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const path = @import("path.zig");

pub const Adapter = struct {
    root: *uefi.protocol.File,

    pub fn init(root: *uefi.protocol.File) Adapter {
        return .{ .root = root };
    }

    pub fn source(self: *Adapter) usos.catalog.directory_source.Source {
        return .{ .context = self, .list_fn = list, .page_fn = listPage };
    }

    fn list(context: *anyopaque, directory_path: []const u8, output: []usos.catalog.directory_source.Entry) anyerror!usize {
        const page_result = try listPage(context, directory_path, 0, output);
        if (page_result.has_more) return error.TooManyEntries;
        return page_result.count;
    }

    fn listPage(context: *anyopaque, directory_path: []const u8, skip: usize, output: []usos.catalog.directory_source.Entry) anyerror!usos.catalog.directory_source.Page {
        const self: *Adapter = @ptrCast(@alignCast(context));
        var path_buffer: [path.max_path_units + 1]u16 = undefined;
        const directory_name = path.asciiZ(directory_path, &path_buffer) orelse return error.InvalidPath;
        const directory = self.root.open(directory_name, .read, .{}) catch return error.NotFound;
        defer directory.close() catch {};

        var count: usize = 0;
        var logical_index: usize = 0;
        var entry_buffer: [2048]u8 align(8) = undefined;
        while (true) {
            const bytes_read = directory.read(&entry_buffer) catch return error.Io;
            if (bytes_read == 0) break;
            var offset: usize = 0;
            var progressed = false;
            while (offset + @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 <= bytes_read) {
                const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&entry_buffer[offset]));
                const entry_size: usize = @intCast(info.size);
                if (entry_size < @offsetOf(uefi.protocol.File.Info.File, "_file_name") + 2 or entry_size > bytes_read - offset) return error.InvalidDirectoryEntry;
                progressed = true;
                const utf16_name = std.mem.span(info.getFileName());
                if (!isDotDirectory(utf16_name)) {
                    if (logical_index < skip) {
                        logical_index += 1;
                    } else if (count >= output.len) {
                        return .{ .count = count, .has_more = true };
                    } else {
                        var entry = usos.catalog.directory_source.Entry{};
                        if (!entry.name.setAsciiFromUtf16(utf16_name)) return error.UnsupportedName;
                        entry.directory = info.attribute.directory;
                        entry.size = @intCast(@min(info.file_size, std.math.maxInt(u32)));
                        output[count] = entry;
                        count += 1;
                        logical_index += 1;
                    }
                }
                offset += entry_size;
            }
            if (!progressed) return error.InvalidDirectoryEntry;
        }
        return .{ .count = count, .has_more = false };
    }
};

fn isDotDirectory(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or
        (name.len == 2 and name[0] == '.' and name[1] == '.');
}

test "dot directories are ignored by the UEFI catalog adapter" {
    const dot = [_]u16{'.'};
    const dotdot = [_]u16{ '.', '.' };
    const normal = [_]u16{ 'E', 'F', 'I' };
    try std.testing.expect(isDotDirectory(&dot));
    try std.testing.expect(isDotDirectory(&dotdot));
    try std.testing.expect(!isDotDirectory(&normal));
}
