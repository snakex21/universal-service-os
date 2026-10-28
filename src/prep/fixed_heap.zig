//! Bounded single-threaded heap for the BIOS-owned E820 range. Physical block
//! headers live inside that range; arbitrary-order frees split/coalesce there.
//! No OS allocator, atomics, modern CPU instructions or out-of-arena metadata.
const std = @import("std");
const Heap = @This();
const none = std.math.maxInt(usize);
const Header = extern struct { bytes: usize, previous: usize, next: usize, requested: usize };
const unit = @alignOf(Header);
const header_bytes = @sizeOf(Header);
const minimum_block = header_bytes + @sizeOf(usize) + unit;

buffer: []u8,
current_bytes: usize = 0,
peak_bytes: usize = 0,
extent_peak_bytes: usize = 0,

pub fn init(storage: []u8) Heap {
    const start = std.mem.alignForward(usize, @intFromPtr(storage.ptr), unit);
    const skipped = start - @intFromPtr(storage.ptr);
    std.debug.assert(skipped <= storage.len);
    const bytes = std.mem.alignBackward(usize, storage.len - skipped, unit);
    std.debug.assert(bytes >= minimum_block);
    var self: Heap = .{ .buffer = storage[skipped..][0..bytes] };
    self.header(0).* = .{ .bytes = bytes, .previous = none, .next = none, .requested = 0 };
    return self;
}

pub fn allocator(self: *Heap) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn header(self: *Heap, offset: usize) *Header {
    std.debug.assert(offset <= self.buffer.len - header_bytes and offset % unit == 0);
    return @ptrCast(@alignCast(self.buffer.ptr + offset));
}

fn prefix(self: *Heap, payload: usize) *align(1) usize {
    return @ptrCast(self.buffer.ptr + payload - @sizeOf(usize));
}

fn split(self: *Heap, offset: usize, wanted: usize) void {
    const h = self.header(offset);
    if (h.bytes - wanted < minimum_block) return;
    const tail = offset + wanted;
    self.header(tail).* = .{ .bytes = h.bytes - wanted, .previous = offset, .next = h.next, .requested = 0 };
    if (h.next != none) self.header(h.next).previous = tail;
    h.bytes = wanted;
    h.next = tail;
}

fn mergeNext(self: *Heap, offset: usize) void {
    const h = self.header(offset);
    if (h.next == none) return;
    const next = self.header(h.next).*;
    std.debug.assert(next.requested == 0 and offset + h.bytes == h.next);
    h.bytes += next.bytes;
    h.next = next.next;
    if (next.next != none) self.header(next.next).previous = offset;
}

fn recordPeak(self: *Heap, offset: usize) void {
    self.peak_bytes = @max(self.peak_bytes, self.current_bytes);
    self.extent_peak_bytes = @max(self.extent_peak_bytes, offset + self.header(offset).bytes);
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *Heap = @ptrCast(@alignCast(context));
    var offset: usize = 0;
    while (true) {
        const h = self.header(offset);
        if (h.requested == 0) {
            const address = std.mem.alignForward(usize, @intFromPtr(self.buffer.ptr) + offset + header_bytes + @sizeOf(usize), alignment.toByteUnits());
            const payload = address - @intFromPtr(self.buffer.ptr);
            const end = std.math.add(usize, payload, len) catch return null;
            if (end <= offset + h.bytes) {
                const wanted = std.mem.alignForward(usize, end - offset, unit);
                self.split(offset, wanted);
                h.requested = len;
                self.prefix(payload).* = offset;
                self.current_bytes += h.bytes;
                self.recordPeak(offset);
                return self.buffer.ptr + payload;
            }
        }
        if (h.next == none) return null;
        offset = h.next;
    }
}

fn locate(self: *Heap, memory: []u8) usize {
    const payload = @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
    std.debug.assert(payload >= header_bytes + @sizeOf(usize) and payload < self.buffer.len);
    const offset = self.prefix(payload).*;
    const h = self.header(offset);
    std.debug.assert(h.requested == memory.len and payload + memory.len <= offset + h.bytes);
    return offset;
}

