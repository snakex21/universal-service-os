//! Ordered target write combining for explicitly authorized virtual cases.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
pub const capacity = 1024 * 1024;
pub const alignment = std.mem.Alignment.fromByteUnits(4096);
pub const Backend = enum { raw_file, qcow2_file };
pub const Stats = struct {
    logical_writes: u64 = 0,
    logical_bytes: u64 = 0,
    upstream_writes: u64 = 0,
    upstream_bytes: u64 = 0,
    drains: u64 = 0,
    overlay_reads: u64 = 0,
    overlay_bytes: u64 = 0,
    recovery_writes: u64 = 0,
    failures: u64 = 0,
};
pub const Cache = struct {
    base: p.Disk,
    allocator: std.mem.Allocator,
    backend: Backend,
    buffer: []align(4096) u8,
    start: u64 = 0,
    pending: usize = 0,
    first_error: ?p.Error = null,
    stats: Stats = .{},

    /// Backend identity is supplied only by the pinned virtual-case caller.
    /// Guest BlockIo geometry cannot identify a raw/QCOW host backing file.
    pub fn init(allocator: std.mem.Allocator, base: p.Disk, backend: Backend) !Cache {
        if ((base.sector_bytes != 512 and base.sector_bytes != 4096) or try base.bytes() < 4096) return error.Unsupported;
        return .{ .base = base, .allocator = allocator, .backend = backend, .buffer = try allocator.alignedAlloc(u8, alignment, capacity) };
    }
    /// Does no I/O, including on error unwind. The caller explicitly flushes
    /// before claiming success; abandoned pending bytes are intentionally lost.
    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
    pub fn disk(self: *Cache) p.Disk {
        return .{ .context = self, .sector_bytes = self.base.sector_bytes, .sectors = self.base.sectors,
            .read_fn = read, .write_fn = write, .flush_fn = flushCallback, .profiler = self.base.profiler };
    }
    fn fail(self: *Cache, err: p.Error) p.Error {
        if (self.first_error == null) self.first_error = err;
        self.stats.failures +|= 1;
        // The failed operation may have partially overwritten the backend.
        // Never replay this uncertain batch over a later dirty-state repair.
        self.pending = 0;
        return err;
    }
    fn directWrite(self: *Cache, at: u64, bytes: []const u8) p.Error!void {
        self.stats.upstream_writes +|= 1;
        self.stats.upstream_bytes +|= bytes.len;
        self.base.write(at, bytes) catch |err| return self.fail(err);
    }
    fn drain(self: *Cache) p.Error!void {
        if (self.pending == 0) return;
        try self.directWrite(self.start, self.buffer[0..self.pending]);
        self.stats.drains +|= 1;
        self.pending = 0;
    }
    pub fn flush(self: *Cache) p.Error!void {
        if (self.first_error) |original| {
            // Dirty-state repair writes bypass the cache after poison. Still
            // attempt their durability barrier, but never return success.
            self.base.flush() catch { self.stats.failures +|= 1; };
            return original;
        }
        try self.drain();
        self.base.flush() catch |err| return self.fail(err);
    }
    fn flushCallback(ctx: *anyopaque) p.Error!void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.flush();
    }
    fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) p.Error!void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        self.stats.logical_writes +|= 1;
        self.stats.logical_bytes +|= bytes.len;
        if (self.first_error != null) {
            // NTFS markIncomplete must be able to repair $Volume after a
            // failed final flush. This cannot clear the sticky failure.
            self.stats.recovery_writes +|= 1;
            try self.directWrite(offset, bytes);
            return;
        }
        var done: usize = 0;
        while (done < bytes.len) {
            const at = offset + done; // Disk checks the whole request first.
            if (self.pending != 0 and at != self.start + self.pending) try self.drain();
            if (self.pending == 0) self.start = at;
            const n = @min(bytes.len - done, self.buffer.len - self.pending);
            @memcpy(self.buffer[self.pending..][0..n], bytes[done..][0..n]);
            self.pending += n;
            done += n;
            if (self.pending == self.buffer.len) try self.drain();
        }
    }
    fn sourceRead(self: *Cache, at: u64, out: []u8) p.Error!void {
        if (out.len == 0) return;
        self.base.read(at, out) catch |err| return self.fail(err);
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        if (self.pending == 0 or self.first_error != null or offset >= self.start + self.pending or offset + out.len <= self.start) {
            try self.sourceRead(offset, out);
            return;
        }
        var done: usize = 0;
        if (offset < self.start) {
            done = @intCast(self.start - offset);
            try self.sourceRead(offset, out[0..done]);
        }
        const within: usize = @intCast(offset + done - self.start);
        const n = @min(out.len - done, self.pending - within);
        @memcpy(out[done..][0..n], self.buffer[within..][0..n]);
        self.stats.overlay_reads +|= 1;
        self.stats.overlay_bytes +|= n;
        done += n;
        if (done != out.len) try self.sourceRead(offset + done, out[done..]);
    }
};
test { _ = @import("writecombine_tests.zig"); }
