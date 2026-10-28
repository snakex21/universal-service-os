//! Raw WIM chunk codecs. Allocator memory is workspace only; caller owns
//! compressed input and exact-size output. No whole-resource/file buffer.
const std = @import("std");
const xpress = @import("wim_xpress.zig");
const lzx = @import("wim_lzx.zig");
const lzms = @import("wim_lzms.zig");
pub const Kind = enum { xpress, lzx, lzms };
pub const chunk_limit: usize = 32768;
pub const lzms_chunk_limit: usize = 128 * 1024;
/// Peak dynamically allocated decoder workspace, excluding caller input and
/// output buffers. No call changes an input buffer or takes its ownership.
pub fn memoryEstimate(kind: Kind, chunk_size: usize) !usize {
    if (chunk_size == 0 or chunk_size > (if (kind == .lzms) lzms_chunk_limit else chunk_limit)) return error.UnsupportedChunkSize;
    return switch (kind) {
        .xpress => xpress.workspace_bytes,
        .lzx => lzx.workspace_bytes,
        .lzms => lzms.workspace_bytes,
    };
}
pub fn decode(kind: Kind, input: []const u8, output: []u8, allocator: std.mem.Allocator) !void {
    _ = try memoryEstimate(kind, output.len);
    switch (kind) {
        .xpress => try xpress.decode(input, output, allocator),
        .lzx => try lzx.decode(input, output, allocator),
        .lzms => try lzms.decode(input, output, allocator),
    }
}
test {
    _ = @import("wim_xpress.zig");
    _ = @import("wim_lzx.zig");
    _ = @import("wim_lzms.zig");
}

test "all raw codecs bound malformed data and release every workspace on failure" {
    var random = std.Random.DefaultPrng.init(0x55534f5357494d);
    var input: [512]u8 = undefined;
    var guarded: [258]u8 = undefined;
    inline for (.{ Kind.xpress, Kind.lzx, Kind.lzms }) |kind| {
        for (0..192) |_| {
            random.random().bytes(&input);
            const length = random.random().uintLessThan(usize, input.len + 1);
            const size = 1 + random.random().uintLessThan(usize, 256);
            @memset(&guarded, 0xcd);
            decode(kind, input[0..length], guarded[1..][0..size], std.testing.allocator) catch {};
            try std.testing.expectEqual(@as(u8, 0xcd), guarded[0]);
            for (guarded[1 + size ..]) |sentinel| try std.testing.expectEqual(@as(u8, 0xcd), sentinel);
        }
    }
}