fn resize(context: *anyopaque, memory: []u8, _: std.mem.Alignment, len: usize, _: usize) bool {
    const self: *Heap = @ptrCast(@alignCast(context));
    const offset = self.locate(memory);
    const h = self.header(offset);
    const payload = @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
    const end = std.math.add(usize, payload, len) catch return false;
    if (end > self.buffer.len) return false;
    const wanted = std.mem.alignForward(usize, end - offset, unit);
    const old = h.bytes;
    if (wanted > h.bytes) {
        if (h.next == none) return false;
        const next = self.header(h.next);
        if (next.requested != 0 or wanted > h.bytes + next.bytes) return false;
        self.mergeNext(offset);
    }
    self.split(offset, wanted);
    // Splitting a shrinking allocation may adjoin an already-free successor.
    if (h.next != none) {
        const tail = self.header(h.next);
        if (tail.requested == 0 and tail.next != none and self.header(tail.next).requested == 0)
            self.mergeNext(h.next);
    }
    h.requested = len;
    self.current_bytes = self.current_bytes - old + h.bytes;
    self.recordPeak(offset);
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
    return if (resize(context, memory, alignment, len, ret)) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const self: *Heap = @ptrCast(@alignCast(context));
    var offset = self.locate(memory);
    const h = self.header(offset);
    self.current_bytes -= h.bytes;
    h.requested = 0;
    if (h.next != none and self.header(h.next).requested == 0) self.mergeNext(offset);
    if (h.previous != none and self.header(h.previous).requested == 0) {
        offset = h.previous;
        self.mergeNext(offset);
    }
}

test "non-LIFO repeated frees reclaim the actual fixed arena" {
    var region: [16384]u8 align(16) = undefined;
    var heap = Heap.init(&region);
    const a = heap.allocator();
    for (0..10000) |_| {
        const first = try a.alloc(u8, 129);
        const second = try a.alloc(u8, 312);
        const third = try a.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 700);
        a.free(first);
        a.free(second);
        a.free(third);
        try std.testing.expectEqual(@as(usize, 0), heap.current_bytes);
        try std.testing.expectEqual(region.len, heap.header(0).bytes);
        try std.testing.expectEqual(none, heap.header(0).next);
    }
    try std.testing.expect(heap.peak_bytes < 8192);
    const large = try a.alloc(u8, 16000);
    a.free(large);
}

test "splitting coalescing growth and shrink preserve live neighbors" {
    var region: [8192]u8 align(16) = undefined;
    var heap = Heap.init(&region);
    const a = heap.allocator();
    var first = try a.alloc(u8, 512);
    const middle = try a.alloc(u8, 1024);
    const last = try a.alloc(u8, 512);
    @memset(first, 0x39); @memset(last, 0x75);
    a.free(middle);
    first = try a.realloc(first, 1200);
    try std.testing.expect(std.mem.allEqual(u8, first[0..512], 0x39));
    first = try a.realloc(first, 64);
    const reused = try a.alloc(u8, 1000);
    try std.testing.expect(std.mem.allEqual(u8, last, 0x75));
    a.free(last); a.free(first); a.free(reused);
    try std.testing.expectEqual(@as(usize, 0), heap.current_bytes);
    try std.testing.expectEqual(region.len, heap.header(0).bytes);
}

test "bounded heap honors alignment exhaustion and caller canaries" {
    var region: [4098]u8 = @splat(0xC7);
    var heap = Heap.init(region[1 .. region.len - 1]);
    const a = heap.allocator();
    const aligned = try a.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(256), 513);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 256);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4096));
    @memset(aligned, 0xAB);
    a.free(aligned);
    try std.testing.expectEqual(@as(u8, 0xC7), region[0]);
    try std.testing.expectEqual(@as(u8, 0xC7), region[region.len - 1]);
}

test "mixed arbitrary-order realloc and free keep payloads and recover all space" {
    var region: [32768]u8 align(16) = undefined;
    var heap = Heap.init(&region);
    const a = heap.allocator();
    var slots: [64]?[]u8 = @splat(null);
    var random = std.Random.DefaultPrng.init(0xED09A735);
    for (0..20000) |_| {
        const slot = random.random().uintLessThan(usize, slots.len);
        if (slots[slot]) |old| {
            try std.testing.expect(std.mem.allEqual(u8, old, @intCast(slot)));
            if (random.random().boolean()) {
                const wanted = random.random().uintLessThan(usize, 512) + 1;
                const changed = a.realloc(old, wanted) catch continue;
                try std.testing.expect(std.mem.allEqual(u8, changed[0..@min(old.len, wanted)], @intCast(slot)));
                @memset(changed, @intCast(slot));
                slots[slot] = changed;
            } else { a.free(old); slots[slot] = null; }
        } else {
            const bytes = a.alloc(u8, random.random().uintLessThan(usize, 512) + 1) catch continue;
            @memset(bytes, @intCast(slot)); slots[slot] = bytes;
        }
    }
    for (slots) |slot| if (slot) |bytes| { a.free(bytes); };
    try std.testing.expectEqual(@as(usize, 0), heap.current_bytes);
    try std.testing.expectEqual(region.len, heap.header(0).bytes);
    try std.testing.expectEqual(none, heap.header(0).next);
}
