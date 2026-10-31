//! Bounded current-directory INDX read cache. SPDX-License-Identifier: GPL-3.0-or-later
//!
//! Pages contain exactly the MST-protected bytes exchanged by index.Backend.
//! Writes remain write-through; a failed operation discards all cached pages.
//! Keep this object at a stable address after obtaining backend(). The owner
//! must be switched before the underlying directory runlists are changed.
const std = @import("std");
const index = @import("index.zig");

pub const page_count = 32;
pub const payload_bytes = page_count * index.block_bytes;
const Tag = struct { vcn: u64 = 0, valid: bool = false, referenced: bool = false };
pub const Stats = struct {
    read_hits: u64 = 0,
    read_misses: u64 = 0,
    backend_reads: u64 = 0,
    backend_writes: u64 = 0,
    invalidations: u64 = 0,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    backing: index.Backend,
    pages: [][4096]u8,
    tags: [page_count]Tag = @splat(.{}),
    hand: usize = 0,
    owner: ?u64 = null,
    revision: u64 = 1,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator, backing: index.Backend) !Cache {
        return .{ .allocator = allocator, .backing = backing, .pages = try allocator.alloc([4096]u8, page_count) };
    }
    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.pages);
        self.pages = &.{};
        self.owner = null;
    }
    pub fn switchOwner(self: *Cache, owner: u64) void {
        if (self.owner == owner) return;
        self.owner = owner;
        self.invalidateAll();
    }
    pub fn invalidateAll(self: *Cache) void {
        for (&self.tags) |*tag| tag.valid = false;
        self.hand = 0;
        self.changed();
        self.stats.invalidations +|= 1;
    }
    pub fn invalidateNode(self: *Cache, vcn: u64) void {
        for (&self.tags) |*tag| if (tag.valid and tag.vcn == vcn) {
            tag.valid = false;
        };
        self.changed();
        self.stats.invalidations +|= 1;
    }
    pub fn backend(self: *Cache) index.Backend {
        return .{ .context = self, .read_node = read, .write_node = write,
            .alloc_node = allocate, .free_node = free, .set_root = setRoot, .identity = identity,
            .invalidate = invalidate };
    }
    fn changed(self: *Cache) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
    fn identity(ctx: *anyopaque) ?index.Identity {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        return .{ .owner = self.owner orelse return null, .revision = self.revision };
    }
    fn invalidate(ctx: *anyopaque) void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        self.invalidateAll();
    }
    fn slot(self: *Cache, vcn: u64) ?usize {
        for (self.tags, 0..) |tag, i| if (tag.valid and tag.vcn == vcn) return i;
        return null;
    }
    fn victim(self: *Cache) usize {
        for (0..page_count * 2) |_| {
            const result = self.hand;
            self.hand = (self.hand + 1) % page_count;
            const tag = &self.tags[result];
            if (!tag.valid or !tag.referenced) return result;
            tag.referenced = false;
        }
        unreachable;
    }
    fn remember(self: *Cache, vcn: u64, data: *const [4096]u8) void {
        const place = self.slot(vcn) orelse self.victim();
        self.pages[place] = data.*;
        self.tags[place] = .{ .vcn = vcn, .valid = true, .referenced = true };
    }
    fn ready(self: *const Cache) !void {
        if (self.owner == null or self.pages.len != page_count) return error.InvalidArgument;
    }
    fn read(ctx: *anyopaque, vcn: u64, out: *[4096]u8) !void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.ready();
        if (self.slot(vcn)) |place| {
            self.stats.read_hits +|= 1;
            self.tags[place].referenced = true;
            out.* = self.pages[place];
            return;
        }
        self.stats.read_misses +|= 1;
        self.stats.backend_reads +|= 1;
        self.backing.read_node(self.backing.context, vcn, out) catch |err| {
            self.invalidateAll();
            return err;
        };
        self.remember(vcn, out);
    }
    fn write(ctx: *anyopaque, vcn: u64, data: *const [4096]u8) !void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.ready();
        self.stats.backend_writes +|= 1;
        self.backing.write_node(self.backing.context, vcn, data) catch |err| {
            self.invalidateAll();
            return err;
        };
        self.remember(vcn, data);
        self.changed();
    }
    fn allocate(ctx: *anyopaque) !u64 {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.ready();
        const vcn = self.backing.alloc_node(self.backing.context) catch |err| {
            self.invalidateAll();
            return err;
        };
        self.invalidateNode(vcn);
        return vcn;
    }
    fn free(ctx: *anyopaque, vcn: u64) !void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.ready();
        self.invalidateNode(vcn);
        self.backing.free_node(self.backing.context, vcn) catch |err| {
            self.invalidateAll();
            return err;
        };
    }
    fn setRoot(ctx: *anyopaque, vcn: u64) !void {
        const self: *Cache = @ptrCast(@alignCast(ctx));
        try self.ready();
        self.backing.set_root(self.backing.context, vcn) catch |err| {
            self.invalidateAll();
            return err;
        };
        self.changed();
    }
};

comptime {
    // Includes the caller's persistent bitmap and one active prepared hint.
    if (payload_bytes + @sizeOf(Cache) + @sizeOf(index.InsertHint) + 4096 + 128 > 144 * 1024)
        @compileError("Directory index cache exceeds its144KiB budget");
}
