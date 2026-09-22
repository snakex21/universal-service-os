const catalog = @import("catalog");
const storage = @import("storage");

const fat32 = storage.fat32;
const random_reader = storage.random_reader;

const max_components: usize = 16;
const max_component_units: usize = 127;

pub const Adapter = struct {
    fs: fat32.FileSystem,
    reader: random_reader.Reader,

    pub fn init(fs: fat32.FileSystem, reader: random_reader.Reader) Adapter {
        return .{ .fs = fs, .reader = reader };
    }

    pub fn source(self: *Adapter) catalog.directory_source.Source {
        return .{ .context = self, .list_fn = list };
    }

    fn list(context: *anyopaque, directory_path: []const u8, output: []catalog.directory_source.Entry) anyerror!usize {
        const self: *Adapter = @ptrCast(@alignCast(context));
        var component_storage: [max_components][max_component_units]u16 = undefined;
        var component_lengths: [max_components]usize = [_]usize{0} ** max_components;
        var component_slices: [max_components][]const u16 = undefined;
        const component_count = try splitAsciiPath(directory_path, &component_storage, &component_lengths, &component_slices);

        var fat_entries: [catalog.directory_source.max_directory_entries]fat32.DirectoryItem = undefined;
        const count = try fat32.listDirectory(self.fs, self.reader, component_slices[0..component_count], fat_entries[0..@min(output.len, fat_entries.len)]);
        if (count > output.len) return error.TooManyEntries;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var entry = catalog.directory_source.Entry{};
            const name_len: usize = @intCast(fat_entries[index].name_len);
            if (name_len > entry.name.bytes.len) return error.UnsupportedName;
            if (!entry.name.setAsciiFromUtf16(fat_entries[index].name[0..name_len])) return error.UnsupportedName;
            entry.directory = fat_entries[index].isDirectory();
            entry.size = fat_entries[index].size;
            output[index] = entry;
        }
        return count;
    }
};

fn splitAsciiPath(
    path: []const u8,
    component_storage: *[max_components][max_component_units]u16,
    lengths: *[max_components]usize,
    slices: *[max_components][]const u16,
) !usize {
    var component_count: usize = 0;
    var index: usize = 0;
    while (index < path.len) {
        while (index < path.len and (path[index] == '\\' or path[index] == '/')) index += 1;
        if (index >= path.len) break;
        if (component_count >= max_components) return error.PathTooDeep;
        var length: usize = 0;
        while (index < path.len and path[index] != '\\' and path[index] != '/') : (index += 1) {
            if (length >= max_component_units) return error.ComponentTooLong;
            const byte = path[index];
            if (byte > 0x7F) return error.UnsupportedName;
            component_storage[component_count][length] = byte;
            length += 1;
        }
        lengths[component_count] = length;
        slices[component_count] = component_storage[component_count][0..length];
        component_count += 1;
    }
    return component_count;
}

test "BIOS catalog path splitter accepts root and nested paths" {
    const std = @import("std");
    var storage_buf: [max_components][max_component_units]u16 = undefined;
    var lengths: [max_components]usize = [_]usize{0} ** max_components;
    var slices: [max_components][]const u16 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try splitAsciiPath("\\", &storage_buf, &lengths, &slices));
    const count = try splitAsciiPath("\\Systems\\Windows\\Windows 11\\Images", &storage_buf, &lengths, &slices);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u16, 'S'), slices[0][0]);
    try std.testing.expectEqual(@as(u16, 'W'), slices[2][0]);
}
