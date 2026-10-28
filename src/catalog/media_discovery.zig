const std = @import("std");
const directory_source = @import("directory_source.zig");
const FixedText = @import("../core/fixed_text.zig").FixedText;
const ImageItem = @import("image_item.zig").ImageItem;
const ImageKind = @import("image_kind.zig").ImageKind;
const ImageList = @import("image_list.zig").ImageList;
const SystemMediaStatus = @import("system_media_status.zig").SystemMediaStatus;
const floppy_set = @import("floppy_set.zig");

pub const max_cached_directories: usize = 48;
pub const max_path_bytes: usize = 260;

const CacheEntry = struct {
    used: bool = false,
    path: [max_path_bytes]u8 = [_]u8{0} ** max_path_bytes,
    path_len: u16 = 0,
    status: SystemMediaStatus = .{},
};

pub const Discovery = struct {
    source: directory_source.Source,
    cache: [max_cached_directories]CacheEntry = [_]CacheEntry{.{}} ** max_cached_directories,
    cache_hits: usize = 0,
    cache_misses: usize = 0,

    pub fn init(source: directory_source.Source) Discovery {
        return .{ .source = source };
    }

    pub fn mediaStatus(self: *Discovery, directory_path: []const u8) SystemMediaStatus {
        if (self.findCached(directory_path)) |entry| {
            self.cache_hits += 1;
            return entry.status;
        }
        self.cache_misses += 1;
        const status = self.scanMediaStatus(directory_path);
        self.storeCached(directory_path, status);
        return status;
    }

    pub fn images(self: *Discovery, directory_path: []const u8) ImageList {
        var result = ImageList{};
        var entries: [directory_source.max_directory_entries]directory_source.Entry = undefined;
        var skip: usize = 0;
        while (true) {
            const page = self.source.listPage(directory_path, skip, &entries) catch return result;
            for (entries[0..page.count]) |entry| {
                if (entry.directory) {
                    // A folder of diskette images: one floppy-set entry
                    // (not compiled into the BIOS Core).
                    if (comptime floppy_set.enabled) {
                        const disks = self.floppySetDisks(directory_path, entry.name.slice());
                        if (disks != 0 and !result.append(.{ .name = entry.name, .kind = .floppy_set, .disks = disks })) return result;
                    }
                    continue;
                }
                const kind = ImageKind.fromFilename(entry.name.slice()) orelse continue;
                if (!result.append(.{ .name = entry.name, .kind = kind })) return result;
            }
            if (!page.has_more) return result;
            if (page.count == 0) return result;
            skip += page.count;
        }
    }

    pub fn listDirectories(self: *Discovery, directory_path: []const u8, output: []FixedText) usize {
        var entries: [directory_source.max_directory_entries]directory_source.Entry = undefined;
        var written: usize = 0;
        var skip: usize = 0;
        while (written < output.len) {
            const page = self.source.listPage(directory_path, skip, &entries) catch return written;
            for (entries[0..page.count]) |entry| {
                if (!entry.directory) continue;
                if (written >= output.len) return written;
                output[written] = entry.name;
                written += 1;
            }
            if (!page.has_more or page.count == 0) return written;
            skip += page.count;
        }
        return written;
    }

    pub fn listFilesWithExtension(self: *Discovery, directory_path: []const u8, extension: []const u8, output: []FixedText) usize {
        var entries: [directory_source.max_directory_entries]directory_source.Entry = undefined;
        var written: usize = 0;
        var skip: usize = 0;
        while (written < output.len) {
            const page = self.source.listPage(directory_path, skip, &entries) catch return written;
            for (entries[0..page.count]) |entry| {
                if (entry.directory) continue;
                if (!endsWithAsciiIgnoreCase(entry.name.slice(), extension)) continue;
                if (written >= output.len) return written;
                output[written] = entry.name;
                written += 1;
            }
            if (!page.has_more or page.count == 0) return written;
            skip += page.count;
        }
        return written;
    }

    pub fn invalidate(self: *Discovery) void {
        self.cache = [_]CacheEntry{.{}} ** max_cached_directories;
        self.cache_hits = 0;
        self.cache_misses = 0;
    }

    fn scanMediaStatus(self: *Discovery, directory_path: []const u8) SystemMediaStatus {
        var status = SystemMediaStatus{};
        var entries: [directory_source.max_directory_entries]directory_source.Entry = undefined;
        var skip: usize = 0;
        while (true) {
            const page = self.source.listPage(directory_path, skip, &entries) catch return status;
            for (entries[0..page.count]) |entry| {
                if (entry.directory) {
                    if (comptime floppy_set.enabled) {
                        if (self.floppySetDisks(directory_path, entry.name.slice()) != 0) status.floppy_set_count += 1;
                    }
                    continue;
                }
                const kind = ImageKind.fromFilename(entry.name.slice()) orelse continue;
                switch (kind) {
                    .iso => status.iso_count += 1,
                    .wim => status.wim_count += 1,
                    .img => status.img_count += 1,
                    .vhd => status.vhd_count += 1,
                    .vhdx => status.vhdx_count += 1,
                    .efi => status.efi_count += 1,
                    .floppy_set => unreachable, // never a file extension
                }
            }
            if (!page.has_more or page.count == 0) return status;
            skip += page.count;
        }
    }

    /// Diskette images in the folder `name` of `directory_path` (0: not a
    /// floppy set).
    /// Only the folder's first page is read (64 entries; a set has fewer).
    fn floppySetDisks(self: *Discovery, directory_path: []const u8, name: []const u8) u8 {
        var path_buffer: [max_path_bytes]u8 = undefined;
        const child = floppy_set.childPath(&path_buffer, directory_path, name) orelse return 0;
        var entries: [directory_source.max_directory_entries]directory_source.Entry = undefined;
        const page = self.source.listPage(child, 0, &entries) catch return 0;
        var disks: u8 = 0;
        for (entries[0..page.count]) |entry| {
            if (entry.directory or !floppy_set.isDisketteImage(entry.name.slice(), entry.size)) continue;
            if (disks < floppy_set.max_disks) disks += 1;
        }
        return disks;
    }

    fn findCached(self: *Discovery, path: []const u8) ?*CacheEntry {
        for (&self.cache) |*entry| {
            if (!entry.used or entry.path_len != path.len) continue;
            if (std.mem.eql(u8, entry.path[0..entry.path_len], path)) return entry;
        }
        return null;
    }

    fn storeCached(self: *Discovery, path: []const u8, status: SystemMediaStatus) void {
        if (path.len > max_path_bytes) return;
        for (&self.cache) |*entry| {
            if (entry.used) continue;
            entry.used = true;
            @memcpy(entry.path[0..path.len], path);
            entry.path_len = @intCast(path.len);
            entry.status = status;
            return;
        }
    }
};

