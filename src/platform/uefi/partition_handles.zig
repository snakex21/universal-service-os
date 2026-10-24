//! Partition Block I/O handles for USOS partitions the firmware leaves out.
//!
//! The installer marks DATA and WORK with GPT attribute bit 1
//! (EFI_PART_ATTR_NO_BLOCK_IO_PROTOCOL, UEFI 2.x 5.3.3) so that the firmware
//! partition driver creates no handle for them, and with it no boot-menu
//! entry: the F11 menu then lists the USOS ESP only. Everything that needs a
//! partition handle for DATA or WORK (the NTFS driver for the WORK handoff
//! and the UEFI Shell, LoadImage of the Windows boot manager from WORK, and
//! the Windows boot manager itself looking for its boot device or a
//! vhd=[locate] file on DATA) gets it from here instead: a child handle with
//! the same Device Path (parent disk + HD node) and a Block I/O that maps the
//! partition onto the whole-disk Block I/O at the partition's LBA offset,
//! as the EDK2 PartitionDxe child would have done.
//!
//! The catalog reader (data_volume.zig) never needed these handles: it reads
//! DATA through the whole-disk Block I/O and USOS's own NTFS reader.
//!
//! A partition without bit 1, or one the firmware made a handle for anyway
//! (an HD node with its GPT signature already exists), is left alone.

const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const builtin = @import("builtin");

const gpt = usos.storage.gpt;
const BlockIo = uefi.protocol.BlockIo;
const Status = uefi.Status;
const cc = uefi.cc;

pub const max_children = 4;
const path_capacity = 512;
const hd_node_bytes = 42;
const end_node_bytes = 4;
const sector_bytes: u32 = 512;

const Child = struct {
    block_io: BlockIo,
    media: BlockIo.BlockMedia,
    parent: *BlockIo,
    start_lba: u64,
    part_guid: [16]u8,
    handle: ?uefi.Handle = null,
    path: [path_capacity]u8 align(8) = undefined,
};

var children: [max_children]Child = undefined;
var child_count: usize = 0;

pub const Range = union(enum) {
    /// Parent LBA of the first block.
    ok: u64,
    empty,
    bad_buffer_size,
    invalid_parameter,
};

/// Maps a partition-relative request onto the parent disk with the Block
/// I/O rules of the UEFI spec (and EDK2 PartitionDxe): size a multiple of
/// the block size, every block inside the partition.
pub fn translate(start_lba: u64, last_block: u64, block_size: u32, lba: u64, size: usize) Range {
    if (block_size == 0) return .invalid_parameter;
    if (size % block_size != 0) return .bad_buffer_size;
    if (size == 0) return .empty;
    const blocks: u64 = size / block_size;
    if (lba > last_block or blocks - 1 > last_block - lba) return .invalid_parameter;
    const parent = std.math.add(u64, start_lba, lba) catch return .invalid_parameter;
    return .{ .ok = parent };
}

/// HD(entry_index + 1, GPT, <PARTUUID>, start, size) as PartitionDxe builds it.
pub fn hardDriveNode(partition: gpt.Partition) [hd_node_bytes]u8 {
    var node: [hd_node_bytes]u8 = undefined;
    node[0] = 4; // media device path
    node[1] = 1; // hard drive
    std.mem.writeInt(u16, node[2..4], hd_node_bytes, .little);
    std.mem.writeInt(u32, node[4..8], partition.entry_index + 1, .little);
    std.mem.writeInt(u64, node[8..16], partition.start_lba, .little);
    std.mem.writeInt(u64, node[16..24], partition.sectorCount(), .little);
    // The GPT entry stores the partition GUID in EFI_GUID byte order, which
    // is also the byte order of the HD node signature.
    @memcpy(node[24..40], &partition.part_guid);
    node[40] = 2; // GPT
    node[41] = 2; // GUID signature
    return node;
}

/// Length of a device path up to (not including) its end node, or null when
/// it is malformed or longer than `limit`.
pub fn pathPrefixLength(path: [*]const u8, limit: usize) ?usize {
    var at: usize = 0;
    while (true) {
        if (at + end_node_bytes > limit) return null;
        const node_type = path[at];
        const length = std.mem.readInt(u16, path[at + 2 ..][0..2], .little);
        if (node_type == 0x7f) return at;
        if (length < end_node_bytes) return null;
        at += length;
    }
}

