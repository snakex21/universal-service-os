//! Streaming NTFS 3.1 proof-of-concept formatter and single-writer file builder.
//!
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Format consulted: Linux-NTFS Documentation 0.6 and ntfs-3g commit
//! 7f0f841fc52cf719106c5c93bafe465004e36816 (mkntfs.c, layout.h, logfile.h,
//! sd.c; GPL-2.0-or-later, Anton Altaparmakov, Richard Russon, Szabolcs
//! Szakacsits, Erik Sornes, Yura Pakhuchiy, Jean-Pierre Andre and contributors).
//! The record construction, allocator, index builder and IO below are Zig;
//! no C library is linked and no Microsoft source is used or translated.
//!
//! Dynamic fragmented MFT, paged allocation bitmaps and incremental indexes;
//! 512-byte sectors/4096-byte clusters, offline single writer, no concurrent mount.
//! $Volume stays dirty while files/indexes are staged. finish() flushes the
//! final index and mirror, then clears it. This is not a journalled live FS.
const std = @import("std");
const p = @import("platform.zig");
const partitions = @import("partitions.zig");
const r = @import("record.zig");
const unicode = @import("unicode_upper.zig");
const runs = @import("runs.zig");
const bm = @import("bitmap.zig");
const index = @import("index.zig");
const meta_index = @import("secure_index.zig");
const ea = @import("ea.zig");
const mft_cache = @import("mft_cache.zig");
const index_cache = @import("index_cache.zig");
const Run = runs.Run;
const get = r.get;
const put = r.put;
const align8 = r.aligned;
const cluster: u64 = 4096;
const index_name = std.unicode.utf8ToUtf16LeStringLiteral("$I30");
const timestamp: u64 = 132537600000000000;
pub const Source = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) p.Error!void,
};
pub const FileTimes = struct { created: u64, modified: u64, changed: u64, accessed: u64 };
pub const FileOptions = struct {
    timestamp: u64 = timestamp,
    times: ?FileTimes = null,
    attributes: u32 = 0x20,
    security_id: ?u32 = null,
    security_descriptor: ?[]const u8 = null,
    max_run_clusters: u64 = 0,
    sparse: bool = false,
    compressed: bool = false,
};
pub const Stats = struct { mft_records: u64 = 0, mft_runs: usize = 0, allocated_clusters: u64 = 0, freed_clusters: u64 = 0, reused_clusters: u64 = 0, record_reuses: u64 = 0, reuse_accounting_dropped: u64 = 0, mft_record_reads: u64 = 0, mft_record_writes: u64 = 0, mft_mirror_writes: u64 = 0, prepared_inserts: u64 = 0, directory_switches: u64 = 0, index_reads: u64 = 0, index_writes: u64 = 0, index_bitmap_reads: u64 = 0, index_bitmap_writes: u64 = 0 };
pub const FileStats = struct { size: u64 = 0, run_count: usize = 0, attribute_list_records: usize = 0 };
pub fn validateShortName(name: []const u16) !void {
    if (name.len == 0 or name.len > 12) return error.InvalidShortName;
    var dot: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '.') {
            if (dot != null or i == 0 or i > 8 or i + 1 == name.len or name.len - i - 1 > 3) return error.InvalidShortName;
            dot = i;
        } else if (c <= 0x20 or (c >= 0xd800 and c <= 0xdfff) or
            std.mem.indexOfScalar(u16, &.{ '"', '*', '+', ',', '/', ':', ';', '<', '=', '>', '?', '[', '\\', ']', '|' }, c) != null) return error.InvalidShortName;
    }
    if (dot == null and name.len > 8) return error.InvalidShortName;
}
const Stream = struct {
    list: std.ArrayList(Run) = .empty,
    bytes: u64 = 0,
    flags: u16 = 0,
    fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }
    fn clusters(self: *const Stream) !u64 {
        return runs.totalClusters(self.list.items);
    }
};
const OwnedAttribute = struct { bytes: []u8, origin: u64 };
const Directory = struct { number: u64, root: u64 = 0, data: Stream = .{}, bits: Stream = .{}, index_hint: u64 = 0, allocation: ?bm.Bitmap = null };
const Entry = struct {
    reference: u64,
    len: u16,
    key: [576]u8,
};
const Extent = struct { lcn: u64 = 0, clusters: u64 = 0, bytes: u64 = 0 };