fn endsWithAsciiIgnoreCase(name: []const u8, suffix: []const u8) bool {
    if (suffix.len > name.len) return false;
    const start = name.len - suffix.len;
    for (suffix, 0..) |expected, index| {
        if (std.ascii.toLower(name[start + index]) != std.ascii.toLower(expected)) return false;
    }
    return true;
}

const FakeDirectory = struct {
    list_calls: usize = 0,

    fn source(self: *FakeDirectory) directory_source.Source {
        return .{ .context = self, .list_fn = list };
    }

    fn list(context: *anyopaque, path: []const u8, output: []directory_source.Entry) anyerror!usize {
        const self: *FakeDirectory = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, "\\Systems\\Windows\\Windows 11\\Images")) return error.NotFound;
        self.list_calls += 1;
        if (output.len < 3) return error.TooSmall;
        output[0] = makeFile("install.iso");
        output[1] = makeFile("boot.WIM");
        output[2] = makeDirectory("nested");
        return 3;
    }
};

fn makeFile(name: []const u8) directory_source.Entry {
    var entry = directory_source.Entry{};
    @memcpy(entry.name.bytes[0..name.len], name);
    entry.name.len = name.len;
    return entry;
}

fn makeDirectory(name: []const u8) directory_source.Entry {
    var entry = makeFile(name);
    entry.directory = true;
    return entry;
}

