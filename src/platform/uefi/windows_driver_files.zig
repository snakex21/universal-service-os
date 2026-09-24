// Copy user-supplied driver packages into one RAM archive before USB leaves UEFI.
// Packages retain their relative paths; Windows performs hardware/signature matching.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const ntfs = usos.storage.ntfs;
const Catalog = @import("data_volume.zig").Catalog;
const user_drivers = @import("windows_user_drivers.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const max_files = 512;
const max_directories = 128;
const max_path = 180;
const max_bytes = 64 * 1024 * 1024;
const Item = struct { path: [max_path]u8 = undefined, len: usize = 0, size: usize = 0 };
const Inventory = struct {
    files: [max_files]Item = undefined,
    directories: [max_directories]Item = undefined,
    file_count: usize = 0,
    directory_count: usize = 1,
    inf_count: usize = 0,
    total: usize = 12,
};
pub const Archive = struct { bytes: []align(8) u8, inf_count: usize, user_infs: usize = 0, user_skipped: usize = 0 };
/// DATA\Drivers\Windows 7 (docs/drivers.md): user packages for the x64
/// target, after the bundled library in the same archive.
const user_folder = "Windows 7";
const user_targets = [_]usos.flow.inf_package.Arch{.amd64};
const user_log_name = "user\\usos-user-drivers.log";

fn components(relative: []const u8, storage: *[max_path]u16, slices: *[20][]const u16) ![]const []const u16 {
    const root = [_][]const u16{ wide("Systems"), wide("Windows"), wide("Windows 7"), wide("Drivers"), wide("x64") };
    @memcpy(slices[0..root.len], &root);
    for (relative, 0..) |ch, i| storage[i] = ch;
    var count = root.len;
    var start: usize = 0;
    for (relative, 0..) |ch, i| if (ch == '\\') {
        if (count == slices.len) return error.DriverPathTooDeep;
        slices[count] = storage[start..i];
        count += 1;
        start = i + 1;
    };
    if (relative.len > start) {
        if (count == slices.len) return error.DriverPathTooDeep;
        slices[count] = storage[start..relative.len];
        count += 1;
    }
    return slices[0..count];
}
fn inventory(catalog: *Catalog, result: *Inventory) !void {
    result.* = .{};
    result.directories[0] = .{};
    var dir: usize = 0;
    while (dir < result.directory_count) : (dir += 1) {
        const parent = &result.directories[dir];
        var storage: [max_path]u16 = undefined;
        var slices: [20][]const u16 = undefined;
        const parts = try components(parent.path[0..parent.len], &storage, &slices);
        var skip: usize = 0;
        while (true) {
            var entries: [8]ntfs.DirectoryItem = undefined;
            const page = ntfs.listDirectoryPage(catalog.fs, catalog.reader(), parts, skip, &entries) catch |err| {
                if (err == error.NotFound and dir == 0) return;
                return err;
            };
            for (entries[0..page.count]) |entry| {
                const name = entry.name[0..entry.name_len];
                if (std.mem.eql(u16, name, wide(".")) or std.mem.eql(u16, name, wide(".."))) continue;
                if (entry.attributes & 0x400 != 0) return error.DriverReparsePointUnsupported;
                var item = Item{};
                const prefix = parent.len + @as(usize, if (parent.len == 0) 0 else 1);
                if (prefix + name.len > item.path.len) return error.DriverPathTooLong;
                @memcpy(item.path[0..parent.len], parent.path[0..parent.len]);
                if (parent.len != 0) item.path[parent.len] = '\\';
                for (name, 0..) |ch, i| {
                    if (ch < 32 or ch > 126 or std.mem.indexOfScalar(u8, "\\/:\"<>|*?%", @intCast(ch)) != null) return error.UnsupportedDriverName;
                    item.path[prefix + i] = @intCast(ch);
                }
                item.len = prefix + name.len;
                if (entry.isDirectory()) {
                    if (result.directory_count == max_directories) return error.TooManyDriverDirectories;
                    result.directories[result.directory_count] = item;
                    result.directory_count += 1;
                } else {
                    if (result.file_count == max_files or entry.size > max_bytes) return error.DriverArchiveTooLarge;
                    item.size = @intCast(entry.size);
                    if (result.total + 6 + item.len + item.size > max_bytes) return error.DriverArchiveTooLarge;
                    result.total += 6 + item.len + item.size;
                    result.files[result.file_count] = item;
                    result.file_count += 1;
                    if (std.ascii.endsWithIgnoreCase(item.path[0..item.len], ".inf")) result.inf_count += 1;
                }
            }
            if (!page.has_more) break;
            if (page.count == 0) return error.DriverDirectoryDidNotAdvance;
            skip += page.count;
        }
    }
}
pub fn infCount(catalog: *Catalog) !usize {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const memory = try bs.allocatePool(.loader_data, @sizeOf(Inventory));
    defer bs.freePool(memory.ptr) catch {};
    const info: *Inventory = @ptrCast(@alignCast(memory.ptr));
    try inventory(catalog, info);
    return info.inf_count;
}
/// Used and skipped user INFs (Drivers\Windows 7), for the summary page.
pub fn userCounts(catalog: *Catalog) ?[2]usize {
    const set = user_drivers.scan(catalog, user_folder, &user_targets, max_bytes) orelse return null;
    defer user_drivers.release(set);
    return .{ set.infs_used, set.infs_skipped };
}

pub fn load(catalog: *Catalog) !Archive {
    return loadFor(catalog, true, user_folder);
}

/// DATA\Drivers\<folder> only (Windows 10/11 native start: no bundled
/// library). The archive layout is the same USOSDRV1 (entries "user\...")
/// that usos-drivers.exe expands in WinPE. Null when there is nothing to use.
pub fn loadUser(catalog: *Catalog, folder: []const u8) !?Archive {
    const archive = try loadFor(catalog, false, folder);
    if (archive.user_infs == 0) {
        const bs = uefi.system_table.boot_services orelse return null;
        bs.freePool(archive.bytes.ptr) catch {};
        return null;
    }
    return archive;
}

/// Used and skipped user INFs of DATA\Drivers\<folder>, for the summary.
pub fn userCountsFor(catalog: *Catalog, folder: []const u8) ?[2]usize {
    const set = user_drivers.scan(catalog, folder, &user_targets, max_bytes) orelse return null;
    defer user_drivers.release(set);
    return .{ set.infs_used, set.infs_skipped };
}

fn loadFor(catalog: *Catalog, bundled: bool, folder: []const u8) !Archive {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const memory = try bs.allocatePool(.loader_data, @sizeOf(Inventory));
    defer bs.freePool(memory.ptr) catch {};
    const info: *Inventory = @ptrCast(@alignCast(memory.ptr));
    if (bundled) try inventory(catalog, info) else {
        info.file_count = 0;
        info.inf_count = 0;
        info.total = 12;
    }
    // User packages come after the bundled library and only use what is
    // left of the 64 MiB archive; they never fail the start.
    const log_reserve: usize = 6 + user_log_name.len + 16 * 1024;
    const user = user_drivers.scan(catalog, folder, &user_targets, max_bytes -| (info.total + log_reserve));
    defer if (user) |set| user_drivers.release(set);
    var total = info.total;
    var count = info.file_count;
    if (user) |set| {
        var it = set.used();
        var path: [user_drivers.max_archive_path]u8 = undefined;
        while (it.next()) |file| {
            const name = user_drivers.archivePath(set, file, &path) orelse continue;
            total += 6 + name.len + @as(usize, @intCast(file.size));
            count += 1;
        }
        total += 6 + user_log_name.len + set.logText().len;
        count += 1;
    }
    const bytes = try bs.allocatePool(.loader_data, total);
    errdefer bs.freePool(bytes.ptr) catch {};
    @memcpy(bytes[0..8], "USOSDRV1");
    var at: usize = 12;
    for (info.files[0..info.file_count]) |*item| {
        std.mem.writeInt(u16, bytes[at..][0..2], @intCast(item.len), .little);
        std.mem.writeInt(u32, bytes[at + 2 ..][0..4], @intCast(item.size), .little);
        at += 6;
        @memcpy(bytes[at..][0..item.len], item.path[0..item.len]);
        at += item.len;
        var storage: [max_path]u16 = undefined;
        var slices: [20][]const u16 = undefined;
        var file: ntfs.File = undefined;
        try ntfs.openFile(catalog.fs, catalog.reader(), try components(item.path[0..item.len], &storage, &slices), &file);
        if (file.size() != item.size) return error.DriverFileChanged;
        try file.readAt(catalog.fs, catalog.reader(), 0, bytes[at..][0..item.size]);
        at += item.size;
    }
    var user_infs: usize = 0;
    var user_skipped: usize = 0;
    var written = info.file_count;
    if (user) |set| {
        var it = set.used();
        var path: [user_drivers.max_archive_path]u8 = undefined;
        var file: ntfs.File = undefined;
        var folder16: [64]u16 = undefined;
        const folder_len = try std.unicode.utf8ToUtf16Le(&folder16, folder);
        const root = [_][]const u16{ wide("Drivers"), folder16[0..folder_len] };
        while (it.next()) |entry| {
            const name = user_drivers.archivePath(set, entry, &path) orelse continue;
            const size: usize = @intCast(entry.size);
            // A file that cannot be read now is dropped (logged), not fatal.
            user_drivers.open(catalog, set, &root, entry, &file) catch continue;
            if (file.size() != entry.size) continue;
            if (at + 6 + name.len + size > bytes.len) break;
            file.readAt(catalog.fs, catalog.reader(), 0, bytes[at + 6 + name.len ..][0..size]) catch continue;
            std.mem.writeInt(u16, bytes[at..][0..2], @intCast(name.len), .little);
            std.mem.writeInt(u32, bytes[at + 2 ..][0..4], @intCast(size), .little);
            @memcpy(bytes[at + 6 ..][0..name.len], name);
            at += 6 + name.len + size;
            written += 1;
        }
        const log = set.logText();
        if (at + 6 + user_log_name.len + log.len <= bytes.len) {
            std.mem.writeInt(u16, bytes[at..][0..2], @intCast(user_log_name.len), .little);
            std.mem.writeInt(u32, bytes[at + 2 ..][0..4], @intCast(log.len), .little);
            @memcpy(bytes[at + 6 ..][0..user_log_name.len], user_log_name);
            @memcpy(bytes[at + 6 + user_log_name.len ..][0..log.len], log);
            at += 6 + user_log_name.len + log.len;
            written += 1;
        }
        user_infs = set.infs_used;
        user_skipped = set.infs_skipped;
    }
    std.mem.writeInt(u32, bytes[8..12], @intCast(written), .little);
    return .{ .bytes = bytes[0..at], .inf_count = info.inf_count, .user_infs = user_infs, .user_skipped = user_skipped };
}