/// <parent disk path> + HD node + End, written into `out`.
pub fn buildChildPath(parent: [*]const u8, partition: gpt.Partition, out: []u8) ?[]u8 {
    if (out.len < hd_node_bytes + end_node_bytes) return null;
    const prefix = pathPrefixLength(parent, out.len - hd_node_bytes - end_node_bytes) orelse return null;
    @memcpy(out[0..prefix], parent[0..prefix]);
    const node = hardDriveNode(partition);
    @memcpy(out[prefix..][0..hd_node_bytes], &node);
    const end = out[prefix + hd_node_bytes ..][0..end_node_bytes];
    end.* = .{ 0x7f, 0xff, end_node_bytes, 0 };
    return out[0 .. prefix + hd_node_bytes + end_node_bytes];
}

/// True when the device path has an HD node with this GPT signature.
pub fn pathHasPartition(path: [*]const u8, limit: usize, part_guid: [16]u8) bool {
    var at: usize = 0;
    while (at + end_node_bytes <= limit) {
        const node_type = path[at];
        const subtype = path[at + 1];
        const length = std.mem.readInt(u16, path[at + 2 ..][0..2], .little);
        if (node_type == 0x7f or length < end_node_bytes) return false;
        if (node_type == 4 and subtype == 1 and length == hd_node_bytes and at + hd_node_bytes <= limit and
            path[at + 41] == 2 and std.mem.eql(u8, path[at + 24 ..][0..16], &part_guid)) return true;
        at += length;
    }
    return false;
}

fn childOf(io: *BlockIo) *Child {
    return @fieldParentPtr("block_io", io);
}

fn reset(io: *BlockIo, extended: bool) callconv(cc) Status {
    const self = childOf(io);
    return self.parent._reset(self.parent, extended);
}

fn readBlocks(io: *BlockIo, media_id: u32, lba: u64, size: usize, buffer: [*]u8) callconv(cc) Status {
    const self = childOf(io);
    if (!self.parent.media.media_present) return .no_media;
    return switch (translate(self.start_lba, self.media.last_block, self.media.block_size, lba, size)) {
        .ok => |parent_lba| self.parent._read_blocks(self.parent, media_id, parent_lba, size, buffer),
        .empty => .success,
        .bad_buffer_size => .bad_buffer_size,
        .invalid_parameter => .invalid_parameter,
    };
}

fn writeBlocks(io: *BlockIo, media_id: u32, lba: u64, size: usize, buffer: [*]const u8) callconv(cc) Status {
    const self = childOf(io);
    if (!self.parent.media.media_present) return .no_media;
    if (self.media.read_only) return .write_protected;
    return switch (translate(self.start_lba, self.media.last_block, self.media.block_size, lba, size)) {
        .ok => |parent_lba| self.parent._write_blocks(self.parent, media_id, parent_lba, size, buffer),
        .empty => .success,
        .bad_buffer_size => .bad_buffer_size,
        .invalid_parameter => .invalid_parameter,
    };
}

fn flushBlocks(io: *BlockIo) callconv(cc) Status {
    const self = childOf(io);
    return self.parent._flush_blocks(self.parent);
}

fn alreadyInstalled(part_guid: [16]u8) bool {
    for (children[0..child_count]) |*child| {
        if (std.mem.eql(u8, &child.part_guid, &part_guid)) return true;
    }
    return false;
}

fn firmwareHandleExists(bs: *uefi.tables.BootServices, handles: []const uefi.Handle, part_guid: [16]u8) bool {
    for (handles) |handle| {
        const path = (bs.handleProtocol(uefi.protocol.DevicePath, handle) catch continue) orelse continue;
        if (pathHasPartition(@ptrCast(path), 4096, part_guid)) return true;
    }
    return false;
}

const Install = *const fn (*?uefi.Handle, *const uefi.Guid, uefi.tables.InterfaceType, *anyopaque) callconv(cc) Status;
const Uninstall = *const fn (uefi.Handle, *const uefi.Guid, *anyopaque) callconv(cc) Status;

fn installChild(bs: *uefi.tables.BootServices, disk: uefi.Handle, parent: *BlockIo, partition: gpt.Partition) bool {
    if (child_count == max_children) return false;
    const parent_path = (bs.handleProtocol(uefi.protocol.DevicePath, disk) catch return false) orelse return false;
    const child = &children[child_count];
    child.* = .{
        .block_io = undefined,
        .media = undefined,
        .parent = parent,
        .start_lba = partition.start_lba,
        .part_guid = partition.part_guid,
    };
    const parent_media = parent.media;
    child.media = std.mem.zeroes(BlockIo.BlockMedia);
    child.media.media_id = parent_media.media_id;
    child.media.removable_media = parent_media.removable_media;
    child.media.media_present = true;
    child.media.logical_partition = true;
    child.media.read_only = parent_media.read_only;
    child.media.write_caching = parent_media.write_caching;
    child.media.block_size = parent_media.block_size;
    child.media.io_align = parent_media.io_align;
    child.media.last_block = partition.sectorCount() - 1;
    child.media.logical_blocks_per_physical_block = 1;
    child.block_io = .{
        .revision = 0x00010000,
        .media = &child.media,
        ._reset = reset,
        ._read_blocks = readBlocks,
        ._write_blocks = writeBlocks,
        ._flush_blocks = flushBlocks,
    };
    _ = buildChildPath(@ptrCast(parent_path), partition, child.path[0..]) orelse return false;

    // The bundled Zig headers declare the Handle* argument as Handle.
    const install: Install = @ptrCast(bs._installProtocolInterface);
    const uninstall: Uninstall = @ptrCast(bs._uninstallProtocolInterface);
    var handle: ?uefi.Handle = null;
    if (install(&handle, &uefi.protocol.DevicePath.guid, .native, @ptrCast(&child.path)) != .success) return false;
    const created = handle orelse return false;
    if (install(&handle, &BlockIo.guid, .native, @ptrCast(&child.block_io)) != .success) {
        _ = uninstall(created, &uefi.protocol.DevicePath.guid, @ptrCast(&child.path));
        return false;
    }
    child.handle = created;
    child_count += 1;
    return true;
}

