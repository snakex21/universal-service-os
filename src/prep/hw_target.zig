//! SPDX-License-Identifier: GPL-3.0-or-later
//! Hardware (non-QEMU) target support for the MiniOS install workload.
//!
//! The QEMU gates require a target whose every byte is zero (a fresh image)
//! and a host-written token. On real hardware the USOS flow asks the one disk
//! question, writes the token to the chosen disk only, and the disk holds old
//! data. `VirtualBlank` restores the blank-disk contract without a full-disk
//! wipe:
//!
//! * reads of a 1 MiB chunk MiniOS never wrote return zeros (the writer sees
//!   exactly what it sees on a fresh image);
//! * the first write into a chunk zeroes the whole chunk on the device first
//!   (unless the write covers it completely), so stale bytes never survive
//!   next to new data;
//! * `fillRange` zeroes every untouched chunk of the regions Windows reads
//!   as metadata (ESP, MSR, the Windows volume up to the NTFS allocation
//!   high-water mark), making them byte-identical to a fresh-image run.
//!
//! Untouched chunks beyond the allocation high-water mark keep old bytes:
//! they are free clusters, which a fresh image would hold as zeros and which
//! NTFS never reads as metadata.
const std = @import("std");
const p = @import("platform.zig");

pub const chunk_bytes: u64 = 1024 * 1024;
const zero_bytes = 64 * 1024;

pub const VirtualBlank = struct {
    base: p.Disk,
    allocator: std.mem.Allocator,
    touched: []u64,
    zeros: []align(4096) u8,
    stats: Stats = .{},

    pub const Stats = struct { first_touch_zeroed: u64 = 0, full_chunk_writes: u64 = 0, virtual_zero_reads: u64 = 0, gap_chunks_zeroed: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, base: p.Disk) !VirtualBlank {
        const bytes = try base.bytes();
        const chunks = std.math.divCeil(u64, bytes, chunk_bytes) catch return error.Bounds;
        const words: usize = @intCast(std.math.divCeil(u64, chunks, 64) catch return error.Bounds);
        const touched = try allocator.alloc(u64, words);
        errdefer allocator.free(touched);
        @memset(touched, 0);
        const zeros = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), zero_bytes);
        @memset(zeros, 0);
        return .{ .base = base, .allocator = allocator, .touched = touched, .zeros = zeros };
    }
    pub fn deinit(self: *VirtualBlank) void {
        self.allocator.free(self.touched);
        self.allocator.free(self.zeros);
        self.* = undefined;
    }
    pub fn disk(self: *VirtualBlank) p.Disk {
        return .{ .context = self, .sector_bytes = self.base.sector_bytes, .sectors = self.base.sectors, .read_fn = read, .write_fn = write, .flush_fn = flush, .profiler = self.base.profiler };
    }
    pub fn isTouched(self: *const VirtualBlank, index: u64) bool {
        return self.touched[@intCast(index / 64)] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }
    fn mark(self: *VirtualBlank, index: u64) void {
        self.touched[@intCast(index / 64)] |= @as(u64, 1) << @intCast(index % 64);
    }
    fn chunkEnd(self: *const VirtualBlank, index: u64) !u64 {
        return @min((index + 1) * chunk_bytes, try self.base.bytes());
    }
    fn zeroChunk(self: *VirtualBlank, index: u64) p.Error!void {
        var at = index * chunk_bytes;
        const end = try self.chunkEnd(index);
        while (at < end) {
            const n: usize = @intCast(@min(end - at, self.zeros.len));
            try self.base.write(at, self.zeros[0..n]);
            at += n;
        }
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            const index = at / chunk_bytes;
            const end = try self.chunkEnd(index);
            var n: usize = @intCast(@min(out.len - done, end - at));
            // Merge consecutive chunks of the same state into one device read.
            if (self.isTouched(index)) {
                var next = index + 1;
                while (done + n < out.len and self.isTouched(next)) : (next += 1) n = @intCast(@min(out.len - done, (try self.chunkEnd(next)) - at));
                try self.base.read(at, out[done..][0..n]);
            } else {
                self.stats.virtual_zero_reads +|= 1;
                @memset(out[done..][0..n], 0);
            }
            done += n;
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        if (input.len == 0) return;
        const first = offset / chunk_bytes;
        const last = (offset + input.len - 1) / chunk_bytes;
        var index = first;
        while (index <= last) : (index += 1) {
            if (self.isTouched(index)) continue;
            const start = index * chunk_bytes;
            const end = try self.chunkEnd(index);
            if (offset <= start and offset + input.len >= end) {
                self.stats.full_chunk_writes +|= 1;
            } else {
                try self.zeroChunk(index);
                self.stats.first_touch_zeroed +|= 1;
            }
            self.mark(index);
        }
        try self.base.write(offset, input);
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        try self.base.flush();
    }
    /// Zeroes every untouched chunk overlapping [start, end) on the device.
    pub fn fillRange(self: *VirtualBlank, start: u64, end: u64) p.Error!void {
        if (end <= start) return;
        const last = (@min(end, try self.base.bytes()) - 1) / chunk_bytes;
        var index = start / chunk_bytes;
        while (index <= last) : (index += 1) {
            if (self.isTouched(index)) continue;
            try self.zeroChunk(index);
            self.mark(index);
            self.stats.gap_chunks_zeroed +|= 1;
        }
    }
};

