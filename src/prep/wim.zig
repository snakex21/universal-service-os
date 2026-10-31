//! Bounded WIM resources, selected-image lookup and streaming SHA-1.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Disk-layout references: wimlib v1.14.5 header.h/resource.h/blob_table.c
//! (Eric Biggers and contributors, LGPL-2.1-or-later), public WIM format.
//! This is a Zig implementation; no foreign library is linked.
const std = @import("std");
const platform = @import("platform.zig");
const codec = @import("wim_codec.zig");
pub const Input = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) platform.Error!void,
    profiler: ?*platform.profiling.Profiler = null,
    pub fn read(self: Input, offset: u64, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset) return error.WimBounds;
        if (out.len != 0) try self.read_fn(self.context, offset, out);
    }
};
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
pub const Descriptor = struct {
    stored: u64,
    offset: u64,
    size: u64,
    flags: u8,
    pub fn parse(raw: *const [24]u8, file_size: u64) !Descriptor {
        const result: Descriptor = .{
            .stored = get(u64, raw, 0) & 0x00ffffffffffffff,
            .flags = raw[7],
            .offset = get(u64, raw, 8),
            .size = get(u64, raw, 16),
        };
        if (result.flags & 0x10 != 0) return error.UnsupportedSolid;
        if (result.flags & 0x08 != 0) return error.UnsupportedSplitWim;
        if (result.flags & ~@as(u8, 0x07) != 0) return error.UnsupportedResourceFlags;
        if (result.offset > file_size or result.stored > file_size - result.offset) return error.WimBounds;
        if (result.stored != 0 and result.offset < 208) return error.CorruptWim;
        if (result.flags & 4 == 0 and result.stored != result.size) return error.CorruptWim;
        if (result.size != 0 and result.stored == 0) return error.CorruptWim;
        return result;
    }
};
pub const Header = struct {
    version: u32,
    flags: u32,
    chunk_size: u32,
    compression: ?codec.Kind,
    images: u32,
    lookup: Descriptor,
    xml: Descriptor,
    integrity: Descriptor,
    pub fn read(input: Input) !Header {
        var raw: [208]u8 = undefined;
        try input.read(0, &raw);
        if (!std.mem.eql(u8, raw[0..8], "MSWIM\x00\x00\x00") or get(u32, &raw, 8) != 208) return error.UnsupportedWimHeader;
        const version = get(u32, &raw, 12);
        if (version != 0x10d00 and version != 0xe00) return error.UnsupportedWimVersion;
        const flags = get(u32, &raw, 16);
        if (flags & 0x40 != 0) return error.IncompleteWim;
        if (get(u16, &raw, 40) != 1 or get(u16, &raw, 42) != 1 or flags & 8 != 0) return error.UnsupportedSplitWim;
        const kinds = flags & 0x000e0000;
        const kind: ?codec.Kind = if (kinds == 0) null else if (kinds == 0x20000) .xpress else if (kinds == 0x40000) .lzx else if (kinds == 0x80000) .lzms else return error.UnsupportedCompression;
        if ((flags & 2 != 0) != (kind != null)) return error.CorruptWim;
        const chunk_size = get(u32, &raw, 20);
        if (kind) |k| {
            _ = try codec.memoryEstimate(k, chunk_size);
        } else if (chunk_size != 0) return error.CorruptWim;
        const images = get(u32, &raw, 44);
        if (images == 0 or images > 64) return error.UnsupportedImageCount;
        return .{
            .version = version,
            .flags = flags,
            .compression = kind,
            .chunk_size = chunk_size,
            .images = images,
            .lookup = try Descriptor.parse(raw[48..72], input.size),
            .xml = try Descriptor.parse(raw[72..96], input.size),
            .integrity = try Descriptor.parse(raw[124..148], input.size),
        };
    }
};

