//! LZX as stored in WIM32KiB chunks (not CAB/LZX-DELTA).
//! Zig adaptation of wimlib src/lzx_decompress.c and src/lzx_common.c,
//! commit cd5e231c348c255ae5088873b5a66ee0eb96fa07.
//! Copyright (C)2012-2016 Eric Biggers; (C)2026 USOS Authors.
//! SPDX-License-Identifier: LGPL-2.1-or-later
const std = @import("std");
const c = @import("wim_bits.zig");
const bases = [_]u32{ 0, 0, 0, 1, 2, 4, 6, 10, 14, 22, 30, 46, 62, 94, 126, 190, 254, 382, 510, 766, 1022, 1534, 2046, 3070, 4094, 6142, 8190, 12286, 16382, 24574 };
const extras = [_]u6{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const Workspace = struct {
    main: c.Huffman = .{},
    length: c.Huffman = .{},
    pre: c.Huffman = .{},
    aligned: c.Huffman = .{},
    main_lens: [496]u8 = @splat(0),
    length_lens: [249]u8 = @splat(0),
    pre_lens: [20]u8 = undefined,
    aligned_lens: [8]u8 = undefined,
};
pub const workspace_bytes = @sizeOf(Workspace);
fn delta(old: u8, difference: u16) c.Error!u8 {
    if (difference > 17 or old > 16) return error.InvalidData;
    return @intCast((@as(u16, old) + 17 - difference) % 17);
}
fn readLengths(work: *Workspace, bits: *c.Bits, lengths: []u8) !void {
    for (&work.pre_lens) |*n| n.* = @intCast(try bits.read(4));
    try work.pre.build(&work.pre_lens, 15);
    var position: usize = 0;
    while (position < lengths.len) {
        const symbol = try work.pre.decode(bits);
        if (symbol < 17) {
            lengths[position] = try delta(lengths[position], symbol);
            position += 1;
        } else {
            var count: usize = undefined;
            var value: u8 = 0;
            if (symbol == 17) count = 4 + try bits.read(4) else if (symbol == 18) count = 20 + try bits.read(5) else if (symbol == 19) {
                count = 4 + try bits.read(1);
                value = try delta(lengths[position], try work.pre.decode(bits));
            } else return error.InvalidData;
            if (count > lengths.len - position) return error.InvalidData;
            @memset(lengths[position..][0..count], value);
            position += count;
        }
    }
}
pub fn postprocess(output: []u8) void {
    if (output.len <= 10) return;
    var position: usize = 0;
    while (position < output.len - 10) {
        if (output[position] != 0xe8) {
            position += 1;
            continue;
        }
        const target = output[position + 1 ..][0..4];
        const absolute = std.mem.readInt(i32, target, .little);
        const current: i32 = @intCast(position);
        if (absolute >= 0) {
            if (absolute < 12000000) std.mem.writeInt(i32, target, absolute - current, .little);
        } else if (absolute >= -current) std.mem.writeInt(i32, target, absolute + 12000000, .little);
        position += 5;
    }
}
pub fn decode(input: []const u8, output: []u8, allocator: std.mem.Allocator) !void {
    if (output.len == 0 or output.len > 32768) return error.UnsupportedChunkSize;
    const work = try allocator.create(Workspace);
    defer allocator.destroy(work);
    work.* = .{};
    var bits: c.Bits = .{ .input = input };
    var recent: [3]u32 = .{ 1, 1, 1 };
    var position: usize = 0;
    while (position < output.len) {
        const kind = try bits.read(3);
        const size: usize = if (try bits.read(1) != 0) 32768 else try bits.read(16);
        if (size == 0 or size > output.len - position) return error.InvalidData;
        const end = position + size;
        if (kind == 3) {
            bits.ensure(1);
            bits.alignUnit();
            for (&recent) |*offset| {
                offset.* = try bits.u32le();
                if (offset.* == 0) return error.InvalidData;
            }
            @memcpy(output[position..end], try bits.bytes(size));
            // Native WIM encoders may omit this alignment byte after the
            // final block. It aligns a following block; it is not output.
            // Keep payload reads strict and require it between blocks.
            if (size & 1 != 0 and (end != output.len or bits.next < input.len)) _ = try bits.byte();
            position = end;
            continue;
        }
        if (kind != 1 and kind != 2) return error.InvalidData;
        if (kind == 2) {
            for (&work.aligned_lens) |*n| n.* = @intCast(try bits.read(3));
            try work.aligned.build(&work.aligned_lens, 7);
        }
        try readLengths(work, &bits, work.main_lens[0..256]);
        try readLengths(work, &bits, work.main_lens[256..]);
        try readLengths(work, &bits, &work.length_lens);
        try work.main.build(&work.main_lens, 16);
        try work.length.build(&work.length_lens, 16);
        while (position < end) {
            const symbol = try work.main.decode(&bits);
            if (symbol < 256) {
                output[position] = @intCast(symbol);
                position += 1;
                continue;
            }
            var length: usize = symbol & 7;
            const slot: usize = (symbol - 256) / 8;
            if (slot >= bases.len) return error.InvalidData;
            if (length == 7) length += try work.length.decode(&bits);
            length += 2;
            var offset: u32 = undefined;
            if (slot < 3) {
                offset = recent[slot];
                recent[slot] = recent[0];
            } else {
                if (kind == 2 and slot >= 8) {
                    offset = (try bits.read(extras[slot] - 3) << 3) | try work.aligned.decode(&bits);
                } else offset = try bits.read(extras[slot]);
                offset += bases[slot];
                recent[2] = recent[1];
                recent[1] = recent[0];
            }
            recent[0] = offset;
            if (length > end - position) return error.InvalidData;
            try c.copyMatch(output, position, length, offset);
            position += length;
        }
    }
    postprocess(output);
}

test "LZX uncompressed block alignment and invalid recent offset" {
    var input: [34]u8 = @splat(0);
    input[0..4].* = .{ 1, 0x60, 0, 0x10 }; // kind3,size17,16-bit aligned.
    for (0..3) |i| std.mem.writeInt(u32, input[4 + 4 * i ..][0..4], 1, .little);
    @memcpy(input[16..33], "abcdefghijklmnopq");
    var output: [17]u8 = undefined;
    try decode(&input, &output, std.testing.allocator);
    try std.testing.expectEqualStrings("abcdefghijklmnopq", &output);
    // Both forms are accepted by the independent wimlib decoder. The
    // native Windows WIM encoder also emits the form without final padding.
    try decode(input[0..33], &output, std.testing.allocator);
    try std.testing.expectEqualStrings("abcdefghijklmnopq", &output);
    try std.testing.expectError(error.Truncated, decode(input[0..32], &output, std.testing.allocator));
    input[4] = 0;
    try std.testing.expectError(error.InvalidData, decode(&input, &output, std.testing.allocator));
}
test "LZX WIM E8 postprocessing skips instruction operands and the last ten bytes" {
    var data: [32]u8 = @splat(0);
    data[1] = 0xe8;
    std.mem.writeInt(i32, data[2..6], 17, .little);
    data[23] = 0xe8;
    std.mem.writeInt(i32, data[24..28], 500, .little);
    postprocess(&data);
    try std.testing.expectEqual(@as(i32, 16), std.mem.readInt(i32, data[2..6], .little));
    try std.testing.expectEqual(@as(i32, 500), std.mem.readInt(i32, data[24..28], .little));
}

test "LZX requires odd raw-block padding before the next block" {
    var input: [52]u8 = @splat(0);
    input[0..4].* = .{ 1, 0x60, 0, 0x10 }; // Raw block of seventeen bytes.
    input[34..38].* = .{ 0, 0x60, 0, 0x20 }; // Raw block of two bytes.
    for (0..3) |i| {
        std.mem.writeInt(u32, input[4 + 4 * i ..][0..4], 1, .little);
        std.mem.writeInt(u32, input[38 + 4 * i ..][0..4], 1, .little);
    }
    @memcpy(input[16..33], "abcdefghijklmnopq");
    @memcpy(input[50..52], "rs");
    var output: [19]u8 = undefined;
    try decode(&input, &output, std.testing.allocator);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrs", &output);
    // End of input is permissible only after all requested output exists.
    try std.testing.expectError(error.Truncated, decode(input[0..33], &output, std.testing.allocator));
}