pub const Ntfs = struct {
    disk: p.Disk,
    partition: partitions.Partition,
    serial: u64,
    allocator: std.mem.Allocator,
    scratch: []u8,
    upcase: []u16,
    directory: ?Directory = null,
    mft_runs: std.ArrayList(Run) = .empty,
    record_cache: mft_cache.Cache,
    mft_cache_ready: bool = false,
    node_cache: index_cache.Cache,
    insert_hint: index.InsertHint = .{},
    volume_bits: ?bm.Bitmap = null,
    record_bits: ?bm.Bitmap = null,
    counters: Stats = .{},
    freed_ranges: std.ArrayList(bm.Span) = .empty,
    formatted: bool = false,
    completed: bool = false,
    failed: bool = false,
    total_clusters: u64,
    bitmap: Stream = .{},
    mft_bitmap: Stream = .{},
    logfile: Extent = .{},
    attrdef: Extent = .{},
    upcase_extent: Extent = .{},
    secure: Extent = .{},
    secure_stream: Stream = .{},
    security_entries: std.ArrayList(meta_index.SecurityEntry) = .empty,
    security_cursor: u64 = 0,
    security_changed: bool = false,
    reparse_entries: std.ArrayList(meta_index.ReparseEntry) = .empty,
    object_entries: std.ArrayList(meta_index.ObjectIdEntry) = .empty,
    next_lcn: u64 = 4096,
    mft_records: u64 = 64,
    next_record: u64 = 27,

    pub fn init(disk: p.Disk, partition: partitions.Partition, allocator: std.mem.Allocator, serial: u64) !Ntfs {
        var result: Ntfs = undefined;
        try initInto(disk, partition, allocator, serial, &result);
        return result;
    }
    /// A comptime error with an 8 KiB payload otherwise materializes a full
    /// zero-filled Ntfs constant per error in the freestanding IA32 image.
    pub fn initInto(disk: p.Disk, partition: partitions.Partition, allocator: std.mem.Allocator, serial: u64, out: *Ntfs) !void {
        if (serial == 0) return error.InvalidArgument;
        if (disk.sector_bytes != 512 or partition.start_bytes % 512 != 0 or partition.size_bytes % 512 != 0) return error.Unsupported;
        if (partition.size_bytes < 64 * 1024 * 1024) return error.NoSpace;
        const end = std.math.add(u64, partition.start_bytes, partition.size_bytes) catch return error.Bounds;
        if (end > try disk.bytes()) return error.Bounds;
        const scratch = try allocator.alloc(u8, 256 * 1024);
        errdefer allocator.free(scratch);
        const upcase = try allocator.alloc(u16, 65536);
        errdefer allocator.free(upcase);
        unicode.build(upcase);
        const record_cache = try mft_cache.Cache.init(allocator);
        errdefer {
            var cache = record_cache;
            cache.deinit(allocator);
        }
        const node_cache = try index_cache.Cache.init(allocator, out.rawIndexBackend());
        errdefer {
            var cache = node_cache;
            cache.deinit();
        }
        out.* = .{ .disk = disk, .partition = partition, .serial = serial, .allocator = allocator, .scratch = scratch, .upcase = upcase, .record_cache = record_cache, .node_cache = node_cache, .total_clusters = (partition.size_bytes / 512 - 1) / 8 };
    }
    pub fn deinit(self: *Ntfs) void {
        if (self.directory) |*directory| {
            directory.data.deinit(self.allocator);
            directory.bits.deinit(self.allocator);
        }
        self.bitmap.deinit(self.allocator);
        self.mft_bitmap.deinit(self.allocator);
        self.mft_runs.deinit(self.allocator);
        self.record_cache.deinit(self.allocator);
        self.node_cache.deinit();
        self.freed_ranges.deinit(self.allocator);
        self.secure_stream.deinit(self.allocator);
        self.security_entries.deinit(self.allocator);
        self.reparse_entries.deinit(self.allocator);
        self.object_entries.deinit(self.allocator);
        self.allocator.free(self.upcase);
        self.allocator.free(self.scratch);
    }
    fn write(self: *Ntfs, offset: u64, data: []const u8) p.Error!void {
        const end = std.math.add(u64, offset, data.len) catch return error.Bounds;
        if (end > self.partition.size_bytes) return error.Bounds;
        try self.disk.write(self.partition.start_bytes + offset, data);
    }
    fn read(self: *Ntfs, offset: u64, data: []u8) p.Error!void {
        const end = std.math.add(u64, offset, data.len) catch return error.Bounds;
        if (end > self.partition.size_bytes) return error.Bounds;
        try self.disk.read(self.partition.start_bytes + offset, data);
    }
    fn fill(self: *Ntfs, offset: u64, size: u64, byte: u8) !void {
        @memset(self.scratch, byte);
        var done: u64 = 0;
        while (done < size) {
            const n: usize = @intCast(@min(size - done, self.scratch.len));
            try self.write(offset + done, self.scratch[0..n]);
            done += n;
        }
    }
    fn take(self: *Ntfs, bytes: u64) !Extent {
        const clusters = (bytes + cluster - 1) / cluster;
        if (clusters > self.total_clusters -| self.next_lcn) return error.NoSpace;
        const result: Extent = .{ .lcn = self.next_lcn, .clusters = clusters, .bytes = bytes };
        self.next_lcn += clusters;
        return result;
    }
    fn allocate(self: *Ntfs, bytes: u64) !Extent {
        return self.allocateContiguous(bytes);
    }
    fn streamExtent(self: *Ntfs, extent: Extent) !Stream {
        var stream: Stream = .{ .bytes = extent.bytes };
        try stream.list.append(self.allocator, .{ .lcn = extent.lcn, .clusters = extent.clusters });
        return stream;
    }
    fn clearStream(self: *Ntfs, stream: *const Stream) !void {
        for (stream.list.items) |run| {
            const lcn = run.lcn orelse return error.Corrupt;
            try self.fill(lcn * cluster, run.clusters * cluster, 0);
        }
    }
    fn volumeBitmapRead(ctx: *anyopaque, offset: u64, out: *[4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        try self.readRuns(self.bitmap.list.items, offset, out);
    }
    fn volumeBitmapWrite(ctx: *anyopaque, offset: u64, data: *const [4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        try self.writeRuns(self.bitmap.list.items, offset, data);
    }
    fn recordBitmapRead(ctx: *anyopaque, offset: u64, out: *[4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        try self.readRuns(self.mft_bitmap.list.items, offset, out);
    }
    fn recordBitmapWrite(ctx: *anyopaque, offset: u64, data: *const [4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        try self.writeRuns(self.mft_bitmap.list.items, offset, data);
    }
    fn accountAllocation(self: *Ntfs, start: u64, count: u64) void {
        self.counters.allocated_clusters += count;
        const stop = start + count;
        var i: usize = 0;
        while (i < self.freed_ranges.items.len) {
            const range = self.freed_ranges.items[i];
            const lo = @max(start, range.start);
            const hi = @min(stop, range.start + range.count);
            if (lo >= hi) {
                i += 1;
                continue;
            }
            self.counters.reused_clusters += hi - lo;
            if (lo == range.start and hi == range.start + range.count) {
                _ = self.freed_ranges.swapRemove(i);
                continue;
            }
            if (lo == range.start) {
                self.freed_ranges.items[i] = .{ .start = hi, .count = range.start + range.count - hi };
            } else if (hi == range.start + range.count) {
                self.freed_ranges.items[i].count = lo - range.start;
            } else {
                // Split ranges only when memory can represent both; dropping
                // the right accounting tail under OOM undercounts reuse,
                // never changes the allocation bitmap or invents evidence.
                self.freed_ranges.items[i].count = lo - range.start;
                if (self.freed_ranges.items.len < 4096) self.freed_ranges.append(self.allocator, .{ .start = hi, .count = range.start + range.count - hi }) catch {
                    self.counters.reuse_accounting_dropped += range.start + range.count - hi;
                } else self.counters.reuse_accounting_dropped += range.start + range.count - hi;
            }
            i += 1;
        }
    }
    fn release(self: *Ntfs, start: u64, count: u64) !void {
        if (count == 0) return;
        try self.markClusters(start, count, false);
        self.counters.freed_clusters += count;
        // Accounting must never fail after the real bitmap was changed. Merge
        // adjacent spans, cap metadata RAM, and expose any omitted lower-bound
        // reuse evidence instead of retaining a per-deleted-file history.
        var first = start;
        var last = start + count;
        var i: usize = 0;
        while (i < self.freed_ranges.items.len) {
            const span = self.freed_ranges.items[i];
            if (span.start > last or span.start + span.count < first) {
                i += 1;
                continue;
            }
            first = @min(first, span.start);
            last = @max(last, span.start + span.count);
            _ = self.freed_ranges.swapRemove(i);
        }
        if (self.freed_ranges.items.len >= 4096) {
            self.counters.reuse_accounting_dropped += last - first;
            return;
        }
        self.freed_ranges.append(self.allocator, .{ .start = first, .count = last - first }) catch {
            self.counters.reuse_accounting_dropped += last - first;
        };
    }
    fn allocateContiguous(self: *Ntfs, bytes: u64) !Extent {
        const count = std.math.divCeil(u64, bytes, cluster) catch return error.Bounds;
        if (count == 0) return .{};
        const bits = &self.volume_bits.?;
        const original_hint = bits.hint;
        var start = @min(bits.hint, self.total_clusters);
        var wrapped = false;
        while (true) {
            const limit = if (wrapped) original_hint else self.total_clusters;
            while (start < limit and try bits.get(start)) : (start += 1) {}
            var end = start;
            while (end < limit and end - start < count and !(try bits.get(end))) : (end += 1) {}
            if (end - start == count) {
                try bits.set(start, count, true);
                bits.hint = end;
                self.accountAllocation(start, count);
                return .{ .lcn = start, .clusters = count, .bytes = bytes };
            }
            if (end >= limit) {
                if (wrapped or original_hint == 0) return error.NoSpace;
                wrapped = true;
                start = 0;
            } else start = end + 1;
        }
    }
    fn allocateRuns(self: *Ntfs, bytes: u64, maximum: u64) !Stream {
        var result: Stream = .{ .bytes = bytes };
        errdefer {
            for (result.list.items) |run| self.release(run.lcn.?, run.clusters) catch {
                self.failed = true;
            };
            result.deinit(self.allocator);
        }
        var left = std.math.divCeil(u64, bytes, cluster) catch return error.Bounds;
        while (left != 0) {
            const span = try self.volume_bits.?.allocate(if (maximum == 0) left else @min(left, maximum));
            self.accountAllocation(span.start, span.count);
            appendRun(&result.list, self.allocator, .{ .lcn = span.start, .clusters = span.count }) catch |err| {
                self.release(span.start, span.count) catch {
                    self.failed = true;
                };
                return err;
            };
            left -= span.count;
        }
        return result;
    }
    fn readRuns(self: *Ntfs, list: []const Run, offset: u64, out: []u8) !void {
        var done: usize = 0;
        while (done < out.len) {
            const current = std.math.add(u64, offset, done) catch return error.Bounds;
            const loc = try runs.locate(list, current / cluster);
            const intra = current % cluster;
            const n: usize = @intCast(@min(out.len - done, loc.available * cluster - intra));
            if (loc.lcn) |lcn| try self.read(lcn * cluster + intra, out[done..][0..n]) else @memset(out[done..][0..n], 0);
            done += n;
        }
    }
    fn writeRuns(self: *Ntfs, list: []const Run, offset: u64, data: []const u8) !void {
        var done: usize = 0;
        while (done < data.len) {
            const current = std.math.add(u64, offset, done) catch return error.Bounds;
            const loc = try runs.locate(list, current / cluster);
            const intra = current % cluster;
            const n: usize = @intCast(@min(data.len - done, loc.available * cluster - intra));
            const lcn = loc.lcn orelse return error.InvalidArgument;
            try self.write(lcn * cluster + intra, data[done..][0..n]);
            done += n;
        }
    }
    fn decodeAttribute(self: *Ntfs, attr: []const u8, stream: *Stream) !void {
        if (attr.len < 64 or attr[8] != 1) return error.Corrupt;
        if (get(u64, attr, 16) != (try stream.clusters())) return error.Corrupt;
        const pairs = get(u16, attr, 32);
        if (pairs >= attr.len) return error.Corrupt;
        var decoder: runs.Decoder = .{ .bytes = attr[pairs..] };
        while (try decoder.next()) |run| try appendRun(&stream.list, self.allocator, run);
        if (get(u64, attr, 16) == 0) {
            stream.bytes = get(u64, attr, 48);
            stream.flags = get(u16, attr, 12);
        }
        if (decoder.vcn != 0 and get(u64, attr, 24) != get(u64, attr, 16) + decoder.vcn - 1) return error.Corrupt;
    }
    fn freeAttributes(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute)) void {
        for (attrs.items) |attr| self.allocator.free(attr.bytes);
        attrs.deinit(self.allocator);
    }
    fn collectAttributes(self: *Ntfs, number: u64) !std.ArrayList(OwnedAttribute) {
        var attrs: std.ArrayList(OwnedAttribute) = .empty;
        errdefer self.freeAttributes(&attrs);
        var bootstrap: Stream = if (number == 0) try self.bootstrapMft() else .{};
        defer bootstrap.deinit(self.allocator);
        var base: [1024]u8 = undefined;
        if (number == 0) try self.readMappedRecord(bootstrap.list.items, number, &base) else try self.readRecord(number, &base);
        if (try r.find(&base, 0x20, &.{})) |list_attr| {
            const storage = try self.readAttributeList(list_attr.bytes);
            defer self.allocator.free(storage);
            var cursor: usize = 0;
            while (cursor < storage.len) {
                if (cursor + 26 > storage.len) return error.Corrupt;
                const length = get(u16, storage, cursor + 4);
                if (length < 26 or cursor + length > storage.len) return error.Corrupt;
                const ref = get(u64, storage, cursor + 16);
                const record = ref & 0xffffffffffff;
                var data: [1024]u8 = undefined;
                if (number == 0) try self.readMappedRecord(bootstrap.list.items, record, &data) else try self.readRecord(record, &data);
                if (get(u16, &data, 16) != ref >> 48) return error.Corrupt;
                const id = get(u16, storage, cursor + 24);
                var pos: usize = get(u16, &data, 20);
                var found = false;
                while (pos + 8 <= data.len) {
                    const kind = get(u32, &data, pos);
                    if (kind == 0xffffffff) break;
                    const n = get(u32, &data, pos + 4);
                    if (n < 24 or pos + n > data.len) return error.Corrupt;
                    const continuation = get(u64, storage, cursor + 8);
                    const matching = if (continuation == 0) get(u16, &data, pos + 14) == id else kind == get(u32, storage, cursor) and data[pos + 8] == 1 and get(u64, &data, pos + 16) == continuation;
                    const name_len: usize = storage[cursor + 6];
                    const list_name: usize = cursor + storage[cursor + 7];
                    const attr_name: usize = pos + get(u16, &data, pos + 10);
                    if (list_name + name_len * 2 > cursor + length or attr_name + @as(usize, data[pos + 9]) * 2 > pos + n) return error.Corrupt;
                    const name_matches = data[pos + 9] == name_len and std.mem.eql(u8, storage[list_name..][0 .. name_len * 2], data[attr_name..][0 .. name_len * 2]);
                    if (matching and name_matches) {
                        if (kind != get(u32, storage, cursor)) return error.Corrupt;
                        try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, data[pos..][0..n]), .origin = record });
                        found = true;
                        break;
                    }
                    pos += n;
                }
                if (!found) return error.Corrupt;
                cursor += length;
            }
        } else {
            var pos: usize = get(u16, &base, 20);
            while (pos + 8 <= base.len) {
                const kind = get(u32, &base, pos);
                if (kind == 0xffffffff) break;
                const n = get(u32, &base, pos + 4);
                if (n < 24 or pos + n > base.len) return error.Corrupt;
                try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, base[pos..][0..n]), .origin = number });
                pos += n;
            }
        }
        return attrs;
    }
    fn readAttributeList(self: *Ntfs, attr: []u8) ![]u8 {
        if (attr[8] == 0) return self.allocator.dupe(u8, try r.value(attr));
        var stream: Stream = .{};
        defer stream.deinit(self.allocator);
        try self.decodeAttribute(attr, &stream);
        if (stream.bytes > 256 * 1024) return error.Unsupported;
        const storage = try self.allocator.alloc(u8, @intCast(stream.bytes));
        errdefer self.allocator.free(storage);
        try self.readRuns(stream.list.items, 0, storage);
        return storage;
    }
    fn readMappedRecord(self: *Ntfs, map: []const Run, number: u64, out: *[1024]u8) !void {
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        try self.readRuns(map, std.math.mul(u64, number, 1024) catch return error.Bounds, out);
        if (!std.mem.eql(u8, out[0..4], "FILE")) return error.Corrupt;
        try r.unprotect(out);
        if (get(u32, out, 44) != number) return error.Corrupt;
    }
    fn bootstrapMft(self: *Ntfs) !Stream {
        // The boot sector names LCN4. No cached full MFT map is consulted:
        // each continuation record must be readable through earlier extents.
        var base: [1024]u8 = undefined;
        try self.readMappedRecord(&.{.{ .lcn = 4, .clusters = 1 }}, 0, &base);
        const first = (try r.find(&base, 0x80, &.{})) orelse return error.Corrupt;
        var result: Stream = .{};
        errdefer result.deinit(self.allocator);
        try self.decodeAttribute(first.bytes, &result);
        if (try r.find(&base, 0x20, &.{})) |list_attr| {
            const storage = try self.readAttributeList(list_attr.bytes);
            defer self.allocator.free(storage);
            var cursor: usize = 0;
            while (cursor < storage.len) {
                if (storage.len - cursor < 26) return error.Corrupt;
                const length = get(u16, storage, cursor + 4);
                if (length < 26 or length > storage.len - cursor) return error.Corrupt;
                const lowest = get(u64, storage, cursor + 8);
                if (get(u32, storage, cursor) == 0x80 and storage[cursor + 6] == 0 and lowest != 0) {
                    const ref = get(u64, storage, cursor + 16);
                    const number = ref & 0xffffffffffff;
                    var record: [1024]u8 = undefined;
                    // Bounds from readRuns are deliberate: reading this record
                    // with self.mft_runs would silently mask a circular map.
                    try self.readMappedRecord(result.list.items, number, &record);
                    if (get(u16, &record, 16) != ref >> 48 or get(u64, &record, 32) != (@as(u64, get(u16, &base, 16)) << 48)) return error.Corrupt;
                    const attr = (try r.find(&record, 0x80, &.{})) orelse return error.Corrupt;
                    if (attr.bytes[8] != 1 or get(u64, attr.bytes, 16) != lowest) return error.Corrupt;
                    try self.decodeAttribute(attr.bytes, &result);
                }
                cursor += length;
            }
        }
        if ((try result.clusters()) * cluster < result.bytes) return error.Corrupt;
        return result;
    }
    pub fn validateMftBootstrap(self: *Ntfs) !void {
        var map = try self.bootstrapMft();
        defer map.deinit(self.allocator);
        if (map.bytes != self.mft_records * 1024) return error.Corrupt;
        if (map.list.items.len != self.mft_runs.items.len) return error.Corrupt;
        for (map.list.items, self.mft_runs.items) |left, right| if (!std.meta.eql(left, right)) return error.Corrupt;
    }
    fn loadStream(self: *Ntfs, number: u64, kind: u32, name: []const u16) !Stream {
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var stream: Stream = .{};
        errdefer stream.deinit(self.allocator);
        var found = false;
        for (attrs.items) |attr| if (attrMatches(attr.bytes, kind, name)) {
            if (attr.bytes[8] != 1) return error.InvalidArgument;
            try self.decodeAttribute(attr.bytes, &stream);
            found = true;
        };
        if (!found) return error.Corrupt;
        return stream;
    }
    fn addRunAttributes(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16, stream: *const Stream) !void {
        return self.addRunAttributesLimited(attrs, kind, name, stream, 384);
    }
    fn addRunAttributesLimited(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16, stream: *const Stream, first_limit: usize) !void {
        var first: usize = 0;
        var vcn: u64 = 0;
        while (first < stream.list.items.len or (first == 0 and stream.list.items.len == 0)) {
            var stop = first;
            const limit = if (first == 0) first_limit else 384;
            while (stop < stream.list.items.len and (try runs.encodedSize(stream.list.items[first .. stop + 1])) <= limit) : (stop += 1) {}
            if (stop == first and stream.list.items.len != 0) return error.Corrupt;
            var b = r.Builder.init(0, 1, 1, 0);
            try b.nonresidentRunsFlags(kind, name, stream.list.items[first..stop], vcn, if (vcn == 0) (try stream.clusters()) * cluster else 0, if (vcn == 0) stream.bytes else 0, if (vcn == 0) stream.bytes else 0, stream.flags, if (vcn == 0) physicalClusters(stream.list.items) * cluster else 0);
            const attr = (try r.find(&b.b, kind, name)).?;
            try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, attr.bytes), .origin = std.math.maxInt(u64) });
            vcn += try runs.totalClusters(stream.list.items[first..stop]);
            first = stop;
            if (stream.list.items.len == 0) break;
        }
    }
    fn replaceStreamAttrs(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16, stream: *const Stream) !void {
        return self.replaceStreamAttrsLimited(attrs, kind, name, stream, 384);
    }
    fn replaceStreamAttrsLimited(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16, stream: *const Stream, first_limit: usize) !void {
        var i: usize = 0;
        while (i < attrs.items.len) {
            if (attrMatches(attrs.items[i].bytes, kind, name)) {
                self.allocator.free(attrs.items[i].bytes);
                _ = attrs.orderedRemove(i);
            } else i += 1;
        }
        try self.addRunAttributesLimited(attrs, kind, name, stream, first_limit);
    }
    fn writeAttributes(self: *Ntfs, number: u64, attrs: *std.ArrayList(OwnedAttribute)) anyerror!void {
        var old: [1024]u8 = undefined;
        try self.readRecord(number, &old);
        return self.writeAttributesFromRecord(number, attrs, &old);
    }
    fn writeAttributesFromRecord(self: *Ntfs, number: u64, attrs: *std.ArrayList(OwnedAttribute), old: *[1024]u8) anyerror!void {
        // Metadata publication is not journalled in this offline formatter.
        // Once this path fails, finish must never clear the dirty flag.
        errdefer self.failed = true;
        var previous_extensions: std.ArrayList(u64) = .empty;
        defer previous_extensions.deinit(self.allocator);
        var old_list: Stream = .{};
        defer old_list.deinit(self.allocator);
        if (try r.find(old, 0x20, &.{})) |list_attr| {
            var old_attrs = try self.collectAttributes(number);
            defer self.freeAttributes(&old_attrs);
            for (old_attrs.items) |attr| {
                if (attr.origin == number or std.mem.indexOfScalar(u64, previous_extensions.items, attr.origin) != null) continue;
                try previous_extensions.append(self.allocator, attr.origin);
            }
            if (list_attr.bytes[8] == 1) try self.decodeAttribute(list_attr.bytes, &old_list);
        }
        std.mem.sort(OwnedAttribute, attrs.items, @as([]const u16, self.upcase), attributeLess);
        var plain = r.Builder.init(number, get(u16, old, 16), get(u16, old, 22), get(u16, old, 18));
        var fits = true;
        for (attrs.items) |attr| {
            // Public NTFS layout: lowest_vcn!=0 requires ATTRIBUTE_LIST,
            // with one continuation extent in each referenced FILE record.
            if (attr.bytes[8] == 1 and get(u64, attr.bytes, 16) != 0) {
                fits = false;
                break;
            }
            _ = plain.copyRaw(attr.bytes) catch {
                fits = false;
                break;
            };
        }
        if (fits) {
            try self.writeRecord(number, &plain.b);
        } else {
            var list_bytes: usize = 0;
            for (attrs.items) |attr| list_bytes = std.math.add(usize, list_bytes, align8(26 + @as(usize, attr.bytes[9]) * 2)) catch return error.Bounds;
            if (list_bytes > 256 * 1024) return error.NoSpace; // NTFS cache-manager format limit.
            var list_stream = try self.allocateRuns(list_bytes, 0);
            defer list_stream.deinit(self.allocator);
            var list_builder = r.Builder.init(0, 1, 1, 0);
            try list_builder.nonresidentRuns(0x20, &.{}, list_stream.list.items, 0, (try list_stream.clusters()) * cluster, list_bytes, list_bytes);
            const list_attr = (try r.find(&list_builder.b, 0x20, &.{})).?;
            const list_data = try self.allocator.alloc(u8, list_bytes);
            defer self.allocator.free(list_data);
            @memset(list_data, 0);
            const Staged = struct { number: u64, b: r.Builder };
            var staged: std.ArrayList(Staged) = .empty;
            defer staged.deinit(self.allocator);
            var b = r.Builder.init(number, get(u16, old, 16), get(u16, old, 22), get(u16, old, 18));
            var cursor: usize = 0;
            var list_inserted = false;
            var extension_count: usize = 0;
            // The first DATA extent of $MFT must remain in its base record.
            // Its reserved bootstrap records16..23 are in that first extent.
            var pinned_bytes: usize = 0;
            if (number == 0) for (attrs.items) |attr| {
                if (attrMatches(attr.bytes, 0x80, &.{}) and attr.bytes[8] == 1 and get(u64, attr.bytes, 16) == 0) pinned_bytes += attr.bytes.len;
            };
            for (attrs.items) |attr| {
                const kind = get(u32, attr.bytes, 0);
                if (!list_inserted and kind > 0x20) {
                    _ = try b.copyRaw(list_attr.bytes);
                    list_inserted = true;
                }
                const continuation = attr.bytes[8] == 1 and get(u64, attr.bytes, 16) != 0;
                const pinned = number == 0 and attrMatches(attr.bytes, 0x80, &.{}) and attr.bytes[8] == 1 and get(u64, attr.bytes, 16) == 0;
                if (pinned) pinned_bytes -= attr.bytes.len;
                var record_number = number;
                var record_sequence = get(u16, old, 16);
                const id = blk: {
                    const reserve = pinned_bytes + (if (!list_inserted) list_attr.bytes.len else 0);
                    if (!continuation and b.pos + attr.bytes.len + reserve + 8 <= b.b.len) break :blk try b.copyRaw(attr.bytes);
                    if (pinned) return error.NoSpace;
                    record_number = if (extension_count < previous_extensions.items.len) previous_extensions.items[extension_count] else try self.allocateExtensionRecord(number);
                    extension_count += 1;
                    var blank: [1024]u8 = undefined;
                    try self.readRecord(record_number, &blank);
                    record_sequence = get(u16, &blank, 16);
                    var extension = r.Builder.init(record_number, record_sequence, 1, 0);
                    put(u64, &extension.b, 32, number | (@as(u64, get(u16, old, 16)) << 48));
                    const copied = try extension.copyRaw(attr.bytes);
                    try staged.append(self.allocator, .{ .number = record_number, .b = extension });
                    break :blk copied;
                };
                const length = align8(26 + @as(usize, attr.bytes[9]) * 2);
                const entry = list_data[cursor..][0..length];
                put(u32, entry, 0, kind);
                put(u16, entry, 4, @intCast(length));
                entry[6] = attr.bytes[9];
                entry[7] = 26;
                put(u64, entry, 8, if (attr.bytes[8] == 1) get(u64, attr.bytes, 16) else 0);
                put(u64, entry, 16, record_number | (@as(u64, record_sequence) << 48));
                put(u16, entry, 24, if (continuation) 0 else id);
                if (entry[6] != 0) {
                    const name_offset = get(u16, attr.bytes, 10);
                    @memcpy(entry[26..][0 .. @as(usize, entry[6]) * 2], attr.bytes[name_offset..][0 .. @as(usize, entry[6]) * 2]);
                }
                cursor += length;
            }
            if (!list_inserted) return error.Corrupt;
            try staged.append(self.allocator, .{ .number = number, .b = b });
            try self.clearStream(&list_stream);
            try self.writeRuns(list_stream.list.items, 0, list_data);
            // Extension records and their stream precede publishing the new
            // base record; an interrupted build retains the dirty flag.
            for (staged.items) |*item| if (item.number != number) try self.writeRecord(item.number, &item.b.b);
            for (staged.items) |*item| if (item.number != number) try self.flushMftRecord(item.number);
            for (staged.items) |*item| if (item.number == number) try self.writeRecord(item.number, &item.b.b);
            // Do not free storage still referenced by the durable old base.
            if (previous_extensions.items.len != 0 or old_list.list.items.len != 0) try self.flushMftRecord(number);
            // Reused extension records are still part of the new list.
            if (extension_count < previous_extensions.items.len) {
                for (previous_extensions.items[extension_count..]) |extension| try self.releaseRecord(extension);
            }
            previous_extensions.clearRetainingCapacity();
        }
        if (previous_extensions.items.len != 0 or old_list.list.items.len != 0) try self.flushMftRecord(number);
        for (previous_extensions.items) |extension| try self.releaseRecord(extension);
        for (old_list.list.items) |run| if (run.lcn) |lcn| try self.release(lcn, run.clusters);
    }
    fn allocateRecord(self: *Ntfs) anyerror!u64 {
        const number = blk: {
            const span = self.record_bits.?.allocate(1) catch |err| switch (err) {
                error.NoSpace => {
                    try self.ensureMft(self.mft_records);
                    break :blk (try self.record_bits.?.allocate(1)).start;
                },
                else => return err,
            };
            break :blk span.start;
        };
        var old: [1024]u8 = undefined;
        try self.readAllocatedRecord(number, &old);
        if (get(u16, &old, 22) & 1 != 0) return error.Corrupt;
        if (get(u16, &old, 16) > 1) self.counters.record_reuses += 1;
        self.next_record = @max(self.next_record, number + 1);
        return number;
    }
    fn allocateExtensionRecord(self: *Ntfs, owner: u64) !u64 {
        if (owner != 0) return self.allocateRecord();
        // Public Linux-NTFS files/index.html: reserved MFT slots break the
        // circular dependency between its DATA mapping and extension record.
        // This offline implementation uses16..23 (eight records), never an
        // unbootstrappable record at the new end of $MFT. Exhaustion is explicit.
        for (16..24) |number| {
            if (try self.record_bits.?.get(number)) continue;
            try self.record_bits.?.set(number, 1, true);
            return number;
        }
        return error.NoSpace;
    }
    fn releaseRecord(self: *Ntfs, number: u64) !void {
        if (number < 27 and (number < 16 or number > 23)) return error.InvalidArgument;
        var old: [1024]u8 = undefined;
        try self.readRecord(number, &old);
        var seq = get(u16, &old, 16) +% 1;
        if (seq == 0) seq = 1;
        var empty = r.Builder.init(number, seq, 0, 0);
        try self.writeRecord(number, &empty.b);
        try self.record_bits.?.set(number, 1, false);
        // Record slots are cheap exact reuse, unlike a whole volume-prefix
        // scan. The cached empty record already carries its new sequence.
        self.record_bits.?.hint = @min(self.record_bits.?.hint, number);
    }
    fn actualReference(self: *Ntfs, number: u64) !u64 {
        var data: [1024]u8 = undefined;
        try self.readRecord(number, &data);
        return number | (@as(u64, get(u16, &data, 16)) << 48);
    }
    fn bitmapSet(self: *Ntfs, extent: *const Stream, bit_start: u64, bit_count: u64, value: bool) !void {
        var cursor = bit_start;
        const end = std.math.add(u64, bit_start, bit_count) catch return error.Bounds;
        if (end > (try extent.clusters()) * cluster * 8) return error.Bounds;
        var page: [4096]u8 = undefined;
        while (cursor < end) {
            const page_bit = (cursor / (4096 * 8)) * (4096 * 8);
            try self.readRuns(extent.list.items, page_bit / 8, &page);
            const stop = @min(end, page_bit + 4096 * 8);
            while (cursor < stop) : (cursor += 1) {
                const rel: usize = @intCast(cursor - page_bit);
                const mask: u8 = @as(u8, 1) << @intCast(rel % 8);
                if (value) page[rel / 8] |= mask else page[rel / 8] &= ~mask;
            }
            try self.writeRuns(extent.list.items, page_bit / 8, &page);
        }
    }
    fn markClusters(self: *Ntfs, start: u64, count: u64, used: bool) !void {
        if (start > self.total_clusters or count > self.total_clusters - start) return error.Bounds;
        if (count == 0) return;
        if (self.volume_bits) |*bits| try bits.set(start, count, used) else try self.bitmapSet(&self.bitmap, start, count, used);
    }
    fn recordBackend(self: *Ntfs) mft_cache.Backend {
        return .{ .context = self, .read = cacheReadRecord, .write = cacheWriteRecord };
    }
    fn cacheReadRecord(ctx: *anyopaque, number: u64, out: *[1024]u8) anyerror!void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        return self.readRecordPhysical(number, out);
    }
    fn cacheWriteRecord(ctx: *anyopaque, number: u64, data: *[1024]u8) anyerror!void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        return self.writeRecordPhysical(number, data);
    }
    fn readRecordPhysical(self: *Ntfs, number: u64, out: *[1024]u8) !void {
        if (number >= self.mft_records) return error.Bounds;
        self.counters.mft_record_reads +|= 1;
        try self.readRuns(self.mft_runs.items, number * 1024, out);
        if (!std.mem.eql(u8, out[0..4], "FILE")) return error.Corrupt;
        try r.unprotect(out);
        if (get(u32, out, 44) != number) return error.Corrupt;
    }
    fn writeRecordPhysical(self: *Ntfs, number: u64, data: *[1024]u8) !void {
        // A failed disk write never leaves the caller/cache MST-protected.
        var protected = data.*;
        try r.protect(&protected);
        self.counters.mft_record_writes +|= 1;
        try self.writeRuns(self.mft_runs.items, number * 1024, &protected);
        if (number < 4) {
            self.counters.mft_mirror_writes +|= 1;
            try self.write(2 * cluster + number * 1024, &protected);
        }
        try r.unprotect(&protected);
        data.* = protected;
    }
    fn readAllocatedRecord(self: *Ntfs, number: u64, out: *[1024]u8) !void {
        if (!self.mft_cache_ready or number < 27) return self.readRecord(number, out);
        if (number >= self.mft_records) return error.Bounds;
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        self.record_cache.readForMutation(self.recordBackend(), number, out) catch |err| {
            self.failed = true;
            return err;
        };
    }
    fn readRecord(self: *Ntfs, number: u64, out: *[1024]u8) !void {
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        if (number >= self.mft_records) return error.Bounds;
        if (!self.mft_cache_ready or number < 27) return self.readRecordPhysical(number, out);
        self.record_cache.read(self.recordBackend(), number, out) catch |err| {
            self.failed = true;
            return err;
        };
    }
    fn writeRecord(self: *Ntfs, number: u64, data: *[1024]u8) !void {
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        errdefer self.failed = true;
        if (!self.mft_cache_ready or number < 27) return self.writeRecordPhysical(number, data);
        try self.record_cache.store(self.recordBackend(), number, data);
    }
    fn flushMftRecord(self: *Ntfs, number: u64) !void {
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        errdefer self.failed = true;
        try self.record_cache.flushRecord(self.recordBackend(), number);
    }
    /// Explicit metadata barrier; never called by deinit. A failure poisons the
    /// builder, so a later finish cannot accidentally publish a clean volume.
    pub fn flushMftRecords(self: *Ntfs) !void {
        const timing = p.measure(self.disk.profiler, .mft);
        defer p.measured(self.disk.profiler, timing);
        if (self.failed) return error.PoisonedVolume;
        errdefer self.failed = true;
        try self.record_cache.flush(self.recordBackend());
    }
    pub fn mftCacheStatistics(self: *const Ntfs) mft_cache.Statistics {
        return self.record_cache.statistics;
    }
    fn extentAttr(self: *Ntfs, b: *r.Builder, kind: u32, name: []const u16, extent: Extent) !void {
        _ = self;
        try b.nonresident(kind, name, extent.lcn, extent.clusters, extent.bytes, extent.bytes);
    }
    fn standard(b: *r.Builder, attrs: u32, time: u64, security_id: u32) !void {
        var data: [72]u8 = @splat(0);
        for (0..4) |i| put(u64, &data, i * 8, time);
        put(u32, &data, 32, attrs);
        put(u32, &data, 52, security_id);
        try b.resident(0x10, &.{}, &data, false);
    }
    fn filename(parent: u64, name: []const u16, allocation: u64, bytes: u64, flags: u32, time: u64, out: []u8) !usize {
        try validateName(name, std.mem.eql(u16, name, std.unicode.utf8ToUtf16LeStringLiteral(".")));
        const length = 66 + name.len * 2;
        @memset(out[0..length], 0);
        put(u64, out, 0, reference(parent));
        for (0..4) |i| put(u64, out, 8 + i * 8, time);
        put(u64, out, 40, allocation);
        put(u64, out, 48, bytes);
        put(u32, out, 56, flags);
        out[64] = @intCast(name.len);
        out[65] = 0; // POSIX namespace; no claim that an 8.3 alias exists.
        r.utf16(out[66..], name);
        return length;
    }
    fn baseRecord(number: u64, parent: u64, name: []const u16, record_flags: u16, file_flags: u32, allocated: u64, bytes: u64, opts: FileOptions) !r.Builder {
        var b = r.Builder.init(number, sequence(number), record_flags, if (name.len != 0) 1 else 0);
        try standard(&b, file_flags & ~@as(u32, 0x10000010), opts.timestamp, opts.security_id orelse if (opts.security_descriptor == null) @as(u32, 256) else 0);
        if (opts.times) |times| writeTimes(try r.value((try r.find(&b.b, 0x10, &.{})).?.bytes), 0, times);
        if (name.len != 0) {
            var key: [576]u8 = undefined;
            const n = try filename(parent, name, allocated, bytes, file_flags, opts.timestamp, &key);
            if (opts.times) |times| writeTimes(key[0..n], 8, times);
            // Reserved metadata names already have their canonical DOS name;
            // use the combined namespace without manufacturing short aliases.
            if (number < 27) key[65] = 3;
            try b.resident(0x30, &.{}, key[0..n], true);
        }
        if (opts.security_descriptor) |sd| {
            try validateDescriptor(sd);
            try b.resident(0x50, &.{}, sd, false);
        }
        return b;
    }

    pub fn format(self: *Ntfs) !void {
        if (self.formatted) return error.InvalidArgument;
        try self.mft_runs.append(self.allocator, .{ .lcn = 4, .clusters = self.mft_records / 4 });
        const initial_bitmap = try self.take(((self.total_clusters + 63) / 64) * 8);
        const initial_mft_bitmap = try self.take(4096);
        self.bitmap = try self.streamExtent(initial_bitmap);
        self.mft_bitmap = try self.streamExtent(initial_mft_bitmap);
        self.logfile = try self.take(4 * 1024 * 1024);
        self.attrdef = try self.take(2560);
        self.upcase_extent = try self.take(65536 * 2);
        const sd = defaultDescriptor();
        const sds_length = (20 + sd.len + 15) & ~@as(usize, 15);
        self.secure = try self.take(0x40000 + sds_length);
        try self.clearStream(&self.bitmap);
        try self.clearStream(&self.mft_bitmap);
        try self.markClusters(0, 3, true); // Boot and first-four-record mirror.
        try self.markClusters(4, self.mft_records / 4, true);
        try self.markClusters(4096, self.next_lcn - 4096, true);
        if (self.bitmap.bytes * 8 > self.total_clusters) try self.bitmapSet(&self.bitmap, self.total_clusters, self.bitmap.bytes * 8 - self.total_clusters, true);
        for (0..64) |number| {
            var empty = r.Builder.init(number, sequence(number), 0, 0);
            try self.writeRecord(number, &empty.b);
        }
        try self.bitmapSet(&self.mft_bitmap, 0, 16, true);
        try self.bitmapSet(&self.mft_bitmap, 24, 3, true);
        try self.fill(self.logfile.lcn * cluster, self.logfile.clusters * cluster, 0xff);
        try self.writeRestartPages();
        try self.writeAttributeDefinitions();
        for (self.upcase, 0..) |unit, i| put(u16, self.scratch, i * 2, unit);
        try self.write(self.upcase_extent.lcn * cluster, self.scratch[0 .. 65536 * 2]);
        try self.fill(self.secure.lcn * cluster, self.secure.clusters * cluster, 0);
        var sds: [256]u8 = @splat(0);
        put(u32, &sds, 0, securityHash(&sd));
        put(u32, &sds, 4, 256);
        put(u32, &sds, 16, @intCast(20 + sd.len));
        @memcpy(sds[20..][0..sd.len], &sd);
        try self.write(self.secure.lcn * cluster, sds[0..sds_length]);
        self.secure_stream = try self.streamExtent(self.secure);
        self.security_cursor = sds_length;
        try self.security_entries.append(self.allocator, .{ .offset = 0, .hash = securityHash(&sd), .id = 256, .length = @intCast(20 + sd.len) });
        try self.write(self.secure.lcn * cluster + 0x40000, sds[0..sds_length]);
        var boot: [8192]u8 = @splat(0);
        boot[0] = 0xeb;
        boot[1] = 0x52;
        boot[2] = 0x90;
        @memcpy(boot[3..11], "NTFS    ");
        put(u16, &boot, 11, 512);
        boot[13] = 8;
        boot[21] = 0xf8;
        put(u16, &boot, 24, 63);
        put(u16, &boot, 26, 255);
        put(u32, &boot, 28, @intCast(self.partition.start_bytes / 512));
        boot[36] = 0x80;
        boot[38] = 0x80;
        put(u64, &boot, 40, self.partition.size_bytes / 512 - 1);
        put(u64, &boot, 48, 4);
        put(u64, &boot, 56, 2);
        boot[64] = 0xf6;
        boot[68] = 1;
        put(u64, &boot, 72, self.serial);
        // Deliberately non-booting volume: no borrowed Windows VBR instructions.
        boot[84] = 0xfa;
        boot[85] = 0xf4;
        boot[86] = 0xeb;
        boot[87] = 0xfd;
        put(u16, &boot, 510, 0xaa55);
        try self.write(0, &boot);
        try self.write(self.partition.size_bytes - 512, boot[0..512]);

        const names = [_][]const u16{
            u("$MFT"),    u("$MFTMirr"), u("$LogFile"), u("$Volume"), u("$AttrDef"), u("."),
            u("$Bitmap"), u("$Boot"),    u("$BadClus"), u("$Secure"), u("$UpCase"),  u("$Extend"),
        };
        const extents = [_]Extent{
            .{ .lcn = 4, .clusters = self.mft_records / 4, .bytes = self.mft_records * 1024 },
            .{ .lcn = 2, .clusters = 1, .bytes = 4096 },
            self.logfile,
            .{},
            self.attrdef,
            .{},
            initial_bitmap,
            .{ .lcn = 0, .clusters = 2, .bytes = 8192 },
            .{},
            .{},
            self.upcase_extent,
            .{},
        };
        for (0..16) |number| {
            const is_dir = number == 5 or number == 11;
            const is_view = number == 9;
            const flags: u32 = 6 | (if (is_dir) @as(u32, 0x10000000) else 0) | (if (is_view) @as(u32, 0x20000000) else 0);
            const name: []const u16 = if (number < names.len) names[number] else &.{};
            const extent = if (number < extents.len) extents[number] else Extent{};
            var b = try baseRecord(number, 5, name, 1 | (if (is_dir) @as(u16, 2) else 0) | (if (is_view) @as(u16, 8) else 0), flags, extent.clusters * cluster, extent.bytes, .{});
            switch (number) {
                0 => {
                    try self.extentAttr(&b, 0x80, &.{}, extent);
                    var m = initial_mft_bitmap;
                    m.bytes = 8;
                    try self.extentAttr(&b, 0xb0, &.{}, m);
                },
                1, 2, 4, 6, 7 => try self.extentAttr(&b, 0x80, &.{}, extent),
                10 => {
                    try self.extentAttr(&b, 0x80, &.{}, extent);
                    // ntfs-3g mkntfs.c UPCASEINFO: Windows8+ validates the
                    // on-disk table through this named32-byte DATA stream.
                    // GPL-2.0-or-later format adaptation, authors credited
                    // above. Fields beyond length/checksum remain zero as
                    // in the public formatter; no Windows table is copied.
                    var info: [32]u8 = @splat(0);
                    put(u32, &info, 0, info.len);
                    for (self.upcase, 0..) |unit, i| put(u16, self.scratch, i * 2, unit);
                    put(u64, &info, 8, upcaseChecksum(self.scratch[0..131072]));
                    try b.resident(0x80, u("$Info"), &info, false);
                },
                3 => {
                    var label: [16]u8 = undefined;
                    r.utf16(&label, u("USOSPREP"));
                    try b.resident(0x60, &.{}, &label, false);
                    var info: [12]u8 = @splat(0);
                    info[8] = 3;
                    info[9] = 1;
                    put(u16, &info, 10, 1);
                    try b.resident(0x70, &.{}, &info, false);
                    try b.resident(0x80, &.{}, &.{}, false);
                },
                5, 11 => {
                    const root = emptyIndexRoot(0x30, 1);
                    try b.resident(0x90, index_name, &root, false);
                },
                8 => {
                    try b.resident(0x80, &.{}, &.{}, false);
                    try b.nonresident(0x80, u("$Bad"), null, self.total_clusters, self.total_clusters * cluster, 0);
                    // $Bad is a special uncompressed, non-sparse-flagged
                    // metadata stream. Its allocation field covers the whole
                    // logical volume even though its mapping is a hole. A
                    // zero allocation here differs from the public formatter's
                    // non-compressed DataSize/AllocationSize convention. This
                    // change alone did not fix Windows mount error1393.
                    const bad = (try r.find(&b.b, 0x80, u("$Bad"))) orelse return error.Corrupt;
                    put(u64, bad.bytes, 40, self.total_clusters * cluster);
                },
                9 => {
                    try self.extentAttr(&b, 0x80, u("$SDS"), self.secure);
                    try self.secureIndexes(&b, &sd);
                },
                else => try b.resident(0x80, &.{}, &.{}, false),
            }
            try self.writeRecord(number, &b.b);
        }
        for (24..27) |number| {
            const name = switch (number) {
                24 => u("$Quota"),
                25 => u("$ObjId"),
                else => u("$Reparse"),
            };
            var b = try baseRecord(number, 11, name, 0x0d, 0x20000026, 0, 0, .{});
            if (number == 24) try self.quotaIndexes(&b) else {
                const root = emptyIndexRoot(0, 0x13);
                try b.resident(0x90, if (number == 25) u("$O") else u("$R"), &root, false);
            }
            try self.writeRecord(number, &b.b);
        }
        self.formatted = true;
        self.volume_bits = .{ .io = .{ .context = self, .read = volumeBitmapRead, .write = volumeBitmapWrite }, .bits = self.total_clusters };
        self.record_bits = .{ .io = .{ .context = self, .read = recordBitmapRead, .write = recordBitmapWrite }, .bits = self.mft_records, .minimum = 27, .hint = 27 };
        try self.loadDirectory(5);
        for (0..12) |number| {
            var record: [1024]u8 = undefined;
            try self.readRecord(number, &record);
            try self.addCached(number, &record);
        }
        try self.loadDirectory(11);
        for (24..27) |number| {
            var record: [1024]u8 = undefined;
            try self.readRecord(number, &record);
            try self.addCached(number, &record);
        }
        try self.flushDirectoryBitmap();
        try self.volume_bits.?.flush();
        try self.record_bits.?.flush();
        try self.disk.flush();
        self.mft_cache_ready = true;
    }

    fn writeRestartPages(self: *Ntfs) !void {
        var page: [4096]u8 = @splat(0);
        @memcpy(page[0..4], "RSTR");
        put(u16, &page, 4, 30);
        put(u16, &page, 6, 9);
        put(u32, &page, 16, 4096);
        put(u32, &page, 20, 4096);
        put(u16, &page, 24, 64);
        put(u16, &page, 26, 1);
        put(u16, &page, 28, 1);
        const ra: usize = 64;
        put(u16, &page, ra + 8, 1);
        put(u16, &page, ra + 10, 0);
        put(u16, &page, ra + 12, 0xffff);
        put(u16, &page, ra + 14, 2);
        put(u32, &page, ra + 16, 67 - (64 - @clz(self.logfile.bytes)));
        put(u16, &page, ra + 20, 64 + 160);
        put(u16, &page, ra + 22, 64);
        put(u64, &page, ra + 24, self.logfile.bytes);
        put(u16, &page, ra + 36, 48);
        put(u16, &page, ra + 38, 64);
        put(u32, &page, ra + 40, 1);
        const client = ra + 64;
        put(u16, &page, client + 16, 0xffff);
        put(u16, &page, client + 18, 0xffff);
        put(u16, &page, client + 20, 1);
        put(u32, &page, client + 28, 8);
        r.utf16(page[client + 32 ..], u("NTFS"));
        try r.protect(&page);
        try self.write(self.logfile.lcn * cluster, &page);
        try self.write(self.logfile.lcn * cluster + 4096, &page);
    }
    fn writeAttributeDefinitions(self: *Ntfs) !void {
        // Generate schema records from documented type/range/flag fields;
        // never copy an $AttrDef stream from Windows or an existing volume.
        const Def = struct { name: []const u8, kind: u32, flags: u32, min: u64, max: u64 };
        const definitions = [_]Def{
            .{ .name = "$STANDARD_INFORMATION", .kind = 0x10, .flags = 0x40, .min = 48, .max = 72 },
            .{ .name = "$ATTRIBUTE_LIST", .kind = 0x20, .flags = 0x80, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$FILE_NAME", .kind = 0x30, .flags = 0x42, .min = 68, .max = 578 },
            .{ .name = "$OBJECT_ID", .kind = 0x40, .flags = 0x40, .min = 0, .max = 256 },
            .{ .name = "$SECURITY_DESCRIPTOR", .kind = 0x50, .flags = 0x80, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$VOLUME_NAME", .kind = 0x60, .flags = 0x40, .min = 2, .max = 256 },
            .{ .name = "$VOLUME_INFORMATION", .kind = 0x70, .flags = 0x40, .min = 12, .max = 12 },
            .{ .name = "$DATA", .kind = 0x80, .flags = 0, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$INDEX_ROOT", .kind = 0x90, .flags = 0x40, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$INDEX_ALLOCATION", .kind = 0xa0, .flags = 0x80, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$BITMAP", .kind = 0xb0, .flags = 0x80, .min = 0, .max = std.math.maxInt(u64) },
            .{ .name = "$REPARSE_POINT", .kind = 0xc0, .flags = 0x80, .min = 0, .max = 16384 },
            .{ .name = "$EA_INFORMATION", .kind = 0xd0, .flags = 0x40, .min = 8, .max = 8 },
            .{ .name = "$EA", .kind = 0xe0, .flags = 0, .min = 0, .max = 65536 },
            .{ .name = "$LOGGED_UTILITY_STREAM", .kind = 0x100, .flags = 0x80, .min = 0, .max = 65536 },
        };
        var data: [2560]u8 = @splat(0);
        for (definitions, 0..) |def, i| {
            const row = data[i * 160 ..][0..160];
            for (def.name, 0..) |c, j| put(u16, row, j * 2, c);
            put(u32, row, 128, def.kind);
            put(u32, row, 140, def.flags);
            put(u64, row, 144, def.min);
            put(u64, row, 152, def.max);
        }
        try self.fill(self.attrdef.lcn * cluster, cluster, 0);
        try self.write(self.attrdef.lcn * cluster, &data);
    }

    fn secureIndexes(self: *Ntfs, b: *r.Builder, sd: []const u8) !void {
        _ = self;
        const hash = securityHash(sd);
        var sii: [88]u8 = @splat(0);
        indexPrefix(&sii, 0, 0x10, false, 72);
        const s = sii[32..72];
        put(u16, s, 0, 20);
        put(u16, s, 2, 20);
        put(u16, s, 8, 40);
        put(u16, s, 10, 4);
        put(u32, s, 16, 256);
        put(u32, s, 20, hash);
        put(u32, s, 24, 256);
        put(u32, s, 36, @intCast(20 + sd.len));
        endEntry(sii[72..], null);
        var sdh: [96]u8 = @splat(0);
        indexPrefix(&sdh, 0, 0x12, false, 80);
        const h = sdh[32..80];
        put(u16, h, 0, 24);
        put(u16, h, 2, 20);
        put(u16, h, 8, 48);
        put(u16, h, 10, 8);
        put(u32, h, 16, hash);
        put(u32, h, 20, 256);
        put(u32, h, 24, hash);
        put(u32, h, 28, 256);
        put(u32, h, 40, @intCast(20 + sd.len));
        // NTFS_DE_SDH's required magic[2], confirmed by public mkntfs.c
        // initialize_secure and Linux fs/ntfs3/fsntfs.c ntfs_insert_security.
        put(u32, h, 44, 0x00490049);
        endEntry(sdh[80..], null);
        try b.resident(0x90, u("$SDH"), &sdh, false);
        try b.resident(0x90, u("$SII"), &sii, false);
    }
    fn quotaIndexes(self: *Ntfs, b: *r.Builder) !void {
        _ = self;
        var o: [88]u8 = @splat(0);
        indexPrefix(&o, 0, 0x11, false, 72);
        put(u16, &o, 32, 32);
        put(u16, &o, 34, 4);
        put(u16, &o, 40, 40);
        put(u16, &o, 42, 16);
        sid(o[48..64], 5, &.{ 32, 544 });
        put(u32, &o, 64, 256);
        endEntry(o[72..], null);
        var q: [208]u8 = @splat(0);
        indexPrefix(&q, 0, 0x10, false, 192);
        for (0..2) |n| {
            const off: usize = if (n == 0) 32 else 104;
            const size: usize = if (n == 0) 72 else 88;
            const e = q[off..][0..size];
            put(u16, e, 0, 20);
            put(u16, e, 2, if (n == 0) 48 else 64);
            put(u16, e, 8, @intCast(size));
            put(u16, e, 10, 4);
            put(u32, e, 16, if (n == 0) 1 else 256);
            put(u32, e, 20, 2);
            put(u32, e, 24, 1);
            put(u64, e, 36, timestamp);
            put(u64, e, 44, std.math.maxInt(u64));
            put(u64, e, 52, std.math.maxInt(u64));
            if (n == 1) sid(e[68..84], 5, &.{ 32, 544 });
        }
        endEntry(q[192..], null);
        try b.resident(0x90, u("$O"), &o, false);
        try b.resident(0x90, u("$Q"), &q, false);
    }

    fn validateOptions(self: *Ntfs, opts: FileOptions) !void {
        if (opts.security_id != null and opts.security_descriptor != null) return error.InvalidArgument;
        if (opts.attributes & 0x4000 != 0) return error.Unsupported; // EFS ciphertext is not plaintext DATA.
        if (opts.security_id) |id| {
            if (id < 256 or id - 256 >= self.security_entries.items.len) return error.InvalidArgument;
        }
        if (opts.security_descriptor) |sd| try validateDescriptor(sd);
    }
    fn growStream(self: *Ntfs, stream: *Stream, bytes: u64) !void {
        const old_clusters = try stream.clusters();
        const needed = (std.math.add(u64, bytes, cluster - 1) catch return error.Bounds) / cluster;
        if (needed > old_clusters) {
            const count = @max(needed, @max(1, old_clusters * 2));
            var added = try self.allocateRuns((count - old_clusters) * cluster, 0);
            defer added.deinit(self.allocator);
            try self.clearStream(&added);
            for (added.list.items) |run| try appendRun(&stream.list, self.allocator, run);
        }
        stream.bytes = bytes;
    }
    /// Self-relative SECURITY_DESCRIPTOR bytes; IDs start at256 and are stable
    /// for this newly formatted volume. Hash collisions are compared bytewise.
    pub fn registerSecurity(self: *Ntfs, sd: []const u8) !u32 {
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed) return error.InvalidArgument;
        try validateDescriptor(sd);
        const hash = securityHash(sd);
        for (self.security_entries.items) |entry| {
            if (entry.hash != hash or entry.length != sd.len + 20) continue;
            try self.readRuns(self.secure_stream.list.items, entry.offset + 20, self.scratch[0..sd.len]);
            if (std.mem.eql(u8, sd, self.scratch[0..sd.len])) return entry.id;
        }
        if (self.security_entries.items.len >= 65536) return error.NoSpace;
        errdefer self.failed = true;
        const length = (sd.len + 20 + 15) & ~@as(usize, 15);
        var offset = self.security_cursor;
        if (offset & 0x40000 != 0 or (offset & 0x3ffff) + length > 0x40000) offset = ((offset / 0x80000) + 1) * 0x80000;
        const stop = offset + 0x40000 + length;
        if (stop > self.secure_stream.bytes) try self.growStream(&self.secure_stream, stop);
        const id: u32 = @intCast(256 + self.security_entries.items.len);
        @memset(self.scratch[0..length], 0);
        put(u32, self.scratch, 0, hash);
        put(u32, self.scratch, 4, id);
        put(u64, self.scratch, 8, offset);
        put(u32, self.scratch, 16, @intCast(20 + sd.len));
        @memcpy(self.scratch[20..][0..sd.len], sd);
        try self.writeRuns(self.secure_stream.list.items, offset, self.scratch[0..length]);
        try self.writeRuns(self.secure_stream.list.items, offset + 0x40000, self.scratch[0..length]);
        try self.security_entries.append(self.allocator, .{ .offset = offset, .hash = hash, .id = id, .length = @intCast(20 + sd.len) });
        self.security_cursor = offset + length;
        self.security_changed = true;
        return id;
    }
    fn appendResident(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16, value: []const u8, indexed: bool) !void {
        var b = r.Builder.init(0, 1, 1, 0);
        try b.resident(kind, name, value, indexed);
        try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, (try r.find(&b.b, kind, name)).?.bytes), .origin = std.math.maxInt(u64) });
    }
    fn removeAttributes(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), kind: u32, name: []const u16) void {
        var i: usize = 0;
        while (i < attrs.items.len) {
            if (!attrMatches(attrs.items[i].bytes, kind, name)) {
                i += 1;
                continue;
            }
            self.allocator.free(attrs.orderedRemove(i).bytes);
        }
    }
    const MetadataSink = struct {
        fs: *Ntfs,
        data: Stream = .{},
        fn write(ctx: *anyopaque, vcn: u64, page: *const [4096]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.fs.growStream(&self.data, (vcn + 1) * cluster);
            try self.fs.writeRuns(self.data.list.items, vcn * cluster, page);
        }
    };
    fn metadataIndex(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), name: []const u16, items: meta_index.Items) !void {
        var sink: MetadataSink = .{ .fs = self };
        defer sink.data.deinit(self.allocator);
        const root = try meta_index.build(items, .{ .context = &sink, .write_node = MetadataSink.write });
        self.removeAttributes(attrs, 0x90, name);
        self.removeAttributes(attrs, 0xa0, name);
        self.removeAttributes(attrs, 0xb0, name);
        try self.appendResident(attrs, 0x90, name, root.bytes[0..root.length], false);
        if (root.node_count == 0) return;
        sink.data.bytes = root.node_count * cluster;
        try self.addRunAttributes(attrs, 0xa0, name, &sink.data);
        const bytes: usize = @intCast(((root.node_count + 63) / 64) * 8);
        const bits = try self.allocator.alloc(u8, bytes);
        defer self.allocator.free(bits);
        @memset(bits, 0);
        for (0..@intCast(root.node_count)) |i| bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        if (bytes <= 128) try self.appendResident(attrs, 0xb0, name, bits, false) else {
            var stream = try self.allocateRuns(bytes, 0);
            defer stream.deinit(self.allocator);
            try self.clearStream(&stream);
            try self.writeRuns(stream.list.items, 0, bits);
            try self.addRunAttributes(attrs, 0xb0, name, &stream);
        }
    }
    fn finalizeSpecialIndexes(self: *Ntfs) !void {
        // All four index keys are unique (the builder rejects duplicates).
        // Heap sort preserves their ordering with O(n log n) work and O(1)
        // auxiliary space, without four large stable block-sort instances.
        if (self.object_entries.items.len != 0) {
            var attrs = try self.collectAttributes(25);
            defer self.freeAttributes(&attrs);
            std.sort.heap(meta_index.ObjectIdEntry, self.object_entries.items, {}, meta_index.objectIdLess);
            try self.metadataIndex(&attrs, u("$O"), .{ .object_id = self.object_entries.items });
            try self.writeAttributes(25, &attrs);
        }
        if (self.security_changed) {
            var attrs = try self.collectAttributes(9);
            defer self.freeAttributes(&attrs);
            try self.replaceStreamAttrs(&attrs, 0x80, u("$SDS"), &self.secure_stream);
            std.sort.heap(meta_index.SecurityEntry, self.security_entries.items, {}, meta_index.securityHashLess);
            try self.metadataIndex(&attrs, u("$SDH"), .{ .sdh = self.security_entries.items });
            std.sort.heap(meta_index.SecurityEntry, self.security_entries.items, {}, meta_index.securityIdLess);
            try self.metadataIndex(&attrs, u("$SII"), .{ .sii = self.security_entries.items });
            try self.writeAttributes(9, &attrs);
            self.security_changed = false;
        }
        if (self.reparse_entries.items.len != 0) {
            var attrs = try self.collectAttributes(26);
            defer self.freeAttributes(&attrs);
            std.sort.heap(meta_index.ReparseEntry, self.reparse_entries.items, {}, meta_index.reparseLess);
            try self.metadataIndex(&attrs, u("$R"), .{ .reparse = self.reparse_entries.items });
            try self.writeAttributes(26, &attrs);
        }
    }
    fn ensureMft(self: *Ntfs, number: u64) anyerror!void {
        if (number < self.mft_records) return;
        const previous = self.mft_records;
        var count = previous;
        while (count <= number) count = std.math.mul(u64, count, 2) catch return error.Bounds;
        if (count > self.total_clusters * 4) return error.NoSpace;
        var added = try self.allocateRuns((count - previous) * 1024, 0);
        defer added.deinit(self.allocator);
        errdefer self.failed = true;
        for (added.list.items) |run| try appendRun(&self.mft_runs, self.allocator, run);
        const bitmap_bytes = ((count + 63) / 64) * 8;
        if (bitmap_bytes > (try self.mft_bitmap.clusters()) * cluster) {
            try self.record_bits.?.flush();
            var replacement = try self.allocateRuns(bitmap_bytes, 0);
            errdefer replacement.deinit(self.allocator);
            try self.clearStream(&replacement);
            var copied: u64 = 0;
            const old_bytes = (try self.mft_bitmap.clusters()) * cluster;
            while (copied < old_bytes) {
                const n: usize = @intCast(@min(self.scratch.len, old_bytes - copied));
                try self.readRuns(self.mft_bitmap.list.items, copied, self.scratch[0..n]);
                try self.writeRuns(replacement.list.items, copied, self.scratch[0..n]);
                copied += n;
            }
            for (self.mft_bitmap.list.items) |run| try self.release(run.lcn.?, run.clusters);
            self.mft_bitmap.deinit(self.allocator);
            self.mft_bitmap = replacement;
            replacement = .{};
            self.record_bits.?.page_number = null;
        }
        self.mft_bitmap.bytes = bitmap_bytes;
        self.mft_records = count;
        self.record_bits.?.bits = count;
        var cursor = previous;
        while (cursor < count) {
            const records: usize = @intCast(@min(count - cursor, self.scratch.len / 1024));
            for (0..records) |i| {
                var empty = r.Builder.init(cursor + i, 1, 0, 0);
                try r.protect(&empty.b);
                @memcpy(self.scratch[i * 1024 ..][0..1024], &empty.b);
            }
            try self.writeRuns(self.mft_runs.items, cursor * 1024, self.scratch[0 .. records * 1024]);
            cursor += records;
        }
        var attrs = try self.collectAttributes(0);
        defer self.freeAttributes(&attrs);
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            const key = try r.value(attr.bytes);
            put(u64, key, 40, count * 1024);
            put(u64, key, 48, count * 1024);
        };
        var stream: Stream = .{ .bytes = count * 1024 };
        defer stream.deinit(self.allocator);
        try stream.list.appendSlice(self.allocator, self.mft_runs.items);
        try self.replaceStreamAttrsLimited(&attrs, 0x80, &.{}, &stream, 32);
        try self.replaceStreamAttrs(&attrs, 0xb0, &.{}, &self.mft_bitmap);
        try self.writeAttributes(0, &attrs);
    }
    fn ensureNameAvailable(self: *Ntfs, name: []const u16) !void {
        self.insert_hint = .{};
        try validateName(name, false);
        if (self.directory.?.data.list.items.len == 0) return;
        var tree = self.openTree();
        const timing = p.measure(self.disk.profiler, .index);
        defer p.measured(self.disk.profiler, timing);
        tree.prepareInsert(name, &self.insert_hint) catch |err| {
            self.indexError(err);
            return err;
        };
    }
    fn buildMetadata(self: *Ntfs, number: u64, parent: u64, name: []const u16, dir: bool, allocated: u64, bytes: u64, opts: FileOptions) !r.Builder {
        var previous: [1024]u8 = undefined;
        try self.readRecord(number, &previous);
        var base_opts = opts;
        base_opts.security_descriptor = null;
        const attributes = (opts.attributes & ~@as(u32, 0x10000010)) | (if (dir) @as(u32, 0x10000000) else 0) | (if (opts.sparse) @as(u32, 0x200) else 0) | (if (opts.compressed) @as(u32, 0x800) else 0);
        var b = try baseRecord(number, parent, name, if (dir) 3 else 1, attributes, allocated, bytes, base_opts);
        put(u16, &b.b, 16, get(u16, &previous, 16));
        const fn_attr = (try r.find(&b.b, 0x30, &.{})).?;
        put(u64, try r.value(fn_attr.bytes), 0, try self.actualReference(parent));
        if (opts.security_descriptor != null) {
            const si = (try r.find(&b.b, 0x10, &.{})).?;
            put(u32, try r.value(si.bytes), 52, 0);
        }
        return b;
    }
    fn appendRecordAttributes(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), number: u64, base: *[1024]u8) !void {
        var pos: usize = get(u16, base, 20);
        while (pos + 8 <= base.len) {
            const kind = get(u32, base, pos);
            if (kind == 0xffffffff) return;
            const n = get(u32, base, pos + 4);
            if (n < 24 or pos + n > base.len) return error.Corrupt;
            const copy = try self.allocator.dupe(u8, base[pos..][0..n]);
            errdefer self.allocator.free(copy);
            try attrs.append(self.allocator, .{ .bytes = copy, .origin = number });
            pos += n;
        }
        return error.Corrupt;
    }
    fn appendDescriptor(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), opts: FileOptions) !void {
        if (opts.security_descriptor) |sd| {
            try validateDescriptor(sd);
            var b = r.Builder.init(0, 1, 1, 0);
            try b.resident(0x50, &.{}, sd, false);
            try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, (try r.find(&b.b, 0x50, &.{})).?.bytes), .origin = std.math.maxInt(u64) });
        }
    }
    pub fn mkdir(self: *Ntfs, parent: u64, name: []const u16, opts: FileOptions) !u64 {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed) return error.InvalidArgument;
        try self.validateOptions(opts);
        try self.loadDirectory(parent);
        try self.ensureNameAvailable(name);
        const number = try self.allocateRecord();
        errdefer self.failed = true;
        var base = try self.buildMetadata(number, parent, name, true, 0, 0, opts);
        var attrs: std.ArrayList(OwnedAttribute) = .empty;
        defer self.freeAttributes(&attrs);
        try self.appendRecordAttributes(&attrs, number, &base.b);
        try self.appendDescriptor(&attrs, opts);
        var b = r.Builder.init(number, 1, 3, 1);
        const root = emptyIndexRoot(0x30, 1);
        try b.resident(0x90, index_name, &root, false);
        try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, (try r.find(&b.b, 0x90, index_name)).?.bytes), .origin = std.math.maxInt(u64) });
        try self.writeAttributesFromRecord(number, &attrs, &base.b);
        var record: [1024]u8 = undefined;
        try self.readRecord(number, &record);
        try self.addCached(number, &record);
        try self.flushDirectoryBitmap();
        return number;
    }
    fn sourceRead(self: *Ntfs, source: Source, offset: u64, output: []u8) p.Error!void {
        source.read_fn(source.context, offset, output) catch |err| {
            self.failed = true;
            return err;
        };
    }
    fn buildData(self: *Ntfs, source: Source, opts: FileOptions) !Stream {
        const compressed = opts.compressed or opts.attributes & 0x800 != 0;
        const sparse = !compressed and (opts.sparse or opts.attributes & 0x200 != 0);
        var stream: Stream = .{ .bytes = source.size, .flags = if (compressed) 1 else if (sparse) 0x8000 else 0 };
        errdefer stream.deinit(self.allocator);
        errdefer for (stream.list.items) |run| if (run.lcn) |lcn| {
            self.release(lcn, run.clusters) catch {
                self.failed = true;
            };
        };
        if (sparse) {
            var done: u64 = 0;
            while (done < source.size) : (done += cluster) {
                const n: usize = @intCast(@min(cluster, source.size - done));
                @memset(self.scratch[0..4096], 0);
                try self.sourceRead(source, done, self.scratch[0..n]);
                if (std.mem.allEqual(u8, self.scratch[0..4096], 0)) {
                    try appendRun(&stream.list, self.allocator, .{ .lcn = null, .clusters = 1 });
                } else {
                    // Allocation may use scratch internally; preserve the single
                    // cluster, never an entire source or compression resource.
                    var page: [4096]u8 = undefined;
                    @memcpy(&page, self.scratch[0..4096]);
                    var one = try self.allocateRuns(cluster, opts.max_run_clusters);
                    defer one.deinit(self.allocator);
                    try self.writeRuns(one.list.items, 0, &page);
                    for (one.list.items) |run| try appendRun(&stream.list, self.allocator, run);
                }
            }
        } else {
            // A compressed unit whose full16 physical clusters are present is
            // canonically stored raw, without LZNT1 encoding. Pad the final unit.
            const unit: u64 = if (compressed) 16 * cluster else cluster;
            const allocation = (std.math.add(u64, source.size, unit - 1) catch return error.Bounds) / unit * unit;
            stream = try self.allocateRuns(allocation, opts.max_run_clusters);
            stream.bytes = source.size;
            stream.flags = if (compressed) 1 else 0;
            var done: u64 = 0;
            while (done < allocation) {
                const n: usize = @intCast(@min(allocation - done, self.scratch.len));
                @memset(self.scratch[0..n], 0);
                const available: usize = @intCast(@min(source.size -| done, n));
                if (available != 0) try self.sourceRead(source, done, self.scratch[0..available]);
                try self.writeRuns(stream.list.items, done, self.scratch[0..n]);
                done += n;
            }
        }
        return stream;
    }
    fn appendData(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), name: []const u16, source: Source, opts: FileOptions) anyerror!u64 {
        return self.appendDataImpl(attrs, name, source, opts) catch |err| {
            // A fully rolled-back allocation shortage may leave a usable
            // builder. IO, integrity and allocator failures must never permit
            // a caller to publish a clean target after a failed WIM resource.
            if (err != error.NoSpace) self.failed = true;
            return err;
        };
    }
    fn appendDataImpl(self: *Ntfs, attrs: *std.ArrayList(OwnedAttribute), name: []const u16, source: Source, opts: FileOptions) anyerror!u64 {
        // An empty flagged stream still needs its sparse/compressed header.
        if (source.size <= 128 and !opts.sparse and !opts.compressed and opts.attributes & 0xa00 == 0) {
            const n: usize = @intCast(source.size);
            if (n != 0) try self.sourceRead(source, 0, self.scratch[0..n]);
            try self.appendResident(attrs, 0x80, name, self.scratch[0..n], false);
            return 0;
        }
        var stream = try self.buildData(source, opts);
        defer stream.deinit(self.allocator);
        errdefer self.failed = true;
        try self.addRunAttributes(attrs, 0x80, name, &stream);
        return physicalClusters(stream.list.items) * cluster;
    }
    pub fn writeFile(self: *Ntfs, parent: u64, name: []const u16, source: Source, opts: FileOptions) !u64 {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed) return error.InvalidArgument;
        try self.validateOptions(opts);
        if (source.size > self.total_clusters * cluster) return error.NoSpace;
        try self.loadDirectory(parent);
        try self.ensureNameAvailable(name);
        const number = try self.allocateRecord();
        var issued = false;
        errdefer if (!issued) {
            self.releaseRecord(number) catch {
                self.failed = true;
            };
        };
        var attrs: std.ArrayList(OwnedAttribute) = .empty;
        defer self.freeAttributes(&attrs);
        // Build DATA before publishing an in-use FILE record; NoSpace can be
        // rolled back without creating an unindexed live record.
        const allocated = try self.appendData(&attrs, &.{}, source, opts);
        issued = true;
        errdefer self.failed = true;
        var base = try self.buildMetadata(number, parent, name, false, allocated, source.size, opts);
        try self.appendRecordAttributes(&attrs, number, &base.b);
        try self.appendDescriptor(&attrs, opts);
        try self.writeAttributesFromRecord(number, &attrs, &base.b);
        var record: [1024]u8 = undefined;
        try self.readRecord(number, &record);
        try self.addCached(number, &record);
        try self.flushDirectoryBitmap();
        return number;
    }
    /// Append one uniquely named DATA attribute to an existing inode, also
    /// shared by every hardlink. This never addresses a path containing ':'.
    pub fn writeStream(self: *Ntfs, number: u64, name: []const u16, source: Source, opts: FileOptions) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or number < 27) return error.InvalidArgument;
        try validateName(name, false);
        try self.validateOptions(opts);
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x80, name)) return error.InvalidArgument;
        errdefer self.failed = true;
        _ = try self.appendData(&attrs, name, source, opts);
        try self.writeAttributes(number, &attrs);
        try self.flushDirectoryBitmap();
    }
    pub fn lookup(self: *Ntfs, parent: u64, name: []const u16) !?u64 {
        try self.loadDirectory(parent);
        if (self.directory.?.data.list.items.len == 0) return null;
        var tree = self.openTree();
        const ref = (try self.lookupIndex(&tree, name)) orelse return null;
        const number = ref & 0xffffffffffff;
        if (try self.actualReference(number) != ref) return error.Corrupt;
        return number;
    }
    fn indexedKey(self: *Ntfs, ref: u64, key: []const u8, replace: bool) !void {
        if (key.len < 66 or 66 + @as(usize, key[64]) * 2 > key.len) return error.Corrupt;
        const parent_ref = get(u64, key, 0);
        const parent = parent_ref & 0xffffffffffff;
        if (try self.actualReference(parent) != parent_ref) return error.Corrupt;
        try self.loadDirectory(parent);
        var name: [255]u16 = undefined;
        for (0..key[64]) |i| name[i] = get(u16, key, 66 + i * 2);
        if (self.directory.?.data.list.items.len == 0) {
            if (replace) return error.Corrupt;
            try self.createIndex();
        }
        var tree = self.openTree();
        if (replace and !(try self.removeIndex(&tree, name[0..key[64]]))) return error.Corrupt;
        // Removing an entry may collapse the root. Reopen before insertion.
        tree = self.openTree();
        try self.insertIndex(&tree, ref, key);
    }
    fn refreshKeys(self: *Ntfs, number: u64, attrs: []const OwnedAttribute) !void {
        const ref = try self.actualReference(number);
        for (attrs) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) try self.indexedKey(ref, try r.value(attr.bytes), true);
    }
    /// Add another FILE_NAME/index entry to the same inode; no data or security
    /// duplication. Directory hardlinks are deliberately unsupported.
    pub fn linkFile(self: *Ntfs, parent: u64, name: []const u16, number: u64) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or number < 27) return error.InvalidArgument;
        try self.loadDirectory(parent);
        try self.ensureNameAvailable(name);
        var base: [1024]u8 = undefined;
        try self.readRecord(number, &base);
        if (get(u16, &base, 22) & 3 != 1 or get(u16, &base, 18) == std.math.maxInt(u16)) return error.InvalidArgument;
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var key: [576]u8 = @splat(0);
        var found = false;
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            @memcpy(key[0..66], (try r.value(attr.bytes))[0..66]);
            found = true;
            break;
        };
        if (!found) return error.Corrupt;
        put(u64, &key, 0, try self.actualReference(parent));
        key[64] = @intCast(name.len);
        key[65] = 0;
        r.utf16(key[66..], name);
        errdefer self.failed = true;
        try self.appendResident(&attrs, 0x30, &.{}, key[0 .. 66 + name.len * 2], true);
        put(u16, &base, 18, get(u16, &base, 18) + 1);
        try self.writeRecord(number, &base);
        try self.writeAttributes(number, &attrs);
        try self.indexedKey(try self.actualReference(number), key[0 .. 66 + name.len * 2], false);
        try self.flushDirectoryBitmap();
    }
    /// Preserve an image's DOS name alongside the existing Win32 name. A DOS
    /// alias is a second FILE_NAME/index key, never an extra hardlink count.
    pub fn setShortName(self: *Ntfs, parent: u64, name: []const u16, short: []const u16, number: u64) !bool {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or number < 27) return error.InvalidArgument;
        try validateShortName(short);
        try self.loadDirectory(parent);
        var combined = name.len == short.len;
        if (combined) for (name, short) |a, b| {
            if (self.upcase[a] != self.upcase[b]) {
                combined = false;
                break;
            }
        };
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        // Windows supports one DOS/Win32 pair per inode. Additional hardlinks
        // stay POSIX names, as in public wimlib win32_apply.c. Multiple pairs
        // with different DOS spellings corrupt Vista's MUI hardlink indices.
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            const ns = (try r.value(attr.bytes))[65];
            if (ns == 2 or ns == 3) return false;
        };
        if (!combined) try self.ensureNameAvailable(short);
        var long_key: [576]u8 = undefined;
        var long_len: usize = 0;
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            const value = try r.value(attr.bytes);
            if (get(u64, value, 0) & 0xffffffffffff != parent or !keyNameEqual(value, name, self.upcase)) continue;
            if (value[65] != 0) return error.InvalidArgument;
            value[65] = if (combined) 3 else 1;
            long_len = value.len;
            if (long_len > long_key.len) return error.Corrupt;
            @memcpy(long_key[0..long_len], value);
            break;
        };
        if (long_len == 0) return error.InvalidArgument;
        errdefer self.failed = true;
        var dos: [90]u8 = @splat(0);
        if (!combined) {
            @memcpy(dos[0..66], long_key[0..66]);
            dos[64] = @intCast(short.len);
            dos[65] = 2;
            r.utf16(dos[66..], short);
            try self.appendResident(&attrs, 0x30, &.{}, dos[0 .. 66 + short.len * 2], true);
        }
        try self.writeAttributes(number, &attrs);
        const ref = try self.actualReference(number);
        try self.indexedKey(ref, long_key[0..long_len], true);
        if (!combined) try self.indexedKey(ref, dos[0 .. 66 + short.len * 2], false);
        try self.flushDirectoryBitmap();
        return true;
    }
    /// Apply all four independent FILETIMEs and Win32 attributes. The sparse,
    /// compressed and reparse bits also describe DATA/layout and cannot be
    /// silently removed by a later metadata pass.
    pub fn setMetadata(self: *Ntfs, number: u64, opts: FileOptions) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or (number < 27 and number != 5)) return error.InvalidArgument;
        try self.validateOptions(opts);
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var base: [1024]u8 = undefined;
        try self.readRecord(number, &base);
        const dir = get(u16, &base, 22) & 2 != 0;
        var layout_flags: u32 = 0;
        var tag: u32 = 0;
        var ea_size: u32 = 0;
        for (attrs.items) |attr| {
            if (get(u32, attr.bytes, 0) == 0xd0) ea_size = get(u16, try r.value(attr.bytes), 0);
            if (get(u32, attr.bytes, 0) == 0x80) {
                if (get(u16, attr.bytes, 12) & 0x8000 != 0) layout_flags |= 0x200;
                if (get(u16, attr.bytes, 12) & 1 != 0) layout_flags |= 0x800;
            }
            if (get(u32, attr.bytes, 0) == 0xc0) {
                layout_flags |= 0x400;
                if (attr.bytes[8] == 0) tag = get(u32, try r.value(attr.bytes), 0) else {
                    var stream: Stream = .{};
                    defer stream.deinit(self.allocator);
                    try self.decodeAttribute(attr.bytes, &stream);
                    var head: [8]u8 = undefined;
                    try self.readRuns(stream.list.items, 0, &head);
                    tag = get(u32, &head, 0);
                }
            }
        }
        // Record5 is the NTFS volume's own metadata root. Its HIDDEN|SYSTEM
        // identity must survive ordinary WIM root attributes, in SI as well
        // as FILE_NAME. A controlled fresh-image diagnostic changing only
        // root SI0->6 made native Windows chkdsk change from stage1 error5
        // to a clean exit0; preserving FN6 alone had not fixed that error.
        // This exception is deliberately restricted to the volume root.
        const reserved_root_flags: u32 = if (number == 5) 6 else 0;
        const flags = (opts.attributes & ~@as(u32, 0x10000010)) | layout_flags | reserved_root_flags;
        const times = opts.times orelse FileTimes{ .created = opts.timestamp, .modified = opts.timestamp, .changed = opts.timestamp, .accessed = opts.timestamp };
        for (attrs.items) |attr| {
            if (attrMatches(attr.bytes, 0x10, &.{})) {
                const value = try r.value(attr.bytes);
                writeTimes(value, 0, times);
                put(u32, value, 32, flags);
                if (opts.security_id) |id| put(u32, value, 52, id);
            }
            if (attrMatches(attr.bytes, 0x30, &.{})) {
                const value = try r.value(attr.bytes);
                writeTimes(value, 8, times);
                put(u32, value, 56, flags | if (dir) @as(u32, 0x10000000) else 0);
                put(u32, value, 60, if (layout_flags & 0x400 != 0) tag else ea_size);
            }
        }
        if (opts.security_descriptor != null) {
            self.removeAttributes(&attrs, 0x50, &.{});
            try self.appendDescriptor(&attrs, opts);
            for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x10, &.{})) put(u32, try r.value(attr.bytes), 52, 0);
        } else if (opts.security_id != null) self.removeAttributes(&attrs, 0x50, &.{});
        errdefer self.failed = true;
        try self.writeAttributes(number, &attrs);
        try self.refreshKeys(number, attrs.items);
        try self.flushDirectoryBitmap();
    }
    /// raw_REPARSE_DATA_BUFFER: u32tag,u16data_length,u16reserved(0),payload.
    /// Only mount-point and symbolic-link layouts are supported, never opaque
    /// WOF/EFS data. Byte offsets are relative to the UTF16 PathBuffer.
    pub fn setExtendedAttributes(self: *Ntfs, number: u64, raw: []const u8) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or (number < 27 and number != 5)) return error.InvalidArgument;
        const info = try ea.validateNative(raw);
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0xd0, &.{}) or attrMatches(attr.bytes, 0xe0, &.{})) return error.InvalidArgument;
        errdefer self.failed = true;
        var bytes: [8]u8 = undefined;
        put(u16, &bytes, 0, info.packed_size);
        put(u16, &bytes, 2, info.needed);
        put(u32, &bytes, 4, info.unpacked_size);
        try self.appendResident(&attrs, 0xd0, &.{}, &bytes, false);
        if (raw.len <= 512) try self.appendResident(&attrs, 0xe0, &.{}, raw, false) else {
            var stream = try self.allocateRuns(raw.len, 0);
            defer stream.deinit(self.allocator);
            try self.writeRuns(stream.list.items, 0, raw);
            try self.addRunAttributes(&attrs, 0xe0, &.{}, &stream);
        }
        var has_reparse = false;
        for (attrs.items) |attr| if (get(u32, attr.bytes, 0) == 0xc0) {
            has_reparse = true;
            break;
        };
        if (!has_reparse) for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            put(u32, try r.value(attr.bytes), 60, info.packed_size);
        };
        try self.writeAttributes(number, &attrs);
        try self.refreshKeys(number, attrs.items);
        try self.flushDirectoryBitmap();
    }
    pub fn setObjectId(self: *Ntfs, number: u64, raw: []const u8) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or (number < 27 and number != 5)) return error.InvalidArgument;
        if (raw.len < 16 or raw.len > 64 or raw.len % 16 != 0 or std.mem.allEqual(u8, raw[0..16], 0)) return error.InvalidObjectId;
        if (self.object_entries.items.len >= 65536) return error.NoSpace;
        for (self.object_entries.items) |entry|
            if (std.mem.eql(u8, raw[0..16], entry.value[0..16]) or entry.reference & 0xffffffffffff == number) return error.DuplicateObjectId;
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x40, &.{})) return error.InvalidObjectId;
        errdefer self.failed = true;
        // The file attribute holds the current GUID only. The remaining
        // birth/domain GUIDs belong to the $ObjId:$O index data.
        try self.appendResident(&attrs, 0x40, &.{}, raw[0..16], false);
        try self.writeAttributes(number, &attrs);
        var entry: meta_index.ObjectIdEntry = .{ .reference = try self.actualReference(number), .value = @splat(0) };
        @memcpy(entry.value[0..raw.len], raw);
        try self.object_entries.append(self.allocator, entry);
        try self.flushDirectoryBitmap();
    }
    pub fn setReparse(self: *Ntfs, number: u64, raw: []const u8) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed or number < 27) return error.InvalidArgument;
        try validateReparse(raw);
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        for (attrs.items) |attr| if (get(u32, attr.bytes, 0) == 0xc0) return error.InvalidArgument;
        errdefer self.failed = true;
        if (raw.len <= 512) try self.appendResident(&attrs, 0xc0, &.{}, raw, false) else {
            var stream = try self.allocateRuns(raw.len, 0);
            defer stream.deinit(self.allocator);
            try self.clearStream(&stream);
            try self.writeRuns(stream.list.items, 0, raw);
            try self.addRunAttributes(&attrs, 0xc0, &.{}, &stream);
        }
        const tag = get(u32, raw, 0);
        for (attrs.items) |attr| {
            if (attrMatches(attr.bytes, 0x10, &.{})) {
                const value = try r.value(attr.bytes);
                put(u32, value, 32, get(u32, value, 32) | 0x400);
            }
            if (attrMatches(attr.bytes, 0x30, &.{})) {
                const value = try r.value(attr.bytes);
                put(u32, value, 56, get(u32, value, 56) | 0x400);
                put(u32, value, 60, tag);
            }
        }
        try self.writeAttributes(number, &attrs);
        try self.refreshKeys(number, attrs.items);
        try self.reparse_entries.append(self.allocator, .{ .reference = try self.actualReference(number), .tag = tag });
        try self.flushDirectoryBitmap();
    }
    pub fn removeFile(self: *Ntfs, parent: u64, name: []const u16) !void {
        errdefer self.invalidateIndexCache();
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted or self.completed) return error.InvalidArgument;
        const number = (try self.lookup(parent, name)) orelse return error.InvalidArgument;
        if (number < 27) return error.InvalidArgument;
        var base: [1024]u8 = undefined;
        try self.readRecord(number, &base);
        if (get(u16, &base, 22) & 2 != 0) return error.InvalidArgument;
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        // Offline WIM apply never unlinks. Until paired-name unlink is added,
        // refuse it explicitly instead of leaving an orphan DOS index key.
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x30, &.{})) {
            if ((try r.value(attr.bytes))[65] == 2) return error.UnsupportedShortNameUnlink;
        };
        errdefer self.failed = true;
        if (get(u16, &base, 18) > 1) {
            var removed = false;
            for (attrs.items, 0..) |attr, i| if (attrMatches(attr.bytes, 0x30, &.{})) {
                const key = try r.value(attr.bytes);
                if (get(u64, key, 0) & 0xffffffffffff != parent or !keyNameEqual(key, name, self.upcase)) continue;
                self.allocator.free(attrs.orderedRemove(i).bytes);
                removed = true;
                break;
            };
            if (!removed) return error.Corrupt;
            var tree = self.openTree();
            if (!(try self.removeIndex(&tree, name))) return error.Corrupt;
            try self.collapseEmptyDirectory();
            put(u16, &base, 18, get(u16, &base, 18) - 1);
            try self.writeRecord(number, &base);
            try self.writeAttributes(number, &attrs);
            try self.flushDirectoryBitmap();
            return;
        }
        var extensions: std.ArrayList(u64) = .empty;
        defer extensions.deinit(self.allocator);
        for (attrs.items) |attr| if (attr.origin != number and std.mem.indexOfScalar(u64, extensions.items, attr.origin) == null) try extensions.append(self.allocator, attr.origin);
        var tree = self.openTree();
        if (!(try self.removeIndex(&tree, name))) return error.Corrupt;
        try self.collapseEmptyDirectory();
        for (attrs.items) |attr| if (attr.bytes[8] == 1) {
            const pairs = get(u16, attr.bytes, 32);
            var decoder: runs.Decoder = .{ .bytes = attr.bytes[pairs..] };
            while (try decoder.next()) |run| if (run.lcn) |lcn| try self.release(lcn, run.clusters);
        };
        if (try r.find(&base, 0x20, &.{})) |list_attr| if (list_attr.bytes[8] == 1) {
            var decoder: runs.Decoder = .{ .bytes = list_attr.bytes[get(u16, list_attr.bytes, 32)..] };
            while (try decoder.next()) |run| if (run.lcn) |lcn| try self.release(lcn, run.clusters);
        };
        for (extensions.items) |extension| try self.releaseRecord(extension);
        for (self.reparse_entries.items, 0..) |entry, i| if (entry.reference & 0xffffffffffff == number) {
            _ = self.reparse_entries.swapRemove(i);
            break;
        };
        for (self.object_entries.items, 0..) |entry, i| if (entry.reference & 0xffffffffffff == number) {
            _ = self.object_entries.swapRemove(i);
            break;
        };
        try self.releaseRecord(number);
        try self.flushDirectoryBitmap();
    }
    pub fn readFile(self: *Ntfs, number: u64, offset: u64, out: []u8) !usize {
        return self.readStream(number, &.{}, offset, out);
    }
    pub fn readStream(self: *Ntfs, number: u64, name: []const u16, offset: u64, out: []u8) !usize {
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var stream: Stream = .{};
        defer stream.deinit(self.allocator);
        var found = false;
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x80, name)) {
            found = true;
            if (attr.bytes[8] == 0) {
                const value = try r.value(attr.bytes);
                if (offset >= value.len) return 0;
                const n: usize = @intCast(@min(out.len, value.len - offset));
                @memcpy(out[0..n], value[@intCast(offset)..][0..n]);
                return n;
            }
            try self.decodeAttribute(attr.bytes, &stream);
        };
        if (!found) return error.Corrupt;
        if (offset >= stream.bytes) return 0;
        const n: usize = @intCast(@min(out.len, stream.bytes - offset));
        try self.readRuns(stream.list.items, offset, out[0..n]);
        return n;
    }
    pub fn hashFile(self: *Ntfs, number: u64) ![32]u8 {
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var stream: Stream = .{};
        defer stream.deinit(self.allocator);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var found = false;
        for (attrs.items) |attr| if (attrMatches(attr.bytes, 0x80, &.{})) {
            found = true;
            if (attr.bytes[8] == 0) {
                hash.update(try r.value(attr.bytes));
                return hash.finalResult();
            }
            try self.decodeAttribute(attr.bytes, &stream);
        };
        if (!found) return error.Corrupt;
        var done: u64 = 0;
        while (done < stream.bytes) {
            const n: usize = @intCast(@min(self.scratch.len, stream.bytes - done));
            try self.readRuns(stream.list.items, done, self.scratch[0..n]);
            hash.update(self.scratch[0..n]);
            done += n;
        }
        return hash.finalResult();
    }
    pub fn fileStats(self: *Ntfs, number: u64) !FileStats {
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        var stream: Stream = .{};
        defer stream.deinit(self.allocator);
        var extensions: std.ArrayList(u64) = .empty;
        defer extensions.deinit(self.allocator);
        var result: FileStats = .{};
        for (attrs.items) |attr| {
            if (attr.origin != number and std.mem.indexOfScalar(u64, extensions.items, attr.origin) == null) try extensions.append(self.allocator, attr.origin);
            if (attrMatches(attr.bytes, 0x80, &.{})) {
                if (attr.bytes[8] == 0) result.size = (try r.value(attr.bytes)).len else try self.decodeAttribute(attr.bytes, &stream);
            }
        }
        if (stream.list.items.len != 0) {
            result.size = stream.bytes;
            result.run_count = stream.list.items.len;
        }
        result.attribute_list_records = extensions.items.len;
        return result;
    }
    pub fn statistics(self: *const Ntfs) Stats {
        var result = self.counters;
        result.mft_records = self.mft_records;
        result.mft_runs = self.mft_runs.items.len;
        return result;
    }
    /// Persist the incomplete state even if a final flush failed after finish.
    /// The caller must never expose a partially applied Windows as complete.
    pub fn markIncomplete(self: *Ntfs) !void {
        self.failed = true;
        self.completed = false;
        self.invalidateIndexCache();
        if (!self.formatted) return;
        var volume: [1024]u8 = undefined;
        try self.readRecordPhysical(3, &volume);
        const attr = (try r.find(&volume, 0x70, &.{})) orelse return error.Corrupt;
        const info = try r.value(attr.bytes);
        put(u16, info, 10, get(u16, info, 10) | @as(u16, 1));
        try self.writeRecordPhysical(3, &volume);
        try self.disk.flush();
    }
    pub fn finish(self: *Ntfs) !void {
        if (self.failed) return error.PoisonedVolume;
        if (!self.formatted) return error.InvalidArgument;
        if (self.completed) return;
        errdefer self.failed = true;
        try self.finalizeSpecialIndexes();
        try self.validateMftBootstrap();
        // INDEX_ROOT no longer rebuilds the directory. Refresh just the $MFT
        // FILE_NAME key whose cached sizes changed during dynamic growth.
        try self.loadDirectory(5);
        var tree = self.openTree();
        if (!(try self.removeIndex(&tree, u("$MFT")))) return error.Corrupt;
        var mft: [1024]u8 = undefined;
        try self.readRecord(0, &mft);
        try self.addCached(0, &mft);
        try self.flushDirectoryBitmap();
        try self.volume_bits.?.flush();
        try self.record_bits.?.flush();
        try self.flushMftRecords();
        try self.disk.flush();
        var volume: [1024]u8 = undefined;
        try self.readRecord(3, &volume);
        const a = (try r.find(&volume, 0x70, &.{})).?;
        const info = try r.value(a.bytes);
        put(u16, info, 10, get(u16, info, 10) & ~@as(u16, 1));
        try self.writeRecord(3, &volume);
        try self.disk.flush();
        self.completed = true;
    }

    fn rawIndexBackend(self: *Ntfs) index.Backend {
        return .{ .context = self, .read_node = indexReadNode, .write_node = indexWriteNode, .alloc_node = indexAllocateNode, .free_node = indexFreeNode, .set_root = indexSetRoot };
    }
    fn indexBackend(self: *Ntfs) index.Backend {
        self.node_cache.backing = self.rawIndexBackend();
        return self.node_cache.backend();
    }
    fn invalidateIndexCache(self: *Ntfs) void {
        self.node_cache.invalidateAll();
        self.insert_hint = .{};
    }
    fn indexError(self: *Ntfs, err: anyerror) void {
        self.invalidateIndexCache();
        if (err != error.InvalidArgument) self.failed = true;
    }
    fn createIndex(self: *Ntfs) !void {
        const timing = p.measure(self.disk.profiler, .index);
        defer p.measured(self.disk.profiler, timing);
        _ = index.Tree.create(self.indexBackend(), self.upcase) catch |err| {
            self.indexError(err);
            return err;
        };
    }
    fn lookupIndex(self: *Ntfs, tree: *index.Tree, name: []const u16) !?u64 {
        const timing = p.measure(self.disk.profiler, .index);
        defer p.measured(self.disk.profiler, timing);
        return tree.lookup(name) catch |err| {
            self.indexError(err);
            return err;
        };
    }
    fn removeIndex(self: *Ntfs, tree: *index.Tree, name: []const u16) !bool {
        const timing = p.measure(self.disk.profiler, .index);
        defer p.measured(self.disk.profiler, timing);
        return tree.remove(name) catch |err| {
            self.indexError(err);
            return err;
        };
    }
    fn insertIndex(self: *Ntfs, tree: *index.Tree, reference_value: u64, key: []const u8) !void {
        const timing = p.measure(self.disk.profiler, .index);
        defer p.measured(self.disk.profiler, timing);
        const prepared = tree.insertPrepared(reference_value, key, &self.insert_hint) catch |err| {
            self.indexError(err);
            return err;
        };
        if (prepared) self.counters.prepared_inserts +|= 1;
    }
    fn directoryAllocator(self: *Ntfs) !*bm.Bitmap {
        const dir = &self.directory.?;
        if (dir.allocation == null) dir.allocation = .{
            .io = .{ .context = self, .read = directoryBitmapRead, .write = directoryBitmapWrite },
            .bits = try dir.data.clusters(),
            .hint = dir.index_hint,
        };
        dir.allocation.?.bits = try dir.data.clusters();
        dir.allocation.?.hint = dir.index_hint;
        return &dir.allocation.?;
    }
    fn flushDirectoryBitmap(self: *Ntfs) !void {
        if (self.directory) |*dir| if (dir.allocation) |*bits| {
            bits.flush() catch |err| {
                self.indexError(err);
                return err;
            };
            dir.index_hint = bits.hint;
        };
    }
    pub fn indexCacheStatistics(self: *const Ntfs) index_cache.Stats {
        return self.node_cache.stats;
    }
    fn openTree(self: *Ntfs) index.Tree {
        return index.Tree.open(self.indexBackend(), self.upcase, self.directory.?.root);
    }
    fn indexReadNode(ctx: *anyopaque, vcn: u64, out: *[4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        self.counters.index_reads +|= 1;
        try self.readRuns(self.directory.?.data.list.items, vcn * cluster, out);
    }
    fn indexWriteNode(ctx: *anyopaque, vcn: u64, data: *const [4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        self.counters.index_writes +|= 1;
        try self.writeRuns(self.directory.?.data.list.items, vcn * cluster, data);
    }
    fn directoryBitmapRead(ctx: *anyopaque, offset: u64, out: *[4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        self.counters.index_bitmap_reads +|= 1;
        try self.readRuns(self.directory.?.bits.list.items, offset, out);
    }
    fn directoryBitmapWrite(ctx: *anyopaque, offset: u64, data: *const [4096]u8) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        self.counters.index_bitmap_writes +|= 1;
        try self.writeRuns(self.directory.?.bits.list.items, offset, data);
    }
    fn indexAllocateNode(ctx: *anyopaque) !u64 {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        var capacity = try self.directory.?.data.clusters();
        const bits = try self.directoryAllocator();
        if (capacity != 0) {
            if (bits.allocate(1)) |span| {
                self.directory.?.index_hint = bits.hint;
                return span.start;
            } else |err| if (err != error.NoSpace) return err;
        }
        // A pending bitmap page must reach its old runlist before copying or
        // replacing that stream; cached INDX pages must not survive remapping.
        try self.flushDirectoryBitmap();
        self.node_cache.invalidateAll();
        const additional = @max(@as(u64, 8), capacity);
        var added = try self.allocateRuns(additional * cluster, 0);
        defer added.deinit(self.allocator);
        for (added.list.items) |run| {
            try self.fill(run.lcn.? * cluster, run.clusters * cluster, 0);
            try appendRun(&self.directory.?.data.list, self.allocator, run);
        }
        capacity += additional;
        self.directory.?.data.bytes = capacity * cluster;
        const bitmap_bytes = ((capacity + 63) / 64) * 8;
        if (bitmap_bytes > (try self.directory.?.bits.clusters()) * cluster) {
            var old = self.directory.?.bits;
            var replacement = try self.allocateRuns(bitmap_bytes, 0);
            errdefer replacement.deinit(self.allocator);
            try self.clearStream(&replacement);
            var copied: u64 = 0;
            const old_bytes = (try old.clusters()) * cluster;
            while (copied < old_bytes) {
                const n: usize = @intCast(@min(self.scratch.len, old_bytes - copied));
                try self.readRuns(old.list.items, copied, self.scratch[0..n]);
                try self.writeRuns(replacement.list.items, copied, self.scratch[0..n]);
                copied += n;
            }
            self.directory.?.bits = replacement;
            replacement = .{};
            bits.page_number = null;
            bits.dirty = false;
            // Publish the new bitmap mapping before returning its old pages.
            self.directory.?.bits.bytes = bitmap_bytes;
            try self.saveDirectory();
            try self.flushMftRecord(self.directory.?.number);
            for (old.list.items) |run| try self.release(run.lcn.?, run.clusters);
            old.deinit(self.allocator);
        }
        self.directory.?.bits.bytes = bitmap_bytes;
        try self.saveDirectory();
        bits.bits = capacity;
        const result = try bits.allocate(1);
        self.directory.?.index_hint = bits.hint;
        return result.start;
    }
    fn indexFreeNode(ctx: *anyopaque, vcn: u64) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        errdefer self.failed = true;
        const bits = try self.directoryAllocator();
        if (!(try bits.get(vcn))) return error.Corrupt;
        try bits.set(vcn, 1, false);
        self.directory.?.index_hint = @min(self.directory.?.index_hint, vcn);
        bits.hint = self.directory.?.index_hint;
    }
    fn indexSetRoot(ctx: *anyopaque, vcn: u64) !void {
        const self: *Ntfs = @ptrCast(@alignCast(ctx));
        self.directory.?.root = vcn;
        try self.saveDirectory();
    }
    fn saveDirectory(self: *Ntfs) !void {
        try self.flushDirectoryBitmap();
        const dir = &self.directory.?;
        var attrs = try self.collectAttributes(dir.number);
        defer self.freeAttributes(&attrs);
        var i: usize = 0;
        while (i < attrs.items.len) {
            if (attrMatches(attrs.items[i].bytes, 0x90, index_name) or attrMatches(attrs.items[i].bytes, 0xa0, index_name) or attrMatches(attrs.items[i].bytes, 0xb0, index_name)) {
                self.allocator.free(attrs.items[i].bytes);
                _ = attrs.orderedRemove(i);
            } else i += 1;
        }
        var b = r.Builder.init(0, 1, 3, 1);
        if (dir.data.list.items.len == 0) {
            const root = emptyIndexRoot(0x30, 1);
            try b.resident(0x90, index_name, &root, false);
        } else {
            var root: [56]u8 = @splat(0);
            put(u32, &root, 0, 0x30);
            put(u32, &root, 4, 1);
            put(u32, &root, 8, 4096);
            root[12] = 1;
            put(u32, &root, 16, 16);
            put(u32, &root, 20, 40);
            put(u32, &root, 24, 40);
            root[28] = 1;
            endEntry(root[32..], dir.root);
            try b.resident(0x90, index_name, &root, false);
        }
        try attrs.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, (try r.find(&b.b, 0x90, index_name)).?.bytes), .origin = std.math.maxInt(u64) });
        if (dir.data.list.items.len != 0) {
            try self.addRunAttributes(&attrs, 0xa0, index_name, &dir.data);
            try self.addRunAttributes(&attrs, 0xb0, index_name, &dir.bits);
        }
        try self.writeAttributes(dir.number, &attrs);
    }
    fn collapseEmptyDirectory(self: *Ntfs) !void {
        if (self.directory.?.data.list.items.len == 0) return;
        var page: [4096]u8 = undefined;
        const backend = self.indexBackend();
        try backend.read_node(backend.context, self.directory.?.root, &page);
        try r.unprotect(&page);
        if (page[36] != 0 or get(u16, &page, 64 + 12) & 2 == 0) return;
        try self.flushDirectoryBitmap();
        self.invalidateIndexCache();
        self.directory.?.allocation = null;
        var allocation = self.directory.?.data;
        defer allocation.deinit(self.allocator);
        var bits = self.directory.?.bits;
        defer bits.deinit(self.allocator);
        self.directory.?.data = .{};
        self.directory.?.bits = .{};
        self.directory.?.root = 0;
        self.directory.?.index_hint = 0;
        // Publish the resident empty index before returning its backing
        // allocation and bitmap to the volume allocator.
        try self.saveDirectory();
        try self.flushMftRecord(self.directory.?.number);
        for (allocation.list.items) |run| try self.release(run.lcn.?, run.clusters);
        for (bits.list.items) |run| try self.release(run.lcn.?, run.clusters);
    }
    fn loadDirectory(self: *Ntfs, number: u64) !void {
        if (self.directory != null and self.directory.?.number == number) return;
        if (self.failed) return error.PoisonedVolume;
        try self.flushDirectoryBitmap();
        self.node_cache.switchOwner(number);
        self.insert_hint = .{};
        self.counters.directory_switches +|= 1;
        errdefer self.invalidateIndexCache();
        if (self.directory) |*old| {
            old.data.deinit(self.allocator);
            old.bits.deinit(self.allocator);
        }
        self.directory = null;
        var record: [1024]u8 = undefined;
        try self.readRecord(number, &record);
        if (get(u16, &record, 22) & 3 != 3) return error.InvalidArgument;
        var attrs = try self.collectAttributes(number);
        defer self.freeAttributes(&attrs);
        self.directory = .{ .number = number };
        var root_value: []u8 = &.{};
        var bit_stream: Stream = .{};
        defer bit_stream.deinit(self.allocator);
        for (attrs.items) |attr| {
            if (attrMatches(attr.bytes, 0x90, index_name)) root_value = try r.value(attr.bytes);
            if (attrMatches(attr.bytes, 0xa0, index_name)) try self.decodeAttribute(attr.bytes, &self.directory.?.data);
            if (attrMatches(attr.bytes, 0xb0, index_name)) try self.decodeAttribute(attr.bytes, &bit_stream);
        }
        if (root_value.len < 48) return error.Corrupt;
        if (root_value[28] & 1 == 0) {
            const first: usize = 16 + get(u32, root_value, 16);
            if (first + 16 > root_value.len or get(u16, root_value, first + 12) & 2 == 0) return error.Unsupported;
            if (self.directory.?.data.list.items.len != 0 or bit_stream.list.items.len != 0) return error.Corrupt;
        } else {
            if (root_value.len != 56 or bit_stream.list.items.len == 0) return error.Corrupt;
            for (bit_stream.list.items) |run| if (run.lcn == null) return error.Corrupt;
            self.directory.?.root = get(u64, root_value, 48);
            self.directory.?.bits = bit_stream;
            bit_stream = .{};
        }
    }
    fn addCached(self: *Ntfs, number: u64, record: *[1024]u8) !void {
        var attrs: std.ArrayList(OwnedAttribute) = .empty;
        defer self.freeAttributes(&attrs);
        const attr = (try r.find(record, 0x30, &.{})) orelse blk: {
            attrs = try self.collectAttributes(number);
            for (attrs.items) |candidate| if (attrMatches(candidate.bytes, 0x30, &.{})) break :blk r.Attribute{ .offset = 0, .bytes = candidate.bytes };
            return error.Corrupt;
        };
        const key = try r.value(attr.bytes);
        if (self.directory.?.data.list.items.len == 0) try self.createIndex();
        var tree = self.openTree();
        try self.insertIndex(&tree, number | (@as(u64, get(u16, record, 16)) << 48), key);
        // insert() can update its own root through the backend callback;
        // directory.root is the authoritative persisted state afterwards.
    }
};

