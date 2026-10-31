//! Bounded, random-access traversal of verified WIM image metadata.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Layout/stream semantics: wimlib v1.14.5 dentry.c/security.c (Eric Biggers,
//! LGPL-2.1-or-later). This module stores neither a whole resource nor tree.
const std = @import("std");
const wim = @import("wim.zig");
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn aligned(value: u64) !u64 {
    return (std.math.add(u64, value, 7) catch return error.WimBounds) & ~@as(u64, 7);
}
pub const Times = struct { created: u64, accessed: u64, modified: u64 };
pub const Entry = struct {
    offset: u64,
    next: u64,
    attributes: u32,
    security: u32,
    children: u64,
    times: Times,
    main_hash: [20]u8,
    link_group: u64,
    reparse_tag: u32,
    reparse_reserved: u16,
    reparse_flags: u16,
    extra_count: u16,
    extra_offset: u64,
    short_name_bytes: u16,
    short_name: [12]u16 = undefined,
    short_name_len: usize = 0,
    name: [255]u16 = undefined,
    name_len: usize,
    tagged_metadata: bool,
    tagged_offset: u64 = 0,
    tagged_bytes: u64 = 0,
    pub fn isDirectory(self: Entry) bool {
        return self.attributes & 0x10 != 0;
    }
    pub fn isReparse(self: Entry) bool {
        return self.attributes & 0x400 != 0;
    }
};
pub const Stream = struct {
    next: u64,
    hash: [20]u8,
    name: [255]u16 = undefined,
    name_len: usize,
};
pub const TaggedItem = struct { tag: u32, data_offset: u64, bytes: u32, next: u64 };
pub const StreamKind = enum { data, named_data, reparse };
pub const StreamRef = struct { kind: StreamKind, hash: [20]u8, name: [255]u16 = undefined, name_len: usize = 0 };
pub const StreamIterator = struct {
    metadata: *Metadata,
    entry: Entry,
    main_pending: bool,
    extra_left: u16,
    cursor: u64,
    unnamed: u8 = 0,
    fallback_done: bool = false,
    pub fn init(metadata: *Metadata, entry: Entry) StreamIterator {
        return .{ .metadata = metadata, .entry = entry, .main_pending = !std.mem.allEqual(u8, &entry.main_hash, 0), .extra_left = entry.extra_count, .cursor = entry.extra_offset };
    }
    pub fn next(self: *StreamIterator) !?StreamRef {
        var hash: [20]u8 = undefined;
        if (self.main_pending) {
            self.main_pending = false;
            hash = self.entry.main_hash;
        } else if (self.extra_left != 0) {
            const item = try self.metadata.readStream(self.cursor);
            self.cursor = item.next;
            self.extra_left -= 1;
            if (item.name_len != 0) return .{ .kind = .named_data, .hash = item.hash, .name = item.name, .name_len = item.name_len };
            hash = item.hash;
        } else if (self.unnamed == 0 and !self.fallback_done) {
            self.fallback_done = true;
            hash = @splat(0);
        } else return null;
        const maximum: u8 = if (self.entry.isReparse()) 2 else 1;
        if (self.unnamed >= maximum) return error.UnsupportedExtraUnnamedStream;
        const kind: StreamKind = if (self.unnamed == 0 and self.entry.isReparse()) .reparse else .data;
        self.unnamed += 1;
        return .{ .kind = kind, .hash = hash };
    }
};
pub const Metadata = struct {
    resource: *wim.Resource,
    allocator: std.mem.Allocator,
    security_offsets: []u64,
    root_offset: u64,
    pub fn open(allocator: std.mem.Allocator, resource: *wim.Resource) !Metadata {
        if (!resource.verified) return error.UnverifiedMetadata;
        var head: [8]u8 = undefined;
        try resource.read(0, &head);
        const length = @max(8, try aligned(get(u32, &head, 0)));
        const count = get(u32, &head, 4);
        if (count > 65536 or length > resource.descriptor.size or 8 + @as(u64, count) * 8 > length) return error.CorruptSecurityTable;
        const offsets = try allocator.alloc(u64, @as(usize, count) + 1);
        errdefer allocator.free(offsets);
        var cursor: u64 = 8 + @as(u64, count) * 8;
        for (0..count) |i| {
            try resource.read(8 + @as(u64, i) * 8, &head);
            const n = get(u64, &head, 0);
            if (n < 20 or n > 65536 or cursor > length or n > length - cursor) return error.UnsupportedSecurityDescriptor;
            offsets[i] = cursor;
            cursor += n;
        }
        offsets[count] = cursor;
        return .{ .resource = resource, .allocator = allocator, .security_offsets = offsets, .root_offset = length };
    }
    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.security_offsets);
        self.* = undefined;
    }
    pub fn securityCount(self: Metadata) usize {
        return self.security_offsets.len - 1;
    }
    pub fn readSecurity(self: *Metadata, index: u32, buffer: []u8) ![]const u8 {
        if (index >= self.securityCount()) return error.CorruptSecurityId;
        const at = self.security_offsets[index];
        const n = self.security_offsets[index + 1] - at;
        if (n > buffer.len) return error.SecurityBufferTooSmall;
        try self.resource.read(at, buffer[0..@intCast(n)]);
        return buffer[0..@intCast(n)];
    }
    fn readName(self: *Metadata, at: u64, byte_length: u16, out: []u16, stream_name: bool) !usize {
        if (byte_length % 2 != 0 or byte_length / 2 > out.len) return error.UnsupportedNameLength;
        if (byte_length == 0) return 0;
        var raw: [512]u8 = undefined;
        try self.resource.read(at, raw[0 .. @as(usize, byte_length) + 2]);
        if (get(u16, &raw, byte_length) != 0) return error.CorruptNameTerminator;
        for (0..byte_length / 2) |i| {
            const c = get(u16, &raw, i * 2);
            if (c == 0 or c == '/' or c == '\\' or c == ':') return error.UnsafeWimName;
            out[i] = c;
        }
        if (!stream_name and ((byte_length == 2 and out[0] == '.') or (byte_length == 4 and out[0] == '.' and out[1] == '.'))) return error.UnsafeWimName;
        return byte_length / 2;
    }
    pub fn readStream(self: *Metadata, at: u64) !Stream {
        var result: Stream = undefined;
        try self.readStreamInto(at,&result);
        return result;
    }
    pub fn readStreamInto(self: *Metadata, at: u64, out: *Stream) !void {
        var raw: [38]u8 = undefined;
        try self.resource.read(at, &raw);
        const length = try aligned(get(u64, &raw, 0));
        const name_bytes = get(u16, &raw, 36);
        const needed = 38 + @as(u64, name_bytes) + @as(u64, if (name_bytes != 0) 2 else 0);
        if (length < needed or length > 65536 or at > self.resource.descriptor.size or length > self.resource.descriptor.size - at) return error.CorruptStreamEntry;
        var stream: Stream = .{ .next = at + length, .hash = raw[16..36].*, .name_len = 0 };
        stream.name_len = try self.readName(at + 38, name_bytes, &stream.name, true);
        out.* = stream;
    }
    pub fn readTagged(self: *Metadata, at: u64, end: u64) !TaggedItem {
        if (at > end or end - at < 8) return error.CorruptTaggedMetadata;
        var header: [8]u8 = undefined;
        try self.resource.read(at, &header);
        const bytes = get(u32, &header, 4);
        const size = try aligned(bytes);
        if (size > end - at - 8) return error.CorruptTaggedMetadata;
        return .{ .tag = get(u32, &header, 0), .data_offset = at + 8, .bytes = bytes, .next = at + 8 + size };
    }
    pub fn readEntry(self: *Metadata, at: u64, root: bool) !?Entry {
        var result: Entry = undefined;
        if (try self.readEntryInto(at,root,&result)) return result;
        return null;
    }
    /// Keep validation failures in a small error union on freestanding IA32.
    /// false marks the directory terminator; out is valid only after true.
    pub fn readEntryInto(self: *Metadata, at: u64, root: bool, out: *Entry) !bool {
        if (at % 8 != 0 or at < self.root_offset) return error.CorruptDentryOffset;
        var raw: [102]u8 = undefined;
        try self.resource.read(at, raw[0..8]);
        const raw_length = get(u64, &raw, 0);
        if (raw_length == 0) return false;
        const length = try aligned(raw_length);
        if (length < 102 or length > 65536 or at > self.resource.descriptor.size or length > self.resource.descriptor.size - at) return error.CorruptDentry;
        try self.resource.read(at, &raw);
        const short_bytes = get(u16, &raw, 98);
        const name_bytes = get(u16, &raw, 100);
        const names_end = 102 + @as(u64, name_bytes) + @as(u64, if (name_bytes != 0) 2 else 0) + short_bytes + @as(u64, if (short_bytes != 0) 2 else 0);
        if (names_end > length or short_bytes > 24 or short_bytes % 2 != 0) return error.CorruptDentry;
        var item: Entry = .{
            .offset = at,
            .next = at + length,
            .attributes = get(u32, &raw, 8),
            .security = get(u32, &raw, 12),
            .children = get(u64, &raw, 16),
            .times = .{ .created = get(u64, &raw, 40), .accessed = get(u64, &raw, 48), .modified = get(u64, &raw, 56) },
            .main_hash = raw[64..84].*,
            .link_group = get(u64, &raw, 88),
            .reparse_tag = get(u32, &raw, 88),
            .reparse_reserved = get(u16, &raw, 92),
            .reparse_flags = get(u16, &raw, 94),
            .extra_count = get(u16, &raw, 96),
            .extra_offset = at + length,
            .short_name_bytes = short_bytes,
            .name_len = 0,
            .tagged_metadata = length > try aligned(names_end),
            .tagged_offset = at + try aligned(names_end),
            .tagged_bytes = length - try aligned(names_end),
        };
        if (item.security != 0xffffffff and item.security >= self.securityCount()) return error.CorruptSecurityId;
        if (item.attributes & 0x4000 != 0) return error.UnsupportedEncryptedFile;
        if (item.extra_count > 1024) return error.UnsupportedStreamCount;
        item.name_len = try self.readName(at + 102, name_bytes, &item.name, false);
        if (root != (item.name_len == 0) or (root and !item.isDirectory())) return error.CorruptRootName;
        if (short_bytes != 0) {
            item.short_name_len = try self.readName(at + 102 + name_bytes + @as(u64, if (name_bytes != 0) 2 else 0), short_bytes, &item.short_name, false);
        }
        var tagged = item.tagged_offset;
        while (tagged < item.extra_offset) {
            const tag = try self.readTagged(tagged, item.extra_offset);
            if (tag.tag == 1 and (tag.bytes < 16 or tag.bytes > 64 or tag.bytes % 16 != 0)) return error.UnsupportedObjectId;
            tagged = tag.next;
        }
        if (item.children != 0 and (!item.isDirectory() or item.children <= at or item.children % 8 != 0 or item.children >= self.resource.descriptor.size)) return error.CorruptDentryOffset;
        if (item.isReparse() and (item.children != 0 or (item.reparse_tag != 0xa0000003 and item.reparse_tag != 0xa000000c))) return error.UnsupportedReparsePoint;
        for (0..item.extra_count) |_| item.next = (try self.readStream(item.next)).next;
        out.* = item;
        return true;
    }
    /// Depth-first traversal uses only a bounded parent stack and one dentry.
    /// Entry offsets strictly increase on descent, so cycles cannot recur.
    pub fn walk(self: *Metadata, context: *anyopaque, enter: *const fn (*anyopaque, u64, *const Entry) anyerror!u64, leave: *const fn (*anyopaque, u64, *const Entry) anyerror!void) !void {
        const Frame = struct { offset: u64, cursor: u64, record: u64 };
        const stack = try self.allocator.alloc(Frame, 256);
        defer self.allocator.free(stack);
        const root = (try self.readEntry(self.root_offset, true)) orelse return error.MissingRoot;
        const record = try enter(context, 5, &root);
        stack[0] = .{ .offset = root.offset, .cursor = root.children, .record = record };
        var depth: usize = 1;
        var seen: u64 = 1;
        while (depth != 0) {
            const frame = &stack[depth - 1];
            const item = if (frame.cursor == 0) null else try self.readEntry(frame.cursor, false);
            if (item) |child| {
                frame.cursor = child.next;
                if (seen >= 1000000) return error.WimTreeBudgetExceeded;
                seen += 1;
                const child_record = try enter(context, frame.record, &child);
                if (child.isDirectory() and child.children != 0) {
                    if (depth == stack.len) return error.WimDepthExceeded;
                    stack[depth] = .{ .offset = child.offset, .cursor = child.children, .record = child_record };
                    depth += 1;
                } else try leave(context, child_record, &child);
            } else {
                const entry = (try self.readEntry(frame.offset, depth == 1)) orelse return error.CorruptDentry;
                try leave(context, frame.record, &entry);
                depth -= 1;
            }
        }
    }
};

