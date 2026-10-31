//! WIM export + update writer: one image of a source WIM becomes a new
//! single-image WIM, with files added or replaced (the Alpine route's
//! `wimlib-imagex export SRC IDX DST --boot` followed by
//! `wimlib-imagex update DST 1 < add-commands`, in one pass).
//! SPDX-License-Identifier: GPL-3.0-or-later
//! Disk-layout references: wimlib v1.14.5 header.h/resource.h/dentry.c/
//! blob_table.c/xml.c (Eric Biggers, LGPL-2.1-or-later) and the public WIM
//! format; this is an own Zig implementation, no foreign code is linked.
//!
//! Design:
//! * The output is a pull Source with an exact precomputed size, read
//!   strictly sequentially (an NTFS writeFile can consume it directly).
//! * Existing blobs referenced by the image are copied byte-for-byte (same
//!   compressed chunks, flags and chunk size); unreferenced ones are dropped.
//! * New file data is stored uncompressed (resource flags 0), metadata is
//!   stored uncompressed (flags 0x2), lookup table and XML as wimlib (0x2).
//! * The metadata resource is rewritten by streaming the old one: dentries
//!   are copied with their subdirectory offsets relocated, new dentries are
//!   inserted in the directory's existing collation order, replaced dentries
//!   are swapped. Nothing but bounded per-blob bookkeeping is kept in RAM.
//! * New dentries follow wimlib's UNIX capture (the Alpine route): no short
//!   name, no security descriptor (-1) unless `.parent` is chosen, a single
//!   timestamp, FILE_ATTRIBUTE_NORMAL unless set otherwise.
const std = @import("std");
const platform = @import("platform.zig");
const wim = @import("wim.zig");
const meta = @import("wim_metadata.zig");
const upper = @import("unicode_upper.zig");

pub const Source = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) platform.Error!void,
};
pub const Add = struct {
    /// WIM path with '/' or '\\' separators, e.g. "/Windows/System32/x.ini".
    path: []const u8,
    source: Source,
};
pub const SecurityMode = enum { none, parent };
pub const Options = struct {
    guid: [16]u8,
    /// FILETIME for new dentries and the image LASTMODIFICATIONTIME.
    timestamp: u64,
    attributes: u32 = 0x80,
    security: SecurityMode = .none,
    boot: bool = true,
};
pub const Stats = struct {
    dirs: u64 = 0,
    files: u64 = 0,
    total_bytes: u64 = 0,
    hard_link_bytes: u64 = 0,
    added: u32 = 0,
    replaced: u32 = 0,
    new_blobs: u32 = 0,
    deduplicated: u32 = 0,
    copied_blobs: u32 = 0,
    dropped_blobs: u32 = 0,
    copied_bytes: u64 = 0,
    unsorted_parents: u32 = 0,
    metadata_old: u64 = 0,
    metadata_new: u64 = 0,
};

const Blob = struct { offset: u64, stored: u64, size: u64, hash: [20]u8, refs: u32, flags: u8 };
const Target = struct { offset: u64, next: u64, link_group: u64, reparse: bool, old_bytes: u64, links: u32 = 0 };
const Pending = struct {
    source: Source,
    size: u64,
    hash: [20]u8,
    parent_security: u32,
    insert_at: u64,
    name: []u16,
    target: ?Target,
    blob: ?u32 = null, // index into new blobs, null = existing/empty
};
const Edit = struct { offset: u64, old_len: u64, bytes: []u8, replace: bool, name: []const u16 };
const NewBlob = struct { pending: u32, refs: u32 };
const max_name = 255;
const xml_limit = 256 * 1024;

fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn align8(v: u64) u64 {
    return (v + 7) & ~@as(u64, 7);
}
/// Windows collation used for directory order and name equality.
pub fn compareNames(a: []const u16, b: []const u16) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const x = upper.upperUnit(a[i]);
        const y = upper.upperUnit(b[i]);
        if (x != y) return std.math.order(x, y);
    }
    return std.math.order(a.len, b.len);
}
fn descriptorBytes(out: []u8, stored: u64, flags: u8, offset: u64, size: u64) void {
    put(u64, out, 0, stored | (@as(u64, flags) << 56));
    put(u64, out, 8, offset);
    put(u64, out, 16, size);
}