fn physicalClusters(list: []const Run) u64 {
    var total: u64 = 0;
    for (list) |run| if (run.lcn != null) {
        total += run.clusters;
    };
    return total;
}
fn writeTimes(out: []u8, offset: usize, times: FileTimes) void {
    put(u64, out, offset, times.created);
    put(u64, out, offset + 8, times.modified);
    put(u64, out, offset + 16, times.changed);
    put(u64, out, offset + 24, times.accessed);
}
fn keyNameEqual(key: []const u8, name: []const u16, upcase: []const u16) bool {
    if (key.len < 66 or key[64] != name.len or key.len < 66 + name.len * 2) return false;
    for (name, 0..) |unit, i| if (upcase[unit] != upcase[get(u16, key, 66 + i * 2)]) return false;
    return true;
}
pub fn validateReparse(raw: []const u8) !void {
    if (raw.len < 16 or raw.len > 16384 or get(u16, raw, 4) != raw.len - 8 or get(u16, raw, 6) != 0) return error.InvalidArgument;
    const tag = get(u32, raw, 0);
    if (tag != 0xa0000003 and tag != 0xa000000c) return error.Unsupported;
    const start: usize = if (tag == 0xa0000003) 16 else 20;
    if (raw.len < start or (raw.len - start) % 2 != 0) return error.InvalidArgument;
    if (tag == 0xa000000c and get(u32, raw, 16) > 1) return error.InvalidArgument;
    for ([_]usize{ 8, 12 }) |at| {
        const offset: usize = get(u16, raw, at);
        const length: usize = get(u16, raw, at + 2);
        if ((offset | length) % 2 != 0 or offset > raw.len - start or length > raw.len - start - offset) return error.InvalidArgument;
        if (at == 8 and length == 0) return error.InvalidArgument;
    }
}
fn appendRun(list: *std.ArrayList(Run), allocator: std.mem.Allocator, run: Run) !void {
    if (run.clusters == 0) return error.Corrupt;
    if (list.items.len != 0) {
        const last = &list.items[list.items.len - 1];
        const contiguous = if (last.lcn) |lcn| if (run.lcn) |next| (std.math.add(u64, lcn, last.clusters) catch return error.Bounds) == next else false else run.lcn == null;
        if (contiguous) {
            last.clusters = std.math.add(u64, last.clusters, run.clusters) catch return error.Bounds;
            return;
        }
    }
    try list.append(allocator, run);
}
fn attrMatches(attr: []const u8, kind: u32, name: []const u16) bool {
    if (attr.len < 24 or get(u32, attr, 0) != kind or attr[9] != name.len) return false;
    const offset = get(u16, attr, 10);
    if (offset + name.len * 2 > attr.len) return false;
    for (name, 0..) |unit, i| if (get(u16, attr, offset + i * 2) != unit) return false;
    return true;
}
fn attributeLess(upcase: []const u16, left: OwnedAttribute, right: OwnedAttribute) bool {
    const a = left.bytes;
    const b = right.bytes;
    const kind_a = get(u32, a, 0);
    const kind_b = get(u32, b, 0);
    if (kind_a != kind_b) return kind_a < kind_b;
    const ao = get(u16, a, 10);
    const bo = get(u16, b, 10);
    for (0..@min(a[9], b[9])) |i| {
        const x = upcase[get(u16, a, ao + i * 2)];
        const y = upcase[get(u16, b, bo + i * 2)];
        if (x != y) return x < y;
    }
    if (a[9] != b[9]) return a[9] < b[9];
    // NTFS full collation (ntfs-3g unistr.c): primary UpCase comparison,
    // then original code units for names equal ignoring case. Raw UTF16
    // first incorrectly puts Zone.Identifier before large-世界, and Windows
    // rejects the record and cannot open the latter ADS.
    for (0..a[9]) |i| {
        const x = get(u16, a, ao + i * 2);
        const y = get(u16, b, bo + i * 2);
        if (x != y) return x < y;
    }
    const av: u64 = if (a[8] == 1) get(u64, a, 16) else 0;
    const bv: u64 = if (b[8] == 1) get(u64, b, 16) else 0;
    return av < bv;
}

