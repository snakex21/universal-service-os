//! A small chunk cache in front of a positional reader (`size()` and
//! `readAt(offset, buffer) !usize`). The UDF/ISO9660 parsers read media in
//! many small pieces (a directory scan reads every 38-byte entry header and
//! then the entry itself), and the UEFI menu reads ISOs on DATA through the
//! NTFS reader and firmware Block I/O, where every piece is one USB command.
//! With the cache a scan of a large `sources` directory costs a few 32 KiB
//! reads instead of thousands of sector reads. Reads of a chunk or more go
//! straight to the inner reader (WIM XML metadata).
const std = @import("std");

pub const chunk_bytes: usize = 32 * 1024;
pub const slot_count: usize = 8;

pub fn CachedReader(comptime Inner: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            valid: bool = false,
            base: u64 = 0,
            len: usize = 0,
            stamp: u64 = 0,
            bytes: [chunk_bytes]u8 = undefined,
        };

        inner: Inner,
        slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
        clock: u64 = 0,

        /// Points the cache at `inner` and drops every cached chunk (call
        /// it whenever the underlying file changes).
        pub fn reset(self: *Self, inner: Inner) void {
            self.inner = inner;
            for (&self.slots) |*slot| slot.valid = false;
            self.clock = 0;
        }

        pub fn size(self: *const Self) u64 {
            return self.inner.size();
        }

        pub fn readAt(self: *Self, offset: u64, output: []u8) !usize {
            const total = self.inner.size();
            if (offset >= total or output.len == 0) return 0;
            const wanted: usize = @intCast(@min(@as(u64, output.len), total - offset));
            if (wanted >= chunk_bytes) return self.inner.readAt(offset, output[0..wanted]);

            var written: usize = 0;
            while (written < wanted) {
                const cursor = offset + written;
                const slot = try self.chunk(cursor - cursor % chunk_bytes, total);
                const within: usize = @intCast(cursor - slot.base);
                if (within >= slot.len) break;
                const amount = @min(wanted - written, slot.len - within);
                @memcpy(output[written..][0..amount], slot.bytes[within..][0..amount]);
                written += amount;
            }
            return written;
        }

        fn chunk(self: *Self, base: u64, total: u64) !*Slot {
            self.clock += 1;
            var victim: ?*Slot = null;
            for (&self.slots) |*slot| {
                if (slot.valid and slot.base == base) {
                    slot.stamp = self.clock;
                    return slot;
                }
                // An empty slot first, otherwise the least recently used.
                const current = victim orelse {
                    victim = slot;
                    continue;
                };
                if (!current.valid) continue;
                if (!slot.valid or slot.stamp < current.stamp) victim = slot;
            }
            const target = victim.?;
            const len: usize = @intCast(@min(@as(u64, chunk_bytes), total - base));
            target.valid = false;
            target.len = try self.inner.readAt(base, target.bytes[0..len]);
            target.base = base;
            target.stamp = self.clock;
            target.valid = true;
            return target;
        }
    };
}

const CountingReader = struct {
    bytes: []const u8,
    calls: usize = 0,

    pub fn size(self: *const CountingReader) u64 {
        return self.bytes.len;
    }

    pub fn readAt(self: *CountingReader, offset: u64, buffer: []u8) !usize {
        self.calls += 1;
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const len = @min(buffer.len, self.bytes.len - start);
        @memcpy(buffer[0..len], self.bytes[start..][0..len]);
        return len;
    }
};

test "cached reads return the same bytes as the inner reader" {
    const bytes = try std.testing.allocator.alloc(u8, 3 * chunk_bytes + 777);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% index / 251);
    var inner = CountingReader{ .bytes = bytes };
    const cache = try std.testing.allocator.create(CachedReader(*CountingReader));
    defer std.testing.allocator.destroy(cache);
    cache.* = .{ .inner = &inner };

    var buffer: [4096]u8 = undefined;
    const offsets = [_]u64{ 0, 1, chunk_bytes - 10, 2 * chunk_bytes + 5, 3 * chunk_bytes + 700, 3 * chunk_bytes + 777, 12345 };
    for (offsets) |offset| {
        const got = try cache.readAt(offset, &buffer);
        const expected: usize = @intCast(@min(@as(u64, buffer.len), bytes.len - @min(offset, bytes.len)));
        try std.testing.expectEqual(expected, got);
        try std.testing.expectEqualSlices(u8, bytes[@intCast(offset)..][0..got], buffer[0..got]);
    }
    // A large read bypasses the cache and is still exact.
    const large = try std.testing.allocator.alloc(u8, chunk_bytes + 3);
    defer std.testing.allocator.free(large);
    try std.testing.expectEqual(large.len, try cache.readAt(100, large));
    try std.testing.expectEqualSlices(u8, bytes[100..][0..large.len], large);
}

test "many small reads of one region cost one inner read per chunk" {
    const bytes = try std.testing.allocator.alloc(u8, 4 * chunk_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0x5a);
    var inner = CountingReader{ .bytes = bytes };
    const cache = try std.testing.allocator.create(CachedReader(*CountingReader));
    defer std.testing.allocator.destroy(cache);
    cache.* = .{ .inner = &inner };

    // A directory-scan pattern: 38-byte header, then the whole entry.
    var header: [38]u8 = undefined;
    var record: [120]u8 = undefined;
    var pos: u64 = 0;
    while (pos + record.len <= 2 * chunk_bytes) : (pos += record.len) {
        _ = try cache.readAt(pos, &header);
        _ = try cache.readAt(pos, &record);
    }
    try std.testing.expectEqual(@as(usize, 2), inner.calls);

    // reset drops the cached chunks.
    cache.reset(&inner);
    _ = try cache.readAt(0, &header);
    try std.testing.expectEqual(@as(usize, 3), inner.calls);
}

test "least recently used chunk is evicted" {
    const bytes = try std.testing.allocator.alloc(u8, (slot_count + 1) * chunk_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 1);
    var inner = CountingReader{ .bytes = bytes };
    const cache = try std.testing.allocator.create(CachedReader(*CountingReader));
    defer std.testing.allocator.destroy(cache);
    cache.* = .{ .inner = &inner };

    var byte: [1]u8 = undefined;
    for (0..slot_count) |index| _ = try cache.readAt(index * chunk_bytes, &byte);
    _ = try cache.readAt(0, &byte); // chunk 0 is now the most recent
    _ = try cache.readAt(slot_count * chunk_bytes, &byte); // evicts chunk 1
    try std.testing.expectEqual(slot_count + 1, inner.calls);
    _ = try cache.readAt(0, &byte);
    try std.testing.expectEqual(slot_count + 1, inner.calls);
    _ = try cache.readAt(chunk_bytes, &byte);
    try std.testing.expectEqual(slot_count + 2, inner.calls);
}
