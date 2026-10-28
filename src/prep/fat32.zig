// SPDX-License-Identifier: GPL-3.0-or-later
//! Fresh-volume FAT32 formatter and append-only ESP writer. No allocator or
//! firmware dependency. Disk/partition selection and empty-disk checks belong
//! to the caller; this API never discovers a target or reformats implicitly.
//!
//! On-disk structures follow Microsoft's public FAT specification v1.03,
//! 2000-12-06, sections Boot Sector/BPB, FAT32 FSInfo, directories and LFN:
//! https://download.microsoft.com/download/1/6/1/161ba512-40e2-4cc9-843a-923143f3456c/fatgen103.doc
//! This is independently written implementation code, not specification text.
const std = @import("std");
const p = @import("platform.zig");
const partitions = @import("partitions.zig");
const unicode = @import("unicode_upper.zig");

pub const Error = p.Error || error{ InvalidName, AlreadyExists, NotFound, NotDirectory, Busy, Incomplete, Poisoned };
pub const Partition = partitions.Partition;
pub const Options = struct { serial: u32, label: [11]u8 = "USOS ESP   ".* };
const max_sector = 4096;
const eoc = 0x0fffffff;
const min_clusters = 65525;
const max_dir_slots = 65536;

fn put(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

pub const Geometry = struct {
    sector_bytes: u32,
    sectors_per_cluster: u8,
    total_sectors: u32,
    sectors_per_fat: u32,
    first_data_sector: u32,
    cluster_count: u32,
    pub fn clusterBytes(self: Geometry) u32 {
        return self.sector_bytes * self.sectors_per_cluster;
    }
};

pub fn geometry(disk: p.Disk, part: Partition) Error!Geometry {
    const bps = disk.sector_bytes;
    if (bps != 512 and bps != 4096) return error.Unsupported;
    if (part.start_bytes % bps != 0 or part.size_bytes % bps != 0 or part.size_bytes == 0) return error.InvalidArgument;
    const capacity = try disk.bytes();
    if (part.start_bytes > capacity or part.size_bytes > capacity - part.start_bytes) return error.Bounds;
    const total = part.size_bytes / bps;
    if (total > std.math.maxInt(u32) or part.start_bytes / bps > std.math.maxInt(u32)) return error.Unsupported;
    if (total <= 32) return error.NoSpace;
    // One-sector clusters are deliberately valid even on the260MiB4Kn ESP.
    // Larger volumes choose at most32KiB clusters, maintaining FAT32's range.
    var spc: u32 = 1;
    while (spc * bps < 32768 and total / spc > 4 * 1024 * 1024) spc *= 2;
    const fat = std.math.divCeil(u64, (total / spc + 2) * 4, bps) catch return error.Bounds;
    const data = 32 + 2 * fat;
    if (data >= total) return error.NoSpace;
    const clusters = (total - data) / spc;
    if (clusters < min_clusters) return error.NoSpace;
    if (clusters > 0x0fffffef) return error.Unsupported;
    return .{ .sector_bytes = bps, .sectors_per_cluster = @intCast(spc), .total_sectors = @intCast(total), .sectors_per_fat = @intCast(fat), .first_data_sector = @intCast(data), .cluster_count = @intCast(clusters) };
}

pub fn format(disk: p.Disk, part: Partition, options: Options) Error!Volume {
    const g = try geometry(disk, part);
    if (options.serial == 0 or options.serial == std.math.maxInt(u32)) return error.InvalidArgument;
    for (options.label) |c| if (c < 0x20 or c >= 0x7f or std.mem.indexOfScalar(u8, "\"*+,./:;<=>?[\\]|", c) != null) return error.InvalidName;
    var volume = Volume{ .disk = disk, .partition = part, .g = g, .free_clusters = g.cluster_count - 1 };
    // Metadata and the root cluster are initialized; unused data clusters are
    // zeroed on allocation, so stale contents never become file slack bytes.
    try volume.zero(0, @as(u64, g.first_data_sector) * g.sector_bytes + g.clusterBytes());
    var boot: [max_sector]u8 = @splat(0);
    @memcpy(boot[0..3], &[_]u8{ 0xeb, 0x58, 0x90 });
    @memcpy(boot[3..11], "USOSPREP");
    put(u16, &boot, 11, @intCast(g.sector_bytes));
    boot[13] = g.sectors_per_cluster;
    put(u16, &boot, 14, 32);
    boot[16] = 2;
    boot[21] = 0xf8;
    put(u16, &boot, 24, 63);
    put(u16, &boot, 26, 255);
    put(u32, &boot, 28, @intCast(part.start_bytes / g.sector_bytes));
    put(u32, &boot, 32, g.total_sectors);
    put(u32, &boot, 36, g.sectors_per_fat);
    put(u32, &boot, 44, 2);
    put(u16, &boot, 48, 1);
    put(u16, &boot, 50, 6);
    boot[64] = 0x80;
    boot[66] = 0x29;
    put(u32, &boot, 67, options.serial);
    @memcpy(boot[71..82], &options.label);
    @memcpy(boot[82..90], "FAT32   ");
    put(u16, &boot, 510, 0xaa55);
    try volume.write(0, boot[0..g.sector_bytes]);
    try volume.write(6 * g.sector_bytes, boot[0..g.sector_bytes]);
    // FAT's complete reserved boot record has three signed sectors. The
    // middle sector is FSInfo (written by flush); the third has no ESP code.
    @memset(&boot, 0);
    put(u16, &boot, 510, 0xaa55);
    try volume.write(2 * g.sector_bytes, boot[0..g.sector_bytes]);
    try volume.write(8 * g.sector_bytes, boot[0..g.sector_bytes]);
    try volume.setFat(0, 0x0ffffff8);
    try volume.setFat(1, eoc);
    try volume.setFat(2, eoc);
    var label: [32]u8 = @splat(0);
    @memcpy(label[0..11], &options.label);
    label[11] = 0x08;
    try volume.write(try volume.clusterOffset(2), &label);
    try volume.flush();
    return volume;
}

pub const Volume = struct {
    disk: p.Disk,
    partition: Partition,
    g: Geometry,
    free_clusters: u32,
    next_cluster: u32 = 3,
    open_file: bool = false,
    writer_generation: u64 = 0,
    poisoned: bool = false,

    /// Resume an ESP previously formatted by this writer. This deliberately
    /// does not mount arbitrary FAT volumes: the unchanged own geometry,
    /// mirrored metadata and append-only allocation invariants are required.
    /// There are no writes, flushes, allocator requests or sector discovery.
    pub fn openExisting(disk: p.Disk, partition: Partition) Error!Volume {
        const g = try geometry(disk, partition);
        var volume = Volume{ .disk = disk, .partition = partition, .g = g, .free_clusters = 0 };
        var primary: [max_sector]u8 = undefined;
        var backup: [max_sector]u8 = undefined;
        const bytes = g.sector_bytes;
        try volume.read(0, primary[0..bytes]);
        if (!std.mem.eql(u8, primary[3..11], "USOSPREP") or !std.mem.eql(u8, primary[82..90], "FAT32   ") or
            get(u16, &primary, 510) != 0xaa55 or get(u16, &primary, 11) != bytes or
            primary[13] != g.sectors_per_cluster or get(u16, &primary, 14) != 32 or primary[16] != 2 or
            get(u16, &primary, 17) != 0 or get(u16, &primary, 19) != 0 or primary[21] != 0xf8 or
            get(u16, &primary, 22) != 0 or get(u32, &primary, 28) != partition.start_bytes / bytes or
            get(u32, &primary, 32) != g.total_sectors or get(u32, &primary, 36) != g.sectors_per_fat or
            get(u16, &primary, 40) != 0 or get(u16, &primary, 42) != 0 or get(u32, &primary, 44) != 2 or
            get(u16, &primary, 48) != 1 or get(u16, &primary, 50) != 6 or primary[66] != 0x29 or
            get(u32, &primary, 67) == 0 or get(u32, &primary, 67) == 0xffffffff) return error.Corrupt;
        try volume.read(6 * bytes, backup[0..bytes]);
        if (!std.mem.eql(u8, primary[0..bytes], backup[0..bytes])) return error.Corrupt;
        try volume.read(2 * bytes, primary[0..bytes]);
        try volume.read(8 * bytes, backup[0..bytes]);
        if (get(u16, &primary, 510) != 0xaa55 or !std.mem.eql(u8, primary[0..bytes], backup[0..bytes])) return error.Corrupt;
        try volume.read(bytes, primary[0..bytes]);
        try volume.read(7 * bytes, backup[0..bytes]);
        if (!std.mem.eql(u8, primary[0..bytes], backup[0..bytes]) or get(u32, &primary, 0) != 0x41615252 or
            get(u32, &primary, 484) != 0x61417272 or get(u32, &primary, 508) != 0xaa550000) return error.Corrupt;
        const free = get(u32, &primary, 488);
        const next_hint = get(u32, &primary, 492);
        if (free >= g.cluster_count) return error.Corrupt;
        var saw_free = false;
        var counted_free: u32 = 0;
        var last_used: u32 = 1;
        for (0..g.sectors_per_fat) |sector| {
            try volume.read((32 + @as(u64, sector)) * bytes, primary[0..bytes]);
            try volume.read((32 + g.sectors_per_fat + @as(u64, sector)) * bytes, backup[0..bytes]);
            if (!std.mem.eql(u8, primary[0..bytes], backup[0..bytes])) return error.Corrupt;
            var offset: usize = 0;
            while (offset < bytes) : (offset += 4) {
                const cluster = @as(u64, sector) * (bytes / 4) + offset / 4;
                const value = get(u32, &primary, offset);
                if (cluster == 0) {
                    if (value != 0x0ffffff8) return error.Corrupt;
                    continue;
                }
                if (cluster == 1) {
                    if (value != eoc) return error.Corrupt;
                    continue;
                }
                if (cluster > g.cluster_count + 1) {
                    if (value != 0) return error.Corrupt;
                    continue;
                }
                if (value == 0) {
                    saw_free = true;
                    counted_free += 1;
                } else {
                    // Our writer never frees clusters or creates backward
                    // chain links. Enforce that invariant before resuming.
                    if (saw_free or value > eoc or (value < 0x0ffffff8 and (value <= cluster or value > g.cluster_count + 1))) return error.Corrupt;
                    last_used = @intCast(cluster);
                }
            }
        }
        if (last_used < 2 or free != counted_free or (free == 0 and next_hint != 0xffffffff) or
            (free != 0 and next_hint != last_used + 1)) return error.Corrupt;
        volume.free_clusters = free;
        volume.next_cluster = last_used + 1;
        return volume;
    }

    pub fn root(_: *Volume) u32 {
        return 2;
    }
    fn ready(self: *Volume) Error!void {
        if (self.poisoned) return error.Poisoned;
        if (self.open_file) return error.Busy;
    }
    fn read(self: *Volume, offset: u64, out: []u8) Error!void {
        if (offset > self.partition.size_bytes or out.len > self.partition.size_bytes - offset) return error.Bounds;
        try self.disk.read(self.partition.start_bytes + offset, out);
    }
    fn write(self: *Volume, offset: u64, bytes: []const u8) Error!void {
        if (offset > self.partition.size_bytes or bytes.len > self.partition.size_bytes - offset) return error.Bounds;
        // Firmware BlockIo and the BIOS backend accept complete logical
        // sectors. Directory cells and a caller's small stream chunks do not
        // have that alignment, so confine read/modify/write to this partition.
        var position = offset;
        var left = bytes;
        var bounce: [max_sector]u8 = undefined;
        while (left.len != 0) {
            const within: usize = @intCast(position % self.g.sector_bytes);
            if (within == 0 and left.len >= self.g.sector_bytes) {
                // Preserve large streaming writes rather than issuing one
                // firmware request per sector. Backends may subdivide further.
                const aligned = @min(left.len / self.g.sector_bytes * self.g.sector_bytes, 64 * 1024);
                self.disk.write(self.partition.start_bytes + position, left[0..aligned]) catch |err| {
                    self.poisoned = true;
                    return err;
                };
                position += aligned;
                left = left[aligned..];
                continue;
            }
            const base = position - within;
            const take = @min(left.len, self.g.sector_bytes - within);
            try self.read(base, bounce[0..self.g.sector_bytes]);
            @memcpy(bounce[within..][0..take], left[0..take]);
            self.disk.write(self.partition.start_bytes + base, bounce[0..self.g.sector_bytes]) catch |err| {
                self.poisoned = true;
                return err;
            };
            position += take;
            left = left[take..];
        }
    }
    fn zero(self: *Volume, start: u64, len: u64) Error!void {
        var buffer: [8192]u8 = @splat(0);
        var offset = start;
        var left = len;
        while (left != 0) {
            const take: usize = @intCast(@min(buffer.len, left));
            try self.write(offset, buffer[0..take]);
            offset += take;
            left -= take;
        }
    }
    fn clusterOffset(self: *Volume, cluster: u32) Error!u64 {
        if (cluster < 2 or cluster - 2 >= self.g.cluster_count) return error.Corrupt;
        return @as(u64, self.g.first_data_sector) * self.g.sector_bytes + @as(u64, cluster - 2) * self.g.clusterBytes();
    }
    fn fat(self: *Volume, cluster: u32) Error!u32 {
        if (cluster > self.g.cluster_count + 1) return error.Corrupt;
        var buffer: [max_sector]u8 = undefined;
        const pos = @as(u64, cluster) * 4;
        try self.read(32 * self.g.sector_bytes + pos / self.g.sector_bytes * self.g.sector_bytes, buffer[0..self.g.sector_bytes]);
        return get(u32, &buffer, @intCast(pos % self.g.sector_bytes)) & 0x0fffffff;
    }
    fn setFat(self: *Volume, cluster: u32, value: u32) Error!void {
        if (cluster > self.g.cluster_count + 1 or value > eoc) return error.Corrupt;
        const pos = @as(u64, cluster) * 4;
        var buffer: [max_sector]u8 = undefined;
        for (0..2) |copy| {
            const offset = (32 + @as(u64, copy) * self.g.sectors_per_fat) * self.g.sector_bytes + pos / self.g.sector_bytes * self.g.sector_bytes;
            try self.read(offset, buffer[0..self.g.sector_bytes]);
            put(u32, &buffer, @intCast(pos % self.g.sector_bytes), value);
            try self.write(offset, buffer[0..self.g.sector_bytes]);
        }
    }
    fn allocate(self: *Volume) Error!u32 {
        return self.allocateChain(1);
    }
    fn allocateChain(self: *Volume, count: u32) Error!u32 {
        if (count == 0) return 0;
        if (count > self.free_clusters or self.next_cluster > self.g.cluster_count + 1 or count > self.g.cluster_count + 2 - self.next_cluster) return error.NoSpace;
        const first = self.next_cluster;
        var cluster = first;
        var buffer: [max_sector]u8 = undefined;
        while (cluster < first + count) {
            const relative = @as(u64, cluster) * 4;
            const sector = relative / self.g.sector_bytes;
            try self.read((32 + sector) * self.g.sector_bytes, buffer[0..self.g.sector_bytes]);
            while (cluster < first + count and @as(u64, cluster) * 4 / self.g.sector_bytes == sector) : (cluster += 1) {
                const offset: usize = @intCast(@as(u64, cluster) * 4 % self.g.sector_bytes);
                if (get(u32, &buffer, offset) & 0x0fffffff != 0) return error.Corrupt;
                put(u32, &buffer, offset, if (cluster == first + count - 1) eoc else cluster + 1);
            }
            for (0..2) |copy| try self.write((32 + @as(u64, copy) * self.g.sectors_per_fat + sector) * self.g.sector_bytes, buffer[0..self.g.sector_bytes]);
        }
        try self.zero(try self.clusterOffset(first), @as(u64, count) * self.g.clusterBytes());
        self.next_cluster += count;
        self.free_clusters -= count;
        return first;
    }
    pub fn flush(self: *Volume) Error!void {
        if (self.poisoned) return error.Poisoned;
        if (self.open_file) return error.Busy;
        var info: [max_sector]u8 = @splat(0);
        put(u32, &info, 0, 0x41615252);
        put(u32, &info, 484, 0x61417272);
        put(u32, &info, 488, self.free_clusters);
        put(u32, &info, 492, if (self.free_clusters == 0) 0xffffffff else self.next_cluster);
        put(u32, &info, 508, 0xaa550000);
        try self.write(self.g.sector_bytes, info[0..self.g.sector_bytes]);
        try self.write(7 * self.g.sector_bytes, info[0..self.g.sector_bytes]);
        self.disk.flush() catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    /// Idempotent directory creation. All parents must already exist.
    pub fn mkdir(self: *Volume, path: []const u8) Error!u32 {
        try self.ready();
        const parent = try self.resolveParent(path);
        if (try self.find(parent.cluster, parent.name())) |entry| {
            if (!entry.directory) return error.NotDirectory;
            return entry.cluster;
        }
        const alias = try self.chooseAlias(parent.cluster, parent.name());
        const slots = try self.reserve(parent.cluster, longCount(parent.name(), alias) + 1);
        const cluster = try self.allocate();
        var dots: [64]u8 = @splat(0);
        @memset(dots[0..11], ' ');
        dots[0] = '.';
        dots[11] = 0x10;
        dates(dots[0..32]);
        setEntryCluster(dots[0..32], cluster);
        @memset(dots[32..43], ' ');
        dots[32] = '.';
        dots[33] = '.';
        dots[43] = 0x10;
        dates(dots[32..64]);
        setEntryCluster(dots[32..64], if (parent.cluster == 2) 0 else parent.cluster);
        try self.write(try self.clusterOffset(cluster), &dots);
        try self.publish(parent.cluster, slots, parent.name(), alias, cluster, 0, 0x10);
        return cluster;
    }

    /// Creates a file once, with its final size known. Writes are sequential;
    /// there is at most one in-flight writer. finish() publishes its directory
    /// entry only after every byte was supplied. Failed I/O poisons the volume.
    pub fn createFile(self: *Volume, path: []const u8, size: u64) Error!FileWriter {
        try self.ready();
        if (size > std.math.maxInt(u32)) return error.Unsupported;
        const parent = try self.resolveParent(path);
        if (try self.find(parent.cluster, parent.name()) != null) return error.AlreadyExists;
        const alias = try self.chooseAlias(parent.cluster, parent.name());
        const needed = std.math.divCeil(u64, size, self.g.clusterBytes()) catch return error.Bounds;
        if (needed > self.free_clusters) return error.NoSpace;
        const slots = try self.reserve(parent.cluster, longCount(parent.name(), alias) + 1);
        if (needed > self.free_clusters) return error.NoSpace;
        const first = try self.allocateChain(@intCast(needed));
        var name: [255]u16 = undefined;
        @memcpy(name[0..parent.len], parent.name());
        self.writer_generation = std.math.add(u64, self.writer_generation, 1) catch return error.TooManyEntries;
        self.open_file = true;
        return .{ .volume = self, .parent_cluster = parent.cluster, .slots = slots, .name = name, .name_len = @intCast(parent.len), .alias = alias, .first = first, .size = @intCast(size), .generation = self.writer_generation };
    }

    const Path = struct { cluster: u32, name: [255]u16, len: usize };
    fn parseParent(self: *Volume, path: []const u8) Error!Path {
        if (path.len == 0 or path[0] == '/' or path[0] == '\\' or path[path.len - 1] == '/' or path[path.len - 1] == '\\') return error.InvalidName;
        var validate = std.mem.splitAny(u8, path, "/\\");
        var validated: usize = 0;
        while (validate.next()) |component| {
            var units: [255]u16 = undefined;
            _ = try nameUnits(component, &units);
            validated += 1;
            if (validated > 65) return error.TooManyEntries;
        }
        var iterator = std.mem.splitAny(u8, path, "/\\");
        var cluster: u32 = 2;
        var component = iterator.next() orelse return error.InvalidName;
        var depth: usize = 0;
        while (true) {
            var units: [255]u16 = undefined;
            const len = try nameUnits(component, &units);
            const next = iterator.next() orelse return .{ .cluster = cluster, .name = units, .len = len };
            depth += 1;
            if (depth > 64) return error.TooManyEntries;
            const entry = try self.find(cluster, units[0..len]) orelse return error.NotFound;
            if (!entry.directory) return error.NotDirectory;
            cluster = entry.cluster;
            component = next;
        }
    }
    fn resolveParent(self: *Volume, path: []const u8) Error!ResolvedParent {
        const parsed = try self.parseParent(path);
        return .{ .cluster = parsed.cluster, .storage = parsed.name, .len = parsed.len };
    }
    const ResolvedParent = struct {
        cluster: u32,
        storage: [255]u16,
        len: usize,
        fn name(self: *const ResolvedParent) []const u16 {
            return self.storage[0..self.len];
        }
    };

    const Entry = struct { cluster: u32, size: u32, directory: bool };
    fn find(self: *Volume, dir: u32, name: []const u16) Error!?Entry {
        var cursor = Cursor.init(self, dir);
        var long: [260]u16 = @splat(0xffff);
        var remaining: u8 = 0;
        var check: u8 = 0;
        var valid = false;
        while (try cursor.next()) |raw| {
            if (raw[0] == 0) return null;
            if (raw[0] == 0xe5) {
                valid = false;
                continue;
            }
            if (raw[11] == 0x0f) {
                const ordinal = raw[0] & 0x1f;
                if (raw[0] & 0x40 != 0) {
                    long = @splat(0xffff);
                    remaining = ordinal;
                    check = raw[13];
                    valid = ordinal > 0 and ordinal <= 20;
                }
                if (!valid or remaining != ordinal or ordinal == 0 or raw[13] != check or raw[12] != 0 or get(u16, raw, 26) != 0) {
                    valid = false;
                    continue;
                }
                for (lfn_offsets, 0..) |offset, i| long[(@as(usize, ordinal) - 1) * 13 + i] = get(u16, raw, offset);
                remaining -= 1;
                continue;
            }
            const matches = valid and remaining == 0 and check == checksum(raw[0..11]) and equalName(trimLong(&long), name);
            valid = false;
            if (raw[11] & 0x08 != 0) continue;
            if (matches or shortMatches(raw[0..11], name)) return .{ .cluster = @as(u32, get(u16, raw, 20)) << 16 | get(u16, raw, 26), .size = get(u32, raw, 28), .directory = raw[11] & 0x10 != 0 };
        }
        return null;
    }
    fn aliasUsed(self: *Volume, dir: u32, short: [11]u8) Error!bool {
        var cursor = Cursor.init(self, dir);
        while (try cursor.next()) |raw| {
            if (raw[0] == 0) return false;
            if (raw[0] != 0xe5 and raw[11] != 0x0f and std.mem.eql(u8, raw[0..11], &short)) return true;
        }
        return false;
    }
    fn chooseAlias(self: *Volume, dir: u32, name: []const u16) Error![11]u8 {
        if (simpleAlias(name)) |short| if (!try self.aliasUsed(dir, short)) return short;
        var candidate: [11]u8 = @splat(' ');
        const dot = std.mem.lastIndexOfScalar(u16, name, '.') orelse name.len;
        const base = name[0..dot];
        var cleaned: [255]u8 = undefined;
        var length: usize = 0;
        for (base) |unit| {
            if (unit == ' ' or unit == '.') continue;
            cleaned[length] = aliasChar(unit);
            length += 1;
        }
        if (length == 0) {
            cleaned[0] = '_';
            length = 1;
        }
        if (dot < name.len) for (name[dot + 1 ..][0..@min(3, name.len - dot - 1)], 0..) |unit, i| {
            candidate[8 + i] = aliasChar(unit);
        };
        var serial: u32 = 1;
        while (serial <= 999999) : (serial += 1) {
            var digits: [6]u8 = undefined;
            const decimal = std.fmt.bufPrint(&digits, "{d}", .{serial}) catch return error.TooManyEntries;
            @memset(candidate[0..8], ' ');
            const prefix = @min(length, 7 - decimal.len);
            @memcpy(candidate[0..prefix], cleaned[0..prefix]);
            candidate[prefix] = '~';
            @memcpy(candidate[prefix + 1 ..][0..decimal.len], decimal);
            if (!try self.aliasUsed(dir, candidate)) return candidate;
        }
        return error.TooManyEntries;
    }
    fn slotOffset(self: *Volume, dir: u32, index: u32, extend: bool) Error!u64 {
        if (index >= max_dir_slots) return error.TooManyEntries;
        const per_cluster = self.g.clusterBytes() / 32;
        var cluster = dir;
        var walk: u32 = 0;
        while (walk < index / per_cluster) : (walk += 1) {
            var next = try self.fat(cluster);
            if (next >= 0x0ffffff8) {
                if (!extend) return error.Bounds;
                next = try self.allocate();
                try self.setFat(cluster, next);
            }
            if (next < 2 or next > self.g.cluster_count + 1) return error.Corrupt;
            cluster = next;
        }
        return try self.clusterOffset(cluster) + index % per_cluster * 32;
    }
    fn reserve(self: *Volume, dir: u32, count: u32) Error!u32 {
        var cursor = Cursor.init(self, dir);
        var index: u32 = 0;
        while (try cursor.next()) |raw| : (index += 1) if (raw[0] == 0) break;
        if (count > max_dir_slots - index - 1) return error.TooManyEntries;
        // Include an explicit end marker even if the LFN group crosses a
        // cluster boundary. Existing fresh directories never contain holes.
        _ = try self.slotOffset(dir, index + count, true);
        return index;
    }
    fn publish(self: *Volume, dir: u32, slot: u32, name: []const u16, short: [11]u8, cluster: u32, size: u32, attributes: u8) Error!void {
        const count = longCount(name, short);
        var raw: [32]u8 = undefined;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            @memset(&raw, 0xff);
            const ordinal = count - index;
            raw[0] = @intCast(ordinal | if (index == 0) @as(u32, 0x40) else 0);
            raw[11] = 0x0f;
            raw[12] = 0;
            raw[13] = checksum(&short);
            put(u16, &raw, 26, 0);
            for (lfn_offsets, 0..) |offset, unit| {
                const pos = (ordinal - 1) * 13 + unit;
                put(u16, &raw, offset, if (pos < name.len) name[pos] else if (pos == name.len) 0 else 0xffff);
            }
            try self.write(try self.slotOffset(dir, slot + index, false), &raw);
        }
        @memset(&raw, 0);
        @memcpy(raw[0..11], &short);
        raw[11] = attributes;
        dates(&raw);
        setEntryCluster(&raw, cluster);
        put(u32, &raw, 28, size);
        try self.write(try self.slotOffset(dir, slot + count, false), &raw);
    }

    const Cursor = struct {
        volume: *Volume,
        cluster: u32,
        in_cluster: u32 = 0,
        slots: u32 = 0,
        cached_sector: u64 = std.math.maxInt(u64),
        buffer: [max_sector]u8 = undefined,
        fn init(volume: *Volume, cluster: u32) Cursor {
            return .{ .volume = volume, .cluster = cluster };
        }
        fn next(self: *Cursor) Error!?[]const u8 {
            if (self.slots >= max_dir_slots) return error.TooManyEntries;
            if (self.in_cluster == self.volume.g.clusterBytes()) {
                const next_cluster = try self.volume.fat(self.cluster);
                if (next_cluster >= 0x0ffffff8) return null;
                if (next_cluster < 2 or next_cluster > self.volume.g.cluster_count + 1) return error.Corrupt;
                self.cluster = next_cluster;
                self.in_cluster = 0;
            }
            const offset = try self.volume.clusterOffset(self.cluster) + self.in_cluster;
            const sector = offset / self.volume.g.sector_bytes;
            if (self.cached_sector != sector) {
                try self.volume.read(sector * self.volume.g.sector_bytes, self.buffer[0..self.volume.g.sector_bytes]);
                self.cached_sector = sector;
            }
            self.in_cluster += 32;
            self.slots += 1;
            return self.buffer[@intCast(offset % self.volume.g.sector_bytes)..][0..32];
        }
    };
};

pub const FileWriter = struct {
    volume: *Volume,
    parent_cluster: u32,
    slots: u32,
    name: [255]u16,
    name_len: u8,
    alias: [11]u8,
    first: u32,
    size: u32,
    written: u32 = 0,
    finished: bool = false,
    generation: u64,
    pub fn write(self: *FileWriter, bytes: []const u8) Error!void {
        if (self.volume.poisoned) return error.Poisoned;
        if (self.finished or !self.volume.open_file or self.generation != self.volume.writer_generation) return error.InvalidArgument;
        if (bytes.len > self.size - self.written) return error.Bounds;
        // Allocation is monotonic in a fresh ESP: no other allocation is
        // permitted while this writer is active, therefore its run is contiguous.
        if (bytes.len != 0) try self.volume.write(try self.volume.clusterOffset(self.first) + self.written, bytes);
        self.written += @intCast(bytes.len);
    }
    pub fn finish(self: *FileWriter) Error!void {
        if (self.volume.poisoned) return error.Poisoned;
        if (self.finished or !self.volume.open_file or self.generation != self.volume.writer_generation) return error.InvalidArgument;
        if (self.written != self.size) return error.Incomplete;
        try self.volume.publish(self.parent_cluster, self.slots, self.name[0..self.name_len], self.alias, self.first, self.size, 0x20);
        self.volume.open_file = false;
        self.finished = true;
    }
};

fn dates(raw: []u8) void {
    put(u16, raw, 16, 0x21);
    put(u16, raw, 18, 0x21);
    put(u16, raw, 24, 0x21);
}
fn setEntryCluster(raw: []u8, cluster: u32) void {
    put(u16, raw, 20, @truncate(cluster >> 16));
    put(u16, raw, 26, @truncate(cluster));
}
const lfn_offsets = [_]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
fn checksum(short: []const u8) u8 {
    var sum: u8 = 0;
    for (short) |byte| sum = ((sum & 1) << 7) +% (sum >> 1) +% byte;
    return sum;
}
fn trimLong(name: []const u16) []const u16 {
    var end: usize = 0;
    while (end < name.len and name[end] != 0 and name[end] != 0xffff) : (end += 1) {}
    return name[0..end];
}
fn equalName(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (unicode.upperUnit(x) != unicode.upperUnit(y)) return false;
    return true;
}
fn nameUnits(input: []const u8, output: *[255]u16) Error!usize {
    if (input.len == 0 or std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..") or input[input.len - 1] == '.' or input[input.len - 1] == ' ') return error.InvalidName;
    const len = std.unicode.utf8ToUtf16Le(output, input) catch return error.InvalidName;
    if (len == 0 or len > 255) return error.InvalidName;
    for (output[0..len]) |unit| if (unit < 0x20 or unit == 0xffff or (unit <= 0x7f and std.mem.indexOfScalar(u8, "\"*/:<>?\\|", @intCast(unit)) != null)) return error.InvalidName;
    return len;
}
fn aliasChar(unit: u16) u8 {
    if (unit < 128 and (std.ascii.isAlphanumeric(@intCast(unit)) or std.mem.indexOfScalar(u8, "$%'-_@~`!(){}^#&", @intCast(unit)) != null)) return std.ascii.toUpper(@intCast(unit));
    return '_';
}
fn simpleAlias(name: []const u16) ?[11]u8 {
    const dot = std.mem.lastIndexOfScalar(u16, name, '.') orelse name.len;
    if (dot == 0 or dot > 8 or (dot < name.len and name.len - dot - 1 > 3)) return null;
    var short: [11]u8 = @splat(' ');
    for (name[0..dot], 0..) |unit, i| {
        if (unit >= 128 or unit == ' ' or unit == '.' or aliasChar(unit) != std.ascii.toUpper(@as(u8, @intCast(unit)))) return null;
        short[i] = aliasChar(unit);
    }
    if (dot < name.len) for (name[dot + 1 ..], 0..) |unit, i| {
        if (unit >= 128 or unit == ' ' or unit == '.' or aliasChar(unit) != std.ascii.toUpper(@as(u8, @intCast(unit)))) return null;
        short[8 + i] = aliasChar(unit);
    };
    return short;
}
fn shortMatches(short: []const u8, name: []const u16) bool {
    var units: [12]u16 = undefined;
    var len: usize = 0;
    for (short[0..8]) |byte| {
        if (byte == ' ') break;
        units[len] = byte;
        len += 1;
    }
    if (short[8] != ' ') {
        units[len] = '.';
        len += 1;
        for (short[8..11]) |byte| {
            if (byte == ' ') break;
            units[len] = byte;
            len += 1;
        }
    }
    return equalName(units[0..len], name);
}
fn longCount(name: []const u16, short: [11]u8) u32 {
    if (shortMatches(&short, name)) {
        var upper = true;
        for (name) |unit| if (unit < 128 and std.ascii.isLower(@intCast(unit))) {
            upper = false;
            break;
        };
        if (upper) return 0;
    }
    return @intCast((name.len + 12) / 13);
}