pub const Plan = struct {
    allocator: std.mem.Allocator,
    archive: *wim.Archive,
    options: Options,
    resource: wim.Resource,
    tree: meta.Metadata,
    blobs: []Blob,
    copy_count: usize = 0,
    pending: []Pending,
    edits: []Edit,
    new_blobs: []NewBlob,
    xml: []u8,
    header: [208]u8 = @splat(0),
    stats: Stats = .{},
    // Layout.
    data_end: u64 = 208,
    meta_offset: u64 = 0,
    meta_size: u64 = 0,
    /// Chunk-table bytes in front of the metadata (raw-chunk format).
    meta_table: u64 = 0,
    meta_flags: u8 = 2,
    table_scratch: [8]u8 = undefined,
    lookup_offset: u64 = 0,
    lookup_size: u64 = 0,
    xml_offset: u64 = 0,
    size: u64 = 0,
    // Sequential producer state.
    cursor: u64 = 0,
    segment: u8 = 0,
    item: usize = 0,
    within: u64 = 0,
    blob_sha: std.crypto.hash.Sha1 = std.crypto.hash.Sha1.init(.{}),
    meta_sha: std.crypto.hash.Sha1 = std.crypto.hash.Sha1.init(.{}),
    meta_hash: [20]u8 = undefined,
    em_old: u64 = 0,
    em_span_start: u64 = 0,
    em_span_end: u64 = 0,
    em_fix: ?u64 = null,
    em_in_span: bool = false,
    em_edit: usize = 0,
    em_edit_pos: usize = 0,
    em_in_edit: bool = false,
    lookup_scratch: [50]u8 = undefined,
    lookup_out_offset: u64 = 208,
    last_error: ?anyerror = null,

    /// `archive` must be opened with `selected` = the image to export.
    pub fn init(allocator: std.mem.Allocator, archive: *wim.Archive, adds: []const Add, options: Options) !*Plan {
        const self = try allocator.create(Plan);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .archive = archive, .options = options, .resource = undefined, .tree = undefined, .blobs = &.{}, .pending = &.{}, .edits = &.{}, .new_blobs = &.{}, .xml = &.{} };
        self.resource = try archive.openMetadata();
        errdefer self.resource.deinit();
        try self.resource.verify();
        self.tree = try meta.Metadata.open(allocator, &self.resource);
        errdefer self.tree.deinit();
        self.stats.metadata_old = self.resource.descriptor.size;
        errdefer self.freeOwned();
        try self.loadBlobs();
        try self.resolve(adds);
        try self.countTree();
        try self.applyAdds();
        try self.buildEdits();
        try self.layout();
        return self;
    }
    fn freeOwned(self: *Plan) void {
        const a = self.allocator;
        a.free(self.blobs);
        for (self.pending) |p| a.free(p.name);
        a.free(self.pending);
        for (self.edits) |e| a.free(e.bytes);
        a.free(self.edits);
        a.free(self.new_blobs);
        a.free(self.xml);
    }
    pub fn deinit(self: *Plan) void {
        self.freeOwned();
        self.tree.deinit();
        self.resource.deinit();
        self.allocator.destroy(self);
    }
    pub fn source(self: *Plan) Source {
        return .{ .context = self, .size = self.size, .read_fn = readFn };
    }

    fn loadBlobs(self: *Plan) !void {
        const entries: usize = @intCast(self.archive.resource_count);
        self.blobs = try self.allocator.alloc(Blob, entries);
        for (self.blobs, 0..) |*b, i| {
            const e = try self.archive.entry(@intCast(i));
            b.* = .{ .offset = e.descriptor.offset, .stored = e.descriptor.stored, .size = e.descriptor.size, .hash = e.sha1, .refs = 0, .flags = e.descriptor.flags };
        }
    }

    fn splitPath(self: *Plan, path: []const u8, out: *std.ArrayList([]u16)) !void {
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, ":\x00") != null) return error.InvalidWimPath;
            const len = std.unicode.calcUtf16LeLen(part) catch return error.InvalidWimPath;
            if (len == 0 or len > max_name) return error.InvalidWimPath;
            const wide = try self.allocator.alloc(u16, len);
            errdefer self.allocator.free(wide);
            _ = std.unicode.utf8ToUtf16Le(wide, part) catch return error.InvalidWimPath;
            try out.append(self.allocator, wide);
        }
        if (out.items.len == 0) return error.InvalidWimPath;
    }
    /// Find `name` among the children of `dir`; also the collation insert
    /// position and whether the existing list is in collation order.
    const Lookup = struct { found: ?meta.Entry, insert_at: u64, sorted: bool };
    fn lookupChild(self: *Plan, children: u64, name: []const u16) !Lookup {
        if (children == 0) return error.UnsupportedEmptyWimDirectory;
        var cursor = children;
        var result: Lookup = .{ .found = null, .insert_at = 0, .sorted = true };
        var prev: [max_name]u16 = undefined;
        var prev_len: usize = 0;
        var have_prev = false;
        var entry: meta.Entry = undefined;
        var seen: u32 = 0;
        while (try self.tree.readEntryInto(cursor, false, &entry)) {
            seen += 1;
            if (seen > 1_000_000) return error.WimTreeBudgetExceeded;
            const child = entry.name[0..entry.name_len];
            if (have_prev and compareNames(prev[0..prev_len], child) == .gt) result.sorted = false;
            const order = compareNames(child, name);
            if (order == .eq) {
                if (result.found != null) return error.AmbiguousWimName;
                result.found = entry;
            }
            if (order == .gt and result.insert_at == 0) result.insert_at = entry.offset;
            @memcpy(prev[0..child.len], child);
            prev_len = child.len;
            have_prev = true;
            cursor = entry.next;
        }
        if (!result.sorted or result.insert_at == 0) result.insert_at = cursor; // terminator
        return result;
    }
    fn resolve(self: *Plan, adds: []const Add) !void {
        self.pending = try self.allocator.alloc(Pending, adds.len);
        var filled: usize = 0;
        errdefer {
            for (self.pending[0..filled]) |p| self.allocator.free(p.name);
            self.allocator.free(self.pending);
            self.pending = &.{};
        }
        const buffer = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(buffer);
        for (adds, 0..) |add, i| {
            var parts: std.ArrayList([]u16) = .empty;
            defer {
                for (parts.items) |p| self.allocator.free(p);
                parts.deinit(self.allocator);
            }
            try self.splitPath(add.path, &parts);
            var dir = (try self.tree.readEntry(self.tree.root_offset, true)) orelse return error.MissingRoot;
            for (parts.items[0 .. parts.items.len - 1]) |part| {
                const found = (try self.lookupChild(dir.children, part)).found orelse return error.WimParentMissing;
                if (!found.isDirectory() or found.isReparse()) return error.WimParentNotDirectory;
                dir = found;
            }
            const leaf = parts.items[parts.items.len - 1];
            const look = try self.lookupChild(dir.children, leaf);
            if (!look.sorted) self.stats.unsorted_parents += 1;
            var target: ?Target = null;
            if (look.found) |old| {
                if (old.isDirectory()) return error.WimTargetIsDirectory;
                target = .{ .offset = old.offset, .next = old.next, .link_group = if (old.isReparse()) 0 else old.link_group, .reparse = old.isReparse(), .old_bytes = 0 };
            }
            // Stream the source once for its SHA-1; it is streamed again,
            // and checked against this hash, when the blob is written.
            var hasher = std.crypto.hash.Sha1.init(.{});
            var at: u64 = 0;
            while (at < add.source.size) {
                const n: usize = @intCast(@min(buffer.len, add.source.size - at));
                try add.source.read_fn(add.source.context, at, buffer[0..n]);
                hasher.update(buffer[0..n]);
                at += n;
            }
            var hash: [20]u8 = @splat(0);
            if (add.source.size != 0) hash = hasher.finalResult();
            const name = try self.allocator.dupe(u16, leaf);
            self.pending[i] = .{ .source = add.source, .size = add.source.size, .hash = hash, .parent_security = dir.security, .insert_at = if (look.found) |old| old.offset else look.insert_at, .name = name, .target = target };
            filled += 1;
            for (self.pending[0..i]) |other| {
                if (other.insert_at == self.pending[i].insert_at and (other.target != null) == (target != null) and compareNames(other.name, name) == .eq) return error.DuplicateWimAdd;
                if (other.target != null and target != null and other.target.?.offset == target.?.offset) return error.DuplicateWimAdd;
            }
        }
    }

    const Counter = struct {
        plan: *Plan,
        fn enter(ctx: *anyopaque, _: u64, item: *const meta.Entry) anyerror!u64 {
            const self: *Counter = @ptrCast(@alignCast(ctx));
            const plan = self.plan;
            if (item.isDirectory()) plan.stats.dirs += 1 else plan.stats.files += 1;
            var streams = meta.StreamIterator.init(&plan.tree, item.*);
            var bytes: u64 = 0;
            while (try streams.next()) |stream| {
                if (std.mem.allEqual(u8, &stream.hash, 0)) continue;
                const number = try plan.archive.findNumber(stream.hash);
                plan.blobs[number].refs += 1;
                bytes += plan.blobs[number].size;
            }
            plan.stats.total_bytes += bytes;
            for (plan.pending) |*p| if (p.target) |*t| {
                if (t.offset == item.offset) t.old_bytes = bytes;
                if (t.link_group != 0 and !item.isReparse() and item.link_group == t.link_group) t.links += 1;
            };
            return 5;
        }
        fn leave(_: *anyopaque, _: u64, _: *const meta.Entry) anyerror!void {}
    };
    fn countTree(self: *Plan) !void {
        var counter: Counter = .{ .plan = self };
        try self.tree.walk(&counter, Counter.enter, Counter.leave);
        self.stats.hard_link_bytes = try self.sourceHardLinkBytes();
    }
    fn applyAdds(self: *Plan) !void {
        var list: std.ArrayList(NewBlob) = .empty;
        errdefer list.deinit(self.allocator);
        for (self.pending, 0..) |*p, i| {
            if (p.target) |t| {
                var old = (try self.tree.readEntry(t.offset, false)) orelse return error.CorruptDentry;
                var streams = meta.StreamIterator.init(&self.tree, old);
                while (try streams.next()) |stream| {
                    if (std.mem.allEqual(u8, &stream.hash, 0)) continue;
                    const number = try self.archive.findNumber(stream.hash);
                    if (self.blobs[number].refs == 0) return error.CorruptLookupTable;
                    self.blobs[number].refs -= 1;
                }
                _ = &old;
                self.stats.total_bytes -= t.old_bytes;
                if (t.links >= 2) self.stats.hard_link_bytes -|= t.old_bytes;
                self.stats.replaced += 1;
            } else {
                self.stats.files += 1;
                self.stats.added += 1;
            }
            self.stats.total_bytes += p.size;
            if (p.size == 0) continue;
            if (self.archive.findNumber(p.hash)) |number| {
                self.blobs[number].refs += 1;
                self.stats.deduplicated += 1;
                continue;
            } else |err| if (err != error.MissingWimResource) return err;
            var shared = false;
            for (list.items, 0..) |*nb, k| if (std.mem.eql(u8, &self.pending[nb.pending].hash, &p.hash)) {
                nb.refs += 1;
                p.blob = @intCast(k);
                shared = true;
                self.stats.deduplicated += 1;
                break;
            };
            if (!shared) {
                p.blob = @intCast(list.items.len);
                try list.append(self.allocator, .{ .pending = @intCast(i), .refs = 1 });
            }
        }
        self.new_blobs = try list.toOwnedSlice(self.allocator);
        self.stats.new_blobs = @intCast(self.new_blobs.len);
        // Referenced blobs first, in source file order (sequential reads).
        var w: usize = 0;
        for (self.blobs) |b| {
            if (b.refs != 0) {
                self.blobs[w] = b;
                w += 1;
            } else if (b.flags & 2 == 0) self.stats.dropped_blobs += 1;
        }
        self.copy_count = w;
        std.mem.sort(Blob, self.blobs[0..w], {}, struct {
            fn less(_: void, a: Blob, b: Blob) bool {
                return a.offset < b.offset;
            }
        }.less);
        self.stats.copied_blobs = @intCast(w);
    }
    /// The source XML HARDLINKBYTES; replacements adjust it (see applyAdds).
    fn sourceHardLinkBytes(self: *Plan) !u64 {
        const text = try self.readSourceXml();
        defer self.allocator.free(text);
        const image = try findImage(text, self.archive.selected);
        const value = findText(text[image.start..image.end], "HARDLINKBYTES") orelse return 0;
        return parseDecimal(text[image.start + value.start .. image.start + value.end]);
    }
    fn readSourceXml(self: *Plan) ![]u16 {
        const d = self.archive.header.xml;
        if (d.size < 2 or d.size % 2 != 0 or d.size > xml_limit) return error.UnsupportedWimXml;
        var res = try wim.Resource.init(self.allocator, self.archive.input, self.archive.header, d, null);
        defer res.deinit();
        const raw = try self.allocator.alloc(u8, @intCast(d.size));
        defer self.allocator.free(raw);
        try res.read(0, raw);
        if (get(u16, raw, 0) != 0xfeff) return error.UnsupportedWimXml;
        const text = try self.allocator.alloc(u16, raw.len / 2 - 1);
        for (text, 0..) |*c, i| c.* = get(u16, raw, 2 + i * 2);
        return text;
    }

    fn newDentry(self: *Plan, p: *const Pending) ![]u8 {
        const len = align8(102 + p.name.len * 2 + 2);
        const bytes = try self.allocator.alloc(u8, @intCast(len));
        @memset(bytes, 0);
        put(u64, bytes, 0, len);
        put(u32, bytes, 8, self.options.attributes);
        put(u32, bytes, 12, if (self.options.security == .parent) p.parent_security else 0xffffffff);
        put(u64, bytes, 40, self.options.timestamp);
        put(u64, bytes, 48, self.options.timestamp);
        put(u64, bytes, 56, self.options.timestamp);
        @memcpy(bytes[64..84], &p.hash);
        put(u16, bytes, 100, @intCast(p.name.len * 2));
        for (p.name, 0..) |c, i| put(u16, bytes, 102 + i * 2, c);
        return bytes;
    }
    fn buildEdits(self: *Plan) !void {
        self.edits = try self.allocator.alloc(Edit, self.pending.len);
        var made: usize = 0;
        errdefer {
            for (self.edits[0..made]) |e| self.allocator.free(e.bytes);
            self.allocator.free(self.edits);
            self.edits = &.{};
        }
        for (self.pending) |*p| {
            const bytes = try self.newDentry(p);
            self.edits[made] = .{ .offset = p.insert_at, .old_len = if (p.target) |t| t.next - t.offset else 0, .bytes = bytes, .replace = p.target != null, .name = p.name };
            made += 1;
        }
        std.mem.sort(Edit, self.edits, {}, struct {
            fn less(_: void, a: Edit, b: Edit) bool {
                if (a.offset != b.offset) return a.offset < b.offset;
                if (a.replace != b.replace) return !a.replace; // inserts before the replaced dentry
                return compareNames(a.name, b.name) == .lt;
            }
        }.less);
        var size = self.resource.descriptor.size;
        for (self.edits) |e| size = size - e.old_len + e.bytes.len;
        self.meta_size = size;
        self.stats.metadata_new = size;
    }
    /// New offset of an old metadata offset that starts an item.
    fn relocate(self: *const Plan, old: u64) u64 {
        var delta: i64 = 0;
        for (self.edits) |e| {
            if (e.offset >= old) break;
            delta += @as(i64, @intCast(e.bytes.len)) - @as(i64, @intCast(e.old_len));
        }
        return @intCast(@as(i64, @intCast(old)) + delta);
    }
    fn layout(self: *Plan) !void {
        var at: u64 = 208;
        for (self.blobs[0..self.copy_count]) |b| at += b.stored;
        self.stats.copied_bytes = at - 208;
        for (self.new_blobs) |nb| at += self.pending[nb.pending].size;
        self.data_end = at;
        self.meta_offset = at;
        // Metadata in an archive with compression: a compressed-flag resource
        // whose chunks are all stored raw (stored == chunk size), the form
        // every LZX/XPRESS/LZMS reader handles for incompressible chunks,
        // so a boot-time parser never meets uncompressed metadata.
        const chunk = self.archive.header.chunk_size;
        if (self.archive.header.compression != null and self.meta_size != 0) {
            const entry: u64 = if (self.meta_size > std.math.maxInt(u32)) 8 else 4;
            self.meta_table = (self.meta_size - 1) / chunk * entry;
            self.meta_flags = 6;
        }
        at += self.meta_table + self.meta_size;
        self.lookup_offset = at;
        self.lookup_size = (@as(u64, self.copy_count) + self.new_blobs.len + 1) * 50;
        at += self.lookup_size;
        self.xml_offset = at;
        try self.buildXml(at);
        self.size = at + self.xml.len;
        self.buildHeader();
    }
    fn buildHeader(self: *Plan) void {
        const h = &self.header;
        @memset(h, 0);
        @memcpy(h[0..8], "MSWIM\x00\x00\x00");
        put(u32, h, 8, 208);
        put(u32, h, 12, self.archive.header.version);
        // Keep compression/RP_FIX; drop read-only, split, resource/metadata-only.
        put(u32, h, 16, self.archive.header.flags & ~@as(u32, 0x7c));
        put(u32, h, 20, self.archive.header.chunk_size);
        @memcpy(h[24..40], &self.options.guid);
        put(u16, h, 40, 1);
        put(u16, h, 42, 1);
        put(u32, h, 44, 1);
        descriptorBytes(h[48..72], self.lookup_size, 2, self.lookup_offset, self.lookup_size);
        descriptorBytes(h[72..96], self.xml.len, 2, self.xml_offset, self.xml.len);
        if (self.options.boot) {
            descriptorBytes(h[96..120], self.meta_table + self.meta_size, self.meta_flags, self.meta_offset, self.meta_size);
            put(u32, h, 120, 1);
        }
    }

    // ---- XML -------------------------------------------------------------
    const Span = struct { start: usize, end: usize };
    fn findSeq(hay: []const u16, comptime needle: []const u8, from: usize) ?usize {
        const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(needle);
        const at = std.mem.indexOfPos(u16, hay, from, wide) orelse return null;
        return at;
    }
    /// The whole <IMAGE INDEX="n">...</IMAGE> element.
    fn findImage(text: []const u16, index: u32) !Span {
        var from: usize = 0;
        while (findSeq(text, "<IMAGE INDEX=\"", from)) |start| {
            const digits = start + 14;
            const quote = std.mem.indexOfScalarPos(u16, text, digits, '"') orelse return error.CorruptWimXml;
            const value = parseDecimal(text[digits..quote]) catch return error.CorruptWimXml;
            const close = findSeq(text, "</IMAGE>", quote) orelse return error.CorruptWimXml;
            if (value == index) return .{ .start = start, .end = close + 8 };
            from = close;
        }
        return error.CorruptWimXml;
    }
    /// Text span of the first <TAG>text</TAG> inside `scope`.
    fn findText(scope: []const u16, comptime tag: []const u8) ?Span {
        const open = findSeq(scope, "<" ++ tag ++ ">", 0) orelse return null;
        const start = open + tag.len + 2;
        const end = findSeq(scope, "</" ++ tag ++ ">", start) orelse return null;
        return .{ .start = start, .end = end };
    }
    fn parseDecimal(text: []const u16) !u64 {
        if (text.len == 0) return error.CorruptWimXml;
        var v: u64 = 0;
        for (text) |c| {
            if (c < '0' or c > '9') return error.CorruptWimXml;
            v = std.math.mul(u64, v, 10) catch return error.CorruptWimXml;
            v = std.math.add(u64, v, c - '0') catch return error.CorruptWimXml;
        }
        return v;
    }
    const Replacement = struct { span: Span, text: []const u8 };
    fn buildXml(self: *Plan, xml_offset: u64) !void {
        const text = try self.readSourceXml();
        defer self.allocator.free(text);
        const image_span = try findImage(text, self.archive.selected);
        const image = text[image_span.start..image_span.end];
        var bufs: [6][24]u8 = undefined;
        var reps: [7]Replacement = undefined;
        var n: usize = 0;
        // INDEX="n" -> INDEX="1".
        const digits = 14;
        const quote = std.mem.indexOfScalarPos(u16, image, digits, '"').?;
        reps[n] = .{ .span = .{ .start = digits, .end = quote }, .text = "1" };
        n += 1;
        // A plain export keeps the image XML as it is (wimlib export does);
        // an update recounts it and sets LASTMODIFICATIONTIME (wimlib update).
        const updated = self.pending.len != 0;
        const tags = .{ "DIRCOUNT", "FILECOUNT", "TOTALBYTES", "HARDLINKBYTES" };
        const values = [_]u64{ self.stats.dirs, self.stats.files, self.stats.total_bytes, self.stats.hard_link_bytes };
        if (updated) inline for (tags, 0..) |tag, k| {
            if (findText(image, tag)) |span| {
                reps[n] = .{ .span = span, .text = try std.fmt.bufPrint(&bufs[k], "{d}", .{values[k]}) };
                n += 1;
            }
        };
        if (!updated) {} else if (findText(image, "LASTMODIFICATIONTIME")) |lm| {
            const scope = image[lm.start..lm.end];
            if (findText(scope, "HIGHPART")) |hi| {
                reps[n] = .{ .span = .{ .start = lm.start + hi.start, .end = lm.start + hi.end }, .text = try std.fmt.bufPrint(&bufs[4], "0x{X:0>8}", .{@as(u32, @truncate(self.options.timestamp >> 32))}) };
                n += 1;
            }
            if (findText(scope, "LOWPART")) |lo| {
                reps[n] = .{ .span = .{ .start = lm.start + lo.start, .end = lm.start + lo.end }, .text = try std.fmt.bufPrint(&bufs[5], "0x{X:0>8}", .{@as(u32, @truncate(self.options.timestamp))}) };
                n += 1;
            }
        }
        std.mem.sort(Replacement, reps[0..n], {}, struct {
            fn less(_: void, a: Replacement, b: Replacement) bool {
                return a.span.start < b.span.start;
            }
        }.less);
        // Output size depends on the WIM TOTALBYTES digits (= XML offset).
        var total_buf: [24]u8 = undefined;
        const total = try std.fmt.bufPrint(&total_buf, "{d}", .{xml_offset});
        var units: usize = 1 + "<WIM>".len + image.len + "<TOTALBYTES>".len + total.len + "</TOTALBYTES></WIM>".len;
        for (reps[0..n]) |r| units = units - (r.span.end - r.span.start) + r.text.len;
        self.xml = try self.allocator.alloc(u8, units * 2);
        var w: usize = 0;
        const Writer = struct {
            fn ascii(buf: []u8, at: *usize, s: []const u8) void {
                for (s) |c| {
                    put(u16, buf, at.*, c);
                    at.* += 2;
                }
            }
            fn wide(buf: []u8, at: *usize, s: []const u16) void {
                for (s) |c| {
                    put(u16, buf, at.*, c);
                    at.* += 2;
                }
            }
        };
        put(u16, self.xml, 0, 0xfeff);
        w = 2;
        Writer.ascii(self.xml, &w, "<WIM>");
        var at: usize = 0;
        for (reps[0..n]) |r| {
            Writer.wide(self.xml, &w, image[at..r.span.start]);
            Writer.ascii(self.xml, &w, r.text);
            at = r.span.end;
        }
        Writer.wide(self.xml, &w, image[at..]);
        Writer.ascii(self.xml, &w, "<TOTALBYTES>");
        Writer.ascii(self.xml, &w, total);
        Writer.ascii(self.xml, &w, "</TOTALBYTES></WIM>");
        std.debug.assert(w == self.xml.len);
    }

    // ---- sequential producer --------------------------------------------
    fn readFn(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *Plan = @ptrCast(@alignCast(ctx));
        self.read(offset, out) catch |err| {
            self.last_error = err;
            return switch (err) {
                error.Io => error.Io,
                error.NonSequentialWimRead, error.Bounds => error.Bounds,
                else => error.Corrupt,
            };
        };
    }
    pub fn read(self: *Plan, offset: u64, out: []u8) !void {
        if (offset != self.cursor) return error.NonSequentialWimRead;
        if (out.len > self.size - offset) return error.Bounds;
        var done: usize = 0;
        while (done < out.len) {
            const n = try self.produce(out[done..]);
            if (n == 0) return error.CorruptWimWriterState;
            done += n;
            self.cursor += n;
        }
    }
    fn produce(self: *Plan, out: []u8) !usize {
        switch (self.segment) {
            0 => { // header (final values are known up front)
                const n: usize = @intCast(@min(out.len, 208 - self.within));
                @memcpy(out[0..n], self.header[@intCast(self.within)..][0..n]);
                self.within += n;
                if (self.within == 208) self.next(1);
                return n;
            },
            1 => { // copied blobs, raw
                if (self.item == self.copy_count) {
                    self.next(2);
                    return 0 + try self.produce(out);
                }
                const b = self.blobs[self.item];
                const n: usize = @intCast(@min(out.len, b.stored - self.within));
                try self.archive.input.read(b.offset + self.within, out[0..n]);
                self.within += n;
                if (self.within == b.stored) {
                    self.item += 1;
                    self.within = 0;
                }
                return n;
            },
            2 => { // new blobs, uncompressed, re-hashed
                if (self.item == self.new_blobs.len) {
                    self.next(6);
                    return try self.produce(out);
                }
                const p = &self.pending[self.new_blobs[self.item].pending];
                const n: usize = @intCast(@min(out.len, p.size - self.within));
                try p.source.read_fn(p.source.context, self.within, out[0..n]);
                self.blob_sha.update(out[0..n]);
                self.within += n;
                if (self.within == p.size) {
                    const actual = self.blob_sha.finalResult();
                    if (!std.mem.eql(u8, &actual, &p.hash)) return error.WimAddSourceChanged;
                    self.blob_sha = std.crypto.hash.Sha1.init(.{});
                    self.item += 1;
                    self.within = 0;
                }
                return n;
            },
            3 => { // metadata
                if (self.within == self.meta_size) {
                    if (self.em_old != self.resource.descriptor.size or self.em_edit != self.edits.len) return error.CorruptWimWriterState;
                    self.meta_hash = self.meta_sha.finalResult();
                    self.next(4);
                    return try self.produce(out);
                }
                const limit: usize = @intCast(@min(out.len, self.meta_size - self.within));
                const n = try self.emitMetadata(out[0..limit]);
                self.meta_sha.update(out[0..n]);
                self.within += n;
                return n;
            },
            4 => { // lookup table: metadata entry, copied blobs, new blobs
                const entry: u64 = self.within / 50;
                const part = self.within % 50;
                if (part == 0) self.lookupEntry(@intCast(entry));
                const n: usize = @intCast(@min(out.len, 50 - part));
                @memcpy(out[0..n], self.lookup_scratch[@intCast(part)..][0..n]);
                self.within += n;
                if (self.within == self.lookup_size) self.next(5);
                return n;
            },
            5 => {
                const n: usize = @intCast(@min(out.len, self.xml.len - self.within));
                @memcpy(out[0..n], self.xml[@intCast(self.within)..][0..n]);
                self.within += n;
                return n;
            },
            6 => { // metadata chunk table: chunk k+1 starts at (k+1) * chunk
                if (self.within == self.meta_table) {
                    self.next(3);
                    return try self.produce(out);
                }
                const entry: u64 = if (self.meta_size > std.math.maxInt(u32)) 8 else 4;
                const part = self.within % entry;
                const value = (self.within / entry + 1) * self.archive.header.chunk_size;
                if (entry == 4) put(u32, &self.table_scratch, 0, @intCast(value)) else put(u64, &self.table_scratch, 0, value);
                const n: usize = @intCast(@min(out.len, entry - part));
                @memcpy(out[0..n], self.table_scratch[@intCast(part)..][0..n]);
                self.within += n;
                return n;
            },
            else => return error.CorruptWimWriterState,
        }
    }
    fn next(self: *Plan, segment: u8) void {
        self.segment = segment;
        self.item = 0;
        self.within = 0;
    }
    fn lookupEntry(self: *Plan, entry: usize) void {
        const s = &self.lookup_scratch;
        @memset(s, 0);
        put(u16, s, 24, 1);
        if (entry == 0) {
            descriptorBytes(s[0..24], self.meta_table + self.meta_size, self.meta_flags, self.meta_offset, self.meta_size);
            put(u32, s, 26, 1);
            @memcpy(s[30..50], &self.meta_hash);
            return;
        }
        const k = entry - 1;
        if (k < self.copy_count) {
            const b = self.blobs[k];
            descriptorBytes(s[0..24], b.stored, b.flags, self.lookup_out_offset, b.size);
            put(u32, s, 26, b.refs);
            @memcpy(s[30..50], &b.hash);
            self.lookup_out_offset += b.stored;
            return;
        }
        const nb = self.new_blobs[k - self.copy_count];
        const p = self.pending[nb.pending];
        descriptorBytes(s[0..24], p.size, 0, self.lookup_out_offset, p.size);
        put(u32, s, 26, nb.refs);
        @memcpy(s[30..50], &p.hash);
        self.lookup_out_offset += p.size;
    }
    /// Copy the old metadata, item by item, relocating subdirectory offsets
    /// and splicing in edits at item boundaries.
    fn emitMetadata(self: *Plan, out: []u8) !usize {
        const old_size = self.resource.descriptor.size;
        if (self.em_in_span) {
            const n: usize = @intCast(@min(out.len, self.em_span_end - self.em_old));
            try self.resource.read(self.em_old, out[0..n]);
            if (self.em_fix) |value| {
                var field: [8]u8 = undefined;
                put(u64, &field, 0, value);
                const f0 = self.em_span_start + 16;
                var i: u64 = @max(f0, self.em_old);
                while (i < @min(f0 + 8, self.em_old + n)) : (i += 1) out[@intCast(i - self.em_old)] = field[@intCast(i - f0)];
            }
            self.em_old += n;
            if (self.em_old == self.em_span_end) self.em_in_span = false;
            return n;
        }
        if (self.em_in_edit) {
            const e = self.edits[self.em_edit];
            const n = @min(out.len, e.bytes.len - self.em_edit_pos);
            @memcpy(out[0..n], e.bytes[self.em_edit_pos..][0..n]);
            self.em_edit_pos += n;
            if (self.em_edit_pos == e.bytes.len) {
                self.em_in_edit = false;
                self.em_old += e.old_len;
                self.em_edit += 1;
                self.em_edit_pos = 0;
            }
            return n;
        }
        if (self.em_edit < self.edits.len and self.edits[self.em_edit].offset < self.em_old) return error.WimEditOffItemBoundary;
        if (self.em_edit < self.edits.len and self.edits[self.em_edit].offset == self.em_old) {
            self.em_in_edit = true;
            return self.emitMetadata(out);
        }
        if (self.em_old >= old_size) return error.CorruptWimWriterState;
        self.em_span_start = self.em_old;
        self.em_fix = null;
        if (self.em_old < self.tree.root_offset) {
            self.em_span_end = self.tree.root_offset;
        } else {
            var head: [8]u8 = undefined;
            if (old_size - self.em_old < 8) return error.CorruptDentry;
            try self.resource.read(self.em_old, &head);
            if (get(u64, &head, 0) == 0) {
                self.em_span_end = self.em_old + 8;
            } else {
                var entry: meta.Entry = undefined;
                if (!try self.tree.readEntryInto(self.em_old, self.em_old == self.tree.root_offset, &entry)) return error.CorruptDentry;
                self.em_span_end = entry.next;
                if (entry.children != 0) self.em_fix = self.relocate(entry.children);
            }
        }
        self.em_in_span = true;
        return self.emitMetadata(out);
    }
};