/// One chunk cache. It is never sized by the resource or file length.
/// Lookup and image metadata can be much larger than this cache.
pub const Resource = struct {
    input: Input,
    descriptor: Descriptor,
    allocator: std.mem.Allocator,
    compression: ?codec.Kind,
    chunk_size: u32,
    output: []u8,
    compressed: []u8,
    table_cache: []u8,
    table_cache_at: u64 = std.math.maxInt(u64),
    table_cache_size: usize = 0,
    table_reads: u64 = 0,
    cached_chunk: u64 = std.math.maxInt(u64),
    cached_size: usize = 0,
    loading_chunk: u64 = 0,
    hash: ?[20]u8 = null,
    sha: std.crypto.hash.Sha1 = std.crypto.hash.Sha1.init(.{}),
    sequential: u64 = 0,
    verified: bool = false,
    hash_mismatch: bool = false,
    progress: ?platform.Progress = null,

    pub fn init(allocator: std.mem.Allocator, input: Input, header: Header, descriptor: Descriptor, hash: ?[20]u8) !Resource {
        const chunk_size: u32 = if (descriptor.flags & 4 != 0) header.chunk_size else 32768;
        if (chunk_size == 0 or chunk_size > 128 * 1024) return error.UnsupportedChunkSize;
        const output = try allocator.alloc(u8, chunk_size);
        errdefer allocator.free(output);
        const compressed = try allocator.alloc(u8, if (descriptor.flags & 4 != 0) chunk_size else 0);
        errdefer allocator.free(compressed);
        const table_size: u64 = if (descriptor.flags & 4 != 0 and descriptor.size != 0)
            std.math.mul(u64, (descriptor.size - 1) / chunk_size, if (descriptor.size > std.math.maxInt(u32)) 8 else 4) catch return error.WimBounds
        else 0;
        if (table_size > descriptor.stored) return error.CorruptWim;
        const table_cache = try allocator.alloc(u8, @intCast(@min(table_size, 64 * 1024)));
        return .{ .input = input, .descriptor = descriptor, .allocator = allocator, .compression = header.compression, .chunk_size = chunk_size, .output = output, .compressed = compressed, .table_cache = table_cache, .hash = hash };
    }
    pub fn deinit(self: *Resource) void {
        self.allocator.free(self.output);
        self.allocator.free(self.compressed);
        self.allocator.free(self.table_cache);
        self.* = undefined;
    }
    fn tableEntry(self: *Resource, number: u64, entry_size: u64, table_size: u64) !u64 {
        const at = std.math.mul(u64, number, entry_size) catch return error.WimBounds;
        if ((entry_size != 4 and entry_size != 8) or at > table_size or entry_size > table_size - at or self.table_cache.len == 0) return error.CorruptWim;
        if (self.table_cache_at == std.math.maxInt(u64) or at < self.table_cache_at or
            at - self.table_cache_at > self.table_cache_size or entry_size > self.table_cache_size - (at - self.table_cache_at))
        {
            // Keep the offset window independent of the compressed data cache.
            // Alternating table/data reads must not reread one offset per chunk.
            const window = at / self.table_cache.len * self.table_cache.len;
            const count: usize = @intCast(@min(self.table_cache.len, table_size - window));
            self.table_cache_at = std.math.maxInt(u64);
            self.table_cache_size = 0;
            const absolute = std.math.add(u64, self.descriptor.offset, window) catch return error.WimBounds;
            try self.input.read(absolute, self.table_cache[0..count]);
            self.table_reads +|= 1;
            self.table_cache_at = window;
            self.table_cache_size = count;
        }
        const within: usize = @intCast(at - self.table_cache_at);
        return if (entry_size == 4) get(u32, self.table_cache, within) else get(u64, self.table_cache, within);
    }
    fn chunk(self: *Resource, number: u64) ![]const u8 {
        self.loading_chunk = number;
        if (number == self.cached_chunk) return self.output[0..self.cached_size];
        const start = std.math.mul(u64, number, self.chunk_size) catch return error.WimBounds;
        if (start >= self.descriptor.size) return error.WimBounds;
        const usize_: usize = @intCast(@min(self.chunk_size, self.descriptor.size - start));
        if (self.descriptor.flags & 4 == 0) {
            try self.input.read(self.descriptor.offset + start, self.output[0..usize_]);
        } else {
            const kind = self.compression orelse return error.CorruptWim;
            const count = 1 + (self.descriptor.size - 1) / self.chunk_size;
            const entry_size: u64 = if (self.descriptor.size > std.math.maxInt(u32)) 8 else 4;
            const table_size = std.math.mul(u64, count - 1, entry_size) catch return error.WimBounds;
            if (table_size > self.descriptor.stored) return error.CorruptWim;
            const data_size = self.descriptor.stored - table_size;
            const begin = if (number == 0) 0 else try self.tableEntry(number - 1, entry_size, table_size);
            const end = if (number + 1 == count) data_size else try self.tableEntry(number, entry_size, table_size);
            if (begin >= end or end > data_size or end - begin > usize_) return error.CorruptWim;
            const stored: usize = @intCast(end - begin);
            if (stored == usize_) {
                try self.input.read(self.descriptor.offset + table_size + begin, self.output[0..usize_]);
            } else {
                try self.input.read(self.descriptor.offset + table_size + begin, self.compressed[0..stored]);
                const timing = platform.measure(self.input.profiler, .decode);
                defer platform.measured(self.input.profiler, timing);
                try codec.decode(kind, self.compressed[0..stored], self.output[0..usize_], self.allocator);
            }
        }
        self.cached_chunk = number;
        self.cached_size = usize_;
        return self.output[0..usize_];
    }
    pub fn read(self: *Resource, offset: u64, out: []u8) !void {
        if (offset > self.descriptor.size or out.len > self.descriptor.size - offset) return error.WimBounds;
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            const data = try self.chunk(at / self.chunk_size);
            const within: usize = @intCast(at % self.chunk_size);
            const n = @min(out.len - done, data.len - within);
            @memcpy(out[done..][0..n], data[within..][0..n]);
            done += n;
        }
    }
    /// Sequential file writes check their SHA before returning the final bytes
    /// to the NTFS writer. A mismatch can never publish a clean volume.
    pub fn readSequential(self: *Resource, offset: u64, out: []u8) !void {
        if (offset != self.sequential or self.verified) return error.NonSequentialWimRead;
        try self.read(offset, out);
        self.hashUpdate(out);
        self.sequential += out.len;
        if (self.sequential == self.descriptor.size) try self.finishHash();
        self.reportProgress();
    }
    fn reportProgress(self: *Resource) void {
        if (self.progress) |sink| sink.report(.{ .current = self.sequential, .total = self.descriptor.size, .bytes = self.sequential, .resources = 0 });
    }
    fn hashUpdate(self: *Resource, bytes: []const u8) void {
        const timing = platform.measure(self.input.profiler, .sha);
        defer platform.measured(self.input.profiler, timing);
        self.sha.update(bytes);
    }
    fn finishHash(self: *Resource) !void {
        const timing = platform.measure(self.input.profiler, .sha);
        defer platform.measured(self.input.profiler, timing);
        if (self.hash) |expected| {
            const actual = self.sha.finalResult();
            if (!std.mem.eql(u8, &actual, &expected)) {
                self.hash_mismatch = true;
                return error.WimHashMismatch;
            }
        }
        self.verified = true;
    }
    pub fn verify(self: *Resource) !void {
        self.sha = std.crypto.hash.Sha1.init(.{});
        self.sequential = 0;
        self.verified = false;
        var number: u64 = 0;
        while (self.sequential < self.descriptor.size) : (number += 1) {
            const data = try self.chunk(number);
            self.hashUpdate(data);
            self.sequential += data.len;
            if (self.sequential != self.descriptor.size) self.reportProgress();
        }
        try self.finishHash();
        self.reportProgress();
    }
    pub fn fileRead(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *Resource = @ptrCast(@alignCast(ctx));
        self.readSequential(offset, out) catch return error.Corrupt;
    }
};