fn contiguousExtent(attr: []u8) !Extent {
    if (attr[8] != 1 or attr.len < 64) return error.Corrupt;
    const pos = get(u16, attr, 32);
    if (pos + 2 > attr.len) return error.Corrupt;
    const length_bytes = attr[pos] & 15;
    const offset_bytes = attr[pos] >> 4;
    if (length_bytes == 0 or length_bytes > 8 or offset_bytes == 0 or offset_bytes > 8 or pos + 2 + @as(usize, length_bytes) + offset_bytes > attr.len) return error.Unsupported;
    var clusters: u64 = 0;
    var lcn: u64 = 0;
    for (0..length_bytes) |i| clusters |= @as(u64, attr[pos + 1 + i]) << @intCast(i * 8);
    for (0..offset_bytes) |i| lcn |= @as(u64, attr[pos + 1 + length_bytes + i]) << @intCast(i * 8);
    if (attr[pos + length_bytes + offset_bytes] & 0x80 != 0 or attr[pos + 1 + length_bytes + offset_bytes] != 0) return error.Unsupported;
    const bytes = get(u64, attr, 48);
    if (clusters * cluster < bytes or get(u64, attr, 40) != clusters * cluster or get(u64, attr, 56) > bytes) return error.Corrupt;
    return .{ .lcn = lcn, .clusters = clusters, .bytes = bytes };
}