// ---- tests ---------------------------------------------------------------
const testing = std.testing;
pub const Mem = struct {
    bytes: []const u8,
    pub fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    pub fn input(self: *@This()) wim.Input {
        return .{ .context = self, .size = self.bytes.len, .read_fn = read };
    }
    pub fn src(self: *@This()) Source {
        return .{ .context = self, .size = self.bytes.len, .read_fn = read };
    }
};
const Builder = struct {
    out: std.ArrayList(u8) = .empty,
    fn bytes(self: *Builder, data: []const u8) !u64 {
        const at = self.out.items.len;
        try self.out.appendSlice(testing.allocator, data);
        return at;
    }
    fn deinit(self: *Builder) void {
        self.out.deinit(testing.allocator);
    }
};
pub const TNode = struct { name: []const u8, dir: bool = false, data: ?[]const u8 = null, group: u64 = 0, security: u32 = 0, kids: []const TNode = &.{} };
pub fn sha(data: []const u8) [20]u8 {
    var h: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &h, .{});
    return h;
}
fn dentryLen(name: []const u8) u64 {
    return align8(102 + (if (name.len == 0) 0 else name.len * 2 + 2));
}
/// Metadata in wimlib's layout: security, root, root terminator, then
/// each directory's children list (breadth first), lists end with 8 zeros.
fn buildMetadata(m: *std.ArrayList(u8), root: TNode) !void {
    const a = testing.allocator;
    // security: one 20-byte descriptor
    var sec: [8 + 8 + 20]u8 = @splat(0);
    put(u32, &sec, 0, 36);
    put(u32, &sec, 4, 1);
    put(u64, &sec, 8, 20);
    sec[16] = 1;
    try m.appendSlice(a, &sec);
    while (m.items.len % 8 != 0) try m.append(a, 0);
    const Q = struct { node: *const TNode, field: usize };
    var queue: std.ArrayList(Q) = .empty;
    defer queue.deinit(a);
    const writeOne = struct {
        fn f(list: *std.ArrayList(u8), n: *const TNode, q: *std.ArrayList(Q)) !void {
            const at = list.items.len;
            const len = dentryLen(n.name);
            try list.appendNTimes(testing.allocator, 0, @intCast(len));
            const d = list.items[at..];
            put(u64, d, 0, len);
            put(u32, d, 8, if (n.dir) 0x10 else 0x20);
            put(u32, d, 12, n.security);
            put(u64, d, 40, 1);
            if (n.data) |data| if (data.len != 0) @memcpy(d[64..84], &sha(data));
            put(u64, d, 88, n.group);
            put(u16, d, 100, @intCast(n.name.len * 2));
            for (n.name, 0..) |c, i| put(u16, d, 102 + i * 2, c);
            if (n.dir and n.kids.len != 0) try q.append(testing.allocator, .{ .node = n, .field = at + 16 });
        }
    }.f;
    try writeOne(m, &root, &queue);
    try m.appendNTimes(a, 0, 8);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const item = queue.items[qi];
        put(u64, m.items, item.field, m.items.len);
        for (item.node.kids) |*k| try writeOne(m, k, &queue);
        try m.appendNTimes(a, 0, 8);
    }
}
fn collectBlobs(list: *std.ArrayList([]const u8), n: TNode) !void {
    if (n.data) |d| if (d.len != 0) {
        for (list.items) |x| if (std.mem.eql(u8, x, d)) return;
        try list.append(testing.allocator, d);
    };
    for (n.kids) |k| try collectBlobs(list, k);
}
fn countRefs(n: TNode, data: []const u8) u32 {
    var c: u32 = if (n.data != null and n.data.?.len != 0 and std.mem.eql(u8, n.data.?, data)) 1 else 0;
    for (n.kids) |k| c += countRefs(k, data);
    return c;
}
fn utf16xml(list: *std.ArrayList(u8), text: []const u8) !void {
    try list.appendSlice(testing.allocator, &.{ 0xff, 0xfe });
    for (text) |c| try list.appendSlice(testing.allocator, &.{ c, 0 });
}
/// Synthetic source WIM: 2 images (image 2 = `root`), optional XPRESS
/// header with one "compressed" resource made of a raw-stored chunk.
pub fn buildWim(root: TNode, other: TNode, compressed_blob: ?[]const u8) ![]u8 {
    const a = testing.allocator;
    var b: Builder = .{};
    errdefer b.deinit();
    _ = try b.bytes(&([_]u8{0} ** 208));
    var blobs: std.ArrayList([]const u8) = .empty;
    defer blobs.deinit(a);
    try collectBlobs(&blobs, root);
    try collectBlobs(&blobs, other);
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    var entry: [50]u8 = undefined;
    for (blobs.items) |data| {
        const compressed = compressed_blob != null and std.mem.eql(u8, data, compressed_blob.?);
        var stored: u64 = data.len;
        var at: u64 = undefined;
        if (compressed) {
            // 2 chunks: 32768 raw + tail raw; chunk table has one u32 entry.
            var t: [4]u8 = undefined;
            put(u32, &t, 0, 32768);
            at = try b.bytes(&t);
            _ = try b.bytes(data);
            stored += 4;
        } else at = try b.bytes(data);
        @memset(&entry, 0);
        descriptorBytes(entry[0..24], stored, if (compressed) 4 else 0, at, data.len);
        put(u16, &entry, 24, 1);
        put(u32, &entry, 26, countRefs(root, data) + countRefs(other, data));
        @memcpy(entry[30..50], &sha(data));
        try table.appendSlice(a, &entry);
    }
    for ([_]TNode{ other, root }) |image| {
        var m: std.ArrayList(u8) = .empty;
        defer m.deinit(a);
        try buildMetadata(&m, image);
        const at = try b.bytes(m.items);
        @memset(&entry, 0);
        descriptorBytes(entry[0..24], m.items.len, 2, at, m.items.len);
        put(u16, &entry, 24, 1);
        put(u32, &entry, 26, 1);
        @memcpy(entry[30..50], &sha(m.items));
        try table.appendSlice(a, &entry);
    }
    const table_at = try b.bytes(table.items);
    var xml: std.ArrayList(u8) = .empty;
    defer xml.deinit(a);
    try utf16xml(&xml, "<WIM><IMAGE INDEX=\"1\"><NAME>One</NAME></IMAGE><IMAGE INDEX=\"2\"><DIRCOUNT>9</DIRCOUNT><FILECOUNT>9</FILECOUNT><TOTALBYTES>9</TOTALBYTES><HARDLINKBYTES>5</HARDLINKBYTES><LASTMODIFICATIONTIME><HIGHPART>0x00000000</HIGHPART><LOWPART>0x00000001</LOWPART></LASTMODIFICATIONTIME><NAME>Setup \xc2\xae</NAME></IMAGE><TOTALBYTES>1</TOTALBYTES></WIM>");
    const xml_at = try b.bytes(xml.items);
    const h = b.out.items[0..208];
    @memcpy(h[0..8], "MSWIM\x00\x00\x00");
    put(u32, h, 8, 208);
    put(u32, h, 12, 0x10d00);
    put(u32, h, 16, if (compressed_blob != null) 0x20082 else 0x80);
    put(u32, h, 20, if (compressed_blob != null) 32768 else 0);
    put(u16, h, 40, 1);
    put(u16, h, 42, 1);
    put(u32, h, 44, 2);
    descriptorBytes(h[48..72], table.items.len, 2, table_at, table.items.len);
    descriptorBytes(h[72..96], xml.items.len, 2, xml_at, xml.items.len);
    put(u32, h, 120, 2);
    return b.out.toOwnedSlice(a);
}
fn runPlan(src: []const u8, adds: []const Add, options: Options) ![]u8 {
    var mem: Mem = .{ .bytes = src };
    var archive = try wim.Archive.open(testing.allocator, mem.input(), 2);
    defer archive.deinit();
    const plan = try Plan.init(testing.allocator, &archive, adds, options);
    defer plan.deinit();
    const out = try testing.allocator.alloc(u8, @intCast(plan.size));
    errdefer testing.allocator.free(out);
    // Odd-sized pulls exercise every segment boundary.
    var at: usize = 0;
    while (at < out.len) {
        const n = @min(out.len - at, 37 + at % 4093);
        try plan.read(at, out[at..][0..n]);
        at += n;
    }
    try testing.expectError(error.NonSequentialWimRead, plan.read(0, out[0..1]));
    return out;
}
pub fn findPath(tree: *meta.Metadata, path: []const []const u8) !?meta.Entry {
    var dir = (try tree.readEntry(tree.root_offset, true)).?;
    for (path) |part| {
        var cursor = dir.children;
        var hit: ?meta.Entry = null;
        var e: meta.Entry = undefined;
        while (cursor != 0 and try tree.readEntryInto(cursor, false, &e)) : (cursor = e.next) {
            if (e.name_len == part.len) {
                var same = true;
                for (part, 0..) |c, i| same = same and e.name[i] == c;
                if (same) hit = e;
            }
        }
        dir = hit orelse return null;
    }
    return dir;
}
fn readBlob(archive: *wim.Archive, hash: [20]u8, out: []u8) !void {
    const e = try archive.find(hash);
    var r = try archive.openEntry(e);
    defer r.deinit();
    try r.read(0, out);
    try r.verify();
}
/// The lookup table's first entry (metadata) descriptor bytes.
fn archiveMetadataDescriptor(out: []const u8) ![24]u8 {
    const at: usize = @intCast(get(u64, out, 56));
    return out[at..][0..24].*;
}
const big = blk: {
    @setEvalBranchQuota(100000);
    var data: [40000]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 7 + i / 300);
    break :blk data;
};
const sys_old = "old stornvme driver bytes";
pub const tree_root: TNode = .{ .name = "", .dir = true, .kids = &.{
    .{ .name = "Windows", .dir = true, .security = 0, .kids = &.{
        .{ .name = "System32", .dir = true, .kids = &.{
            .{ .name = "apple.dll", .data = "apple" },
            .{ .name = "drivers", .dir = true, .kids = &.{
                .{ .name = "acpi.sys", .data = "acpi" },
                .{ .name = "stornvme.sys", .data = sys_old, .group = 7 },
            } },
            .{ .name = "Zebra.exe", .data = &big },
        } },
        .{ .name = "WinSxS", .dir = true, .kids = &.{
            .{ .name = "stornvme.sys", .data = sys_old, .group = 7 },
        } },
    } },
} };
pub const other_root: TNode = .{ .name = "", .dir = true, .kids = &.{
    .{ .name = "only-image-1.txt", .data = "dropped blob" },
    .{ .name = "same.txt", .data = "reused from image 1" },
} };