pub const Entry = struct { descriptor: Descriptor, part: u16, references: u32, sha1: [20]u8 };
const Index = struct { hash: [20]u8, number: u32 };
pub const Archive = struct {
    input: Input,
    allocator: std.mem.Allocator,
    header: Header,
    table: Resource,
    index: []Index,
    metadata: [64]Entry = undefined,
    metadata_count: usize = 0,
    selected: u32,
    resource_count: u64,
    hashes_verified: u64 = 0,
    failed_chunk: u64 = 0,
    identical_duplicates_verified: u64 = 0,
    verification_bytes: u64 = 0,

    pub fn open(allocator: std.mem.Allocator, input: Input, selected: u32) !Archive {
        const header = try Header.read(input);
        if (selected == 0 or selected > header.images) return error.InvalidImageIndex;
        if (header.lookup.size == 0 or header.lookup.size % 50 != 0) return error.CorruptLookupTable;
        const entries = header.lookup.size / 50;
        if (entries > 131072) return error.WimIndexBudgetExceeded;
        var self: Archive = .{ .input = input, .allocator = allocator, .header = header, .table = try Resource.init(allocator, input, header, header.lookup, null), .index = &.{}, .selected = selected, .resource_count = entries };
        errdefer self.table.deinit();
        self.index = try allocator.alloc(Index, @intCast(entries));
        errdefer allocator.free(self.index);
        var data_count: usize = 0;
        for (0..@as(usize, @intCast(entries))) |i| {
            const item = try self.entry(@intCast(i));
            self.verification_bytes = std.math.add(u64, self.verification_bytes, item.descriptor.size) catch return error.WimBounds;
            if (item.part != 1) return error.UnsupportedSplitWim;
            if (item.references == 0 or std.mem.allEqual(u8, &item.sha1, 0)) return error.CorruptLookupTable;
            if (item.descriptor.flags & 2 != 0) {
                if (self.metadata_count >= header.images) return error.CorruptImageCount;
                self.metadata[self.metadata_count] = item;
                self.metadata_count += 1;
            } else {
                self.index[data_count] = .{ .hash = item.sha1, .number = @intCast(i) };
                data_count += 1;
            }
        }
        if (self.metadata_count != header.images) return error.CorruptImageCount;
        std.mem.sort(Index, self.index[0..data_count], {}, struct {
            fn less(_: void, a: Index, b: Index) bool {
                return std.mem.order(u8, &a.hash, &b.hash) == .lt;
            }
        }.less);
        if (data_count > 1) for (1..data_count) |i| {
            if (!std.mem.eql(u8, &self.index[i - 1].hash, &self.index[i].hash)) continue;
            const first = try self.entry(self.index[i - 1].number);
            const second = try self.entry(self.index[i].number);
            if (first.descriptor.size != second.descriptor.size) return error.ConflictingResourceHash;
            // A shared claimed hash is insufficient: independently decode
            // and SHA1-verify every occurrence before accepting duplicates.
            try self.verifyEntry(first);
            try self.verifyEntry(second);
            self.identical_duplicates_verified += 1;
        };
        // Keep the original allocation length for deallocation; a sentinel
        // marks unused metadata slots at the tail of the in-memory index.
        for (self.index[data_count..]) |*slot| slot.* = .{ .hash = @splat(0xff), .number = std.math.maxInt(u32) };
        return self;
    }
    pub fn deinit(self: *Archive) void {
        self.table.deinit();
        self.allocator.free(self.index);
        self.* = undefined;
    }
    pub fn entry(self: *Archive, number: u32) !Entry {
        if (number >= self.resource_count) return error.WimBounds;
        var raw: [50]u8 = undefined;
        try self.table.read(@as(u64, number) * 50, &raw);
        return .{ .descriptor = try Descriptor.parse(raw[0..24], self.input.size), .part = get(u16, &raw, 24), .references = get(u32, &raw, 26), .sha1 = raw[30..50].* };
    }
    pub fn find(self: *Archive, hash: [20]u8) !Entry {
        var low: usize = 0;
        var high = self.index.len - self.metadata_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, &hash, &self.index[middle].hash)) {
                .lt => high = middle,
                .gt => low = middle + 1,
                .eq => return self.entry(self.index[middle].number),
            }
        }
        return error.MissingWimResource;
    }
    pub fn openEntry(self: *Archive, item: Entry) !Resource {
        return Resource.init(self.allocator, self.input, self.header, item.descriptor, item.sha1);
    }
    fn verifyEntry(self: *Archive, item: Entry) !void {
        var resource = try self.openEntry(item);
        defer resource.deinit();
        try resource.verify();
    }
    pub fn openMetadata(self: *Archive) !Resource {
        return self.openEntry(self.metadata[self.selected - 1]);
    }
    /// Optional raw integrity table covers [208, end-of-lookup). XML and
    /// lookup headers have no individual blob SHA1 in the WIM format.
    pub fn verifyIntegrity(self: *Archive) !bool {
        return self.verifyIntegrityWithProgress(null);
    }
    pub fn verifyIntegrityWithProgress(self: *Archive, progress: ?platform.Progress) !bool {
        const descriptor = self.header.integrity;
        if (descriptor.size == 0) return false;
        var table = try Resource.init(self.allocator, self.input, self.header, descriptor, null);
        defer table.deinit();
        var head: [12]u8 = undefined;
        try table.read(0, &head);
        const size = get(u32, &head, 0);
        const count = get(u32, &head, 4);
        const block_size = get(u32, &head, 8);
        const end = self.header.lookup.offset + self.header.lookup.stored;
        if (end < 208 or descriptor.offset < end or block_size == 0 or size != descriptor.size or @as(u64, count) * 20 + 12 != size or count != (end - 208 + block_size - 1) / block_size) return error.CorruptIntegrityTable;
        const buffer = try self.allocator.alloc(u8, 32768);
        defer self.allocator.free(buffer);
        var cursor: u64 = 208;
        for (0..count) |i| {
            var sha = std.crypto.hash.Sha1.init(.{});
            var left: u64 = @min(@as(u64, block_size), end - cursor);
            while (left != 0) {
                const n: usize = @intCast(@min(left, buffer.len));
                try self.input.read(cursor, buffer[0..n]);
                {
                    const timing = platform.measure(self.input.profiler, .sha);
                    defer platform.measured(self.input.profiler, timing);
                    sha.update(buffer[0..n]);
                }
                cursor += n;
                left -= n;
                if (left != 0) if (progress) |sink| sink.report(.{ .current = cursor - 208, .total = end - 208, .bytes = cursor - 208, .resources = i });
            }
            var expected: [20]u8 = undefined;
            try table.read(12 + @as(u64, i) * 20, &expected);
            const actual = blk: {
                const timing = platform.measure(self.input.profiler, .sha);
                defer platform.measured(self.input.profiler, timing);
                break :blk sha.finalResult();
            };
            if (!std.mem.eql(u8, &actual, &expected)) return error.WimIntegrityMismatch;
            if (progress) |sink| sink.report(.{ .current = cursor - 208, .total = end - 208, .bytes = cursor - 208, .resources = i + 1 });
        }
        return true;
    }
    /// The entire archive's blob SHA-1 values are checked, including images
    /// not selected for apply, without retaining decompressed resources.
    pub fn verifyAll(self: *Archive) !void {
        try self.verifyAllWithProgress(null);
    }
    pub fn verifyAllWithProgress(self: *Archive, progress: ?platform.Progress) !void {
        const Forward = struct {
            sink: ?platform.Progress,
            total: u64,
            bytes: u64 = 0,
            resources: u64 = 0,
            fn report(ctx: *anyopaque, update: platform.ProgressUpdate) void {
                const state: *@This() = @ptrCast(@alignCast(ctx));
                if (state.sink) |sink| sink.report(.{ .current = state.bytes + update.current, .total = state.total, .bytes = state.bytes + update.bytes, .resources = state.resources });
            }
            fn emit(self_: *@This()) void {
                if (self_.sink) |sink| sink.report(.{ .current = self_.bytes, .total = self_.total, .bytes = self_.bytes, .resources = self_.resources });
            }
        };
        var forward: Forward = .{ .sink = progress, .total = self.verification_bytes };
        forward.emit();
        var number: u32 = 0;
        while (number < self.resource_count) : (number += 1) {
            var resource = try self.openEntry(try self.entry(number));
            defer resource.deinit();
            if (progress != null) resource.progress = .{ .context = &forward, .report_fn = Forward.report };
            resource.verify() catch |err| {
                self.failed_chunk = resource.loading_chunk;
                return err;
            };
            self.hashes_verified += 1;
            forward.bytes += resource.descriptor.size;
            forward.resources += 1;
            forward.emit();
        }
    }
};

