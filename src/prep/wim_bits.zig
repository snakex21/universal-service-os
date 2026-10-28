//! Bounded canonical Huffman and 16-bit/MSB-first WIM bitstream primitives.
//! Format/algorithm reference: Eric Biggers' wimlib, commit
//! cd5e231c348c255ae5088873b5a66ee0eb96fa07, decompress_common.h/.c.
//! Zig implementation Copyright (C) 2026 Maksymilian and the USOS Authors.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! No input overread: zero-filled lookahead never authorizes consuming bits
//! that were not present. Raw bytes share the prefetched stream cursor.
const std = @import("std");
pub const Error = error{ InvalidData, Truncated, UnsupportedChunkSize };
pub const Bits = struct {
    input: []const u8,
    next: usize = 0,
    buffer: u64 = 0,
    available: u7 = 0,

    pub fn ensure(self: *Bits, n: u6) void {
        while (self.available < n and self.input.len - self.next >= 2) {
            const word = std.mem.readInt(u16, self.input[self.next..][0..2], .little);
            self.buffer |= @as(u64, word) << @intCast(48 - self.available);
            self.next += 2;
            self.available += 16;
        }
    }
    pub fn peek(self: *const Bits, n: u6) u32 {
        if (n == 0) return 0;
        return @intCast(self.buffer >> @intCast(64 - @as(u7, n)));
    }
    pub fn pop(self: *Bits, n: u6) Error!u32 {
        if (n > self.available) return error.Truncated;
        const value = self.peek(n);
        self.buffer <<= n;
        self.available -= n;
        return value;
    }
    pub fn read(self: *Bits, n: u6) Error!u32 {
        self.ensure(n);
        return self.pop(n);
    }
    pub fn bytes(self: *Bits, count: usize) Error![]const u8 {
        if (count > self.input.len - self.next) return error.Truncated;
        defer self.next += count;
        return self.input[self.next..][0..count];
    }
    pub fn byte(self: *Bits) Error!u8 {
        return (try self.bytes(1))[0];
    }
    pub fn u16le(self: *Bits) Error!u16 {
        return std.mem.readInt(u16, (try self.bytes(2))[0..2], .little);
    }
    pub fn u32le(self: *Bits) Error!u32 {
        return std.mem.readInt(u32, (try self.bytes(4))[0..4], .little);
    }
    pub fn alignUnit(self: *Bits) void {
        self.buffer = 0;
        self.available = 0;
    }
};

pub const max_symbols = 800;
pub const Huffman = struct {
    const root_bits = 10;
    fast: [1 << root_bits]u16 = @splat(0),
    count: [17]u16 = @splat(0),
    first: [17]u32 = @splat(0),
    start: [17]u16 = @splat(0),
    symbols: [max_symbols]u16 = undefined,
    maximum: u6 = 0,
    nonempty: bool = false,

    pub fn build(self: *Huffman, lengths: []const u8, maximum: u6) Error!void {
        if (lengths.len > max_symbols or maximum == 0 or maximum > 16) return error.InvalidData;
        @memset(&self.fast, 0);
        @memset(&self.count, 0);
        self.maximum = maximum;
        self.nonempty = false;
        for (lengths) |n| {
            if (n > maximum) return error.InvalidData;
            if (n != 0) {
                self.count[n] += 1;
                self.nonempty = true;
            }
        }
        var space: i32 = 1;
        var code: u32 = 0;
        var position: u16 = 0;
        for (1..@as(usize, maximum) + 1) |n| {
            space = space * 2 - self.count[n];
            if (space < 0) return error.InvalidData;
            code = (code + self.count[n - 1]) << 1;
            self.first[n] = code;
            self.start[n] = position;
            position += self.count[n];
        }
        if (space != 0 and self.nonempty) return error.InvalidData;
        var cursor = self.start;
        for (lengths, 0..) |n, symbol| {
            if (n == 0) continue;
            const index = cursor[n];
            cursor[n] += 1;
            self.symbols[index] = @intCast(symbol);
            if (n <= root_bits) {
                const canonical = self.first[n] + index - self.start[n];
                const begin = canonical << @intCast(root_bits - n);
                const copies = @as(usize, 1) << @intCast(root_bits - n);
                const entry = (@as(u16, @intCast(symbol)) << 5) | n;
                @memset(self.fast[begin..][0..copies], entry);
            }
        }
    }
    pub fn decode(self: *const Huffman, bits: anytype) Error!u16 {
        if (!self.nonempty) return error.InvalidData;
        // Use the format's maximum, not the longest actually used code:
        // prefetch position is observable by XPRESS's embedded raw lengths.
        bits.ensure(self.maximum);
        const entry = self.fast[bits.peek(root_bits)];
        if (entry != 0) {
            _ = try bits.pop(@intCast(entry & 31));
            return entry >> 5;
        }
        var code: u32 = 0;
        for (1..@as(usize, self.maximum) + 1) |n| {
            code = (code << 1) | try bits.read(1);
            if (code >= self.first[n] and code - self.first[n] < self.count[n])
                return self.symbols[self.start[n] + code - self.first[n]];
        }
        return error.InvalidData;
    }
};

pub fn copyMatch(output: []u8, position: usize, length: usize, offset: usize) Error!void {
    if (offset == 0 or offset > position or length > output.len - position) return error.InvalidData;
    for (0..length) |i| output[position + i] = output[position + i - offset];
}

test "canonical code rejects incomplete/oversubscribed codes and never decodes an empty code" {
    var tree: Huffman = .{};
    try std.testing.expectError(error.InvalidData, tree.build(&.{ 1, 1, 1 }, 15));
    try std.testing.expectError(error.InvalidData, tree.build(&.{ 1, 2 }, 15));
    try tree.build(&.{ 0, 0 }, 15);
    var bits: Bits = .{ .input = &.{ 0, 0 } };
    try std.testing.expectError(error.InvalidData, tree.decode(&bits));
    try tree.build(&.{ 1, 1 }, 15);
    bits = .{ .input = &.{ 0, 0x50 } };
    try std.testing.expectEqual(@as(u16, 0), try tree.decode(&bits));
    try std.testing.expectEqual(@as(u16, 1), try tree.decode(&bits));
    bits = .{ .input = &.{} };
    try std.testing.expectError(error.Truncated, tree.decode(&bits));
}