fn u(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
fn sequence(number: u64) u16 {
    return if (number > 0 and number < 24) @intCast(number) else 1;
}
fn reference(number: u64) u64 {
    return number | (@as(u64, sequence(number)) << 48);
}
fn validateName(name: []const u16, allow_dot: bool) !void {
    if (name.len == 0 or name.len > 255) return error.InvalidArgument;
    if (!allow_dot and ((name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.'))) return error.InvalidArgument;
    var high = false;
    for (name) |c| {
        if (c == 0 or c < 32 or c == '\\' or c == '/' or c == ':' or c == '*' or c == '?' or c == '"' or c == '<' or c == '>' or c == '|') return error.InvalidArgument;
        if (high) {
            if (c < 0xdc00 or c > 0xdfff) return error.InvalidArgument;
            high = false;
        } else if (c >= 0xd800 and c <= 0xdbff) high = true else if (c >= 0xdc00 and c <= 0xdfff) return error.InvalidArgument;
    }
    if (high or name[name.len - 1] == ' ' or (!allow_dot and name[name.len - 1] == '.')) return error.InvalidArgument;
}
fn validateDescriptor(sd: []const u8) !void {
    if (sd.len < 20 or sd.len > 65536 or sd[0] != 1 or get(u16, sd, 2) & 0x8000 == 0) return error.InvalidArgument;
    for ([_]usize{ 4, 8, 12, 16 }) |off| {
        const at: usize = get(u32, sd, off);
        if (at != 0 and (at < 20 or at + 8 > sd.len or at % 4 != 0)) return error.InvalidArgument;
        if (at == 0) continue;
        if (off < 12) {
            if (sd[at] != 1 or at + 8 + @as(usize, sd[at + 1]) * 4 > sd.len) return error.InvalidArgument;
        } else {
            const length = get(u16, sd, at + 2);
            if (length < 8 or at + length > sd.len) return error.InvalidArgument;
            var pos = at + 8;
            for (0..get(u16, sd, at + 4)) |_| {
                if (pos + 4 > at + length) return error.InvalidArgument;
                const size = get(u16, sd, pos + 2);
                if (size < 4 or size % 4 != 0 or pos + size > at + length) return error.InvalidArgument;
                pos += size;
            }
        }
    }
}
fn sid(out: []u8, authority: u8, components: []const u32) void {
    @memset(out[0 .. 8 + components.len * 4], 0);
    out[0] = 1;
    out[1] = @intCast(components.len);
    out[7] = authority;
    for (components, 0..) |v, i| put(u32, out, 8 + i * 4, v);
}
fn defaultDescriptor() [124]u8 {
    // Own policy: SYSTEM/Administrators full control; Everyone read/execute.
    var sd: [124]u8 = @splat(0);
    sd[0] = 1;
    put(u16, &sd, 2, 0x8004);
    put(u32, &sd, 4, 92);
    put(u32, &sd, 8, 108);
    put(u32, &sd, 16, 20);
    sd[20] = 2;
    put(u16, &sd, 22, 72);
    put(u16, &sd, 24, 3);
    var pos: usize = 28;
    const principals = [_]struct { authority: u8, ids: []const u32, mask: u32 }{
        .{ .authority = 5, .ids = &.{18}, .mask = 0x1f01ff },
        .{ .authority = 5, .ids = &.{ 32, 544 }, .mask = 0x1f01ff },
        .{ .authority = 1, .ids = &.{0}, .mask = 0x1200a9 },
    };
    for (principals) |principal| {
        const size = 16 + principal.ids.len * 4;
        sd[pos + 1] = 3;
        put(u16, &sd, pos + 2, @intCast(size));
        put(u32, &sd, pos + 4, principal.mask);
        sid(sd[pos + 8 ..], principal.authority, principal.ids);
        pos += size;
    }
    sid(sd[92..108], 5, &.{ 32, 544 });
    sid(sd[108..124], 5, &.{ 32, 544 });
    return sd;
}
fn securityHash(sd: []const u8) u32 {
    var hash: u32 = 0;
    var pos: usize = 0;
    while (pos + 4 <= sd.len) : (pos += 4) hash = std.math.rotl(u32, hash, 3) +% get(u32, sd, pos);
    return hash;
}
fn upcaseChecksum(bytes: []const u8) u64 {
    // Polynomial and initial/final xor from pinned mkntfs.c crc64(); this
    // own bitwise implementation avoids a persistent lookup-table buffer.
    var crc: u64 = std.math.maxInt(u64);
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = (crc >> 1) ^ (if (crc & 1 != 0) @as(u64, 0x9a6c9329ac4bc9b5) else 0);
    }
    return crc ^ std.math.maxInt(u64);
}
fn indexPrefix(out: []u8, kind: u32, collation: u32, children: bool, entry_end: usize) void {
    put(u32, out, 0, kind);
    put(u32, out, 4, collation);
    put(u32, out, 8, 4096);
    out[12] = 1;
    put(u32, out, 16, 16);
    put(u32, out, 20, @intCast(entry_end + 16 - 16));
    put(u32, out, 24, @intCast(entry_end + 16 - 16));
    out[28] = @intFromBool(children);
}
fn endEntry(out: []u8, child: ?u64) void {
    const n: u16 = if (child != null) 24 else 16;
    @memset(out[0..n], 0);
    put(u16, out, 8, n);
    put(u16, out, 12, if (child != null) 3 else 2);
    if (child) |vcn| put(u64, out, 16, vcn);
}
fn emptyIndexRoot(kind: u32, collation: u32) [48]u8 {
    var root: [48]u8 = @splat(0);
    indexPrefix(&root, kind, collation, false, 32);
    endEntry(root[32..], null);
    return root;
}

test "ordinary POSIX namespace uses conservative validated path components" {
    try validateName(u("Zażółć-世界.txt"), false);
    try std.testing.expectError(error.InvalidArgument, validateName(&.{0xd800}, false));
    try std.testing.expectError(error.InvalidArgument, validateName(&.{0xdc00}, false));
    try std.testing.expectError(error.InvalidArgument, validateName(u(".."), false));
    try std.testing.expectError(error.InvalidArgument, validateName(u("trailing."), false));
    try std.testing.expectError(error.InvalidArgument, validateName(u("dir/file"), false));
    var too_long: [256]u16 = @splat('x');
    try std.testing.expectError(error.InvalidArgument, validateName(&too_long, false));
}
test "generated default security descriptor has bounded ACLs and stable hash" {
    var descriptor = defaultDescriptor();
    try validateDescriptor(&descriptor);
    try std.testing.expect(securityHash(&descriptor) != 0);
    descriptor[22] = 255;
    try std.testing.expectError(error.InvalidArgument, validateDescriptor(&descriptor));
}
test "reserved metadata references use the canonical sequence and namespace" {
    try std.testing.expectEqual(@as(u64, 0x0001000000000000), reference(0));
    try std.testing.expectEqual(@as(u64, 0x0005000000000005), reference(5));
    try std.testing.expectEqual(@as(u64, 0x0009000000000009), reference(9));
    try std.testing.expectEqual(@as(u64, 0x000100000000001b), reference(27));
    var root = try Ntfs.baseRecord(5, 5, u("."), 3, 0x10000006, 0, 0, .{});
    const attr = (try r.find(&root.b, 0x30, &.{})).?;
    const key = try r.value(attr.bytes);
    try std.testing.expectEqual(reference(5), get(u64, key, 0));
    try std.testing.expectEqual(@as(u8, 3), key[65]);
    try std.testing.expectEqual(@as(u16, 5), get(u16, &root.b, 16));
    var ordinary = try Ntfs.baseRecord(27, 5, u("ordinary.txt"), 1, 0x20, 0, 0, .{});
    const ordinary_attr = (try r.find(&ordinary.b, 0x30, &.{})).?;
    try std.testing.expectEqual(@as(u8, 0), (try r.value(ordinary_attr.bytes))[65]);
}

test "NTFS constructor pointer output preserves success errors and allocation cleanup without disk IO" {
    const NoIo = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) p.Error!void {
            return error.Io;
        }
        fn write(_: *anyopaque, _: u64, _: []const u8) p.Error!void {
            return error.Io;
        }
        fn flush(_: *anyopaque) p.Error!void {
            return error.Io;
        }
    };
    var context: u8 = 0;
    const disk: p.Disk = .{ .context = &context, .sectors = 160 * 1024, .read_fn = NoIo.read, .write_fn = NoIo.write, .flush_fn = NoIo.flush };
    const partition: partitions.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = 64 * 1024 * 1024 };
    var direct: Ntfs = undefined;
    try Ntfs.initInto(disk, partition, std.testing.allocator, 1234, &direct);
    defer direct.deinit();
    var wrapped = try Ntfs.init(disk, partition, std.testing.allocator, 1234);
    defer wrapped.deinit();
    try std.testing.expectEqual(wrapped.total_clusters, direct.total_clusters);
    try std.testing.expectEqual(wrapped.serial, direct.serial);
    try std.testing.expectEqualSlices(u16, wrapped.upcase, direct.upcase);
    try std.testing.expectError(error.InvalidArgument, Ntfs.init(disk, partition, std.testing.allocator, 0));
    try std.testing.expectError(error.InvalidArgument, Ntfs.initInto(disk, partition, std.testing.allocator, 0, &direct));
    var unsupported = disk;
    unsupported.sector_bytes = 4096;
    try std.testing.expectError(error.Unsupported, Ntfs.init(unsupported, partition, std.testing.allocator, 1));
    try std.testing.expectError(error.Unsupported, Ntfs.initInto(unsupported, partition, std.testing.allocator, 1, &direct));
    const small: partitions.Partition = .{ .start_bytes = 0, .size_bytes = 1024 * 1024 };
    try std.testing.expectError(error.NoSpace, Ntfs.init(disk, small, std.testing.allocator, 1));
    try std.testing.expectError(error.NoSpace, Ntfs.initInto(disk, small, std.testing.allocator, 1, &direct));
    const outside: partitions.Partition = .{ .start_bytes = 32 * 1024 * 1024, .size_bytes = 64 * 1024 * 1024 };
    try std.testing.expectError(error.Bounds, Ntfs.init(disk, outside, std.testing.allocator, 1));
    try std.testing.expectError(error.Bounds, Ntfs.initInto(disk, outside, std.testing.allocator, 1, &direct));
    var tracker: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 256 * 1024 };
    try std.testing.expectError(error.OutOfMemory, Ntfs.init(disk, partition, tracker.allocator(), 1));
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
    try std.testing.expectError(error.OutOfMemory, Ntfs.initInto(disk, partition, tracker.allocator(), 1, &direct));
    try std.testing.expectEqual(@as(usize, 0), tracker.current);
}