test "export+update: copies compressed blobs raw, inserts in collation order, replaces and relinks" {
    const a = testing.allocator;
    const src = try buildWim(tree_root, other_root, &big);
    defer a.free(src);
    var f1: Mem = .{ .bytes = "[LaunchApps]\r\nx\r\n" };
    var f2: Mem = .{ .bytes = "new nvme" };
    var f3: Mem = .{ .bytes = "new nvme" };
    var f4: Mem = .{ .bytes = "" };
    var f5: Mem = .{ .bytes = "reused from image 1" };
    var f6: Mem = .{ .bytes = "apple" };
    const adds = [_]Add{
        .{ .path = "/Windows/System32/winpeshl.ini", .source = f1.src() },
        .{ .path = "/Windows/System32/usosnvme-nt6.sys", .source = f2.src() },
        .{ .path = "/Windows/System32/drivers/stornvme.sys", .source = f3.src() },
        .{ .path = "\\Windows\\System32\\empty.flag", .source = f4.src() },
        .{ .path = "/Windows/System32/aaa.txt", .source = f5.src() },
        .{ .path = "/Windows/System32/zzz.dll", .source = f6.src() },
    };
    const guid: [16]u8 = @splat(0xab);
    const out = try runPlan(src, &adds, .{ .guid = guid, .timestamp = 0x01dd695200000000 });
    defer a.free(out);
    var mem: Mem = .{ .bytes = out };
    var archive = try wim.Archive.open(a, mem.input(), 1);
    defer archive.deinit();
    try testing.expectEqual(@as(u32, 1), archive.header.images);
    try testing.expectEqual(@as(u32, 0x20082), archive.header.flags);
    try testing.expectEqualSlices(u8, &guid, out[24..40]);
    try testing.expectEqual(@as(u32, 1), get(u32, out, 120));
    try testing.expectEqualSlices(u8, out[96..120], (try archiveMetadataDescriptor(out))[0..24]);
    try archive.verifyAll();
    var res = try archive.openMetadata();
    defer res.deinit();
    try res.verify();
    try testing.expectEqual(@as(u8, 6), res.descriptor.flags);
    var tree = try meta.Metadata.open(a, &res);
    defer tree.deinit();
    // System32 children in collation order with new names merged in.
    const s32 = (try findPath(&tree, &.{ "Windows", "System32" })).?;
    const want = [_][]const u8{ "aaa.txt", "apple.dll", "drivers", "empty.flag", "usosnvme-nt6.sys", "winpeshl.ini", "Zebra.exe", "zzz.dll" };
    var cursor = s32.children;
    var e: meta.Entry = undefined;
    var k: usize = 0;
    while (try tree.readEntryInto(cursor, false, &e)) : (cursor = e.next) {
        try testing.expect(k < want.len);
        try testing.expectEqual(want[k].len, e.name_len);
        for (want[k], 0..) |c, i| try testing.expectEqual(@as(u16, c), e.name[i]);
        k += 1;
    }
    try testing.expectEqual(want.len, k);
    // Content, attributes, security, link group of the new/replaced files.
    const ini = (try findPath(&tree, &.{ "Windows", "System32", "winpeshl.ini" })).?;
    try testing.expectEqual(@as(u32, 0x80), ini.attributes);
    try testing.expectEqual(@as(u32, 0xffffffff), ini.security);
    try testing.expectEqual(@as(u64, 0x01dd695200000000), ini.times.modified);
    var buf: [64]u8 = undefined;
    try readBlob(&archive, ini.main_hash, buf[0..f1.bytes.len]);
    try testing.expectEqualStrings(f1.bytes, buf[0..f1.bytes.len]);
    const nvme = (try findPath(&tree, &.{ "Windows", "System32", "drivers", "stornvme.sys" })).?;
    try testing.expectEqual(@as(u64, 0), nvme.link_group);
    try testing.expectEqualSlices(u8, &sha("new nvme"), &nvme.main_hash);
    const sxs = (try findPath(&tree, &.{ "Windows", "WinSxS", "stornvme.sys" })).?;
    try testing.expectEqual(@as(u64, 7), sxs.link_group);
    try testing.expectEqualSlices(u8, &sha(sys_old), &sxs.main_hash);
    const empty = (try findPath(&tree, &.{ "Windows", "System32", "empty.flag" })).?;
    try testing.expect(std.mem.allEqual(u8, &empty.main_hash, 0));
    // Refcounts: new blob shared by 2 dentries, old driver blob kept once,
    // image-1-only blob dropped, image-1 blob reused, existing apple reused.
    try testing.expectEqual(@as(u32, 2), (try archive.find(sha("new nvme"))).references);
    try testing.expectEqual(@as(u32, 1), (try archive.find(sha(sys_old))).references);
    try testing.expectEqual(@as(u32, 2), (try archive.find(sha("apple"))).references);
    try testing.expectEqual(@as(u32, 1), (try archive.find(sha("reused from image 1"))).references);
    try testing.expectError(error.MissingWimResource, archive.find(sha("dropped blob")));
    // The compressed resource was copied with its flags and chunk table.
    const zebra = try archive.find(sha(&big));
    try testing.expectEqual(@as(u8, 4), zebra.descriptor.flags);
    try testing.expectEqual(@as(u64, big.len + 4), zebra.descriptor.stored);
    // XML: single image, re-indexed, recounted, WIM TOTALBYTES = XML offset.
    const xml = @import("wim_xml.zig");
    const info = try xml.read(&archive);
    try testing.expectEqual(@as(u64, 4 + 1), info.directories); // root, Windows, System32, drivers, WinSxS
    try testing.expectEqual(@as(u64, 5 + 5), info.files);
    const total: u64 = 5 + 4 + 8 + big.len + sys_old.len + f1.bytes.len + 8 + 0 + 19 + 5;
    try testing.expectEqual(total, info.bytes);
}

