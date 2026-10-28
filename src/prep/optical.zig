//! Read-only, platform-independent optical filesystem API.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! ECMA-119 (ISO9660/Joliet), ECMA-167 and OSTA UDF 2.60.
const std = @import("std");
const p = @import("platform.zig");
const upper = @import("unicode_upper.zig");
const iso = @import("optical_iso.zig");
const udf = @import("optical_udf.zig");
pub const max_extents = 256;
pub const max_depth = 64;
pub const max_directory_bytes = 64 * 1024 * 1024;
pub const max_tree_entries = 1000000;
pub const max_path_bytes = 4096;
pub const Input = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) p.Error!void,
    pub fn read(self: Input, offset: u64, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset) return error.OpticalBounds;
        if (out.len != 0) try self.read_fn(self.context, offset, out);
    }
    pub fn fromDisk(disk: *p.Disk) !Input {
        return .{ .context = disk, .size = try disk.bytes(), .read_fn = diskRead };
    }
    fn diskRead(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const disk: *p.Disk = @ptrCast(@alignCast(ctx));
        try disk.read(offset, out);
    }
};
pub const Extent = struct { offset: u64, length: u64, tag_lba: u32 = 0 };
pub const Node = struct {
    size: u64 = 0,
    directory: bool = false,
    identity: u64 = 0,
    udf_partition: u16 = 0,
    udf_lba: u32 = 0,
    extents: [max_extents]Extent = undefined,
    count: usize = 0,
    pub fn append(self: *Node, input: Input, offset: u64, length: u64) !void {
        if (length == 0) return;
        if (offset != std.math.maxInt(u64) and (offset > input.size or length > input.size - offset)) return error.OpticalBounds;
        if (self.count == max_extents) return error.ExtentBudget;
        self.extents[self.count] = .{ .offset = offset, .length = length };
        self.count += 1;
    }
    pub fn read(self: *const Node, input: Input, offset: u64, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset) return error.OpticalBounds;
        var skip = offset;
        var done: usize = 0;
        for (self.extents[0..self.count]) |extent| {
            if (skip >= extent.length) { skip -= extent.length; continue; }
            const n: usize = @intCast(@min(out.len - done, extent.length - skip));
            if (extent.offset == std.math.maxInt(u64)) @memset(out[done..][0..n], 0)
            else try input.read(try add(extent.offset, skip), out[done..][0..n]);
            done += n; skip = 0;
            if (done == out.len) return;
        }
        if (done != out.len) return error.TruncatedOpticalFile;
    }
};
pub const Entry = struct {
    name: [255]u16 = undefined,
    name_len: usize = 0,
    node: Node = .{},
    unsupported: ?anyerror = null,
    pub fn nameSlice(self: *const Entry) []const u16 { return self.name[0..self.name_len]; }
};
pub const Kind = enum { iso9660, joliet, udf };
pub const Volume = struct {
    input: Input,
    kind: Kind,
    block_size: u32 = 2048,
    root: Node,
    udf_state: udf.State = .{},
    pub fn open(input: Input) !Volume {
        var result: Volume = undefined;
        try openInto(input,&result);
        return result;
    }
    /// Keep failures in a small error union; a comptime error returned with a
    /// 12 KiB payload otherwise emits large zero-filled constants on IA32.
    pub fn openInto(input: Input, out: *Volume) !void {
        if (try udf.recognized(input)) return udf.mountInto(input,out);
        return iso.mountInto(input,out);
    }
    pub fn list(self: *const Volume, directory: Node) !Iterator {
        var result: Iterator = undefined;
        try self.listInto(&directory, &result);
        return result;
    }
    /// Pointer variant avoids an additional 6 KiB argument copy in firmware.
    pub fn listInto(self: *const Volume, directory: *const Node, out: *Iterator) !void {
        if (!directory.directory) return error.NotDirectory;
        if (directory.size > max_directory_bytes) return error.DirectoryBudget;
        out.* = .{ .volume = self, .directory = directory.* };
    }
    pub fn find(self: *const Volume, path: []const u8) !Node {
        var result: Node = undefined;
        try self.findInto(path,&result);
        return result;
    }
    pub fn findInto(self: *const Volume, path: []const u8, out: *Node) !void {
        var current = self.root;
        var seen: [max_depth]u64 = undefined;
        seen[0] = current.identity;
        var depth: usize = 1;
        var parts = std.mem.tokenizeAny(u8, path, "/\\");
        while (parts.next()) |part| {
            if (depth == max_depth) return error.DirectoryDepth;
            var name: [255]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&name, part) catch return error.InvalidOpticalName;
            try validateName(name[0..len]);
            var entries: Iterator = undefined;
            try self.listInto(&current,&entries);
            // Listing skips optional unsupported entries, but asking for one
            // explicitly must report its reason rather than resolve another file.
            entries.include_unsupported = true;
            var found = false;
            var entry: Entry = undefined;
            while (try entries.next(&entry)) {
                if (equalName(entry.nameSlice(), name[0..len])) {
                    if (entry.unsupported) |reason| return reason;
                    if (found) return error.AmbiguousOpticalName;
                    out.* = entry.node;
                    found = true;
                }
            }
            if (!found) return error.NotFound;
            current = out.*;
            if (current.directory) {
                for (seen[0..depth]) |id| if (id == current.identity) return error.DirectoryLoop;
                seen[depth] = current.identity;
                depth += 1;
            }
        }
        out.* = current;
    }
    /// WIM takes precedence. ESD and split-WIM are detected explicitly rather
    /// than producing an unhelpful NotFound after the user selected an ISO.
    pub fn findInstallWim(self: *const Volume) !Node {
        var result: Node = undefined;
        try self.findInstallWimInto(&result);
        return result;
    }
    pub fn findInstallWimInto(self: *const Volume, out: *Node) !void {
        if (self.findInto("sources\\install.wim",out)) |_| {
            if (out.directory) return error.NotFile;
            return;
        } else |err| if (err != error.NotFound) return err;
        if (self.findInto("sources\\install.esd",out)) |_| {
            return error.InstallEsdUnsupported;
        } else |err| if (err != error.NotFound) return err;
        try self.findInto("sources",out);
        var iterator: Iterator = undefined;
        try self.listInto(out,&iterator);
        var entry: Entry = undefined;
        while (try iterator.next(&entry)) {
            const name = entry.nameSlice();
            if (name.len >= 11 and equalName(name[0..7],&.{'i','n','s','t','a','l','l'}) and
                equalName(name[name.len-4..],&.{'.','s','w','m'})) return error.InstallSwmUnsupported;
        }
        return error.NotFound;
    }
};
pub const Skipped = struct {
    symbolic_links: usize = 0,
    streams: usize = 0,
    nameless: usize = 0,
    other: usize = 0,
    pub fn total(self: Skipped) usize { return self.symbolic_links + self.streams + self.nameless + self.other; }
    pub fn add(self: *Skipped, other: Skipped) void {
        self.symbolic_links += other.symbolic_links;
        self.streams += other.streams;
        self.nameless += other.nameless;
        self.other += other.other;
    }
};
pub const Iterator = struct {
    volume: *const Volume,
    directory: Node,
    offset: u64 = 0,
    records: usize = 0,
    include_unsupported: bool = false,
    skipped: Skipped = .{},
    tree_budget: ?*TreeBudget = null,
    pub fn record(self: *Iterator) !void {
        if (self.tree_budget) |budget| try budget.consume();
        if (self.records == 1000000) return error.DirectoryBudget;
        self.records += 1;
    }
    pub fn next(self: *Iterator, entry: *Entry) !bool {
        return if (self.volume.kind == .udf) udf.next(self, entry) else iso.next(self, entry);
    }
};
/// Shared physical-record fuel also charges skipped entries. Directory depth
/// and ancestor identity checks prevent cycles without a recursive stack.
pub const TreeBudget = struct {
    limit: usize = max_tree_entries,
    records: usize = 0,
    pub fn consume(self: *TreeBudget) !void {
        if (self.records >= self.limit) return error.TreeBudget;
        self.records += 1;
    }
};
pub const Walker = struct {
    const Frame = struct { iterator: Iterator, path_len: usize };
    allocator: std.mem.Allocator,
    volume: *const Volume,
    frames: []Frame,
    path_buffer: []u8,
    path_len: usize = 0,
    depth: usize = 1,
    budget: TreeBudget = .{},
    entries: usize = 0,
    skipped: Skipped = .{},
    pub fn init(volume: *const Volume, allocator: std.mem.Allocator) !Walker {
        const frames = try allocator.alloc(Frame, max_depth);
        errdefer allocator.free(frames);
        const path_buffer = try allocator.alloc(u8, max_path_bytes);
        errdefer allocator.free(path_buffer);
        try volume.listInto(&volume.root, &frames[0].iterator);
        frames[0].path_len = 0;
        return .{ .allocator = allocator, .volume = volume, .frames = frames, .path_buffer = path_buffer };
    }
    pub fn deinit(self: *Walker) void {
        self.allocator.free(self.path_buffer);
        self.allocator.free(self.frames);
    }
    pub fn path(self: *const Walker) []const u8 { return self.path_buffer[0..self.path_len]; }
    pub fn next(self: *Walker, entry: *Entry) !bool {
        while (self.depth != 0) {
            const frame = &self.frames[self.depth-1];
            frame.iterator.tree_budget = &self.budget;
            const before = frame.iterator.skipped;
            const has_next = try frame.iterator.next(entry);
            const after = frame.iterator.skipped;
            self.skipped.add(.{
                .symbolic_links = after.symbolic_links-before.symbolic_links,
                .streams = after.streams-before.streams,
                .nameless = after.nameless-before.nameless,
                .other = after.other-before.other,
            });
            if (!has_next) { self.depth -= 1; continue; }
            var at = frame.path_len;
            if (at != 0) {
                if (at == self.path_buffer.len) return error.PathBudget;
                self.path_buffer[at] = '/'; at += 1;
            }
            const n = std.unicode.utf16LeToUtf8(self.path_buffer[at..],entry.nameSlice()) catch return error.PathBudget;
            at += n;
            if (entry.node.directory) {
                for (self.frames[0..self.depth]) |*ancestor| if (ancestor.iterator.directory.identity == entry.node.identity) return error.DirectoryLoop;
                if (self.depth == self.frames.len) return error.DirectoryDepth;
                const child = &self.frames[self.depth];
                try self.volume.listInto(&entry.node, &child.iterator);
                child.path_len = at;
                self.depth += 1;
            }
            self.path_len = at;
            self.entries += 1;
            return true;
        }
        return false;
    }
};
/// A WIM-compatible seekable view. The adapter has no write method.
pub const Stream = struct {
    input: Input,
    node: Node,
    last_error: ?anyerror = null,
    pub fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Stream = @ptrCast(@alignCast(ctx));
        self.node.read(self.input, offset, out) catch |err| {
            self.last_error = err;
            return switch (err) {
                error.Io => error.Io,
                error.Bounds, error.OpticalBounds => error.Bounds,
                error.Unsupported => error.Unsupported,
                error.NoSpace => error.NoSpace,
                error.InvalidArgument => error.InvalidArgument,
                error.TooManyEntries => error.TooManyEntries,
                else => error.Corrupt,
            };
        };
    }
};
pub fn add(a: u64, b: u64) !u64 { return std.math.add(u64, a, b) catch error.OpticalBounds; }
pub fn mul(a: u64, b: u64) !u64 { return std.math.mul(u64, a, b) catch error.OpticalBounds; }
pub fn le(comptime T: type, bytes: []const u8, at: usize) T { return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little); }
pub fn be(comptime T: type, bytes: []const u8, at: usize) T { return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .big); }
pub fn equalName(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper.upperUnit(x) != upper.upperUnit(y)) return false;
    return true;
}
pub fn validateName(name: []const u16) !void {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u16, name, &.{'.'}) or std.mem.eql(u16, name, &.{'.', '.'})) return error.InvalidOpticalName;
    for (name) |c| if (c < 32 or c == '/' or c == '\\' or c == 0 or c >= 0xd800 and c <= 0xdfff) return error.InvalidOpticalName;
}