const Memory = struct {
    bytes: []u8,
    calls: usize = 0,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn input(self: *Memory) Input {
        return .{ .context = self, .size = self.bytes.len, .read_fn = read };
    }
};
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn testHeader(bytes: []u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..8], "MSWIM\x00\x00\x00");
    put(u32, bytes, 8, 208);
    put(u32, bytes, 12, 0x10d00);
    put(u16, bytes, 40, 1);
    put(u16, bytes, 42, 1);
    put(u32, bytes, 44, 1);
}
fn testDescriptor(bytes: []u8, at: usize, stored: u64, offset: u64, size: u64, flags: u8) void {
    put(u64, bytes, at, stored | (@as(u64, flags) << 56));
    put(u64, bytes, at + 8, offset);
    put(u64, bytes, at + 16, size);
}
test "WIM header rejects split, invalid image selection, solid and overflow before target IO" {
    var bytes: [512]u8 = undefined;
    testHeader(&bytes);
    var memory: Memory = .{ .bytes = &bytes };
    _ = try Header.read(memory.input());
    put(u16, &bytes, 42, 2);
    try std.testing.expectError(error.UnsupportedSplitWim, Header.read(memory.input()));
    put(u16, &bytes, 42, 1);
    put(u32, &bytes, 16, 0x40);
    try std.testing.expectError(error.IncompleteWim, Header.read(memory.input()));
    put(u32, &bytes, 16, 0);
    try std.testing.expectError(error.InvalidImageIndex, Archive.open(std.testing.allocator, memory.input(), 2));
    testDescriptor(&bytes, 48, 1, 208, 1, 0x10);
    try std.testing.expectError(error.UnsupportedSolid, Header.read(memory.input()));
    testDescriptor(&bytes, 48, 100, std.math.maxInt(u64) - 20, 100, 0);
    try std.testing.expectError(error.WimBounds, Header.read(memory.input()));
}
test "streamed raw WIM resource checks exact SHA1 and refuses corrupt final bytes" {
    const data = try std.testing.allocator.alloc(u8, 208 + 100003);
    defer std.testing.allocator.free(data);
    testHeader(data);
    for (data[208..], 0..) |*byte, i| byte.* = @truncate(i *% 13);
    var memory: Memory = .{ .bytes = data };
    const header = try Header.read(memory.input());
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data[208..], &hash, .{});
    var resource = try Resource.init(std.testing.allocator, memory.input(), header, .{ .offset = 208, .stored = 100003, .size = 100003, .flags = 0 }, hash);
    defer resource.deinit();
    try resource.verify();
    try std.testing.expect(resource.verified);
    resource.verified = false;
    resource.sequential = 0;
    resource.sha = std.crypto.hash.Sha1.init(.{});
    data[data.len - 1] ^= 1;
    resource.cached_chunk = std.math.maxInt(u64);
    var out: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset + out.len < 100003) : (offset += out.len) try resource.readSequential(offset, &out);
    try std.testing.expectError(error.WimHashMismatch, resource.readSequential(offset, out[0..@intCast(100003 - offset)]));
    try std.testing.expect(resource.hash_mismatch);
    try std.testing.expect(!resource.verified);
}
test "compressed resource streams uncompressed stored chunks and checks 64-bit table bounds" {
    var bytes: [208 + 4 + 32768 + 5]u8 = undefined;
    testHeader(&bytes);
    put(u32, &bytes, 16, 0x20002);
    put(u32, &bytes, 20, 32768);
    put(u32, &bytes, 208, 32768);
    @memset(bytes[212..], 0x39);
    var memory: Memory = .{ .bytes = &bytes };
    const header = try Header.read(memory.input());
    var resource = try Resource.init(std.testing.allocator, memory.input(), header, .{ .offset = 208, .stored = 4 + 32768 + 5, .size = 32768 + 5, .flags = 4 }, null);
    defer resource.deinit();
    try resource.verify();
    var cross: [12]u8 = undefined;
    try resource.read(32760, &cross);
    try std.testing.expect(std.mem.allEqual(u8, &cross, 0x39));
    put(u32, &bytes, 208, 0xffffffff);
    resource.cached_chunk = std.math.maxInt(u64);
    resource.table_cache_at = std.math.maxInt(u64); // Injected source mutation bypasses the immutable-source contract.
    try std.testing.expectError(error.CorruptWim, resource.read(0, &cross));
}
test "lookup metadata and blob index stream separately and resolve SHA1" {
    var bytes: [1024]u8 = undefined;
    testHeader(&bytes);
    testDescriptor(&bytes, 48, 100, 208, 100, 2);
    testDescriptor(&bytes, 208, 4, 800, 4, 2);
    put(u16, &bytes, 232, 1);
    put(u32, &bytes, 234, 1);
    @memcpy(bytes[800..804], "meta");
    var meta_sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("meta", &meta_sha, .{});
    @memcpy(bytes[238..258], &meta_sha);
    testDescriptor(&bytes, 258, 7, 804, 7, 0);
    put(u16, &bytes, 282, 1);
    put(u32, &bytes, 284, 1);
    @memcpy(bytes[804..811], "payload");
    var data_sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("payload", &data_sha, .{});
    @memcpy(bytes[288..308], &data_sha);
    var memory: Memory = .{ .bytes = &bytes };
    var archive = try Archive.open(std.testing.allocator, memory.input(), 1);
    defer archive.deinit();
    try std.testing.expectEqual(@as(u64, 7), (try archive.find(data_sha)).descriptor.size);
    var observer: ProgressFixture = .{};
    try archive.verifyAllWithProgress(observer.sink());
    try std.testing.expect(observer.monotonic);
    try std.testing.expectEqual(@as(u64, 11), observer.previous.total);
    try std.testing.expectEqual(@as(u64, 11), observer.previous.bytes);
    try std.testing.expectEqual(@as(u64, 2), observer.previous.resources);
    try std.testing.expectEqual(@as(u64, 2), archive.hashes_verified);
    bytes[810] ^= 1;
    try std.testing.expectError(error.WimHashMismatch, archive.verifyAll());
}

