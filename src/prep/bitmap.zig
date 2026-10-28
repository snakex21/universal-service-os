//! One-page write-back bitmap allocator; no bitmap-size RAM allocation.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
pub const Io = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u64, *[4096]u8) anyerror!void,
    write: *const fn (*anyopaque, u64, *const [4096]u8) anyerror!void,
};
pub const Span = struct { start: u64, count: u64 };
pub const Bitmap = struct {
    io: Io,
    bits: u64,
    minimum: u64 = 0,
    hint: u64 = 0,
    page: [4096]u8 = undefined,
    page_number: ?u64 = null,
    dirty: bool = false,
    pub fn flush(self: *Bitmap) !void {
        if (self.dirty) {
            try self.io.write(self.io.context, self.page_number.? * 4096, &self.page);
            self.dirty = false;
        }
    }
    fn load(self: *Bitmap, bit: u64) !void {
        if (bit >= self.bits) return error.Bounds;
        const number = bit / (4096 * 8);
        if (self.page_number != number) {
            try self.flush();
            try self.io.read(self.io.context, number * 4096, &self.page);
            self.page_number = number;
        }
    }
    pub fn get(self: *Bitmap, bit: u64) !bool {
        try self.load(bit);
        const p: usize = @intCast(bit % (4096 * 8));
        return self.page[p / 8] & (@as(u8, 1) << @intCast(p % 8)) != 0;
    }
    pub fn set(self: *Bitmap, start: u64, count: u64, value: bool) !void {
        if (start > self.bits or count > self.bits - start) return error.Bounds;
        var current = start;
        while (current < start + count) {
            try self.load(current);
            const stop = @min(start + count, (self.page_number.? + 1) * 4096 * 8);
            while (current < stop) : (current += 1) {
                const p: usize = @intCast(current % (4096 * 8));
                const mask = @as(u8, 1) << @intCast(p % 8);
                if (value) self.page[p / 8] |= mask else self.page[p / 8] &= ~mask;
            }
            self.dirty = true;
        }
        // Preserve the forward allocation cursor. Releases often free temporary
        // metadata behind it; restarting there rescans the allocated prefix for
        // every file. allocate() still wraps and reuses all freed space.
    }
    pub fn allocate(self: *Bitmap, maximum: u64) !Span {
        if (maximum == 0 or self.bits == 0) return error.InvalidArgument;
        const begin = @max(self.minimum, @min(self.hint, self.bits));
        var cursor = begin;
        var wrapped = false;
        while (true) {
            const limit = if (wrapped) begin else self.bits;
            while (cursor < limit and try self.get(cursor)) : (cursor += 1) {}
            if (cursor < limit) {
                const first = cursor;
                while (cursor < limit and cursor - first < maximum and !(try self.get(cursor))) : (cursor += 1) {}
                try self.set(first, cursor - first, true);
                self.hint = cursor;
                return .{ .start = first, .count = cursor - first };
            }
            if (wrapped or begin == self.minimum) return error.NoSpace;
            wrapped = true;
            cursor = self.minimum;
        }
    }
};

test "paged bitmap reuses exact freed intervals and wraps without a full RAM bitmap" {
    const Memory = struct {
        bytes: [8192]u8 = @splat(0),
        reads: usize = 0,
        writes: usize = 0,
        fn read(ctx: *anyopaque, off: u64, out: *[4096]u8) !void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(out, s.bytes[@intCast(off)..][0..4096]);
            s.reads += 1;
        }
        fn write(ctx: *anyopaque, off: u64, source: *const [4096]u8) !void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.bytes[@intCast(off)..][0..4096], source);
            s.writes += 1;
        }
    };
    var memory: Memory = .{};
    var map: Bitmap = .{ .io = .{ .context = &memory, .read = Memory.read, .write = Memory.write }, .bits = 65536 };
    try map.set(0, 9, true);
    const a = try map.allocate(33000);
    try std.testing.expectEqualDeep(Span{ .start = 9, .count = 33000 }, a);
    try map.set(100, 20, false);
    try std.testing.expectEqual(@as(u64, 33009), map.hint);
    try std.testing.expectEqualDeep(Span{ .start = 33009, .count = 1000 }, try map.allocate(1000));
    try map.set(0, 65536, true);
    try map.set(100, 20, false);
    const reused = try map.allocate(1000);
    try std.testing.expectEqualDeep(Span{ .start = 100, .count = 20 }, reused);
    try map.flush();
    try std.testing.expect(memory.writes >= 2);
    try map.set(0, 65536, true);
    try map.set(20, 1, false);
    map.hint = 60000;
    try std.testing.expectEqualDeep(Span{ .start = 20, .count = 1 }, try map.allocate(1));
    try std.testing.expectError(error.NoSpace, map.allocate(1));
}