test "media status scans a directory once and caches the result" {
    var fake = FakeDirectory{};
    var discovery = Discovery.init(fake.source());
    const path = "\\Systems\\Windows\\Windows 11\\Images";
    const first = discovery.mediaStatus(path);
    const second = discovery.mediaStatus(path);
    try std.testing.expectEqual(@as(usize, 1), first.iso_count);
    try std.testing.expectEqual(@as(usize, 1), first.wim_count);
    try std.testing.expectEqual(first.imageCount(), second.imageCount());
    try std.testing.expectEqual(@as(usize, 1), fake.list_calls);
    try std.testing.expectEqual(@as(usize, 1), discovery.cache_hits);
    try std.testing.expectEqual(@as(usize, 1), discovery.cache_misses);
}

test "image listing classifies all supported files in one pass" {
    var fake = FakeDirectory{};
    var discovery = Discovery.init(fake.source());
    const images = discovery.images("\\Systems\\Windows\\Windows 11\\Images");
    try std.testing.expectEqual(@as(usize, 2), images.len);
    try std.testing.expectEqual(ImageKind.iso, images.items[0].kind);
    try std.testing.expectEqual(ImageKind.wim, images.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), fake.list_calls);
}

const FakeFloppies = struct {
    fn source(self: *FakeFloppies) directory_source.Source {
        return .{ .context = self, .list_fn = list };
    }

    fn list(_: *anyopaque, path: []const u8, output: []directory_source.Entry) anyerror!usize {
        if (std.mem.eql(u8, path, "\\Systems\\Windows\\WfW\\Images")) {
            output[0] = makeFile("WfW 3.11 PL.iso");
            output[1] = makeDirectory("WfW 3.11 PL");
            output[2] = makeDirectory("Notes");
            output[3] = makeDirectory("FreeDOS USB");
            return 4;
        }
        if (std.mem.eql(u8, path, "\\Systems\\Windows\\WfW\\Images\\WfW 3.11 PL")) {
            for (0..10) |i| {
                var name_buffer: [16]u8 = undefined;
                output[i] = makeFile(std.fmt.bufPrint(&name_buffer, "disk{d:0>2}.img", .{i + 1}) catch unreachable);
                output[i].size = 1474560;
            }
            output[10] = makeFile("winworldpc.com.txt");
            output[10].size = 691;
            return 11;
        }
        if (std.mem.eql(u8, path, "\\Systems\\Windows\\WfW\\Images\\Notes")) {
            output[0] = makeFile("readme.txt");
            return 1;
        }
        if (std.mem.eql(u8, path, "\\Systems\\Windows\\WfW\\Images\\FreeDOS USB")) {
            output[0] = makeFile("FullUSB.img");
            output[0].size = 536870912;
            return 1;
        }
        return error.NotFound;
    }
};

test "a folder of diskette images is one floppy-set entry; other folders are not" {
    var fake = FakeFloppies{};
    var discovery = Discovery.init(fake.source());
    const images = discovery.images("\\Systems\\Windows\\WfW\\Images");
    try std.testing.expectEqual(@as(usize, 2), images.len);
    try std.testing.expectEqual(ImageKind.iso, images.items[0].kind);
    try std.testing.expectEqual(ImageKind.floppy_set, images.items[1].kind);
    try std.testing.expectEqualStrings("WfW 3.11 PL", images.items[1].name.slice());
    try std.testing.expectEqual(@as(u8, 10), images.items[1].disks);
    const status = discovery.mediaStatus("\\Systems\\Windows\\WfW\\Images");
    try std.testing.expectEqual(@as(usize, 1), status.floppy_set_count);
    try std.testing.expectEqual(@as(usize, 2), status.imageCount());
}