test "identical duplicate blobs require size and verified payload; conflicting duplicates refuse" {
    var bytes: [1024]u8 = undefined;
    testHeader(&bytes);
    testDescriptor(&bytes, 48, 150, 208, 150, 2);
    testDescriptor(&bytes, 208, 4, 800, 4, 2);
    put(u16, &bytes, 232, 1);
    put(u32, &bytes, 234, 1);
    @memcpy(bytes[800..804], "meta");
    std.crypto.hash.Sha1.hash("meta", bytes[238..258], .{});
    testDescriptor(&bytes, 258, 7, 804, 7, 0);
    put(u16, &bytes, 282, 1);
    put(u32, &bytes, 284, 1);
    @memcpy(bytes[804..811], "payload");
    std.crypto.hash.Sha1.hash("payload", bytes[288..308], .{});
    @memcpy(bytes[308..358], bytes[258..308]);
    var memory: Memory = .{ .bytes = &bytes };
    {
        var archive = try Archive.open(std.testing.allocator, memory.input(), 1);
        defer archive.deinit();
        try std.testing.expectEqual(@as(u64, 1), archive.identical_duplicates_verified);
        try archive.verifyAll();
    }
    testDescriptor(&bytes, 308, 7, 820, 7, 0);
    @memcpy(bytes[820..827], "corrupt");
    try std.testing.expectError(error.WimHashMismatch, Archive.open(std.testing.allocator, memory.input(), 1));
    testDescriptor(&bytes, 308, 6, 820, 6, 0);
    try std.testing.expectError(error.ConflictingResourceHash, Archive.open(std.testing.allocator, memory.input(), 1));
}
test "every duplicate occurrence is verified even when hashes and lengths all agree" {
    var bytes: [1024]u8 = undefined;
    testHeader(&bytes);
    testDescriptor(&bytes, 48, 200, 208, 200, 2);
    testDescriptor(&bytes, 208, 4, 800, 4, 2);
    put(u16, &bytes, 232, 1);
    put(u32, &bytes, 234, 1);
    @memcpy(bytes[800..804], "meta");
    std.crypto.hash.Sha1.hash("meta", bytes[238..258], .{});
    for (0..3) |i| {
        const at = 258 + i * 50;
        const payload = 820 + i * 10;
        testDescriptor(&bytes, at, 7, payload, 7, 0);
        put(u16, &bytes, at + 24, 1);
        put(u32, &bytes, at + 26, 1);
        @memcpy(bytes[payload..][0..7], "payload");
        std.crypto.hash.Sha1.hash("payload", bytes[at + 30 ..][0..20], .{});
    }
    var memory: Memory = .{ .bytes = &bytes };
    {
        var archive = try Archive.open(std.testing.allocator, memory.input(), 1);
        defer archive.deinit();
        try std.testing.expectEqual(@as(u64, 2), archive.identical_duplicates_verified);
        try archive.verifyAll();
        try std.testing.expectEqual(@as(u64, 4), archive.hashes_verified);
    }
    // Reject each possible bad copy, not just whichever binary lookup finds.
    for (0..3) |i| {
        const at = 820 + i * 10;
        bytes[at] ^= 1;
        try std.testing.expectError(error.WimHashMismatch, Archive.open(std.testing.allocator, memory.input(), 1));
        bytes[at] ^= 1;
    }
}
test "optional integrity table hashes raw WIM ranges and rejects damaged table or data" {
    var bytes: [2048]u8 = undefined;
    testHeader(&bytes);
    testDescriptor(&bytes, 48, 50, 208, 50, 2);
    testDescriptor(&bytes, 208, 4, 800, 4, 2);
    put(u16, &bytes, 232, 1);
    put(u32, &bytes, 234, 1);
    @memcpy(bytes[800..804], "meta");
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash("meta", &hash, .{});
    @memcpy(bytes[238..258], &hash);
    // Covered interval is exactly [208,258), in three17-byte pieces.
    testDescriptor(&bytes, 124, 72, 1024, 72, 0);
    put(u32, &bytes, 1024, 72);
    put(u32, &bytes, 1028, 3);
    put(u32, &bytes, 1032, 17);
    for (0..3) |i| {
        const begin = 208 + i * 17;
        const end = @min(begin + 17, 258);
        std.crypto.hash.Sha1.hash(bytes[begin..end], &hash, .{});
        @memcpy(bytes[1036 + i * 20 ..][0..20], &hash);
    }
    var memory: Memory = .{ .bytes = &bytes };
    var archive = try Archive.open(std.testing.allocator, memory.input(), 1);
    defer archive.deinit();
    try std.testing.expect(try archive.verifyIntegrity());
    const Capture = struct {
        calls: usize = 0,
        last: platform.ProgressUpdate = .{ .current = 0, .total = 0, .bytes = 0, .resources = 0 },
        fn report(ctx: *anyopaque, update: platform.ProgressUpdate) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(update.current >= self.last.current);
            self.calls += 1; self.last = update;
        }
    };
    var captured: Capture = .{};
    try std.testing.expect(try archive.verifyIntegrityWithProgress(.{ .context = &captured, .report_fn = Capture.report }));
    try std.testing.expectEqual(@as(usize, 3), captured.calls);
    try std.testing.expectEqual(@as(u64, 50), captured.last.bytes);
    try std.testing.expectEqual(@as(u64, 3), captured.last.resources);
    bytes[208] ^= 1;
    try std.testing.expectError(error.WimIntegrityMismatch, archive.verifyIntegrity());
    bytes[208] ^= 1;
    put(u32, &bytes, 1032, 0);
    try std.testing.expectError(error.CorruptIntegrityTable, archive.verifyIntegrity());
}