const TestMemory = struct {
    bytes: []u8,
    fn read(ctx: *anyopaque, at: u64, out: []u8) @import("platform.zig").Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
fn put(comptime T: type, b: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], value, .little);
}
fn fixture(b: []u8) void {
    @memset(b, 0);
    const m = b[208..];
    put(u32, m, 0, 8);
    put(u64, m, 8, 104);
    put(u32, m, 16, 0x10);
    put(u32, m, 20, 0xffffffff);
    put(u64, m, 24, 120);
    put(u64, m, 120, 112);
    put(u32, m, 128, 0x20);
    put(u32, m, 132, 0xffffffff);
    put(u16, m, 220, 6);
    put(u16, m, 222, 'o');
    put(u16, m, 224, 'n');
    put(u16, m, 226, 'e');
}
fn fixtureResource(memory: *TestMemory) !wim.Resource {
    const zero: wim.Descriptor = .{ .stored = 0, .offset = 0, .size = 0, .flags = 0 };
    const header: wim.Header = .{ .version = 0x10d00, .flags = 0, .chunk_size = 0, .compression = null, .images = 1, .lookup = zero, .xml = zero, .integrity = zero };
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(memory.bytes[208..], &hash, .{});
    return wim.Resource.init(std.testing.allocator, .{ .context = memory, .size = memory.bytes.len, .read_fn = TestMemory.read }, header, .{ .offset = 208, .stored = memory.bytes.len - 208, .size = memory.bytes.len - 208, .flags = 2 }, hash);
}
test "metadata requires verified SHA1, walks bounded parents, and rejects traversal and cycles" {
    var bytes: [720]u8 = undefined;
    fixture(&bytes);
    var memory: TestMemory = .{ .bytes = &bytes };
    var resource = try fixtureResource(&memory);
    defer resource.deinit();
    try std.testing.expectError(error.UnverifiedMetadata, Metadata.open(std.testing.allocator, &resource));
    try resource.verify();
    var metadata = try Metadata.open(std.testing.allocator, &resource);
    defer metadata.deinit();
    const Visitor = struct {
        enters: usize = 0,
        leaves: usize = 0,
        fn enter(ctx: *anyopaque, _: u64, item: *const Entry) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.enters += 1;
            if (self.enters == 2) try std.testing.expectEqualSlices(u16, &.{ 'o', 'n', 'e' }, item.name[0..item.name_len]);
            return 5;
        }
        fn leave(ctx: *anyopaque, _: u64, _: *const Entry) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.leaves += 1;
        }
    };
    var visitor: Visitor = .{};
    try metadata.walk(&visitor, Visitor.enter, Visitor.leave);
    try std.testing.expectEqual(@as(usize, 2), visitor.enters);
    try std.testing.expectEqual(visitor.enters, visitor.leaves);
    put(u16, bytes[208..], 224, '/');
    resource.cached_chunk = std.math.maxInt(u64);
    try std.testing.expectError(error.UnsafeWimName, metadata.readEntry(120, false));
    put(u16, bytes[208..], 224, 'n');
    put(u32, bytes[208..], 128, 0x10);
    put(u64, bytes[208..], 136, 8);
    resource.cached_chunk = std.math.maxInt(u64);
    try std.testing.expectError(error.CorruptDentryOffset, metadata.readEntry(120, false));
}
test "metadata stream types keep reparse separate from data and ADS" {
    var bytes: [720]u8 = undefined;
    fixture(&bytes);
    const m = bytes[208..];
    put(u32, m, 128, 0x420);
    put(u32, m, 208, 0xa000000c);
    put(u16, m, 216, 3);
    put(u64, m, 232, 40);
    @memset(m[248..268], 0x11);
    put(u64, m, 272, 40);
    @memset(m[288..308], 0x22);
    put(u64, m, 312, 48);
    @memset(m[328..348], 0x33);
    put(u16, m, 348, 8);
    put(u16, m, 350, 'Z');
    put(u16, m, 352, 'o');
    put(u16, m, 354, 'n');
    put(u16, m, 356, 'e');
    var memory: TestMemory = .{ .bytes = &bytes };
    var resource = try fixtureResource(&memory);
    defer resource.deinit();
    try resource.verify();
    var metadata = try Metadata.open(std.testing.allocator, &resource);
    defer metadata.deinit();
    const item = (try metadata.readEntry(120, false)).?;
    var direct: Entry = undefined;
    try std.testing.expect(try metadata.readEntryInto(120,false,&direct));
    try std.testing.expectEqual(item.offset,direct.offset);
    try std.testing.expectEqual(item.next,direct.next);
    try std.testing.expectEqual(item.extra_count,direct.extra_count);
    try std.testing.expectEqualSlices(u16,item.name[0..item.name_len],direct.name[0..direct.name_len]);
    try std.testing.expect(!(try metadata.readEntryInto(360,false,&direct)));
    try std.testing.expect((try metadata.readEntry(360,false))==null);
    try std.testing.expectError(error.CorruptDentryOffset,metadata.readEntryInto(121,false,&direct));
    try std.testing.expectError(error.CorruptDentryOffset,metadata.readEntry(121,false));
    var stream: Stream = undefined;
    try metadata.readStreamInto(312,&stream);
    const wrapped = try metadata.readStream(312);
    try std.testing.expectEqual(wrapped.next,stream.next);
    try std.testing.expectEqualSlices(u8,&wrapped.hash,&stream.hash);
    try std.testing.expectEqualSlices(u16,wrapped.name[0..wrapped.name_len],stream.name[0..stream.name_len]);
    try std.testing.expectError(error.CorruptStreamEntry,metadata.readStreamInto(360,&stream));
    try std.testing.expectError(error.CorruptStreamEntry,metadata.readStream(360));
    var iterator = StreamIterator.init(&metadata, item);
    try std.testing.expectEqual(StreamKind.reparse, (try iterator.next()).?.kind);
    try std.testing.expectEqual(StreamKind.data, (try iterator.next()).?.kind);
    const ads = (try iterator.next()).?;
    try std.testing.expectEqual(StreamKind.named_data, ads.kind);
    try std.testing.expectEqualSlices(u16, &.{ 'Z', 'o', 'n', 'e' }, ads.name[0..ads.name_len]);
    try std.testing.expect((try iterator.next()) == null);
}