pub const Report = struct {
    installed: usize = 0,
    /// bit 1 set but the firmware made the handle anyway.
    firmware_present: usize = 0,
};

/// Installs partition handles for firmware-hidden DATA/WORK partitions of
/// every USOS disk. Idempotent; the caller connects drivers afterwards
/// (ntfs_driver.loadAndConnect connects every Block I/O handle).
pub fn installHidden() Report {
    var report = Report{};
    const bs = uefi.system_table.boot_services orelse return report;
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &BlockIo.guid }) catch return report) orelse return report;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};

    for (handles) |disk| {
        const io = (bs.handleProtocol(BlockIo, disk) catch continue) orelse continue;
        const media = io.media;
        if (!media.media_present or media.logical_partition or media.block_size != sector_bytes) continue;
        var context = @import("block_reader.zig").Context.init(io) catch continue;
        const reader = context.reader();
        _ = gpt.findUsosEsp(reader) catch continue;
        const found = [_]?gpt.Partition{ gpt.findUsosData(reader) catch null, gpt.findUsosWork(reader) catch null };
        for (found) |maybe| {
            const partition = maybe orelse continue;
            if (!partition.firmwareHidden() or alreadyInstalled(partition.part_guid)) continue;
            if (firmwareHandleExists(bs, handles, partition.part_guid)) {
                report.firmware_present += 1;
                continue;
            }
            if (installChild(bs, disk, io, partition)) report.installed += 1;
        }
    }
    return report;
}

const testing = std.testing;

fn testPartition() gpt.Partition {
    var guid: [16]u8 = undefined;
    for (&guid, 0..) |*byte, i| byte.* = @intCast(0xA0 + i);
    return .{ .start_lba = 90_804_736, .end_lba = 121_077_726, .part_guid = guid, .name_utf16 = [_]u16{0} ** 36, .attributes = gpt.attribute_no_block_io_protocol, .entry_index = 2 };
}

test "requests map onto the parent disk inside the partition only" {
    try testing.expectEqual(Range{ .ok = 2048 }, translate(2048, 99, 512, 0, 512));
    try testing.expectEqual(Range{ .ok = 2048 + 99 }, translate(2048, 99, 512, 99, 512));
    try testing.expectEqual(Range{ .ok = 2048 + 90 }, translate(2048, 99, 512, 90, 10 * 512));
    try testing.expectEqual(Range.invalid_parameter, translate(2048, 99, 512, 90, 11 * 512));
    try testing.expectEqual(Range.invalid_parameter, translate(2048, 99, 512, 100, 512));
    try testing.expectEqual(Range.invalid_parameter, translate(2048, 99, 512, std.math.maxInt(u64), 512));
    try testing.expectEqual(Range.bad_buffer_size, translate(2048, 99, 512, 0, 511));
    try testing.expectEqual(Range.empty, translate(2048, 99, 512, 0, 0));
}

test "the HD node matches the EDK2 PartitionDxe GPT child" {
    const node = hardDriveNode(testPartition());
    try testing.expectEqual(@as(u8, 4), node[0]);
    try testing.expectEqual(@as(u8, 1), node[1]);
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, node[2..4], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, node[4..8], .little));
    try testing.expectEqual(@as(u64, 90_804_736), std.mem.readInt(u64, node[8..16], .little));
    try testing.expectEqual(@as(u64, 121_077_726 - 90_804_736 + 1), std.mem.readInt(u64, node[16..24], .little));
    try testing.expectEqual(@as(u8, 0xA0), node[24]);
    try testing.expectEqual(@as(u8, 0xAF), node[39]);
    try testing.expectEqual(@as(u8, 2), node[40]);
    try testing.expectEqual(@as(u8, 2), node[41]);
    // Same layout as the Zig std definition used by firmware-side parsers.
    try testing.expectEqual(@as(usize, hd_node_bytes), @sizeOf(uefi.DevicePath.Media.HardDriveDevicePath));
}