const OffsetTableFixture = struct {
    size: u64,
    table_calls: u64 = 0,
    data_calls: u64 = 0,
    fail_table: bool = false,
    fn entrySize(self: @This()) u64 { return if (self.size > std.math.maxInt(u32)) 8 else 4; }
    fn tableSize(self: @This()) u64 { return (self.size - 1) / 32768 * self.entrySize(); }
    fn descriptor(self: @This()) Descriptor { return .{ .offset = 208, .stored = self.tableSize() + self.size, .size = self.size, .flags = 4 }; }
    fn input(self: *@This()) Input { return .{ .context = self, .size = 208 + self.descriptor().stored, .read_fn = read }; }
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (at < 208 or at > self.input().size or out.len > self.input().size - at) return error.Bounds;
        const relative = at - 208;
        if (relative < self.tableSize()) {
            if (out.len > self.tableSize() - relative) return error.Bounds;
            self.table_calls += 1;
            if (self.fail_table) { @memset(out, 0xff); return error.Io; }
            for (out, 0..) |*v, i| {
                const cursor = relative + i;
                const value = (cursor / self.entrySize() + 1) * 32768;
                v.* = @truncate(value >> @as(u6, @intCast((cursor % self.entrySize()) * 8)));
            }
        } else {
            self.data_calls += 1;
            for (out, 0..) |*v, i| v.* = @truncate((relative - self.tableSize() + i) *% 13);
        }
    }
};
fn offsetFixtureHeader() !Header {
    var bytes: [208]u8 = undefined;
    testHeader(&bytes);
    put(u32, &bytes, 16, 0x20002);
    put(u32, &bytes, 20, 32768);
    var memory: Memory = .{ .bytes = &bytes };
    return Header.read(memory.input());
}

