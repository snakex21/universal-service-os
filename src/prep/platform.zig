//! Platform-neutral, byte-addressed storage contract. No firmware types here.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
pub const profiling = @import("profiling.zig");
pub fn measure(profile: ?*profiling.Profiler, category: profiling.Category) profiling.Token {
    return if (profile) |pr| pr.begin(category) else .{};
}
pub fn measured(profile: ?*profiling.Profiler, token: profiling.Token) void {
    if (profile) |pr| pr.end(token);
}

pub const Error = error{ Io, Bounds, Unsupported, NoSpace, Corrupt, InvalidArgument, TooManyEntries };

/// Attempts reaching a backend, not bounds refusals or empty reads/writes.
/// Saturation keeps diagnostic counters from changing storage behaviour.
pub const IoCounters = struct {
    read_calls: u64 = 0,
    read_bytes: u64 = 0,
    write_calls: u64 = 0,
    write_bytes: u64 = 0,
    flush_calls: u64 = 0,
    failed_calls: u64 = 0,
    pub fn read(self: *IoCounters, count: u64) void { self.read_calls +|= 1; self.read_bytes +|= count; }
    pub fn write(self: *IoCounters, count: u64) void { self.write_calls +|= 1; self.write_bytes +|= count; }
    pub fn flush(self: *IoCounters) void { self.flush_calls +|= 1; }
    pub fn failed(self: *IoCounters) void { self.failed_calls +|= 1; }
    pub fn calls(self: IoCounters) u64 { return self.read_calls +| self.write_calls +| self.flush_calls; }
    pub fn bytes(self: IoCounters) u64 { return self.read_bytes +| self.write_bytes; }
};
pub const Telemetry = struct {
    io: IoCounters = .{},
    target_io: IoCounters = .{},
    monotonic_ms: ?u64 = null,
    io_kind: enum { unavailable, disk_api, block_io } = .unavailable,
    alloc_peak: u64 = 0,
    stack_high_water: u64 = 0,
    stack_available: bool = false,
};
pub const ProgressUpdate = struct { current: u64, total: u64, bytes: u64, resources: u64 };
pub const Progress = struct {
    context: *anyopaque,
    report_fn: *const fn (*anyopaque, ProgressUpdate) void,
    pub fn report(self: Progress, update: ProgressUpdate) void { self.report_fn(self.context, update); }
};

pub const Disk = struct {
    context: *anyopaque,
    sector_bytes: u32 = 512,
    sectors: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) Error!void,
    write_fn: *const fn (*anyopaque, u64, []const u8) Error!void,
    flush_fn: *const fn (*anyopaque) Error!void,
    /// Optional logical Disk API counters. Firmware can instead record the
    /// same IoCounters at every actual BlockIo call, including bounce IO.
    counters: ?*IoCounters = null,
    /// Shared optional CPU/MFT/index profiler. Physical IO is timed by the
    /// platform adapter, so wrapping a Disk does not count IO twice.
    profiler: ?*profiling.Profiler = null,

    pub fn bytes(self: Disk) Error!u64 {
        return std.math.mul(u64, self.sectors, self.sector_bytes) catch error.Bounds;
    }
    fn check(self: Disk, offset: u64, len: usize) Error!void {
        const end = std.math.add(u64, offset, len) catch return error.Bounds;
        if (end > try self.bytes()) return error.Bounds;
    }
    pub fn read(self: Disk, offset: u64, out: []u8) Error!void {
        try self.check(offset, out.len);
        if (out.len != 0) {
            if (self.counters) |c| c.read(out.len);
            self.read_fn(self.context, offset, out) catch |err| {
                if (self.counters) |c| c.failed();
                return err;
            };
        }
    }
    pub fn write(self: Disk, offset: u64, input: []const u8) Error!void {
        try self.check(offset, input.len);
        if (input.len != 0) {
            if (self.counters) |c| c.write(input.len);
            self.write_fn(self.context, offset, input) catch |err| {
                if (self.counters) |c| c.failed();
                return err;
            };
        }
    }
    pub fn flush(self: Disk) Error!void {
        if (self.counters) |c| c.flush();
        self.flush_fn(self.context) catch |err| {
            if (self.counters) |c| c.failed();
            return err;
        };
    }
};

/// Tracks all core allocator requests, including resize/remap, with a hard cap.
/// Fixed platform/firmware buffers and firmware-owned allocations are reported
/// separately: this counter deliberately does not claim total machine RAM.
pub const TrackedAllocator = struct {
    backing: std.mem.Allocator,
    current: usize = 0,
    peak: usize = 0,
    limit: usize = 8 * 1024 * 1024,

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.limit - self.current) return null;
        const result = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.current += len;
        self.peak = @max(self.peak, self.current);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (len > memory.len and len - memory.len > self.limit - self.current) return false;
        if (!self.backing.rawResize(memory, alignment, len, ret)) return false;
        self.current = self.current - memory.len + len;
        self.peak = @max(self.peak, self.current);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (len > memory.len and len - memory.len > self.limit - self.current) return null;
        const ptr = self.backing.rawRemap(memory, alignment, len, ret) orelse return null;
        self.current = self.current - memory.len + len;
        self.peak = @max(self.peak, self.current);
        return ptr;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret);
        self.current -= memory.len;
    }
};

test "allocator cap and lifetime" {
    var tracked: TrackedAllocator = .{ .backing = std.testing.allocator, .limit = 128 };
    const a = tracked.allocator();
    const p = try a.alloc(u8, 100);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 29));
    try std.testing.expectEqual(@as(usize, 100), tracked.current);
    a.free(p);
    try std.testing.expectEqual(@as(usize, 0), tracked.current);
    try std.testing.expectEqual(@as(usize, 100), tracked.peak);
}
