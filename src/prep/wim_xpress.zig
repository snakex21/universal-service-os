//! WIM XPRESS-Huffman, bounded to a single32KiB chunk.
//! Zig adaptation of wimlib src/xpress_decompress.c, commit
//! cd5e231c348c255ae5088873b5a66ee0eb96fa07.
//! Copyright (C) 2012-2016 Eric Biggers; (C)2026 USOS Authors.
//! SPDX-License-Identifier: LGPL-2.1-or-later
//! Public format: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-xca/
const std = @import("std");
const common = @import("wim_bits.zig");
pub const workspace_bytes = @sizeOf(common.Huffman) + 512;
pub fn decode(input: []const u8, output: []u8, allocator: std.mem.Allocator) !void {
    if (output.len == 0 or output.len > 32768) return error.UnsupportedChunkSize;
    if (input.len < 256) return error.Truncated;
    const workspace = try allocator.create(struct { tree: common.Huffman, lengths: [512]u8 });
    defer allocator.destroy(workspace);
    workspace.tree = .{};
    for (input[0..256], 0..) |value, i| {
        workspace.lengths[i * 2] = value & 15;
        workspace.lengths[i * 2 + 1] = value >> 4;
    }
    try workspace.tree.build(&workspace.lengths, 15);
    var bits: common.Bits = .{ .input = input[256..] };
    var position: usize = 0;
    while (position < output.len) {
        const symbol = try workspace.tree.decode(&bits);
        if (symbol < 256) {
            output[position] = @intCast(symbol);
            position += 1;
        } else {
            var length: usize = symbol & 15;
            const log: u6 = @intCast((symbol >> 4) & 15);
            bits.ensure(16);
            const offset = (@as(u32, 1) << @intCast(log)) | try bits.pop(log);
            if (length == 15) {
                length += try bits.byte();
                if (length == 270) length = try bits.u16le();
            }
            length += 3;
            try common.copyMatch(output, position, length, offset);
            position += length;
        }
    }
}

test "XPRESS canonical literals, early reference rejection, and truncated table" {
    var input: [258]u8 = @splat(0);
    input[65 / 2] = 0x10;
    input[66 / 2] = 1;
    input[257] = 0x50;
    var output: [4]u8 = undefined;
    try decode(&input, &output, std.testing.allocator);
    try std.testing.expectEqualStrings("ABAB", &output);
    try std.testing.expectError(error.Truncated, decode(input[0..255], &output, std.testing.allocator));
    @memset(input[0..256], 0);
    input[256 / 2] = 0x11;
    try std.testing.expectError(error.InvalidData, decode(&input, &output, std.testing.allocator));
}
