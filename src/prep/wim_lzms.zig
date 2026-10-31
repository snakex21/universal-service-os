//! Raw non-solid LZMS, maximum128KiB chunk. No solid resource/window state.
//! Zig adaptation of wimlib lzms_decompress.c/lzms_common.c, commit
//! cd5e231c348c255ae5088873b5a66ee0eb96fa07.
//! Copyright (C)2013-2016 Eric Biggers; (C)2026 USOS Authors.
//! SPDX-License-Identifier: LGPL-2.1-or-later
//!
//! Huffman construction also adapts wimlib compress_common.c:
//! Copyright2022 Eric Biggers. Permission is hereby granted, free of charge,
//! to any person obtaining a copy of this software and associated documentation
//! files (the "Software"), to deal in the Software without restriction,
//! including without limitation the rights to use, copy, modify, merge,
//! publish, distribute, sublicense, and/or sell copies of the Software, and to
//! permit persons to whom the Software is furnished to do so, subject to the
//! following conditions: The above copyright notice and this permission notice
//! shall be included in all copies or substantial portions of the Software.
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//! FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//! IN THE SOFTWARE.
const std = @import("std");
const common = @import("wim_bits.zig");
const tables = @import("wim_lzms_tables.zig");
pub const Stats = struct { literals: u64 = 0, lz: u64 = 0, lz_repeat: u64 = 0, delta: u64 = 0, delta_repeat: u64 = 0, rebuilds: u64 = 0, translated: u64 = 0 };
const BackBits = struct {
    input: []const u8,
    next: usize,
    buffer: u64 = 0,
    available: u7 = 0,
    pub fn ensure(self: *BackBits, n: u6) void {
        while (self.available < n and self.next >= 2) {
            self.next -= 2;
            const word = std.mem.readInt(u16, self.input[self.next..][0..2], .little);
            self.buffer |= @as(u64, word) << @intCast(48 - self.available);
            self.available += 16;
        }
    }
    pub fn peek(self: *const BackBits, n: u6) u32 {
        if (n == 0) return 0;
        return @intCast(self.buffer >> @intCast(64 - @as(u7, n)));
    }
    pub fn pop(self: *BackBits, n: u6) common.Error!u32 {
        if (n > self.available) return error.Truncated;
        const value = self.peek(n);
        self.buffer <<= n;
        self.available -= n;
        return value;
    }
    pub fn read(self: *BackBits, n: u6) common.Error!u32 {
        self.ensure(n);
        return self.pop(n);
    }
};
const Probability = struct { zeros: u32 = 48, recent: u64 = 0x55555555 };
const Range = struct {
    input: []const u8,
    next: usize = 4,
    range: u32 = 0xffffffff,
    code: u32,
    fn bit(self: *Range, entry: *Probability) !bool {
        if (self.range < 0x10000) {
            if (self.input.len - self.next < 2) return error.Truncated;
            self.range <<= 16;
            self.code = (self.code << 16) | std.mem.readInt(u16, self.input[self.next..][0..2], .little);
            self.next += 2;
        }
        const probability = std.math.clamp(entry.zeros, 1, 63);
        const bound = (self.range >> 6) * probability;
        const value = self.code >= bound;
        if (value) {
            self.range -= bound;
            self.code -= bound;
        } else self.range = bound;
        entry.zeros += @intCast(entry.recent >> 63);
        entry.zeros -= @intFromBool(value);
        entry.recent = (entry.recent << 1) | @intFromBool(value);
        return value;
    }
};
fn Context(comptime n: usize) type {
    return struct {
        state: usize = 0,
        entries: [n]Probability = @splat(.{}),
        fn initialize(self: *@This()) void {
            self.state = 0;
            for (&self.entries) |*entry| entry.* = .{};
        }
        fn bit(self: *@This(), range: *Range) !bool {
            const value = try range.bit(&self.entries[self.state]);
            self.state = ((self.state << 1) | @intFromBool(value)) & (n - 1);
            return value;
        }
    };
}
const Build = struct {
    order: [800]u32 = undefined,
    frequency: [800]u32 = undefined,
    parent: [800]u16 = undefined,
    depth: [800]u8 = undefined,
    lengths: [800]u8 = undefined,
};
const Adaptive = struct {
    tree: common.Huffman = .{},
    frequencies: [800]u32 = undefined,
    symbols: usize = 0,
    interval: u16 = 0,
    remaining: u16 = 0,
    fn init(self: *Adaptive, symbols: usize, interval: u16, temp: *Build) !void {
        self.symbols = symbols;
        self.interval = interval;
        @memset(self.frequencies[0..symbols], 1);
        try self.build(temp);
    }
    fn build(self: *Adaptive, temp: *Build) !void {
        const n = self.symbols;
        @memset(&temp.lengths, 0);
        if (n == 1) {
            temp.lengths[0..2].* = .{ 1, 1 };
        } else if (n >= 2) {
            for (0..n) |i| temp.order[i] = (self.frequencies[i] << 10) | @as(u32, @intCast(i));
            std.mem.sort(u32, temp.order[0..n], {}, std.sort.asc(u32));
            // Two monotonic queues, ties favor leaves. Internal parents are
            // sufficient for length counts; low-frequency/small-symbol ties
            // receive longer lengths, exactly as the LZMS format requires.
            var leaf: usize = 0;
            var branch: usize = 0;
            for (0..n - 1) |node| {
                var frequency: u32 = 0;
                for (0..2) |_| {
                    if (leaf < n and (branch == node or temp.order[leaf] >> 10 <= temp.frequency[branch])) {
                        frequency += temp.order[leaf] >> 10;
                        leaf += 1;
                    } else {
                        frequency += temp.frequency[branch];
                        temp.parent[branch] = @intCast(node);
                        branch += 1;
                    }
                }
                temp.frequency[node] = frequency;
            }
            var counts: [16]u16 = @splat(0);
            counts[1] = 2;
            temp.depth[n - 2] = 0;
            var node = n - 2;
            while (node != 0) {
                node -= 1;
                const depth = temp.depth[temp.parent[node]] + 1;
                if (depth >= 15 or counts[depth] == 0) return error.InvalidData;
                temp.depth[node] = depth;
                counts[depth] -= 1;
                counts[depth + 1] += 2;
            }
            var index: usize = 0;
            var length: usize = 15;
            while (length != 0) : (length -= 1) {
                for (0..counts[length]) |_| {
                    temp.lengths[temp.order[index] & 1023] = @intCast(length);
                    index += 1;
                }
            }
            if (index != n) return error.InvalidData;
        }
        try self.tree.build(temp.lengths[0..@max(n, 2)], 15);
        self.remaining = self.interval;
    }
    fn decode(self: *Adaptive, bits: *BackBits, temp: *Build, stats: *Stats) !u16 {
        const symbol = try self.tree.decode(bits);
        if (symbol >= self.symbols) return error.InvalidData;
        self.frequencies[symbol] += 1;
        self.remaining -= 1;
        if (self.remaining == 0) {
            try self.build(temp);
            for (self.frequencies[0..self.symbols]) |*n| n.* = (n.* >> 1) + 1;
            stats.rebuilds += 1;
        }
        return symbol;
    }
};
const State = struct {
    literal: Adaptive = .{},
    lz_offset: Adaptive = .{},
    length: Adaptive = .{},
    delta_offset: Adaptive = .{},
    power: Adaptive = .{},
    main: Context(16) = .{},
    match: Context(32) = .{},
    lz: Context(64) = .{},
    delta: Context(64) = .{},
    lz_rep: [2]Context(64) = @splat(.{}),
    delta_rep: [2]Context(64) = @splat(.{}),
    build: Build = undefined,
    fn initialize(self: *State) void {
        // Do not materialize the mixed-zero/default aggregate as a 49KiB
        // rodata copy in the small BIOS payload. Zeroing initializes the
        // adaptive trees; each probability context then gets its nonzero
        // format defaults. Scratch fields are initialized before use.
        @memset(std.mem.asBytes(self), 0);
        self.main.initialize();
        self.match.initialize();
        self.lz.initialize();
        self.delta.initialize();
        for (&self.lz_rep) |*context| context.initialize();
        for (&self.delta_rep) |*context| context.initialize();
    }
};
const Workspace = union { state: State, targets: [65536]i32 };
pub const workspace_bytes = @sizeOf(Workspace);
fn offsetCode(code: *Adaptive, bits: *BackBits, temp: *Build, stats: *Stats) !u32 {
    const slot = try code.decode(bits, temp, stats);
    if (slot >= tables.offset_bases.len) return error.InvalidData;
    return tables.offset_bases[slot] + try bits.read(tables.offset_extra[slot]);
}
fn lengthCode(state: *State, bits: *BackBits, stats: *Stats) !u32 {
    const slot = try state.length.decode(bits, &state.build, stats);
    return tables.length_bases[slot] + try bits.read(tables.length_extra[slot]);
}
fn repIndex(contexts: *[2]Context(64), range: *Range) !usize {
    if (!try contexts[0].bit(range)) return 0;
    return if (!try contexts[1].bit(range)) 1 else 2;
}
fn repeat(comptime T: type, queue: *[4]T, index: usize) T {
    const value = queue[index];
    var i = index;
    while (i != 0) : (i -= 1) queue[i] = queue[i - 1];
    queue[0] = value;
    return value;
}
fn push(comptime T: type, queue: *[4]T, value: T) void {
    var i: usize = 3;
    while (i != 0) : (i -= 1) queue[i] = queue[i - 1];
    queue[0] = value;
}
pub fn postprocess(output: []u8, targets: *[65536]i32, stats: *Stats) void {
    if (output.len <= 17) return;
    @memset(targets, -65536);
    var last: i32 = -1024;
    var position: usize = 1; // First byte is intentionally ignored by LZMS.
    while (position < output.len - 16) {
        const opcode = output[position];
        var opcode_bytes: usize = 0;
        var maximum: i32 = 1023;
        switch (opcode) {
            0xff => if (output[position + 1] == 0x15) {
                opcode_bytes = 2;
            },
            0xf0 => if (output[position + 1] == 0x83 and output[position + 2] == 5) {
                opcode_bytes = 3;
            },
            0x48, 0x4c => {
                const op = output[position + 1];
                const modrm = output[position + 2];
                if (modrm & 7 == 5 and (op == 0x8d or (op == 0x8b and opcode & 4 == 0 and modrm & 0xf0 == 0))) opcode_bytes = 3;
            },
            0xe8 => {
                opcode_bytes = 1;
                maximum = 511;
            },
            0xe9 => {
                position += 5;
                continue;
            },
            else => {},
        }
        if (opcode_bytes == 0) {
            position += 1;
            continue;
        }
        const i: i32 = @intCast(position);
        const target = output[position + opcode_bytes ..][0..4];
        if (i - last <= maximum) {
            const value = std.mem.readInt(u32, target, .little);
            std.mem.writeInt(u32, target, value -% @as(u32, @intCast(i)), .little);
            stats.translated += 1;
        }
        const id: u16 = @truncate(@as(u32, @intCast(i)) + std.mem.readInt(u16, target[0..2], .little));
        const end: i32 = i + @as(i32, @intCast(opcode_bytes)) + 3;
        if (end - targets[id] <= 65535) last = end;
        targets[id] = end;
        position += opcode_bytes + 4;
    }
}
pub fn decodeWithStats(input: []const u8, output: []u8, allocator: std.mem.Allocator, stats: *Stats) !void {
    if (output.len == 0 or output.len > 128 * 1024) return error.UnsupportedChunkSize;
    if (input.len < 4 or input.len & 1 != 0) return error.Truncated;
    const workspace = try allocator.create(Workspace);
    defer allocator.destroy(workspace);
    workspace.* = .{ .state = undefined };
    const state = &workspace.state;
    state.initialize();
    var slots: usize = 0;
    if (output.len >= 2) for (tables.offset_bases) |base| {
        if (base >= output.len) break;
        slots += 1;
    };
    try state.literal.init(256, 1024, &state.build);
    try state.lz_offset.init(slots, 1024, &state.build);
    try state.delta_offset.init(slots, 1024, &state.build);
    try state.length.init(54, 512, &state.build);
    try state.power.init(8, 512, &state.build);
    var range: Range = .{ .input = input, .code = (@as(u32, std.mem.readInt(u16, input[0..2], .little)) << 16) | std.mem.readInt(u16, input[2..4], .little) };
    var bits: BackBits = .{ .input = input, .next = input.len };
    var recent_lz: [4]u32 = .{ 1, 2, 3, 4 };
    var recent_delta: [4]u64 = .{ 1, 2, 3, 4 };
    var previous: u2 = 0;
    var position: usize = 0;
    while (position < output.len) {
        if (!try state.main.bit(&range)) {
            output[position] = @intCast(try state.literal.decode(&bits, &state.build, stats));
            position += 1;
            previous = 0;
            stats.literals += 1;
        } else if (!try state.match.bit(&range)) {
            var offset: u32 = undefined;
            if (!try state.lz.bit(&range)) {
                offset = try offsetCode(&state.lz_offset, &bits, &state.build, stats);
                push(u32, &recent_lz, offset);
            } else {
                const index = try repIndex(&state.lz_rep, &range);
                offset = repeat(u32, &recent_lz, index + @intFromBool(previous == 1));
                stats.lz_repeat += 1;
            }
            const length = try lengthCode(state, &bits, stats);
            try common.copyMatch(output, position, length, offset);
            position += length;
            previous = 1;
            stats.lz += 1;
        } else {
            var pair: u64 = undefined;
            if (!try state.delta.bit(&range)) {
                const power = try state.power.decode(&bits, &state.build, stats);
                const offset = try offsetCode(&state.delta_offset, &bits, &state.build, stats);
                pair = (@as(u64, power) << 32) | offset;
                push(u64, &recent_delta, pair);
            } else {
                const index = try repIndex(&state.delta_rep, &range);
                pair = repeat(u64, &recent_delta, index + @intFromBool(previous == 2));
                stats.delta_repeat += 1;
            }
            const power: u5 = @intCast(pair >> 32);
            const raw: u32 = @truncate(pair);
            const offset64 = @as(u64, raw) << power;
            const span = @as(u32, 1) << power;
            const length = try lengthCode(state, &bits, stats);
            if (offset64 + span > position or length > output.len - position) return error.InvalidData;
            const offset: usize = @intCast(offset64);
            for (0..length) |i| {
                const here = position + i;
                output[here] = output[here - offset] +% output[here - span] -% output[here - offset - span];
            }
            position += length;
            previous = 2;
            stats.delta += 1;
        }
    }
    workspace.* = .{ .targets = undefined };
    postprocess(output, &workspace.targets, stats);
}

