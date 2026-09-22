const std = @import("std");
const usos = @import("usos");

const catalog = usos.catalog;
const ntfs = usos.storage.ntfs;
const random_reader = usos.storage.random_reader;

const max_components: usize = 16;
const max_component_units: usize = 127;

pub const Adapter = struct {
    fs: ntfs.FileSystem,
    reader: random_reader.Reader,

    pub fn init(fs: ntfs.FileSystem, reader: random_reader.Reader) Adapter {
        return .{ .fs = fs, .reader = reader };
    }

    pub fn source(self: *Adapter) catalog.directory_source.Source {
        return .{ .context = self, .list_fn = list, .page_fn = listPage };
    }

    fn list(context: *anyopaque, directory_path: []const u8, output: []catalog.directory_source.Entry) anyerror!usize {
        const page = try listPage(context, directory_path, 0, output);
        if (page.has_more) return error.TooManyEntries;
        return page.count;
    }

    fn listPage(context: *anyopaque, directory_path: []const u8, skip: usize, output: []catalog.directory_source.Entry) anyerror!catalog.directory_source.Page {
        const self: *Adapter = @ptrCast(@alignCast(context));
        var component_storage: [max_components][max_component_units]u16 = undefined;
        var component_lengths: [max_components]usize = [_]usize{0} ** max_components;
        var component_slices: [max_components][]const u16 = undefined;
        const component_count = try splitAsciiPath(directory_path, &component_storage, &component_lengths, &component_slices);

        var ntfs_entries: [catalog.directory_source.max_directory_entries]ntfs.DirectoryItem = undefined;
        const page = try ntfs.listDirectoryPage(self.fs, self.reader, component_slices[0..component_count], skip, ntfs_entries[0..@min(output.len, ntfs_entries.len)]);
        if (page.count > output.len) return error.TooManyEntries;
        for (ntfs_entries[0..page.count], 0..) |source_entry, index| {
            var entry = catalog.directory_source.Entry{};
            const name_len: usize = @intCast(source_entry.name_len);
            if (name_len > entry.name.bytes.len) return error.UnsupportedName;
            if (!entry.name.setAsciiFromUtf16(source_entry.name[0..name_len])) return error.UnsupportedName;
            entry.directory = source_entry.isDirectory();
            entry.size = @intCast(@min(source_entry.size, std.math.maxInt(u32)));
            output[index] = entry;
        }
        return .{ .count = page.count, .has_more = page.has_more };
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
            if (byte > 0x7f) return error.UnsupportedName;
            component_storage[component_count][length] = byte;
            length += 1;
        }
        lengths[component_count] = length;
        slices[component_count] = component_storage[component_count][0..length];
        component_count += 1;
    }
    return component_count;
}

test "UEFI NTFS catalog path splitter accepts Windows XP Images" {
    var storage_buf: [max_components][max_component_units]u16 = undefined;
    var lengths: [max_components]usize = [_]usize{0} ** max_components;
    var slices: [max_components][]const u16 = undefined;
    const count = try splitAsciiPath("\\Systems\\Windows\\Windows XP\\Images", &storage_buf, &lengths, &slices);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(u16, 'S'), slices[0][0]);
    try std.testing.expectEqual(@as(u16, 'X'), slices[2][8]);
}
