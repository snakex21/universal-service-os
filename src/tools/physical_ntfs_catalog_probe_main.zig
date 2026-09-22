const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const ntfs_directory_source = @import("ntfs_directory_source");

const random_reader = storage.random_reader;
const gpt = storage.gpt;
const ntfs = storage.ntfs;

const systems_component = [_]u16{ 'S', 'y', 's', 't', 'e', 'm', 's' };
const windows_component = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's' };
const windows_path = [_][]const u16{ &systems_component, &windows_component };

const HostFileReader = struct {
    io: std.Io,
    file: std.Io.File,

    fn open(io: std.Io, path: []const u8) !HostFileReader {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        return .{ .io = io, .file = file };
    }

    fn close(self: *HostFileReader) void {
        self.file.close(self.io);
    }

    fn readAt(self: *const HostFileReader, offset: u64, buffer: []u8) !usize {
        var sector: [512]u8 = undefined;
        var cursor = offset;
        var written: usize = 0;
        while (written < buffer.len) {
            const aligned = cursor & ~@as(u64, 511);
            const within: usize = @intCast(cursor - aligned);
            const got = try self.file.readPositionalAll(self.io, &sector, aligned);
            if (got != sector.len) return written;
            const amount = @min(sector.len - within, buffer.len - written);
            @memcpy(buffer[written .. written + amount], sector[within .. within + amount]);
            cursor += amount;
            written += amount;
        }
        return written;
    }
};

fn fileRead(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
    const ctx: *HostFileReader = @ptrCast(@alignCast(context));
    const count = ctx.readAt(offset, output) catch return error.Io;
    if (count != output.len) return error.Io;
}

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const device = args.next() orelse return error.MissingDevicePath;

    var context = try HostFileReader.open(init.io, device);
    defer context.close();
    const reader = random_reader.Reader{ .context = &context, .read_fn = fileRead };

    const data = try gpt.findUsosData(reader);
    const start_bytes = try std.math.mul(u64, data.start_lba, 512);
    const size_bytes = try std.math.mul(u64, data.sectorCount(), 512);
    const partition = ntfs.Partition{ .start_bytes = start_bytes, .size_bytes = size_bytes };
    const boot = try ntfs.probeBootSector(reader, partition);

    std.debug.print("DATA_GPT=FOUND start_lba={d} sectors={d}\n", .{ data.start_lba, data.sectorCount() });
    std.debug.print("VBR_READ=PASS oem_ntfs={} sig_55aa={} bytes_per_sector={d} sectors_per_cluster={d} mft_lcn={d}\n", .{ boot.oem_ntfs, boot.boot_signature_valid, boot.bytes_per_sector, boot.sectors_per_cluster, boot.mft_lcn });

    const fs = try ntfs.mount(reader, partition);
    std.debug.print("NTFS_MOUNT=PASS mft_runs={d}\n", .{fs.mftRunCount()});
    const windows_info = try ntfs.directoryInfo(fs, reader, &windows_path);
    std.debug.print("WINDOWS_DIR record={d} index_allocation={} index_runs={d} first_index_lcn={?d}\n", .{ windows_info.record_number, windows_info.uses_index_allocation, windows_info.index_run_count, windows_info.first_index_lcn });
    if (windows_info.first_index_lcn) |index_lcn| {
        const index_offset = try std.math.add(u64, start_bytes, try std.math.mul(u64, index_lcn, fs.cluster_bytes));
        var cluster: [65536]u8 = undefined;
        const index_bytes: usize = @intCast(fs.cluster_bytes);
        try reader.readAt(index_offset, cluster[0..index_bytes]);
        var hash: u32 = 0x811c9dc5;
        for (cluster[0..index_bytes]) |byte| {
            hash ^= byte;
            hash *%= 0x01000193;
        }
        std.debug.print("WINDOWS_INDEX offset={d} bytes={d} fnv32=0x{X:0>8}\n", .{ index_offset, index_bytes, hash });
    }

    var adapter = ntfs_directory_source.Adapter.init(fs, reader, null);
    const source = adapter.source();
    var entries: [catalog.directory_source.max_directory_entries]catalog.directory_source.Entry = undefined;
    const systems = try source.listPage("\\Systems", 0, &entries);
    std.debug.print("SYSTEMS_OPEN=PASS entries={d} has_more={}\n", .{ systems.count, systems.has_more });

    var discovery = catalog.media_discovery.Discovery.init(source);
    const xp = discovery.mediaStatus("\\Systems\\Windows\\Windows XP\\Images");
    const win11 = discovery.mediaStatus("\\Systems\\Windows\\Windows 11\\Images");
    std.debug.print("XP_IMAGES={d} WIN11_IMAGES={d}\n", .{ xp.imageCount(), win11.imageCount() });
    return 0;
}