test "WIM offset table sequential pair lookups need one IO per64KiB window" {
    var source: OffsetTableFixture = .{ .size = 20000 * 32768 };
    var resource = try Resource.init(std.testing.allocator, source.input(), try offsetFixtureHeader(), source.descriptor(), null);
    defer resource.deinit();
    const entries = source.tableSize() / 4;
    for (0..@as(usize, @intCast(entries))) |i| {
        try std.testing.expectEqual((i + 1) * @as(u64, 32768), try resource.tableEntry(i, 4, source.tableSize()));
        // Each normal chunk requests both its preceding and following offset.
        try std.testing.expectEqual((i + 1) * @as(u64, 32768), try resource.tableEntry(i, 4, source.tableSize()));
    }
    try std.testing.expectEqual(@as(u64, 39998), 2 * entries);
    try std.testing.expectEqual(@as(u64, 2), source.table_calls);
    try std.testing.expectEqual(@as(u64, 2), resource.table_reads);
    try std.testing.expectEqual(@as(usize, 65536), resource.table_cache.len);
    try std.testing.expectEqual(@as(u64, 0), source.data_calls);
    std.debug.print("WIM_OFFSET_CACHE measured_requests={d} upstream_reads={d} cache_bytes={d}\n", .{ 2 * entries, source.table_calls, resource.table_cache.len });
}

