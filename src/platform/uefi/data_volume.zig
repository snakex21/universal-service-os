const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const block_reader = @import("block_reader.zig");

const gpt = usos.storage.gpt;
const ntfs = usos.storage.ntfs;

pub const Error = error{
    BootServicesUnavailable,
    BlockIoEnumerationFailed,
    DataDiskNotFound,
    DataDiskAmbiguous,
} || block_reader.Error || gpt.Error || ntfs.Error;

pub const Catalog = struct {
    block: block_reader.Context,
    partition: gpt.Partition,
    fs: ntfs.FileSystem,

    pub fn reader(self: *Catalog) usos.storage.random_reader.Reader {
        return self.block.reader();
    }
};

const Candidate = struct {
    io: *uefi.protocol.BlockIo,
    partition: gpt.Partition,
    fs: ntfs.FileSystem,
};

pub fn openCatalog() Error!Catalog {
    const boot_services = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const handles = (boot_services.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid }) catch return error.BlockIoEnumerationFailed) orelse return error.BlockIoEnumerationFailed;
    defer boot_services.freePool(@ptrCast(handles.ptr)) catch {};

    var selected: ?Candidate = null;
    for (handles) |handle| {
        const io = (boot_services.handleProtocol(uefi.protocol.BlockIo, handle) catch continue) orelse continue;
        const media = io.media;
        if (!media.media_present or media.logical_partition or media.block_size != 512) continue;

        var context = block_reader.Context.init(io) catch continue;
        const reader = context.reader();
        _ = gpt.findUsosEsp(reader) catch continue;
        const data = gpt.findUsosData(reader) catch continue;

        const start_bytes = std.math.mul(u64, data.start_lba, 512) catch return error.PartitionBounds;
        const size_bytes = std.math.mul(u64, data.sectorCount(), 512) catch return error.PartitionBounds;
        const fs = try ntfs.mount(reader, .{ .start_bytes = start_bytes, .size_bytes = size_bytes });

        if (selected != null) return error.DataDiskAmbiguous;
        selected = .{ .io = io, .partition = data, .fs = fs };
    }

    const found = selected orelse return error.DataDiskNotFound;
    return .{
        .block = try block_reader.Context.init(found.io),
        .partition = found.partition,
        .fs = found.fs,
    };
}
