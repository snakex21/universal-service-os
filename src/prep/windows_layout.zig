//! Isolated Windows disk layout; no destructive operation without full blank scan.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const parts = @import("partitions.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
pub const Mode = enum { uefi, bios };
pub const mib: u64 = 1024 * 1024;
pub const esp_bytes: u64 = 300 * mib;
pub const msr_bytes: u64 = 16 * mib;
pub const bios_system_bytes: u64 = 100 * mib;
pub const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
pub const msr_type = [_]u8{ 0x16, 0xe3, 0xc9, 0xe3, 0x5c, 0x0b, 0xb8, 0x4d, 0x81, 0x7d, 0xf9, 0x2d, 0xf0, 0x02, 0x15, 0xae };
pub const ntfs_type = [_]u8{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 };
pub const Ids = struct {
    base: identity.Identifiers,
    esp: [16]u8,
    msr: [16]u8,
    /// Expand one validated platform-CSPRNG seed with 32-bit SHA-256 rounds.
    /// Two domain-separated outputs avoid re-reading/resetting QEMU fw_cfg
    /// and keep the i486 BIOS image free of a second 64-bit hash engine.
    pub fn fromSeed64(seed: [64]u8) !Ids {
        if (!entropy.healthy(&seed)) return error.EntropyUnavailable;
        var expanded: [128]u8 = undefined;
        @memcpy(expanded[0..64], &seed);
        for (0..2) |counter| {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(&seed);
            hash.update("USOSPREP Windows layout identity v2");
            hash.update(&.{@intCast(counter)});
            hash.final(expanded[64 + counter * 32 ..][0..32]);
        }
        return fromEntropy(expanded);
    }
    pub fn fromEntropy(seed: [128]u8) !Ids {
        if (!entropy.healthy(seed[0..64]) or !entropy.healthy(seed[64..128])) return error.EntropyUnavailable;
        var result: Ids = .{ .base = try identity.Identifiers.fromEntropy(seed[0..64].*), .esp = seed[64..80].*, .msr = seed[80..96].* };
        for ([_]*[16]u8{ &result.esp, &result.msr }) |guid| {
            guid[7] = (guid[7] & 0x0f) | 0x40;
            guid[8] = (guid[8] & 0x3f) | 0x80;
        }
        try result.validate();
        return result;
    }
    pub fn validate(self: Ids) !void {
        try self.base.validate();
        const all = [_][16]u8{ self.base.disk_guid, self.base.partition_guid, self.esp, self.msr };
        for (all, 0..) |guid, i| {
            if (guid[7] >> 4 != 4 or guid[8] >> 6 != 2) return error.InvalidArgument;
            for (all[0..i]) |previous| if (std.mem.eql(u8, &guid, &previous)) return error.InvalidArgument;
        }
    }
};
pub const Layout = struct {
    mode: Mode,
    sector_bytes: u32,
    disk_bytes: u64,
    esp: ?parts.Partition,
    msr: ?parts.Partition,
    system: parts.Partition,
    windows: parts.Partition,
};
pub const Selection = struct {
    explicit: bool,
    source_identity: usize,
    target_identity: usize,
    boot_identity: usize,
    // An exact, known test authorization marker may replace zero bytes at0.
    marker: []const u8 = &.{},
    progress: ?p.Progress = null,
    /// Hardware flow only: the disk is wrapped in hw_target.VirtualBlank,
    /// which presents every never-written chunk as zeros and zeroes chunks
    /// on first write. The full-device scan would only read those virtual
    /// zeros, so it is skipped; the user's disk question authorizes erase.
    virtual_blank: bool = false,
    pub fn validate(self: Selection) !void {
        if (!self.explicit or self.target_identity == 0 or self.source_identity == 0 or self.boot_identity == 0 or
            self.target_identity == self.source_identity or self.target_identity == self.boot_identity) return error.SourceTargetConflict;
        if (self.marker.len != 0) {
            const prefix = "USOSPREP TARGET v1\n";
            if (self.marker.len != prefix.len + 65 or !std.mem.startsWith(u8, self.marker, prefix) or self.marker[self.marker.len - 1] != '\n') return error.InvalidArgument;
            for (self.marker[prefix.len..][0..64]) |c| if (!std.ascii.isHex(c)) return error.InvalidArgument;
        }
    }
};

