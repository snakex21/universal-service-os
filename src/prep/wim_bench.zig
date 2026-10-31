//! Host microbenchmark of the exact firmware LZX decoder and SHA-1 code.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const wim = @import("wim.zig");
const codec = @import("wim_codec.zig");
const max_sample = 4 * 1024 * 1024;
const File = struct {
    io: std.Io,
    file: std.Io.File,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if ((self.file.readPositionalAll(self.io, out, at) catch return error.Io) != out.len) return error.Io;
    }
};
pub const Chunk = struct { input: usize, stored: usize, output: usize, size: usize };
pub const Plan = struct {
    chunks: []Chunk,
    lzx_bytes: u64,
    raw_bytes: u64,
    lzx_chunks: usize,
};
fn get(comptime T: type, raw: []const u8, at: usize) T {
    return std.mem.readInt(T, raw[at..][0..@sizeOf(T)], .little);
}
pub fn planChunks(a: std.mem.Allocator, raw: []const u8, size: usize, chunk_size: usize) !Plan {
    if (size == 0 or size > max_sample or chunk_size != 32768 or raw.len > max_sample) return error.InvalidSample;
    const count = 1 + (size - 1) / chunk_size;
    const table = (count - 1) * 4;
    if (table > raw.len) return error.InvalidSample;
    const body = raw.len - table;
    const chunks = try a.alloc(Chunk, count);
    errdefer a.free(chunks);
    var result: Plan = .{ .chunks = chunks, .lzx_bytes = 0, .raw_bytes = 0, .lzx_chunks = 0 };
    for (chunks, 0..) |*chunk, number| {
        const begin: usize = if (number == 0) 0 else get(u32, raw, (number - 1) * 4);
        const end: usize = if (number + 1 == count) body else get(u32, raw, number * 4);
        const output = number * chunk_size;
        const length = @min(chunk_size, size - output);
        if (begin >= end or end > body or end - begin > length) return error.InvalidSample;
        chunk.* = .{ .input = table + begin, .stored = end - begin, .output = output, .size = length };
        if (chunk.stored < chunk.size) {
            result.lzx_bytes += length;
            result.lzx_chunks += 1;
        } else result.raw_bytes += length;
    }
    return result;
}
fn decodePass(plan: Plan, raw: []const u8, plain: []u8, a: std.mem.Allocator, include_raw: bool) !void {
    for (plan.chunks) |chunk| {
        const output = plain[chunk.output..][0..chunk.size];
        const input = raw[chunk.input..][0..chunk.stored];
        if (chunk.stored < chunk.size) try codec.decode(.lzx, input, output, a) else if (include_raw) @memcpy(output, input);
    }
}
fn choose(a: std.mem.Allocator, input: wim.Input, header: wim.Header) !struct { entry: wim.Entry, number: u32 } {
    if (header.compression != .lzx or header.chunk_size != 32768 or header.lookup.size % 50 != 0) return error.ExpectedLzxWim;
    const count = header.lookup.size / 50;
    if (count == 0 or count > 131072) return error.InvalidLookup;
    var table = try wim.Resource.init(a, input, header, header.lookup, null);
    defer table.deinit();
    for (0..@as(usize, @intCast(count))) |number| {
        var raw: [50]u8 = undefined;
        try table.read(number * 50, &raw);
        const descriptor = try wim.Descriptor.parse(raw[0..24], input.size);
        if (get(u16, &raw, 24) != 1 or get(u32, &raw, 26) == 0) return error.InvalidLookup;
        if (descriptor.flags & 6 == 4 and descriptor.size >= 1024 * 1024 and descriptor.size <= max_sample and descriptor.stored <= max_sample) {
            return .{ .entry = .{ .descriptor = descriptor, .part = 1, .references = get(u32, &raw, 26), .sha1 = raw[30..50].* }, .number = @intCast(number) };
        }
    }
    return error.NoBoundedLzxSample;
}
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingWim;
    const decode_repeat = try std.fmt.parseInt(u32, args.next() orelse return error.MissingDecoderRepeats, 10);
    const sha_repeat = try std.fmt.parseInt(u32, args.next() orelse return error.MissingShaRepeats, 10);
    if (args.next() != null or decode_repeat == 0 or decode_repeat > 256 or sha_repeat == 0 or sha_repeat > 1024
        or !std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//")
        or std.mem.indexOfAny(u8, path, "\r\n\x00") != null or std.mem.indexOfScalar(u8, path[2..], ':') != null) return error.InvalidArgument;
    var file: File = .{ .io = init.io, .file = try std.Io.Dir.openFileAbsolute(init.io, path, .{ .mode = .read_only }) };
    defer file.file.close(init.io);
    const stat = try file.file.stat(init.io);
    if (stat.kind != .file or stat.size > 16 * 1024 * 1024 * 1024) return error.InvalidArgument;
    const input: wim.Input = .{ .context = &file, .size = stat.size, .read_fn = File.read };
    const header = try wim.Header.read(input);
    var tracked: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = 12 * 1024 * 1024 };
    const a = tracked.allocator();
    const sample = try choose(a, input, header);
    const raw = try a.alloc(u8, @intCast(sample.entry.descriptor.stored));
    defer a.free(raw);
    try input.read(sample.entry.descriptor.offset, raw);
    const plain = try a.alloc(u8, @intCast(sample.entry.descriptor.size));
    defer a.free(plain);
    const plan = try planChunks(a, raw, plain.len, header.chunk_size);
    defer a.free(plan.chunks);
    if (plan.lzx_chunks == 0) return error.NoCompressedChunks;
    try decodePass(plan, raw, plain, a, true);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(plain, &digest, .{});
    if (!std.mem.eql(u8, &digest, &sample.entry.sha1)) return error.WimHashMismatch;
    const before_decode = std.Io.Clock.awake.now(init.io);
    for (0..decode_repeat) |_| {
        std.mem.doNotOptimizeAway(plain.ptr);
        try decodePass(plan, raw, plain, a, false);
        std.mem.doNotOptimizeAway(plain.ptr);
    }
    const decode_ns = std.Io.Clock.awake.now(init.io).nanoseconds - before_decode.nanoseconds;
    // Verify outside the timed decoder interval; SHA is measured separately.
    std.crypto.hash.Sha1.hash(plain, &digest, .{});
    if (!std.mem.eql(u8, &digest, &sample.entry.sha1)) return error.WimHashMismatch;
    const before_sha = std.Io.Clock.awake.now(init.io);
    for (0..sha_repeat) |_| {
        std.mem.doNotOptimizeAway(plain.ptr);
        std.crypto.hash.Sha1.hash(plain, &digest, .{});
        std.mem.doNotOptimizeAway(&digest);
    }
    const sha_ns = std.Io.Clock.awake.now(init.io).nanoseconds - before_sha.nanoseconds;
    if (!std.mem.eql(u8, &digest, &sample.entry.sha1) or decode_ns <= 0 or sha_ns <= 0) return error.InvalidMeasurement;
    std.debug.print("BENCH_RESULT {{\"arch\":\"{s}\",\"cpu\":\"{s}\",\"optimize\":\"{s}\",\"resource\":{d},\"offset\":{d},\"stored\":{d},\"size\":{d},\"chunks\":{d},\"lzx_chunks\":{d},\"raw_bytes\":{d},\"decoder_repeats\":{d},\"decoder_bytes\":{d},\"decoder_ns\":{d},\"sha_repeats\":{d},\"sha_bytes\":{d},\"sha_ns\":{d},\"sha1\":\"{s}\",\"sha1_verified\":true,\"timed_io\":false,\"allocator_peak\":{d},\"codec_workspace\":{d}}}\n", .{
        @tagName(builtin.cpu.arch), builtin.cpu.model.name, @tagName(builtin.mode), sample.number, sample.entry.descriptor.offset,
        raw.len, plain.len, plan.chunks.len, plan.lzx_chunks, plan.raw_bytes, decode_repeat, plan.lzx_bytes * decode_repeat,
        decode_ns, sha_repeat, @as(u64, @intCast(plain.len)) * sha_repeat, sha_ns, std.fmt.bytesToHex(digest, .lower), tracked.peak,
        try codec.memoryEstimate(.lzx, header.chunk_size),
    });
    return 0;
}
test "sample plan counts compressed decoding separately from literal copies" {
    var raw: [8]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], 2, .little);
    const plan = try planChunks(std.testing.allocator, &raw, 32770, 32768);
    defer std.testing.allocator.free(plan.chunks);
    try std.testing.expectEqual(@as(usize, 2), plan.chunks.len);
    try std.testing.expectEqual(@as(u64, 32768), plan.lzx_bytes);
    try std.testing.expectEqual(@as(u64, 2), plan.raw_bytes);
}
test "sample plan rejects empty, oversized, truncated and backwards chunks" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidSample, planChunks(a, "", 0, 32768));
    try std.testing.expectError(error.InvalidSample, planChunks(a, "", max_sample + 1, 32768));
    try std.testing.expectError(error.InvalidSample, planChunks(a, "", 32770, 32768));
    try std.testing.expectError(error.InvalidSample, planChunks(a, &.{ 0, 0, 0, 0, 1, 2 }, 32770, 32768));
    try std.testing.expectError(error.InvalidSample, planChunks(a, "x", 1, 4096));
}