test "the child path is the parent disk path plus HD plus End and is found again" {
    // PciRoot-ish ACPI node (12 bytes) + USB node (6 bytes) + End.
    const parent = [_]u8{ 2, 1, 12, 0, 0xd0, 0x41, 0x03, 0x0a, 0, 0, 0, 0, 3, 5, 6, 0, 1, 0, 0x7f, 0xff, 4, 0 };
    var out: [128]u8 = undefined;
    const partition = testPartition();
    const path = buildChildPath(&parent, partition, &out).?;
    try testing.expectEqual(@as(usize, 18 + 42 + 4), path.len);
    try testing.expectEqualSlices(u8, parent[0..18], path[0..18]);
    try testing.expectEqual(@as(u8, 4), path[18]);
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0xff, 4, 0 }, path[60..64]);
    try testing.expect(pathHasPartition(path.ptr, path.len, partition.part_guid));
    try testing.expect(!pathHasPartition(&parent, parent.len, partition.part_guid));
    var other = partition.part_guid;
    other[0] ^= 1;
    try testing.expect(!pathHasPartition(path.ptr, path.len, other));
    // Too small an output buffer or a malformed parent path is refused.
    try testing.expect(buildChildPath(&parent, partition, out[0..50]) == null);
    const broken = [_]u8{ 2, 1, 0, 0, 0x7f, 0xff, 4, 0 };
    try testing.expect(buildChildPath(&broken, partition, &out) == null);
}

test "child Block I/O forwards to the parent at the partition offset" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const Fake = struct {
        var last_lba: u64 = 0;
        var last_size: usize = 0;
        var media = BlockIo.BlockMedia{ .media_id = 7, .removable_media = true, .media_present = true, .logical_partition = false, .read_only = false, .write_caching = false, .block_size = 512, .io_align = 0, .last_block = 1_000_000, .lowest_aligned_lba = 0, .logical_blocks_per_physical_block = 1, .optimal_transfer_length_granularity = 0 };
        fn r(_: *BlockIo, _: bool) callconv(cc) Status {
            return .success;
        }
        fn read(_: *BlockIo, media_id: u32, lba: u64, size: usize, _: [*]u8) callconv(cc) Status {
            if (media_id != 7) return .media_changed;
            last_lba = lba;
            last_size = size;
            return .success;
        }
        fn write(_: *BlockIo, _: u32, lba: u64, size: usize, _: [*]const u8) callconv(cc) Status {
            last_lba = lba;
            last_size = size;
            return .success;
        }
        fn flush(_: *BlockIo) callconv(cc) Status {
            return .success;
        }
    };
    var parent = BlockIo{ .revision = 0x00010000, .media = &Fake.media, ._reset = Fake.r, ._read_blocks = Fake.read, ._write_blocks = Fake.write, ._flush_blocks = Fake.flush };
    var child = Child{ .block_io = undefined, .media = std.mem.zeroes(BlockIo.BlockMedia), .parent = &parent, .start_lba = 4096, .part_guid = [_]u8{0} ** 16 };
    child.media.block_size = 512;
    child.media.last_block = 99;
    child.block_io = .{ .revision = 0x00010000, .media = &child.media, ._reset = reset, ._read_blocks = readBlocks, ._write_blocks = writeBlocks, ._flush_blocks = flushBlocks };
    var buffer: [1024]u8 = undefined;
    try testing.expectEqual(Status.success, child.block_io._read_blocks(&child.block_io, 7, 98, 1024, &buffer));
    try testing.expectEqual(@as(u64, 4096 + 98), Fake.last_lba);
    try testing.expectEqual(@as(usize, 1024), Fake.last_size);
    try testing.expectEqual(Status.invalid_parameter, child.block_io._read_blocks(&child.block_io, 7, 99, 1024, &buffer));
    try testing.expectEqual(Status.media_changed, child.block_io._read_blocks(&child.block_io, 8, 0, 512, &buffer));
    try testing.expectEqual(Status.success, child.block_io._write_blocks(&child.block_io, 7, 1, 512, &buffer));
    try testing.expectEqual(@as(u64, 4097), Fake.last_lba);
    child.media.read_only = true;
    try testing.expectEqual(Status.write_protected, child.block_io._write_blocks(&child.block_io, 7, 1, 512, &buffer));
    Fake.media.media_present = false;
    try testing.expectEqual(Status.no_media, child.block_io._read_blocks(&child.block_io, 7, 0, 512, &buffer));
}