test "export+update: options, errors and an unchanged export" {
    const a = testing.allocator;
    const src = try buildWim(tree_root, other_root, null);
    defer a.free(src);
    var f: Mem = .{ .bytes = "x" };
    try testing.expectError(error.WimParentMissing, runPlan(src, &.{.{ .path = "/Nope/x", .source = f.src() }}, .{ .guid = @splat(0), .timestamp = 1 }));
    try testing.expectError(error.WimTargetIsDirectory, runPlan(src, &.{.{ .path = "/Windows/System32/drivers", .source = f.src() }}, .{ .guid = @splat(0), .timestamp = 1 }));
    try testing.expectError(error.InvalidWimPath, runPlan(src, &.{.{ .path = "/Windows/../x", .source = f.src() }}, .{ .guid = @splat(0), .timestamp = 1 }));
    try testing.expectError(error.DuplicateWimAdd, runPlan(src, &.{ .{ .path = "/Windows/a", .source = f.src() }, .{ .path = "/windows/A", .source = f.src() } }, .{ .guid = @splat(0), .timestamp = 1 }));
    // Plain export (no adds): same tree bytes, metadata unchanged.
    const out = try runPlan(src, &.{}, .{ .guid = @splat(1), .timestamp = 1, .boot = false });
    defer a.free(out);
    var mem: Mem = .{ .bytes = out };
    var archive = try wim.Archive.open(a, mem.input(), 1);
    defer archive.deinit();
    try archive.verifyAll();
    try testing.expectEqual(@as(u32, 0), get(u32, out, 120));
    try testing.expectError(error.MissingWimResource, archive.find(sha("dropped blob")));
    // Parent security inheritance.
    const out2 = try runPlan(src, &.{.{ .path = "/Windows/new.txt", .source = f.src() }}, .{ .guid = @splat(1), .timestamp = 1, .security = .parent, .attributes = 0x20 });
    defer a.free(out2);
    var mem2: Mem = .{ .bytes = out2 };
    var archive2 = try wim.Archive.open(a, mem2.input(), 1);
    defer archive2.deinit();
    var res = try archive2.openMetadata();
    defer res.deinit();
    try res.verify();
    var tree = try meta.Metadata.open(a, &res);
    defer tree.deinit();
    const e = (try findPath(&tree, &.{ "Windows", "new.txt" })).?;
    try testing.expectEqual(@as(u32, 0), e.security);
    try testing.expectEqual(@as(u32, 0x20), e.attributes);
}