pub fn plan(disk: p.Disk, mode: Mode) !Layout {
    if (disk.sector_bytes != 512 and disk.sector_bytes != 4096) return error.Unsupported;
    const bytes = try disk.bytes();
    if (bytes < 64 * mib) return error.NoSpace;
    const table_sectors = @divExact(@as(u64, 16384), disk.sector_bytes);
    const end = if (mode == .uefi) std.mem.alignBackward(u64, bytes - (table_sectors + 1) * disk.sector_bytes, mib) else std.mem.alignBackward(u64, bytes, mib);
    const start = if (mode == .uefi) mib + esp_bytes + msr_bytes else mib + bios_system_bytes;
    if (end <= start or end - start < 32 * mib) return error.NoSpace;
    if (mode == .bios and end / disk.sector_bytes > std.math.maxInt(u32)) return error.Unsupported;
    return .{ .mode = mode, .sector_bytes = disk.sector_bytes, .disk_bytes = bytes, .esp = if (mode == .uefi) .{ .start_bytes = mib, .size_bytes = esp_bytes } else null, .msr = if (mode == .uefi) .{ .start_bytes = mib + esp_bytes, .size_bytes = msr_bytes } else null, .system = .{ .start_bytes = mib, .size_bytes = if (mode == .uefi) esp_bytes else bios_system_bytes }, .windows = .{ .start_bytes = start, .size_bytes = end - start } };
}

pub fn requireBlank(disk: p.Disk, selection: Selection, scratch: []u8) !void {
    try selection.validate();
    if (scratch.len < 4096 or selection.marker.len > scratch.len) return error.InvalidArgument;
    if (selection.virtual_blank) return;
    const bytes = try disk.bytes();
    var offset: u64 = 0;
    if (selection.progress) |hook| hook.report(.{ .current = 0, .total = bytes, .bytes = 0, .resources = 0 });
    while (offset < bytes) {
        const count: usize = @intCast(@min(scratch.len, bytes - offset));
        try disk.read(offset, scratch[0..count]);
        const skip = if (offset == 0) selection.marker.len else 0;
        if (skip != 0 and !std.mem.eql(u8, scratch[0..skip], selection.marker)) return error.TargetNotBlank;
        if (!std.mem.allEqual(u8, scratch[skip..count], 0)) return error.TargetNotBlank;
        offset += count;
        if (selection.progress) |hook| hook.report(.{ .current = offset, .total = bytes, .bytes = offset, .resources = 0 });
    }
}

pub fn create(disk: p.Disk, mode: Mode, ids: Ids, selection: Selection, allocator: std.mem.Allocator) !Layout {
    const layout = try plan(disk, mode);
    try ids.validate();
    const scratch = try allocator.alloc(u8, 65536);
    defer allocator.free(scratch);
    try requireBlank(disk, selection, scratch);
    const sector = scratch[0..disk.sector_bytes];
    @memset(sector, 0);
    if (mode == .bios) put(u32, sector, 440, ids.base.mbr_signature);
    sector[446] = if (mode == .bios) 0x80 else 0;
    sector[447..450].* = if (mode == .bios) .{ 0xfe, 0xff, 0xff } else .{ 0, 2, 0 };
    sector[450] = if (mode == .bios) 7 else 0xee;
    @memset(sector[451..454], 0xff);
    put(u32, sector, 454, if (mode == .bios) @intCast(layout.system.start_bytes / disk.sector_bytes) else 1);
    put(u32, sector, 458, @intCast(@min(if (mode == .bios) layout.system.size_bytes / disk.sector_bytes else disk.sectors - 1, std.math.maxInt(u32))));
    if (mode == .bios) {
        sector[463..466].* = .{ 0xfe, 0xff, 0xff };
        sector[466] = 7;
        @memset(sector[467..470], 0xff);
        put(u32, sector, 470, @intCast(layout.windows.start_bytes / disk.sector_bytes));
        put(u32, sector, 474, @intCast(layout.windows.size_bytes / disk.sector_bytes));
    }
    put(u16, sector, 510, 0xaa55);
    try disk.write(0, sector);
    if (mode == .uefi) {
        const table = scratch[0..16384];
        @memset(table, 0);
        entry(table[0..128], esp_type, ids.esp, layout.esp.?, disk.sector_bytes, "System");
        entry(table[128..256], msr_type, ids.msr, layout.msr.?, disk.sector_bytes, "Microsoft reserved partition");
        entry(table[256..384], ntfs_type, ids.base.partition_guid, layout.windows, disk.sector_bytes, "Windows");
        const crc = std.hash.Crc32.hash(table);
        const table_sectors = 16384 / @as(u64, disk.sector_bytes);
        const backup_table_lba = disk.sectors - 1 - table_sectors;
        try disk.write(2 * @as(u64, disk.sector_bytes), table);
        try disk.write(backup_table_lba * disk.sector_bytes, table);
        header(sector, 1, disk.sectors - 1, 2, disk.sectors, ids.base.disk_guid, crc);
        try disk.write(disk.sector_bytes, sector);
        header(sector, disk.sectors - 1, 1, backup_table_lba, disk.sectors, ids.base.disk_guid, crc);
        try disk.write((disk.sectors - 1) * disk.sector_bytes, sector);
    }
    try disk.flush();
    return layout;
}
fn put(comptime T: type, out: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, out[at..][0..@sizeOf(T)], value, .little);
}
fn entry(out: []u8, kind: [16]u8, guid: [16]u8, part: parts.Partition, sector_bytes: u32, name: []const u8) void {
    @memcpy(out[0..16], &kind);
    @memcpy(out[16..32], &guid);
    put(u64, out, 32, part.start_bytes / sector_bytes);
    put(u64, out, 40, (part.start_bytes + part.size_bytes) / sector_bytes - 1);
    for (name[0..@min(name.len, 36)], 0..) |c, i| put(u16, out, 56 + i * 2, c);
}
fn header(out: []u8, lba: u64, backup: u64, table_lba: u64, sectors: u64, guid: [16]u8, crc: u32) void {
    @memset(out, 0);
    @memcpy(out[0..8], "EFI PART");
    put(u32, out, 8, 0x10000);
    put(u32, out, 12, 92);
    put(u64, out, 24, lba);
    put(u64, out, 32, backup);
    const table_sectors = 16384 / @as(u64, out.len);
    put(u64, out, 40, 2 + table_sectors);
    put(u64, out, 48, sectors - 2 - table_sectors);
    @memcpy(out[56..72], &guid);
    put(u64, out, 72, table_lba);
    put(u32, out, 80, 128);
    put(u32, out, 84, 128);
    put(u32, out, 88, crc);
    put(u32, out, 16, std.hash.Crc32.hash(out[0..92]));
}