/// Previous logs are kept: USOSPREP.LOG -> .1 -> .2 ... up to `keep` files.
/// Returns the rename plan (oldest first) for `keep` generations.
pub fn rotationName(buffer: []u8, generation: usize) ![]const u8 {
    if (generation == 0) return std.fmt.bufPrint(buffer, "\\USOSPREP.LOG", .{});
    return std.fmt.bufPrint(buffer, "\\USOSPREP.{d}.LOG", .{generation});
}

/// Hardware configuration (USOSPREP_HW_V1), written by the USOS menu.
pub const Hardware = struct {
    /// Disk question in MiniOS itself (the only one in this flow).
    build: [32]u8 = @splat(0),
    build_len: usize = 0,
    locale: [32]u8 = @splat(0),
    locale_len: usize = 0,
    unattend: bool = false,
    boot_entry: bool = true,

    pub fn buildId(self: *const Hardware) []const u8 {
        return self.build[0..self.build_len];
    }
    pub fn localeText(self: *const Hardware) []const u8 {
        return if (self.locale_len == 0) "en-US" else self.locale[0..self.locale_len];
    }
};

pub fn validBuildId(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
pub fn validLocale(value: []const u8) bool {
    if (value.len < 2 or value.len > 32) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

/// Fresh RFC 4122 v4 loader GUID derived (domain-separated) from the run's
/// validated entropy; it differs from every layout GUID by construction check.
pub fn loaderGuid(seed: [64]u8, avoid: []const [16]u8) ![16]u8 {
    var counter: u8 = 0;
    while (counter < 8) : (counter += 1) {
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&seed);
        hash.update("USOSPREP hardware loader GUID v1");
        hash.update(&.{counter});
        hash.final(&digest);
        var guid = digest[0..16].*;
        guid[7] = (guid[7] & 0x0f) | 0x40;
        guid[8] = (guid[8] & 0x3f) | 0x80;
        var clash = false;
        for (avoid) |other| clash = clash or std.mem.eql(u8, &guid, &other);
        if (!clash) return guid;
    }
    return error.EntropyUnavailable;
}

const Memory = struct {
    bytes: []u8,
    writes: usize = 0,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, at: u64, in: []const u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        @memcpy(self.bytes[@intCast(at)..][0..in.len], in);
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *Memory) p.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};

test "virtual blank hides stale bytes, zeroes partial first touches and fills gaps" {
    const a = std.testing.allocator;
    const raw = try a.alloc(u8, 8 * chunk_bytes + 512 * 3);
    defer a.free(raw);
    @memset(raw, 0xa5);
    var memory: Memory = .{ .bytes = raw };
    var blank = try VirtualBlank.init(a, memory.disk());
    defer blank.deinit();
    const d = blank.disk();
    var buf: [4096]u8 = undefined;
    try d.read(chunk_bytes - 2048, &buf);
    try std.testing.expect(std.mem.allEqual(u8, &buf, 0));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
    // Partial write into chunk 2: the rest of chunk 2 becomes zero on the device.
    try d.write(2 * chunk_bytes + 4096, "hello");
    try std.testing.expectEqualStrings("hello", raw[2 * chunk_bytes + 4096 ..][0..5]);
    try std.testing.expect(std.mem.allEqual(u8, raw[2 * chunk_bytes .. 2 * chunk_bytes + 4096], 0));
    try std.testing.expect(std.mem.allEqual(u8, raw[2 * chunk_bytes + 4101 .. 3 * chunk_bytes], 0));
    try std.testing.expectEqual(@as(u8, 0xa5), raw[3 * chunk_bytes]);
    // Reads spanning touched and untouched chunks.
    var span: [8]u8 = undefined;
    try d.read(3 * chunk_bytes - 4, &span);
    try std.testing.expect(std.mem.allEqual(u8, &span, 0));
    // A full-chunk write is not pre-zeroed.
    const full = try a.alloc(u8, chunk_bytes);
    defer a.free(full);
    @memset(full, 0x11);
    const before = memory.writes;
    try d.write(4 * chunk_bytes, full);
    try std.testing.expectEqual(before + 1, memory.writes);
    try std.testing.expectEqual(@as(u64, 1), blank.stats.full_chunk_writes);
    // The trailing partial chunk is handled.
    try d.write(8 * chunk_bytes, "end");
    try std.testing.expect(std.mem.allEqual(u8, raw[8 * chunk_bytes + 3 ..], 0));
    try blank.fillRange(0, 4 * chunk_bytes);
    try std.testing.expect(std.mem.allEqual(u8, raw[0 .. 2 * chunk_bytes], 0));
    try std.testing.expectEqual(@as(u8, 0xa5), raw[5 * chunk_bytes]);
    try std.testing.expectEqual(@as(u64, 3), blank.stats.gap_chunks_zeroed);
}

test "loader GUID is version 4 and avoids layout GUIDs" {
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    const first = try loaderGuid(seed, &.{});
    try std.testing.expect(first[7] >> 4 == 4 and first[8] >> 6 == 2);
    const second = try loaderGuid(seed, &.{first});
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "build id and locale validation" {
    try std.testing.expect(validBuildId("B261028-155628-7BA80151"));
    try std.testing.expect(!validBuildId("../x"));
    try std.testing.expect(validLocale("pl-PL") and !validLocale("p") and !validLocale("a b"));
    var name: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\\USOSPREP.LOG", try rotationName(&name, 0));
    try std.testing.expectEqualStrings("\\USOSPREP.2.LOG", try rotationName(&name, 2));
}