test "collation compares case-insensitively with upcase" {
    const A = std.unicode.utf8ToUtf16LeStringLiteral;
    try testing.expectEqual(std.math.Order.eq, compareNames(A("System32"), A("SYSTEM32")));
    try testing.expectEqual(std.math.Order.lt, compareNames(A("spp"), A("System32")));
    try testing.expectEqual(std.math.Order.lt, compareNames(A("a"), A("ab")));
}

test "metadata larger than one chunk is written as raw chunks with a chunk table; plain export keeps XML" {
    const a = testing.allocator;
    var names: [600][24]u8 = undefined;
    var kids: [600]TNode = undefined;
    for (&kids, 0..) |*k, i| {
        const name = try std.fmt.bufPrint(&names[i], "file-{d:0>5}.dat", .{i * 2});
        k.* = .{ .name = name, .data = if (i % 3 == 0) "shared" else name };
    }
    const root: TNode = .{ .name = "", .dir = true, .kids = &.{.{ .name = "Windows", .dir = true, .kids = &kids }} };
    const src = try buildWim(root, other_root, &big);
    defer a.free(src);
    var f: Mem = .{ .bytes = "inserted in the middle" };
    const out = try runPlan(src, &.{.{ .path = "/Windows/file-00301.dat", .source = f.src() }}, .{ .guid = @splat(2), .timestamp = 3 });
    defer a.free(out);
    var mem: Mem = .{ .bytes = out };
    var archive = try wim.Archive.open(a, mem.input(), 1);
    defer archive.deinit();
    try archive.verifyAll();
    var res = try archive.openMetadata();
    defer res.deinit();
    try res.verify();
    try testing.expectEqual(@as(u8, 6), res.descriptor.flags);
    try testing.expect(res.descriptor.size > 2 * 32768);
    try testing.expectEqual(res.descriptor.size + (res.descriptor.size - 1) / 32768 * 4, res.descriptor.stored);
    var tree = try meta.Metadata.open(a, &res);
    defer tree.deinit();
    const hit = (try findPath(&tree, &.{ "Windows", "file-00301.dat" })).?;
    const before = (try findPath(&tree, &.{ "Windows", "file-00300.dat" })).?;
    const after = (try findPath(&tree, &.{ "Windows", "file-00302.dat" })).?;
    try testing.expectEqual(before.next, hit.offset);
    try testing.expectEqual(hit.next, after.offset);
    try testing.expectEqual(@as(u32, 200), (try archive.find(sha("shared"))).references);
    // Plain export: XML counts are the source's.
    const plain = try runPlan(src, &.{}, .{ .guid = @splat(2), .timestamp = 3 });
    defer a.free(plain);
    var mem2: Mem = .{ .bytes = plain };
    var archive2 = try wim.Archive.open(a, mem2.input(), 1);
    defer archive2.deinit();
    try archive2.verifyAll();
    const info = try @import("wim_xml.zig").read(&archive2);
    try testing.expectEqual(@as(u64, 9), info.directories);
}