const SparseDisk = struct {
    head: []u8,
    tail: []u8,
    size: u64 = 512 * mib,
    sector_bytes: u32,
    writes: usize = 0,
    poison: ?u64 = null,
    fn disk(self: *SparseDisk) p.Disk {
        return .{ .context = self, .sectors = self.size / self.sector_bytes, .sector_bytes = self.sector_bytes, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *SparseDisk = @ptrCast(@alignCast(ctx));
        @memset(out, 0);
        if (offset < self.head.len) {
            const n = @min(out.len, self.head.len - @as(usize, @intCast(offset)));
            @memcpy(out[0..n], self.head[@intCast(offset)..][0..n]);
        }
        const start = self.size - self.tail.len;
        const from = @max(offset, start);
        const end = @min(offset + out.len, self.size);
        if (from < end) @memcpy(out[@intCast(from - offset)..][0..@intCast(end - from)], self.tail[@intCast(from - start)..][0..@intCast(end - from)]);
        if (self.poison) |at| if (at >= offset and at - offset < out.len) {
            out[@intCast(at - offset)] = 0x71;
        };
    }
    fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) p.Error!void {
        const self: *SparseDisk = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (offset <= self.head.len and bytes.len <= self.head.len - offset) {
            @memcpy(self.head[@intCast(offset)..][0..bytes.len], bytes);
            return;
        }
        const start = self.size - self.tail.len;
        if (offset >= start and offset <= self.size and bytes.len <= self.size - offset) {
            @memcpy(self.tail[@intCast(offset - start)..][0..bytes.len], bytes);
            return;
        }
        return error.Io;
    }
    fn flush(_: *anyopaque) p.Error!void {}
};
fn testIds() !Ids {
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i + 1);
    return Ids.fromEntropy(bytes);
}
const test_selection: Selection = .{ .explicit = true, .source_identity = 1, .target_identity = 2, .boot_identity = 3 };

