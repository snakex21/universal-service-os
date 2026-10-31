//! Bounded, read-only Windows boot-resource inventory shared by both modes.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const nt = @import("ntfs_ro");
const app = @import("app.zig");
const upper = @import("unicode_upper.zig").upperUnit;
const u = std.unicode.utf8ToUtf16LeStringLiteral;
pub const Arch = enum { x64, ia32 };
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
pub const Item = struct { source: []u16, target: []u8, directory: bool, size: u64 = 0, sha256: [32]u8 = @splat(0) };
pub fn samePath(a: []const u8, b: []const u8) bool {
    const av = std.unicode.Utf8View.init(a) catch return false;
    const bv = std.unicode.Utf8View.init(b) catch return false;
    var ai = av.iterator();
    var bi = bv.iterator();
    while (ai.nextCodepoint()) |ac| {
        const bc = bi.nextCodepoint() orelse return false;
        if ((if (ac <= 65535) @as(u21, upper(@intCast(ac))) else ac) != (if (bc <= 65535) @as(u21, upper(@intCast(bc))) else bc)) return false;
    }
    return bi.nextCodepoint() == null;
}
pub const Context = struct {
    disk: p.Disk,
    allocator: std.mem.Allocator,
    fs: *nt.FileSystem,
    large: *nt.LargeFile,
    buffer: []u8,
    page: []nt.DirectoryItem,
    items: std.ArrayList(Item) = .empty,
    last_error: ?p.Error = null,
    log: app.Logger,
    pub fn deinit(self: *Context) void {
        self.rollback(0);
        self.items.deinit(self.allocator);
    }
    pub fn rollback(self: *Context, start: usize) void {
        for (self.items.items[start..]) |item| {
            self.allocator.free(item.source);
            self.allocator.free(item.target);
        }
        self.items.items.len = start;
    }
    pub fn read(ctx: *anyopaque, at: u64, out: []u8) error{ Io, OutOfBounds }!void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        self.disk.read(at, out) catch |err| {
            self.last_error = err;
            return if (err == error.Bounds) error.OutOfBounds else error.Io;
        };
    }
    fn components(path: []const u16, out: *[32][]const u16) ![]const []const u16 {
        var it = std.mem.splitScalar(u16, path, '\\');
        var count: usize = 0;
        while (it.next()) |name| {
            if (name.len == 0 or count == out.len) return error.BootPathBudget;
            out[count] = name;
            count += 1;
        }
        return out[0..count];
    }
    pub fn open(self: *Context, path: []const u16) !void {
        var fields: [32][]const u16 = undefined;
        try nt.openLargeFile(self.fs, .{ .context = self, .read_fn = read }, try components(path, &fields), self.allocator, self.large);
    }
    pub fn hash(self: *Context, path: []const u16, expected_size: u64) ![32]u8 {
        try self.open(path);
        defer self.large.deinit();
        if (self.large.size() != expected_size) return error.BootSourceSizeChanged;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var at: u64 = 0;
        while (at < expected_size) {
            const n: usize = @intCast(@min(self.buffer.len, expected_size - at));
            try self.large.readAt(self.fs, .{ .context = self, .read_fn = read }, at, self.buffer[0..n]);
            sha.update(self.buffer[0..n]);
            at += n;
        }
        return sha.finalResult();
    }
    pub fn append(self: *Context, source: []const u16, target: []const u8, directory: bool, size: u64) !void {
        if (self.items.items.len >= 4096 or source.len > 4096 or target.len > 4096 or size > std.math.maxInt(u32)) return error.BootInventoryBudget;
        for (self.items.items) |old| if (samePath(old.target, target) and !(old.directory and directory)) return error.BootTargetCollision;
        const src = try self.allocator.dupe(u16, source);
        errdefer self.allocator.free(src);
        const dst = try self.allocator.dupe(u8, target);
        errdefer self.allocator.free(dst);
        try self.items.append(self.allocator, .{ .source = src, .target = dst, .directory = directory, .size = size });
    }
    pub fn collect(self: *Context, source: []const u16, target: []const u8) !void {
        var fields: [32][]const u16 = undefined;
        _ = try nt.directoryInfo(self.fs.*, .{ .context = self, .read_fn = read }, try components(source, &fields));
        const first = self.items.items.len;
        try self.append(source, target, true, 0);
        var cursor = first;
        while (cursor < self.items.items.len) : (cursor += 1) {
            const current = self.items.items[cursor];
            if (!current.directory) continue;
            var skip: usize = 0;
            while (true) {
                const page = try nt.listDirectoryPage(self.fs.*, .{ .context = self, .read_fn = read }, try components(current.source, &fields), skip, self.page);
                if (page.count == 0 and page.has_more) return error.BootDirectoryLoop;
                for (self.page[0..page.count]) |child| {
                    const name = child.name[0..child.name_len];
                    if (name.len == 0 or std.mem.eql(u16, name, u(".")) or std.mem.eql(u16, name, u(".."))) continue;
                    if (child.namespace == 2) continue;
                    if (child.attributes & 0x400 != 0) return error.UnsupportedBootReparse;
                    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.InvalidBootName;
                    for (name) |c| if (c < 32 or std.mem.indexOfScalar(u16, &.{ ':', '*', '?', '"', '<', '>', '|', '/', '\\' }, c) != null) return error.InvalidBootName;
                    const utf8 = try std.unicode.utf16LeToUtf8Alloc(self.allocator, name);
                    defer self.allocator.free(utf8);
                    const src = try self.allocator.alloc(u16, current.source.len + 1 + name.len);
                    defer self.allocator.free(src);
                    @memcpy(src[0..current.source.len], current.source);
                    src[current.source.len] = '\\';
                    @memcpy(src[current.source.len + 1 ..], name);
                    const dst = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current.target, utf8 });
                    defer self.allocator.free(dst);
                    try self.append(src, dst, child.isDirectory(), child.size);
                }
                if (!page.has_more) break;
                skip = std.math.add(usize, skip, page.count) catch return error.BootInventoryBudget;
            }
        }
        for (self.items.items[first..]) |*item| {
            if (!item.directory) item.sha256 = try self.hash(item.source, item.size);
        }
    }
    pub fn pe(self: *Context, path: []const u16, arch: Arch) !void {
        try self.open(path);
        defer self.large.deinit();
        if (self.large.size() < 64) return error.InvalidBootImage;
        try self.large.readAt(self.fs, .{ .context = self, .read_fn = read }, 0, self.buffer[0..64]);
        if (!std.mem.eql(u8, self.buffer[0..2], "MZ")) return error.InvalidBootImage;
        const at = get(u32, self.buffer, 60);
        if (at < 64 or at > self.large.size() or self.large.size() - at < 96) return error.InvalidBootImage;
        try self.large.readAt(self.fs, .{ .context = self, .read_fn = read }, at, self.buffer[0..96]);
        const machine: u16 = if (arch == .x64) 0x8664 else 0x14c;
        const magic: u16 = if (arch == .x64) 0x20b else 0x10b;
        if (!std.mem.eql(u8, self.buffer[0..4], "PE\x00\x00") or get(u16, self.buffer, 4) != machine or get(u16, self.buffer, 20) < 72 or get(u16, self.buffer, 24) != magic or
            (get(u16, self.buffer, 92) != 10 and get(u16, self.buffer, 92) != 16)) return error.InvalidBootImage;
    }
};