test "LZMS runtime initialization resets every probability context on dirty memory" {
    var state: State = undefined;
    @memset(std.mem.asBytes(&state), 0xa5);
    state.initialize();
    inline for (.{ "main", "match", "lz", "delta" }) |name| {
        const context = @field(state, name);
        try std.testing.expectEqual(@as(usize, 0), context.state);
        for (context.entries) |entry| {
            try std.testing.expectEqual(@as(u32, 48), entry.zeros);
            try std.testing.expectEqual(@as(u64, 0x55555555), entry.recent);
        }
    }
    inline for (.{ "lz_rep", "delta_rep" }) |name| for (@field(state, name)) |context| {
        try std.testing.expectEqual(@as(usize, 0), context.state);
        for (context.entries) |entry| {
            try std.testing.expectEqual(@as(u32, 48), entry.zeros);
            try std.testing.expectEqual(@as(u64, 0x55555555), entry.recent);
        }
    };
    inline for (.{ "literal", "lz_offset", "length", "delta_offset", "power" }) |name| {
        const code = @field(state, name);
        try std.testing.expectEqual(@as(usize, 0), code.symbols);
        try std.testing.expect(!code.tree.nonempty);
        for (code.tree.count) |count| try std.testing.expectEqual(@as(u16, 0), count);
    }
}
pub fn decode(input: []const u8, output: []u8, allocator: std.mem.Allocator) !void {
    var stats: Stats = .{};
    return decodeWithStats(input, output, allocator, &stats);
}

test "LZMS rejects odd/truncated input and unsupported output before allocation" {
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.Truncated, decode(&.{ 1, 2, 3 }, &out, std.testing.allocator));
    try std.testing.expectError(error.Truncated, decode(&.{ 1, 2 }, &out, std.testing.allocator));
    try std.testing.expectError(error.UnsupportedChunkSize, decode(&.{ 1, 2, 3, 4 }, &.{}, std.testing.allocator));
}
test "LZMS delayed-repeat queues move the effective index without losing overflow entries" {
    var queue: [4]u32 = .{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(u32, 40), repeat(u32, &queue, 3));
    try std.testing.expectEqualSlices(u32, &.{ 40, 10, 20, 30 }, &queue);
    push(u32, &queue, 50);
    try std.testing.expectEqualSlices(u32, &.{ 50, 40, 10, 20 }, &queue);
}