test "Windows GPT layout512 and4096: ESP MSR Windows, CRC and1MiB alignment" {
    const a = std.testing.allocator;
    const head = try a.alloc(u8, 65536);
    defer a.free(head);
    const tail = try a.alloc(u8, 65536);
    defer a.free(tail);
    const ids = try testIds();
    for ([_]u32{ 512, 4096 }) |sector| {
        @memset(head, 0);
        @memset(tail, 0);
        var memory: SparseDisk = .{ .head = head, .tail = tail, .sector_bytes = sector };
        const layout = try create(memory.disk(), .uefi, ids, test_selection, a);
        try std.testing.expectEqual(300 * mib, layout.esp.?.size_bytes);
        try std.testing.expectEqual(16 * mib, layout.msr.?.size_bytes);
        try std.testing.expectEqual(317 * mib, layout.windows.start_bytes);
        try std.testing.expectEqual(@as(u64, 0), layout.windows.size_bytes % mib);
        try std.testing.expectEqualSlices(u8, &esp_type, head[2 * sector ..][0..16]);
        try std.testing.expectEqualSlices(u8, &msr_type, head[2 * sector + 128 ..][0..16]);
        try std.testing.expectEqualSlices(u8, &ntfs_type, head[2 * sector + 256 ..][0..16]);
        const primary = head[sector..][0..92];
        const saved = std.mem.readInt(u32, primary[16..20], .little);
        @memset(primary[16..20], 0);
        try std.testing.expectEqual(saved, std.hash.Crc32.hash(primary));
        try std.testing.expectEqualSlices(u8, head[2 * sector ..][0..16384], tail[tail.len - sector - 16384 ..][0..16384]);
        const backup = tail[tail.len - sector ..][0..92];
        const saved_b = std.mem.readInt(u32, backup[16..20], .little);
        @memset(backup[16..20], 0);
        try std.testing.expectEqual(saved_b, std.hash.Crc32.hash(backup));
    }
}
test "MBR active NTFS system plus separate Windows, preserve random disk signature" {
    const a = std.testing.allocator;
    const head = try a.alloc(u8, 65536);
    defer a.free(head);
    const tail = try a.alloc(u8, 65536);
    defer a.free(tail);
    @memset(head, 0);
    @memset(tail, 0);
    var memory: SparseDisk = .{ .head = head, .tail = tail, .sector_bytes = 512 };
    const ids = try testIds();
    const layout = try create(memory.disk(), .bios, ids, test_selection, a);
    try std.testing.expectEqual(@as(u8, 0x80), head[446]);
    try std.testing.expectEqual(@as(u8, 7), head[450]);
    try std.testing.expectEqual(@as(u8, 0), head[462]);
    try std.testing.expectEqual(@as(u8, 7), head[466]);
    try std.testing.expectEqual(101 * mib, layout.windows.start_bytes);
    try std.testing.expectEqual(ids.base.mbr_signature, std.mem.readInt(u32, head[440..444], .little));
}
test "source disk, unspecified target and hidden nonzero data refuse with zero writes" {
    const a = std.testing.allocator;
    const head = try a.alloc(u8, 65536);
    defer a.free(head);
    const tail = try a.alloc(u8, 65536);
    defer a.free(tail);
    @memset(head, 0);
    @memset(tail, 0);
    var memory: SparseDisk = .{ .head = head, .tail = tail, .sector_bytes = 512 };
    const ids = try testIds();
    var selection = test_selection;
    selection.target_identity = selection.source_identity;
    try std.testing.expectError(error.SourceTargetConflict, create(memory.disk(), .bios, ids, selection, a));
    selection = test_selection;
    selection.explicit = false;
    try std.testing.expectError(error.SourceTargetConflict, create(memory.disk(), .bios, ids, selection, a));
    memory.poison = 73 * mib + 19;
    try std.testing.expectError(error.TargetNotBlank, create(memory.disk(), .bios, ids, test_selection, a));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
}

test "one CSPRNG seed expands with independent SHA256 reference vectors" {
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const result = try Ids.fromSeed64(seed);
    const expected_esp = [_]u8{ 0xf8, 0xe9, 0xf5, 0xcd, 0x30, 0xbb, 0x8e, 0x4e, 0x84, 0x86, 0xd7, 0xeb, 0x04, 0x20, 0x0c, 0x49 };
    const expected_msr = [_]u8{ 0x45, 0x4a, 0x24, 0x0d, 0xf7, 0x25, 0x7b, 0x40, 0x89, 0x35, 0xe0, 0xec, 0x16, 0x62, 0x90, 0xd3 };
    try std.testing.expectEqualSlices(u8, &expected_esp, &result.esp);
    try std.testing.expectEqualSlices(u8, &expected_msr, &result.msr);
    try std.testing.expectError(error.EntropyUnavailable, Ids.fromSeed64(@splat(0)));
    try std.testing.expectError(error.EntropyUnavailable, Ids.fromSeed64(@splat(0xff)));
    var repeated: [64]u8 = @splat(0);
    for (0..16) |i| std.mem.writeInt(u32, repeated[i * 4 ..][0..4], 0x12345678, .little);
    try std.testing.expectError(error.EntropyUnavailable, Ids.fromSeed64(repeated));
}
