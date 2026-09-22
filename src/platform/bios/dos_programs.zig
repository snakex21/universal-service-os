//! Copy a bounded DOS 8.3 program tree from NTFS into the session's RAM disk.
const storage = @import("storage");
const dos = @import("dos_fat.zig");
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;
const wide = @import("std").unicode.utf8ToUtf16LeStringLiteral;

pub fn copy(fs: ntfs.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder) !void {
    var path: [8][]const u16 = undefined;
    path[0] = wide("Systems"); path[1] = wide("DOS"); path[2] = wide("MS-DOS"); path[3] = wide("Programs");
    try copyPath(fs, reader, bulk, builder, &path, 4);
}

pub fn copyFreeDos(fs: ntfs.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder) !void {
    var path: [8][]const u16 = undefined;
    path[0] = wide("Utilities"); path[1] = wide("FreeDOS"); path[2] = wide("Programs");
    try copyPath(fs, reader, bulk, builder, &path, 3);
}

fn copyPath(fs: ntfs.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder, path: *[8][]const u16, depth: usize) !void {
    _ = ntfs.directoryInfo(fs, reader, path[0..depth]) catch |err| {
        if (err == error.NotFound) return;
        return err;
    };
    var directory = try builder.makeDirectory("PROGRAMS", null);
    try copyDirectory(fs, reader, bulk, builder, path, depth, &directory);
}

fn copyDirectory(fs: ntfs.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder, path: *[8][]const u16, depth: usize, directory: *dos.Directory) anyerror!void {
    if (depth >= path.len) return error.DosProgramsTooDeep;
    var skip: usize = 0;
    var items: [8]ntfs.DirectoryItem = undefined;
    while (true) {
        const page = try ntfs.listDirectoryPage(fs, reader, path[0..depth], skip, &items);
        for (items[0..page.count]) |item| {
            if (item.name_len == 0 or item.name_len > 12 or item.attributes & 0x400 != 0) return error.DosProgramNameNeeds83;
            var name: [12]u8 = undefined;
            for (item.name[0..item.name_len], 0..) |unit, i| {
                if (unit > 127) return error.DosProgramNameNeeds83;
                name[i] = @intCast(unit);
            }
            const filename = name[0..item.name_len];
            _ = dos.shortName(filename) catch return error.DosProgramNameNeeds83;
            path[depth] = item.name[0..item.name_len];
            if (item.isDirectory()) {
                var child = try builder.makeDirectory(filename, directory);
                try copyDirectory(fs, reader, bulk, builder, path, depth + 1, &child);
            } else {
                var file: ntfs.File = undefined;
                try ntfs.openFile(fs, reader, path[0..depth + 1], &file);
                if (file.size() > 32 * 1024 * 1024) return error.DosProgramTooLarge;
                const output = try builder.reserveIn(filename, @intCast(file.size()), directory);
                try file.readAt(fs, bulk, 0, output);
            }
        }
        if (!page.has_more) return;
        if (page.count == 0) return error.InvalidDosProgramDirectory;
        skip += page.count;
    }
}
