const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const ntfs_directory_source = @import("ntfs_directory_source");

const random_reader = storage.random_reader;
const ntfs = storage.ntfs;

const HostFileReader = struct {
    io: std.Io,
    file: std.Io.File,

    fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !HostFileReader {
        var file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        return .{ .io = io, .file = file };
    }

    fn close(self: *HostFileReader) void {
        self.file.close(self.io);
    }

    fn readAt(self: *const HostFileReader, offset: u64, buffer: []u8) !usize {
        return self.file.readPositionalAll(self.io, buffer, offset);
    }
};

fn fileRead(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
    const ctx: *HostFileReader = @ptrCast(@alignCast(context));
    const count = ctx.readAt(offset, output) catch return error.Io;
    if (count != output.len) return error.Io;
}

const systems = [_]u16{ 'S', 'y', 's', 't', 'e', 'm', 's' };
const windows = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's' };
const windows_xp = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's', ' ', 'X', 'P' };
const windows_11 = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's', ' ', '1', '1' };
const windows_11_lower = [_]u16{ 'w', 'i', 'n', 'd', 'o', 'w', 's', ' ', '1', '1' };
const images = [_]u16{ 'I', 'm', 'a', 'g', 'e', 's' };
const images_lower = [_]u16{ 'i', 'm', 'a', 'g', 'e', 's' };
const windows_path = [_][]const u16{ &systems, &windows };
const image_path = [_][]const u16{ &systems, &windows, &windows_xp, &images };
const win11_image_path = [_][]const u16{ &systems, &windows, &windows_11, &images };
const win11_lower_path = [_][]const u16{ &systems, &windows, &windows_11_lower, &images_lower };

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const image_file = args.next() orelse return error.MissingImagePath;
    const expected_error = args.next();

    var context = try HostFileReader.open(init.io, std.Io.Dir.cwd(), image_file);
    defer context.close();
    const reader = random_reader.Reader{ .context = &context, .read_fn = fileRead };

    probe(reader) catch |err| {
        if (expected_error) |name| {
            if (std.mem.eql(u8, @errorName(err), name)) {
                std.debug.print("EXPECTED_FAIL={s}\n", .{@errorName(err)});
                return 0;
            }
        }
        return err;
    };
    if (expected_error != null) return error.ExpectedFailureDidNotOccur;
    return 0;
}

fn probe(reader: random_reader.Reader) !void {
    const partition = try findNtfsMbrPartition(reader);
    const fs = try ntfs.mount(reader, partition);
    if (fs.mftRunCount() < 2) return error.MftFixtureNotFragmented;

    const windows_info = try ntfs.directoryInfo(fs, reader, &windows_path);
    if (!windows_info.uses_index_allocation) return error.IntermediateIndexAllocationFixtureMissing;
    const info = try ntfs.directoryInfo(fs, reader, &image_path);
    if (!info.uses_index_allocation) return error.IndexAllocationFixtureMissing;

    var items: [512]ntfs.DirectoryItem = undefined;
    const count = try ntfs.listDirectory(fs, reader, &image_path, &items);
    if (count < 200) return error.IndexAllocationFixtureTooSmall;
    if (!containsAsciiName(items[0..count], "payload-0319.iso", false)) return error.PayloadSentinelMissing;
    if (!containsAsciiName(items[0..count], "nested", true)) return error.NestedDirectoryMissing;

    var win11_items: [8]ntfs.DirectoryItem = undefined;
    const win11_count = try ntfs.listDirectory(fs, reader, &win11_image_path, &win11_items);
    if (win11_count != 1 or !containsAsciiName(win11_items[0..win11_count], "Win11 Space Path.iso", false)) return error.Win11SpacePathMissing;
    var win11_lower_items: [8]ntfs.DirectoryItem = undefined;
    const win11_lower_count = try ntfs.listDirectory(fs, reader, &win11_lower_path, &win11_lower_items);
    if (win11_lower_count != 1) return error.CaseInsensitivePathLookupFailed;

    var adapter = ntfs_directory_source.Adapter.init(fs, reader, null);
    var discovery = catalog.media_discovery.Discovery.init(adapter.source());
    const status = discovery.mediaStatus("\\Systems\\Windows\\Windows XP\\Images");
    if (status.iso_count != 320) return error.DiscoveryImageCountMismatch;
    const discovered = discovery.images("\\Systems\\Windows\\Windows XP\\Images");
    if (discovered.len != catalog.image_list_max_items) return error.DiscoveryPaginationFailed;

    std.debug.print("NTFS_MFT_RUNS={d}\n", .{fs.mftRunCount()});
    std.debug.print("NTFS_INTERMEDIATE_INDEX_ALLOCATION=yes path=Systems/Windows\n", .{});
    std.debug.print("NTFS_INDEX_ALLOCATION=yes path=Systems/Windows/Windows XP/Images\n", .{});
    std.debug.print("NTFS_IMAGES_ENTRIES={d}\n", .{count});
    std.debug.print("NTFS_DISCOVERY_ISO_COUNT={d}\n", .{status.iso_count});
    std.debug.print("NTFS_DISCOVERY_PAGE_CAP={d}\n", .{discovered.len});
    std.debug.print("NTFS_DIRECTORY_WALK_PASS path=Systems/Windows/Windows XP/Images\n", .{});
    std.debug.print("NTFS_SPACE_PATH_PASS path=Systems/Windows/Windows 11/Images case_insensitive=yes 8dot3=disabled\n", .{});
}

fn findNtfsMbrPartition(reader: random_reader.Reader) !ntfs.Partition {
    var mbr: [512]u8 = undefined;
    try reader.readAt(0, &mbr);
    if (mbr[510] != 0x55 or mbr[511] != 0xaa) return error.InvalidMbr;
    var found: ?ntfs.Partition = null;
    for (0..4) |index| {
        const off = 446 + index * 16;
        if (mbr[off + 4] != 0x07) continue;
        const start = le32(mbr[off + 8 .. off + 12]);
        const sectors = le32(mbr[off + 12 .. off + 16]);
        if (start == 0 or sectors == 0) return error.InvalidMbr;
        if (found != null) return error.MultipleNtfsPartitions;
        found = .{
            .start_bytes = @as(u64, start) * 512,
            .size_bytes = @as(u64, sectors) * 512,
        };
    }
    return found orelse error.NtfsPartitionMissing;
}

fn containsAsciiName(items: []const ntfs.DirectoryItem, wanted: []const u8, directory: bool) bool {
    for (items) |item| {
        if (item.isDirectory() != directory) continue;
        var name: [260]u8 = undefined;
        const len = item.copyNameAscii(&name);
        if (std.ascii.eqlIgnoreCase(name[0..len], wanted)) return true;
    }
    return false;
}

fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