test "compact metadata sorts preserve complete ordering and duplicate rejection" {
    const Check = struct {
        fn same(comptime T: type, input: []const T, comptime less: fn (void, T, T) bool) !void {
            const stable = try std.testing.allocator.dupe(T, input);
            defer std.testing.allocator.free(stable);
            const compact = try std.testing.allocator.dupe(T, input);
            defer std.testing.allocator.free(compact);
            std.mem.sort(T, stable, {}, less);
            std.sort.heap(T, compact, {}, less);
            for (stable, compact) |a, b| try std.testing.expectEqualDeep(a, b);
        }
        fn noWrite(_: *anyopaque, _: u64, _: *const [4096]u8) anyerror!void {
            return error.UnexpectedWrite;
        }
    };
    var security: [257]meta_index.SecurityEntry = undefined;
    var objects: [257]meta_index.ObjectIdEntry = undefined;
    var reparse: [257]meta_index.ReparseEntry = undefined;
    for (0..257) |i| {
        const key = (i * 73) % 257;
        security[i] = .{ .offset = key * 144, .hash = @intCast(key % 7), .id = @intCast(256 + key), .length = 144 };
        objects[i] = .{ .reference = key + 27, .value = @splat(0) };
        put(u32, &objects[i].value, 12, @intCast(key));
        reparse[i] = .{ .reference = (@as(u64, key % 5) << 32) | key, .tag = if (key % 3 == 0) 0xa0000003 else 0xa000000c };
    }
    try Check.same(meta_index.SecurityEntry, &security, meta_index.securityHashLess);
    try Check.same(meta_index.SecurityEntry, &security, meta_index.securityIdLess);
    try Check.same(meta_index.ObjectIdEntry, &objects, meta_index.objectIdLess);
    try Check.same(meta_index.ReparseEntry, &reparse, meta_index.reparseLess);
    var context: u8 = 0;
    const sink: meta_index.Sink = .{ .context = &context, .write_node = Check.noWrite };
    var duplicate_security = [_]meta_index.SecurityEntry{ security[0], security[0] };
    duplicate_security[1].offset += 144;
    var duplicate_objects = [_]meta_index.ObjectIdEntry{ objects[0], objects[0] };
    duplicate_objects[1].reference += 1;
    const duplicate_reparse = [_]meta_index.ReparseEntry{ reparse[0], reparse[0] };
    try std.testing.expectError(error.InvalidArgument, meta_index.build(.{ .sii = &duplicate_security }, sink));
    try std.testing.expectError(error.InvalidArgument, meta_index.build(.{ .sdh = &duplicate_security }, sink));
    try std.testing.expectError(error.InvalidArgument, meta_index.build(.{ .object_id = &duplicate_objects }, sink));
    try std.testing.expectError(error.InvalidArgument, meta_index.build(.{ .reparse = &duplicate_reparse }, sink));
}