test "WIM 64bit offset table seeks cross cache windows and preserve offsets beyond4GiB" {
    var source: OffsetTableFixture = .{ .size = 5 * 1024 * @as(u64, 1024 * 1024) + 31 };
    var resource = try Resource.init(std.testing.allocator, source.input(), try offsetFixtureHeader(), source.descriptor(), null);
    defer resource.deinit();
    for ([_]u64{ 0, 8191, 8192, 8193, source.tableSize() / 8 - 1, 1 }) |number|
        try std.testing.expectEqual((number + 1) * 32768, try resource.tableEntry(number, 8, source.tableSize()));
    try std.testing.expectEqual(@as(u64, 4), source.table_calls);
    var out: [64]u8 = undefined;
    const at = 4 * 1024 * @as(u64, 1024 * 1024) + 57;
    try resource.read(at, &out);
    for (out, 0..) |v, i| try std.testing.expectEqual(@as(u8, @truncate((at + i) *% 13)), v);
    try std.testing.expectEqual(@as(u64, 1), source.data_calls);
}

test "WIM offset cache preserves IO errors invalidates partial data and bounds entries" {
    var source: OffsetTableFixture = .{ .size = 20000 * 32768 };
    var resource = try Resource.init(std.testing.allocator, source.input(), try offsetFixtureHeader(), source.descriptor(), null);
    defer resource.deinit();
    _ = try resource.tableEntry(0, 4, source.tableSize());
    source.fail_table = true;
    try std.testing.expectError(error.Io, resource.tableEntry(16384, 4, source.tableSize()));
    try std.testing.expectEqual(@as(usize, 0), resource.table_cache_size);
    source.fail_table = false;
    try std.testing.expectEqual(@as(u64, 32768), try resource.tableEntry(0, 4, source.tableSize()));
    try std.testing.expectEqual(@as(u64, 3), source.table_calls);
    const calls = source.table_calls;
    try std.testing.expectError(error.CorruptWim, resource.tableEntry(source.tableSize() / 4, 4, source.tableSize()));
    try std.testing.expectError(error.WimBounds, resource.tableEntry(std.math.maxInt(u64), 8, source.tableSize()));
    try std.testing.expectEqual(calls, source.table_calls);
}

test "WIM chunk IO retains table window while random payload reads change source position" {
    var source: OffsetTableFixture = .{ .size = 4000 * 32768 };
    var resource = try Resource.init(std.testing.allocator, source.input(), try offsetFixtureHeader(), source.descriptor(), null);
    defer resource.deinit();
    var out: [91]u8 = undefined;
    for ([_]u64{ 0, 32768, 2000 * 32768 + 17, 500 * 32768, 3999 * 32768 }) |at| {
        try resource.read(at, &out);
        for (out, 0..) |v, i| try std.testing.expectEqual(@as(u8, @truncate((at + i) *% 13)), v);
    }
    try std.testing.expectEqual(@as(u64, 1), source.table_calls);
    try std.testing.expectEqual(@as(u64, 5), source.data_calls);
    try std.testing.expectEqual(@as(usize, 15996), resource.table_cache.len);
}

const ProgressFixture = struct {
    previous: platform.ProgressUpdate = .{ .current = 0, .total = 0, .bytes = 0, .resources = 0 },
    calls: usize = 0,
    monotonic: bool = true,
    fn report(ctx: *anyopaque, update: platform.ProgressUpdate) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.monotonic = self.monotonic and update.current >= self.previous.current and update.bytes >= self.previous.bytes and
            update.resources >= self.previous.resources and update.current <= update.total and update.current == update.bytes;
        self.previous = update;
        self.calls += 1;
    }
    fn sink(self: *@This()) platform.Progress { return .{ .context = self, .report_fn = report }; }
};

test "resource progress reports chunks without claiming a failed final SHA" {
    const bytes = try std.testing.allocator.alloc(u8, 208 + 70000);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x31);
    var source: Memory = .{ .bytes = bytes };
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes[208..], &hash, .{});
    var resource = try Resource.init(std.testing.allocator, source.input(), try offsetFixtureHeader(), .{ .offset = 208, .stored = 70000, .size = 70000, .flags = 0 }, hash);
    defer resource.deinit();
    var observer: ProgressFixture = .{};
    resource.progress = observer.sink();
    try resource.verify();
    try std.testing.expect(observer.monotonic);
    try std.testing.expectEqual(@as(usize, 3), observer.calls);
    try std.testing.expectEqual(@as(u64, 70000), observer.previous.bytes);
    observer = .{};
    bytes[bytes.len - 1] ^= 1;
    resource.cached_chunk = std.math.maxInt(u64);
    try std.testing.expectError(error.WimHashMismatch, resource.verify());
    try std.testing.expect(observer.monotonic);
    try std.testing.expectEqual(@as(usize, 2), observer.calls);
    try std.testing.expectEqual(@as(u64, 65536), observer.previous.bytes);
}