test "full GPT format-write-read: resident, streamed, Unicode, 1000-entry split and MFT growth" {
    const Disk = struct {
        bytes: []u8,
        fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(out, s.bytes[@intCast(offset)..][0..out.len]);
        }
        fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.bytes[@intCast(offset)..][0..input.len], input);
        }
        fn flush(_: *anyopaque) p.Error!void {}
        fn disk(s: *@This()) p.Disk {
            return .{ .context = s, .sectors = s.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
        }
    };
    const Pattern = struct {
        fn read(_: *anyopaque, offset: u64, out: []u8) p.Error!void {
            for (out, 0..) |*byte, i| byte.* = @truncate((offset + i) *% 37 +% 11);
        }
    };
    const bytes = try std.testing.allocator.alloc(u8, 80 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    var memory: Disk = .{ .bytes = bytes };
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    const ids = try @import("identity.zig").Identifiers.fromEntropy(seed);
    const partition = try partitions.create(memory.disk(), .gpt, ids);
    var tracked: p.TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 4 * 1024 * 1024 };
    {
        var fs = try Ntfs.init(memory.disk(), partition, tracked.allocator(), ids.ntfs_serial);
        defer fs.deinit();
        try fs.format();
        const root_dir = try fs.mkdir(5, u("Zażółć-世界"), .{});
        const nested = try fs.mkdir(root_dir, u("nested"), .{});
        var context: u8 = 0;
        const small: Source = .{ .context = &context, .size = 64, .read_fn = Pattern.read };
        var first_file: u64 = 0;
        for (0..1000) |i| {
            var name_bytes: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_bytes, "item-{d:0>4}.txt", .{i});
            var name16: [32]u16 = undefined;
            const n = try std.unicode.utf8ToUtf16Le(&name16, name);
            const record = try fs.writeFile(root_dir, name16[0..n], small, .{});
            if (i == 0) first_file = record;
        }
        const big: Source = .{ .context = &context, .size = 2 * 1024 * 1024 + 123, .read_fn = Pattern.read };
        const large_record = try fs.writeFile(nested, u("streamed.bin"), big, .{});
        var empty = small;
        empty.size = 0;
        const empty_record = try fs.writeFile(nested, u("empty"), empty, .{});
        try fs.finish();
        try std.testing.expect(fs.mft_records >= 2048);
        var small_bytes: [64]u8 = undefined;
        try Pattern.read(&context, 0, &small_bytes);
        var expected_small: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&small_bytes, &expected_small, .{});
        try std.testing.expectEqualSlices(u8, &expected_small, &(try fs.hashFile(first_file)));
        var large_sha = std.crypto.hash.sha2.Sha256.init(.{});
        var block: [4096]u8 = undefined;
        var cursor: u64 = 0;
        while (cursor < big.size) {
            const n: usize = @intCast(@min(block.len, big.size - cursor));
            try Pattern.read(&context, cursor, block[0..n]);
            large_sha.update(block[0..n]);
            cursor += n;
        }
        try std.testing.expectEqualSlices(u8, &large_sha.finalResult(), &(try fs.hashFile(large_record)));
        var empty_sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&.{}, &empty_sha, .{});
        try std.testing.expectEqualSlices(u8, &empty_sha, &(try fs.hashFile(empty_record)));
        for (0..1000) |i| {
            var bytes_name: [32]u8 = undefined;
            const utf8_name = try std.fmt.bufPrint(&bytes_name, "item-{d:0>4}.txt", .{i});
            var wide_name: [32]u16 = undefined;
            const n = try std.unicode.utf8ToUtf16Le(&wide_name, utf8_name);
            try std.testing.expect((try fs.lookup(root_dir, wide_name[0..n])) != null);
        }
        var on_disk: [1024]u8 = undefined;
        try fs.readRecord(first_file, &on_disk);
        const attr = (try r.find(&on_disk, 0x30, &.{})).?;
        try std.testing.expectEqual(@as(u8, 0), (try r.value(attr.bytes))[65]);
        const start: usize = @intCast(partition.start_bytes);
        try std.testing.expectEqual(ids.ntfs_serial, get(u64, bytes[start..], 72));
        const backup: usize = @intCast(partition.start_bytes + partition.size_bytes - 512);
        try std.testing.expectEqual(ids.ntfs_serial, get(u64, bytes[backup..], 72));
        const upcase_start: usize = @intCast(partition.start_bytes + fs.upcase_extent.lcn * 4096);
        var upcase_sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[upcase_start..][0..131072], &upcase_sha, .{});
        try std.testing.expectEqualStrings(unicode.table_sha256, &std.fmt.bytesToHex(upcase_sha, .lower));
        try fs.readRecord(10, &on_disk);
        const upcase_info = (try r.find(&on_disk, 0x80, u("$Info"))).?;
        const info_value = try r.value(upcase_info.bytes);
        try std.testing.expectEqual(@as(usize, 32), info_value.len);
        try std.testing.expectEqual(@as(u32, 32), get(u32, info_value, 0));
        try std.testing.expectEqual(upcaseChecksum(bytes[upcase_start..][0..131072]), get(u64, info_value, 8));
        // Independently extracted from the pinned mkntfs control image.
        try std.testing.expectEqual(@as(u64, 0xdadc7e776b1b690c), get(u64, info_value, 8));
        try fs.readRecord(9, &on_disk);
        const sds_attr = (try r.find(&on_disk, 0x80, u("$SDS"))).?;
        try std.testing.expectEqual(@as(u64, 0x40090), get(u64, sds_attr.bytes, 48));
        try std.testing.expectEqual(@as(u64, 0x40090), get(u64, sds_attr.bytes, 56));
        const sdh_attr = (try r.find(&on_disk, 0x90, u("$SDH"))).?;
        try std.testing.expectEqual(@as(u32, 0x00490049), get(u32, try r.value(sdh_attr.bytes), 76));
        try fs.readRecord(3, &on_disk);
        const volume = (try r.find(&on_disk, 0x70, &.{})).?;
        try std.testing.expectEqual(@as(u16, 0), get(u16, try r.value(volume.bytes), 10) & 1);
        try std.testing.expectError(error.InvalidArgument, fs.writeFile(nested, u("after-finish"), small, .{}));
    }
    try std.testing.expectEqual(@as(usize, 0), tracked.current);
    try std.testing.expect(tracked.peak <= 4 * 1024 * 1024);
}

test {
    _ = @import("mft_cache_tests.zig");
    _ = @import("index_cache_tests.zig");
    _ = @import("ntfs_index_cache_tests.zig");
}
