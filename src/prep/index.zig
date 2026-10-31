//! Incremental NTFS $I30 indexes. SPDX-License-Identifier: GPL-3.0-or-later
//!
//! On-disk format: public Linux-NTFS Documentation 0.6 and ntfs-3g layout.h
//! (GPL-2.0-or-later, Linux-NTFS/Tuxera contributors). NTFS promotes complete
//! FILE_NAME entries into internal index blocks: unlike a textbook B+ tree,
//! the promoted key is not also duplicated in a leaf. All leaves retain the
//! same depth. Splits, rotations and merges touch only the search path and
//! its siblings; no directory-wide array or rebuild is used.
//!
//! Allocation, runlists and the index bitmap belong to the caller. Every
//! VCN denotes one 4096-byte index block (one 4096-byte NTFS cluster).
//! Callbacks exchange MST-protected blocks. INDEX_ROOT is a fixed resident
//! END entry pointing to root_vcn. The caller keeps the volume dirty until
//! all changed index/attribute metadata is committed.
const std = @import("std");
const r = @import("record.zig");
const get = r.get;
const put = r.put;

pub const block_bytes = 4096;
pub const max_key_bytes = 576;
pub const max_depth = 32;
const entry_start = 64;
const min_keys = 2;

pub const Identity = struct { owner: u64, revision: u64 };

pub const Backend = struct {
    context: *anyopaque,
    read_node: *const fn (*anyopaque, u64, *[4096]u8) anyerror!void,
    write_node: *const fn (*anyopaque, u64, *const [4096]u8) anyerror!void,
    alloc_node: *const fn (*anyopaque) anyerror!u64,
    free_node: *const fn (*anyopaque, u64) anyerror!void,
    set_root: *const fn (*anyopaque, u64) anyerror!void,
    /// Optional serial-writer identity. A provider changes revision on every
    /// mutation, owner switch and error. Without it prepared inserts rescan.
    identity: ?*const fn (*anyopaque) ?Identity = null,
    invalidate: ?*const fn (*anyopaque) void = null,
};

const Key = struct {
    reference: u64,
    len: usize,
    bytes: [max_key_bytes]u8,
    fn init(reference: u64, bytes: []const u8) !Key {
        try checkKey(bytes);
        var k: Key = .{ .reference = reference, .len = bytes.len, .bytes = undefined };
        @memcpy(k.bytes[0..bytes.len], bytes);
        return k;
    }
    fn data(self: *const Key) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Meta = struct {
    offsets: [65]u16 = undefined,
    count: usize = 0,
    internal: bool,
    used: usize,
};

/// Only one overflowing block is retained during upward propagation. The
/// second half is workspace, not persistent index capacity.
const Node = struct {
    bytes: [8192]u8 = undefined,
    fn init(vcn: u64, internal: bool) Node {
        var n: Node = undefined;
        @memset(&n.bytes, 0);
        @memcpy(n.bytes[0..4], "INDX");
        put(u16, &n.bytes, 4, 40);
        put(u16, &n.bytes, 6, 9);
        put(u64, &n.bytes, 16, vcn);
        put(u32, &n.bytes, 24, 40);
        put(u32, &n.bytes, 32, 4096 - 24);
        n.bytes[36] = @intFromBool(internal);
        const end_len = encodeEnd(n.bytes[entry_start..], if (internal) 0 else null);
        n.setUsed(entry_start + end_len);
        return n;
    }
    fn setUsed(self: *Node, used: usize) void {
        put(u32, &self.bytes, 28, @intCast(used - 24));
    }
    fn meta(self: *const Node) !Meta {
        if (!std.mem.eql(u8, self.bytes[0..4], "INDX") or get(u16, &self.bytes, 4) != 40 or
            get(u16, &self.bytes, 6) != 9 or get(u32, &self.bytes, 24) != 40 or
            get(u32, &self.bytes, 32) != 4096 - 24 or self.bytes[36] > 1) return error.Corrupt;
        const used64 = @as(u64, get(u32, &self.bytes, 28)) + 24;
        if (used64 < entry_start + 16 or used64 > self.bytes.len) return error.Corrupt;
        var m: Meta = .{ .internal = self.bytes[36] == 1, .used = @intCast(used64) };
        var pos: usize = entry_start;
        while (pos + 16 <= m.used) {
            if (m.count >= m.offsets.len) return error.Corrupt;
            m.offsets[m.count] = @intCast(pos);
            const len: usize = get(u16, &self.bytes, pos + 8);
            const key_len: usize = get(u16, &self.bytes, pos + 10);
            const flags = get(u16, &self.bytes, pos + 12);
            if (flags & ~@as(u16, 3) != 0 or (flags & 1 != 0) != m.internal or
                len < 16 or len % 8 != 0 or pos + len > m.used) return error.Corrupt;
            if (flags & 2 != 0) {
                if (key_len != 0 or len != (if (m.internal) @as(usize, 24) else 16) or
                    pos + len != m.used) return error.Corrupt;
                return m;
            }
            if (key_len < 66 or key_len > max_key_bytes or len != r.aligned(16 + key_len +
                (if (m.internal) @as(usize, 8) else 0))) return error.Corrupt;
            try checkKey(self.bytes[pos + 16 ..][0..key_len]);
            m.count += 1;
            pos += len;
        }
        return error.Corrupt;
    }
    fn key(self: *const Node, m: Meta, pos: usize) []const u8 {
        const off: usize = m.offsets[pos];
        return self.bytes[off + 16 ..][0..get(u16, &self.bytes, off + 10)];
    }
    fn reference(self: *const Node, m: Meta, pos: usize) u64 {
        return get(u64, &self.bytes, m.offsets[pos]);
    }
    fn copyKey(self: *const Node, m: Meta, pos: usize) !Key {
        return Key.init(self.reference(m, pos), self.key(m, pos));
    }
    fn child(self: *const Node, m: Meta, pos: usize) u64 {
        const off: usize = m.offsets[pos];
        return get(u64, &self.bytes, off + get(u16, &self.bytes, off + 8) - 8);
    }
    fn setChild(self: *Node, m: Meta, pos: usize, vcn: u64) void {
        const off: usize = m.offsets[pos];
        put(u64, &self.bytes, off + get(u16, &self.bytes, off + 8) - 8, vcn);
    }
    fn insert(self: *Node, m: Meta, pos: usize, k: *const Key, child_vcn: ?u64) !void {
        if (pos > m.count or (child_vcn != null) != m.internal) return error.Corrupt;
        const len = r.aligned(16 + k.len + (if (m.internal) @as(usize, 8) else 0));
        if (m.used + len > self.bytes.len) return error.Corrupt;
        const off: usize = m.offsets[pos];
        std.mem.copyBackwards(u8, self.bytes[off + len .. m.used + len], self.bytes[off..m.used]);
        _ = encodeEntry(self.bytes[off..], k, child_vcn);
        self.setUsed(m.used + len);
    }
    fn erase(self: *Node, m: Meta, pos: usize) !void {
        if (pos >= m.count) return error.Corrupt;
        const off: usize = m.offsets[pos];
        const len: usize = get(u16, &self.bytes, off + 8);
        std.mem.copyForwards(u8, self.bytes[off .. m.used - len], self.bytes[off + len .. m.used]);
        @memset(self.bytes[m.used - len .. m.used], 0);
        self.setUsed(m.used - len);
    }
    fn replace(self: *Node, m: Meta, pos: usize, k: *const Key) !void {
        const c: ?u64 = if (m.internal) self.child(m, pos) else null;
        try self.erase(m, pos);
        try self.insert(try self.meta(), pos, k, c);
    }
};

const Path = struct { vcn: u64, slot: usize };
const Promotion = struct { key: Key, left: u64, right: u64 };

/// One-use search result. Pointer-out construction avoids a large error-union
/// payload in the freestanding IA32 image. All storage has a fixed bound.
pub const InsertHint = struct {
    context: *anyopaque = undefined,
    identity: ?Identity = null,
    root_vcn: u64 = 0,
    leaf_vcn: u64 = 0,
    slot: usize = 0,
    depth: usize = 0,
    name_len: usize = 0,
    consumed: bool = false,
    path: [max_depth]Path = undefined,
    name: [255]u16 = undefined,
    leaf: [4096]u8 = undefined,
};

pub const Tree = struct {
    backend: Backend,
    upcase: []const u16,
    root_vcn: u64,

    pub fn open(backend: Backend, upcase: []const u16, root_vcn: u64) Tree {
        return .{ .backend = backend, .upcase = upcase, .root_vcn = root_vcn };
    }
    pub fn create(backend: Backend, upcase: []const u16) !Tree {
        if (upcase.len != 65536) return error.InvalidArgument;
        const vcn = try backend.alloc_node(backend.context);
        var t = open(backend, upcase, vcn);
        var n = Node.init(vcn, false);
        try t.write(vcn, &n);
        try backend.set_root(backend.context, vcn);
        return t;
    }
    fn read(self: *Tree, vcn: u64, n: *Node) !Meta {
        errdefer self.invalidateCache();
        try self.backend.read_node(self.backend.context, vcn, n.bytes[0..4096]);
        try r.unprotect(n.bytes[0..4096]);
        const m = try n.meta();
        if (m.used > 4096 or get(u64, &n.bytes, 16) != vcn) return error.Corrupt;
        return m;
    }
    fn write(self: *Tree, vcn: u64, n: *Node) !void {
        errdefer self.invalidateCache();
        const m = try n.meta();
        if (m.used > 4096 or get(u64, &n.bytes, 16) != vcn) return error.Corrupt;
        @memset(n.bytes[m.used..4096], 0);
        try r.protect(n.bytes[0..4096]);
        defer r.unprotect(n.bytes[0..4096]) catch unreachable;
        try self.backend.write_node(self.backend.context, vcn, n.bytes[0..4096]);
    }
    fn invalidateCache(self: *Tree) void {
        if (self.backend.invalidate) |invalidate| invalidate(self.backend.context);
    }
    fn root(self: *Tree, vcn: u64) !void {
        try self.backend.set_root(self.backend.context, vcn);
        self.root_vcn = vcn;
    }
    fn position(self: *const Tree, n: *const Node, m: Meta, name: []const u16) usize {
        var lo: usize = 0;
        var hi = m.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (compareName(self.upcase, n.key(m, mid), name) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
    pub fn lookup(self: *Tree, name: []const u16) !?u64 {
        if (name.len == 0 or name.len > 255 or self.upcase.len != 65536) return error.InvalidArgument;
        var n: Node = undefined;
        var vcn = self.root_vcn;
        for (0..max_depth) |_| {
            const m = try self.read(vcn, &n);
            const pos = self.position(&n, m, name);
            if (pos < m.count and compareName(self.upcase, n.key(m, pos), name) == .eq)
                return n.reference(m, pos);
            if (!m.internal) return null;
            vcn = n.child(m, pos);
        }
        return error.Corrupt;
    }

    /// Reject a duplicate before the caller allocates DATA or publishes MFT
    /// metadata. A later insert can reuse this exact search if its identity
    /// still matches; reads and unrelated file DATA do not change identity.
    pub fn prepareInsert(self: *Tree, name: []const u16, hint: *InsertHint) !void {
        hint.* = .{};
        errdefer hint.consumed = true;
        if (name.len == 0 or name.len > 255 or self.upcase.len != 65536) return error.InvalidArgument;
        hint.context = self.backend.context;
        hint.identity = if (self.backend.identity) |identify| identify(self.backend.context) else null;
        hint.root_vcn = self.root_vcn;
        hint.name_len = name.len;
        @memcpy(hint.name[0..name.len], name);
        var n: Node = undefined;
        var vcn = self.root_vcn;
        while (hint.depth < max_depth) {
            const m = try self.read(vcn, &n);
            const pos = self.position(&n, m, name);
            if (pos < m.count and compareName(self.upcase, n.key(m, pos), name) == .eq) {
                hint.consumed = true;
                return error.InvalidArgument;
            }
            if (!m.internal) {
                hint.leaf_vcn = vcn;
                hint.slot = pos;
                @memcpy(&hint.leaf, n.bytes[0..4096]);
                return;
            }
            hint.path[hint.depth] = .{ .vcn = vcn, .slot = pos };
            hint.depth += 1;
            vcn = n.child(m, pos);
        }
        hint.consumed = true;
        return error.Corrupt;
    }

    /// true means the prepared path was used; false means a safe fresh search.
    /// A hint is consumed even on error, and a non-identifying backend always
    /// takes the ordinary insert path rather than trusting a caller's token.
    pub fn insertPrepared(self: *Tree, reference: u64, bytes: []const u8, hint: *InsertHint) !bool {
        errdefer self.invalidateCache();
        const consumed = hint.consumed;
        hint.consumed = true;
        const k = try Key.init(reference, bytes);
        if (self.upcase.len != 65536) return error.InvalidArgument;
        var same_name = hint.name_len == bytes[64];
        if (same_name) for (hint.name[0..hint.name_len], 0..) |unit, i| {
            if (unit != get(u16, bytes, 66 + i * 2)) {
                same_name = false;
                break;
            }
        };
        const current = if (self.backend.identity) |identify| identify(self.backend.context) else null;
        const same_identity = if (current) |now| if (hint.identity) |before|
            now.owner == before.owner and now.revision == before.revision
        else false else false;
        if (consumed or !same_identity or !same_name or hint.context != self.backend.context or
            hint.root_vcn != self.root_vcn or hint.depth >= max_depth)
        {
            try self.insert(reference, bytes);
            return false;
        }
        var n: Node = undefined;
        @memcpy(n.bytes[0..4096], &hint.leaf);
        const m = try n.meta();
        if (m.internal or m.used > 4096 or get(u64, &n.bytes, 16) != hint.leaf_vcn or hint.slot > m.count)
            return error.Corrupt;
        const needle = hint.name[0..hint.name_len];
        if ((hint.slot != 0 and compareName(self.upcase, n.key(m, hint.slot - 1), needle) != .lt) or
            (hint.slot != m.count and compareName(self.upcase, n.key(m, hint.slot), needle) != .gt))
            return error.Corrupt;
        try n.insert(m, hint.slot, &k, null);
        try self.store(hint.leaf_vcn, &n, hint.path[0..hint.depth]);
        return true;
    }
    pub fn insert(self: *Tree, reference: u64, bytes: []const u8) !void {
        const k = try Key.init(reference, bytes);
        if (self.upcase.len != 65536) return error.InvalidArgument;
        var name: [255]u16 = undefined;
        for (0..bytes[64]) |i| name[i] = get(u16, bytes, 66 + i * 2);
        const needle = name[0..bytes[64]];
        var path: [max_depth]Path = undefined;
        var depth: usize = 0;
        var vcn = self.root_vcn;
        var n: Node = undefined;
        while (depth < path.len) {
            const m = try self.read(vcn, &n);
            const pos = self.position(&n, m, needle);
            if (pos < m.count and compareName(self.upcase, n.key(m, pos), needle) == .eq)
                return error.InvalidArgument;
            if (!m.internal) {
                try n.insert(m, pos, &k, null);
                return self.store(vcn, &n, path[0..depth]);
            }
            path[depth] = .{ .vcn = vcn, .slot = pos };
            depth += 1;
            vcn = n.child(m, pos);
        }
        return error.Corrupt;
    }

    /// Writes a changed node, propagating only a possible separator split.
    /// This is also used when deletion replaces a short separator by a long
    /// predecessor/sibling key; variable-size keys can overflow on deletion.
    fn store(self: *Tree, initial: u64, n: *Node, path: []const Path) !void {
        var vcn = initial;
        var remaining = path.len;
        while (true) {
            const m = try n.meta();
            if (m.used <= 4096) return self.write(vcn, n);
            const promoted = try self.split(vcn, n, m);
            if (remaining == 0) {
                const new_vcn = try self.backend.alloc_node(self.backend.context);
                n.* = Node.init(new_vcn, true);
                try n.insert(try n.meta(), 0, &promoted.key, promoted.left);
                const nm = try n.meta();
                n.setChild(nm, 1, promoted.right);
                try self.write(new_vcn, n);
                return self.root(new_vcn);
            }
            remaining -= 1;
            const parent = path[remaining];
            const pm = try self.read(parent.vcn, n);
            if (!pm.internal or parent.slot > pm.count or n.child(pm, parent.slot) != promoted.left)
                return error.Corrupt;
            try n.insert(pm, parent.slot, &promoted.key, promoted.left);
            n.setChild(try n.meta(), parent.slot + 1, promoted.right);
            vcn = parent.vcn;
        }
    }
    fn split(self: *Tree, vcn: u64, n: *Node, m: Meta) !Promotion {
        if (m.count < min_keys * 2 + 1) return error.Corrupt;
        const end_len: usize = if (m.internal) 24 else 16;
        var middle: ?usize = null;
        var best: usize = std.math.maxInt(usize);
        for (min_keys..m.count - min_keys) |i| {
            const left_used = @as(usize, m.offsets[i]) + end_len;
            const right_used = entry_start + m.used - m.offsets[i + 1];
            if (left_used > 4096 or right_used > 4096) continue;
            const delta = @max(left_used, right_used) - @min(left_used, right_used);
            if (delta < best) {
                best = delta;
                middle = i;
            }
        }
        const mid = middle orelse return error.Corrupt;
        const key = try n.copyKey(m, mid);
        const left_end_child: ?u64 = if (m.internal) n.child(m, mid) else null;
        const right_vcn = try self.backend.alloc_node(self.backend.context);
        var right = Node.init(right_vcn, m.internal);
        const right_start: usize = m.offsets[mid + 1];
        const right_len = m.used - right_start;
        @memcpy(right.bytes[entry_start..][0..right_len], n.bytes[right_start..m.used]);
        right.setUsed(entry_start + right_len);
        const left_end: usize = m.offsets[mid];
        _ = encodeEnd(n.bytes[left_end..], left_end_child);
        n.setUsed(left_end + end_len);
        try self.write(vcn, n);
        try self.write(right_vcn, &right);
        return .{ .key = key, .left = vcn, .right = right_vcn };
    }

    pub fn remove(self: *Tree, name: []const u16) !bool {
        if (name.len == 0 or name.len > 255 or self.upcase.len != 65536) return error.InvalidArgument;
        // A separator can grow during a rotation and split an ancestor. In
        // that uncommon case all edits are durable and lookup restarts from
        // the new root, rather than following stale ancestor slots.
        restart: while (true) {
            var path: [max_depth]Path = undefined;
            var depth: usize = 0;
            var vcn = self.root_vcn;
            var n: Node = undefined;
            while (depth < path.len) {
                const m = try self.read(vcn, &n);
                const pos = self.position(&n, m, name);
                const found = pos < m.count and compareName(self.upcase, n.key(m, pos), name) == .eq;
                if (!m.internal) {
                    if (!found) return false;
                    try n.erase(m, pos);
                    try self.write(vcn, &n);
                    return true;
                }
                if (found) {
                    const left_vcn = n.child(m, pos);
                    const right_vcn = n.child(m, pos + 1);
                    var child: Node = undefined;
                    const lm = try self.read(left_vcn, &child);
                    if (lm.count > min_keys) {
                        path[depth] = .{ .vcn = vcn, .slot = pos };
                        const k = switch (try self.extractExtreme(left_vcn, true, path[0 .. depth + 1])) {
                            .retry => continue :restart,
                            .key => |k| k,
                        };
                        try n.replace(m, pos, &k);
                        try self.store(vcn, &n, path[0..depth]);
                        return true;
                    }
                    const rm = try self.read(right_vcn, &child);
                    if (rm.count > min_keys) {
                        path[depth] = .{ .vcn = vcn, .slot = pos + 1 };
                        const k = switch (try self.extractExtreme(right_vcn, false, path[0 .. depth + 1])) {
                            .retry => continue :restart,
                            .key => |k| k,
                        };
                        try n.replace(m, pos, &k);
                        try self.store(vcn, &n, path[0..depth]);
                        return true;
                    }
                    if (lm.count != min_keys or rm.count != min_keys) return error.Corrupt;
                    const merged = try self.mergeChildren(vcn, &n, m, pos);
                    if (merged.collapsed) {
                        depth = 0;
                    } else {
                        path[depth] = .{ .vcn = vcn, .slot = pos };
                        depth += 1;
                    }
                    vcn = merged.vcn;
                    continue;
                }
                const prepared = try self.prepareChild(vcn, &n, m, pos);
                if (prepared.parent_changed) {
                    const changed = try n.meta();
                    if (changed.used > 4096) {
                        try self.store(vcn, &n, path[0..depth]);
                        continue :restart;
                    }
                    if (!prepared.collapsed) try self.write(vcn, &n);
                }
                if (prepared.collapsed) {
                    depth = 0;
                } else {
                    path[depth] = .{ .vcn = vcn, .slot = prepared.slot };
                    depth += 1;
                }
                vcn = prepared.vcn;
            }
            return error.Corrupt;
        }
    }

    /// Removes the leftmost/rightmost key of a subtree whose root contains
    /// at least three keys. It cannot collapse that subtree's root. Rotating
    /// variable-size separators can split. In that case propagate through
    /// the complete ancestor path, then restart before removing any key.
    const Extracted = union(enum) { key: Key, retry };
    fn extractExtreme(self: *Tree, start: u64, maximum: bool, ancestors: []const Path) !Extracted {
        var vcn = start;
        var n: Node = undefined;
        var path: [max_depth]Path = undefined;
        if (ancestors.len >= path.len) return error.Corrupt;
        @memcpy(path[0..ancestors.len], ancestors);
        var depth = ancestors.len;
        while (depth < path.len) {
            const m = try self.read(vcn, &n);
            if (m.count <= min_keys) return error.Corrupt;
            if (!m.internal) {
                const pos = if (maximum) m.count - 1 else 0;
                const k = try n.copyKey(m, pos);
                try n.erase(m, pos);
                try self.write(vcn, &n);
                return .{ .key = k };
            }
            const pos = if (maximum) m.count else 0;
            const prepared = try self.prepareChild(vcn, &n, m, pos);
            if (prepared.parent_changed) {
                if ((try n.meta()).used > 4096) {
                    try self.store(vcn, &n, path[0..depth]);
                    return .retry;
                }
                if (prepared.collapsed) return error.Corrupt;
                try self.write(vcn, &n);
            }
            path[depth] = .{ .vcn = vcn, .slot = prepared.slot };
            depth += 1;
            vcn = prepared.vcn;
        }
        return error.Corrupt;
    }

    const Prepared = struct { vcn: u64, slot: usize, parent_changed: bool = false, collapsed: bool = false };
    fn prepareChild(self: *Tree, parent_vcn: u64, parent: *Node, pm: Meta, slot: usize) !Prepared {
        const child_vcn = parent.child(pm, slot);
        var child: Node = undefined;
        const cm = try self.read(child_vcn, &child);
        if (cm.count > min_keys) return .{ .vcn = child_vcn, .slot = slot };
        if (cm.count != min_keys) return error.Corrupt;
        var sibling: Node = undefined;
        if (slot > 0) {
            const left_vcn = parent.child(pm, slot - 1);
            const sm = try self.read(left_vcn, &sibling);
            if (sm.internal != cm.internal) return error.Corrupt;
            if (sm.count > min_keys) {
                const down = try parent.copyKey(pm, slot - 1);
                const up = try sibling.copyKey(sm, sm.count - 1);
                const new_child: ?u64 = if (cm.internal) sibling.child(sm, sm.count) else null;
                const new_left_end: ?u64 = if (cm.internal) sibling.child(sm, sm.count - 1) else null;
                try child.insert(cm, 0, &down, new_child);
                try sibling.erase(sm, sm.count - 1);
                if (cm.internal) sibling.setChild(try sibling.meta(), sm.count - 1, new_left_end.?);
                try parent.replace(pm, slot - 1, &up);
                try self.write(left_vcn, &sibling);
                try self.write(child_vcn, &child);
                return .{ .vcn = child_vcn, .slot = slot, .parent_changed = true };
            }
        }
        if (slot < pm.count) {
            const right_vcn = parent.child(pm, slot + 1);
            const sm = try self.read(right_vcn, &sibling);
            if (sm.internal != cm.internal) return error.Corrupt;
            if (sm.count > min_keys) {
                const down = try parent.copyKey(pm, slot);
                const up = try sibling.copyKey(sm, 0);
                const old_end: ?u64 = if (cm.internal) child.child(cm, cm.count) else null;
                const new_end: ?u64 = if (cm.internal) sibling.child(sm, 0) else null;
                try child.insert(cm, cm.count, &down, old_end);
                if (cm.internal) child.setChild(try child.meta(), cm.count + 1, new_end.?);
                try sibling.erase(sm, 0);
                try parent.replace(pm, slot, &up);
                try self.write(right_vcn, &sibling);
                try self.write(child_vcn, &child);
                return .{ .vcn = child_vcn, .slot = slot, .parent_changed = true };
            }
        }
        const sep = if (slot < pm.count) slot else slot - 1;
        const merged = try self.mergeChildren(parent_vcn, parent, pm, sep);
        return .{ .vcn = merged.vcn, .slot = sep, .parent_changed = true, .collapsed = merged.collapsed };
    }
    const Merged = struct { vcn: u64, collapsed: bool };
    fn mergeChildren(self: *Tree, parent_vcn: u64, parent: *Node, pm: Meta, sep: usize) !Merged {
        const left_vcn = parent.child(pm, sep);
        const right_vcn = parent.child(pm, sep + 1);
        var left: Node = undefined;
        var right: Node = undefined;
        const lm = try self.read(left_vcn, &left);
        const rm = try self.read(right_vcn, &right);
        if (lm.internal != rm.internal or lm.count != min_keys or rm.count != min_keys) return error.Corrupt;
        const separator = try parent.copyKey(pm, sep);
        const end: usize = lm.offsets[lm.count];
        const len = encodeEntry(left.bytes[end..], &separator, if (lm.internal) left.child(lm, lm.count) else null);
        const right_len = rm.used - entry_start;
        if (end + len + right_len > 4096) return error.Corrupt;
        @memcpy(left.bytes[end + len ..][0..right_len], right.bytes[entry_start..rm.used]);
        left.setUsed(end + len + right_len);
        try parent.erase(pm, sep);
        const changed = try parent.meta();
        parent.setChild(changed, sep, left_vcn);
        try self.write(left_vcn, &left);
        // A parent must stop referring to the freed block before its bitmap
        // bit can be reused by a later node allocation.
        const collapsed = changed.count == 0 and parent_vcn == self.root_vcn;
        if (collapsed) try self.root(left_vcn) else try self.write(parent_vcn, parent);
        try self.backend.free_node(self.backend.context, right_vcn);
        if (collapsed) try self.backend.free_node(self.backend.context, parent_vcn);
        return .{ .vcn = left_vcn, .collapsed = collapsed };
    }
};

fn checkKey(bytes: []const u8) !void {
    if (bytes.len < 68 or bytes.len > max_key_bytes or bytes.len != 66 + @as(usize, bytes[64]) * 2 or
        bytes[64] == 0 or bytes[65] > 3) return error.Corrupt;
}
fn compareName(upcase: []const u16, key: []const u8, name: []const u16) std.math.Order {
    const count: usize = key[64];
    for (0..@min(count, name.len)) |i| {
        const a = upcase[get(u16, key, 66 + i * 2)];
        const b = upcase[name[i]];
        if (a != b) return std.math.order(a, b);
    }
    return std.math.order(count, name.len);
}
fn encodeEntry(out: []u8, key: *const Key, child_vcn: ?u64) usize {
    const len = r.aligned(16 + key.len + (if (child_vcn != null) @as(usize, 8) else 0));
    @memset(out[0..len], 0);
    put(u64, out, 0, key.reference);
    put(u16, out, 8, @intCast(len));
    put(u16, out, 10, @intCast(key.len));
    put(u16, out, 12, @intFromBool(child_vcn != null));
    @memcpy(out[16..][0..key.len], key.data());
    if (child_vcn) |vcn| put(u64, out, len - 8, vcn);
    return len;
}
fn encodeEnd(out: []u8, child_vcn: ?u64) usize {
    const len: usize = if (child_vcn != null) 24 else 16;
    @memset(out[0..len], 0);
    put(u16, out, 8, @intCast(len));
    put(u16, out, 12, 2 | @as(u16, @intFromBool(child_vcn != null)));
    if (child_vcn) |vcn| put(u64, out, 16, vcn);
    return len;
}

const TestStore = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([4096]u8) = .empty,
    live: std.ArrayList(bool) = .empty,
    free: std.ArrayList(u64) = .empty,
    root_vcn: u64 = 0,
    reads: usize = 0,
    writes: usize = 0,
    fn backend(self: *TestStore) Backend {
        return .{ .context = self, .read_node = read, .write_node = write, .alloc_node = allocate, .free_node = release, .set_root = setRoot };
    }
    fn deinit(self: *TestStore) void {
        self.pages.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.free.deinit(self.allocator);
    }
    fn read(ctx: *anyopaque, vcn: u64, out: *[4096]u8) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        out.* = self.pages.items[@intCast(vcn)];
        self.reads += 1;
    }
    fn write(ctx: *anyopaque, vcn: u64, input: *const [4096]u8) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        self.pages.items[@intCast(vcn)] = input.*;
        self.writes += 1;
    }
    fn allocate(ctx: *anyopaque) !u64 {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (self.free.pop()) |vcn| {
            self.live.items[@intCast(vcn)] = true;
            return vcn;
        }
        const result = self.pages.items.len;
        try self.pages.append(self.allocator, @splat(0));
        try self.live.append(self.allocator, true);
        return @intCast(result);
    }
    fn release(ctx: *anyopaque, vcn: u64) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)] or vcn == self.root_vcn) return error.Corrupt;
        try self.free.append(self.allocator, vcn);
        self.live.items[@intCast(vcn)] = false;
    }
    fn setRoot(ctx: *anyopaque, vcn: u64) !void {
        const self: *TestStore = @ptrCast(@alignCast(ctx));
        if (vcn >= self.pages.items.len or !self.live.items[@intCast(vcn)]) return error.Corrupt;
        self.root_vcn = vcn;
    }
};

fn testKey(number: usize, varied: bool) Key {
    var key: Key = .{ .reference = @as(u64, @intCast(number)) | 0x1000000000000, .len = undefined, .bytes = @splat(0) };
    const n: usize = if (varied) (switch (number % 7) {
        0 => 255,
        1 => 180,
        2 => 100,
        3 => 12,
        else => 24,
    }) else 24;
    key.len = 66 + n * 2;
    key.bytes[64] = @intCast(n);
    key.bytes[65] = 0;
    for (0..n) |i| put(u16, &key.bytes, 66 + i * 2, if (i < 10) '0' else 'x');
    var value = number;
    for (0..10) |i| {
        put(u16, &key.bytes, 66 + (9 - i) * 2, @as(u16, @intCast(value % 10)) + '0');
        value /= 10;
    }
    return key;
}
fn testName(key: *const Key, out: *[255]u16) []const u16 {
    for (0..key.bytes[64]) |i| out[i] = get(u16, key.data(), 66 + i * 2);
    return out[0..key.bytes[64]];
}
const TestInvariant = struct {
    tree: *Tree,
    seen: []bool,
    count: usize = 0,
    previous: ?Key = null,
    leaf_depth: ?usize = null,
    fn visit(self: *TestInvariant, vcn: u64, depth: usize) anyerror!void {
        if (depth >= max_depth or vcn >= self.seen.len or self.seen[@intCast(vcn)]) return error.Corrupt;
        self.seen[@intCast(vcn)] = true;
        var n: Node = undefined;
        const m = try self.tree.read(vcn, &n);
        if (vcn != self.tree.root_vcn and m.count < min_keys) return error.Corrupt;
        if (!m.internal) {
            if (self.leaf_depth) |d| {
                if (d != depth) return error.Corrupt;
            } else self.leaf_depth = depth;
        }
        for (0..m.count) |pos| {
            if (m.internal) try self.visit(n.child(m, pos), depth + 1);
            const key = try n.copyKey(m, pos);
            if (self.previous) |previous| {
                var name: [255]u16 = undefined;
                if (compareName(self.tree.upcase, previous.data(), testName(&key, &name)) != .lt) return error.Corrupt;
            }
            self.previous = key;
            self.count += 1;
        }
        if (m.internal) try self.visit(n.child(m, m.count), depth + 1);
    }
};
fn validateTestTree(tree: *Tree, store: *TestStore, expected: usize) !void {
    const seen = try std.testing.allocator.alloc(bool, store.pages.items.len);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    var invariant: TestInvariant = .{ .tree = tree, .seen = seen };
    try invariant.visit(tree.root_vcn, 0);
    try std.testing.expectEqual(expected, invariant.count);
    try std.testing.expectEqual(store.root_vcn, tree.root_vcn);
    for (seen, store.live.items) |was_seen, live| try std.testing.expectEqual(live, was_seen);
}

test "incremental INDX: 50000 entries in one directory, exact lookups and bounded I/O" {
    const upcase = try std.testing.allocator.alloc(u16, 65536);
    defer std.testing.allocator.free(upcase);
    @import("unicode_upper.zig").build(upcase);
    var store: TestStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    var tree = try Tree.create(store.backend(), upcase);
    for (0..50000) |i| {
        const key = testKey(i, false);
        try tree.insert(key.reference, key.data());
    }
    try validateTestTree(&tree, &store, 50000);
    try std.testing.expect(store.reads < 50000 * 8);
    try std.testing.expect(store.writes < 50000 * 2);
    var name: [255]u16 = undefined;
    for (0..50000) |i| {
        const key = testKey(i, false);
        try std.testing.expectEqual(key.reference, (try tree.lookup(testName(&key, &name))).?);
    }
    const duplicate = testKey(20000, false);
    try std.testing.expectError(error.InvalidArgument, tree.insert(999, duplicate.data()));
}

test "incremental INDX: 150000 permuted entries, no directory array or rebuild" {
    const upcase = try std.testing.allocator.alloc(u16, 65536);
    defer std.testing.allocator.free(upcase);
    @import("unicode_upper.zig").build(upcase);
    var store: TestStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    var tree = try Tree.create(store.backend(), upcase);
    for (0..150000) |i| {
        const key = testKey((i * 7919) % 150000, false);
        try tree.insert(key.reference, key.data());
    }
    try validateTestTree(&tree, &store, 150000);
    try std.testing.expect(store.reads < 150000 * 8);
    try std.testing.expect(store.writes < 150000 * 2);
    var name: [255]u16 = undefined;
    for (0..150000) |i| {
        const key = testKey(i, false);
        try std.testing.expectEqual(key.reference, (try tree.lookup(testName(&key, &name))).?);
    }
}

test "variable UTF16 keys: arbitrary deletions, sibling rotation/merge, root collapse and reuse" {
    const upcase = try std.testing.allocator.alloc(u16, 65536);
    defer std.testing.allocator.free(upcase);
    @import("unicode_upper.zig").build(upcase);
    var store: TestStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    var tree = try Tree.create(store.backend(), upcase);
    const count = 12000;
    for (0..count) |i| {
        const key = testKey((i * 7919) % count, true);
        try tree.insert(key.reference, key.data());
    }
    try validateTestTree(&tree, &store, count);
    var name: [255]u16 = undefined;
    for (0..count) |i| {
        const key = testKey((i * 7919) % count, true);
        try std.testing.expect(try tree.remove(testName(&key, &name)));
        try std.testing.expect((try tree.lookup(testName(&key, &name))) == null);
        if (i % 500 == 499) try validateTestTree(&tree, &store, count - i - 1);
    }
    try validateTestTree(&tree, &store, 0);
    try std.testing.expectEqual(store.pages.items.len - 1, store.free.items.len);
    const missing = testKey(count + 1, true);
    try std.testing.expect(!try tree.remove(testName(&missing, &name)));
    const pages_before = store.pages.items.len;
    for (0..count) |i| {
        const key = testKey(i, true);
        try tree.insert(key.reference, key.data());
    }
    try validateTestTree(&tree, &store, count);
    // Ordered inserts use a different fill factor, but all available freed
    // blocks must be consumed before any new backing block is allocated.
    if (store.pages.items.len > pages_before) try std.testing.expectEqual(@as(usize, 0), store.free.items.len);
}

test "INDX fixup corruption and UTF16 upcase collation" {
    const upcase = try std.testing.allocator.alloc(u16, 65536);
    defer std.testing.allocator.free(upcase);
    @import("unicode_upper.zig").build(upcase);
    var store: TestStore = .{ .allocator = std.testing.allocator };
    defer store.deinit();
    var tree = try Tree.create(store.backend(), upcase);
    var key = testKey(1, false);
    put(u16, &key.bytes, 66, 0x0105); // lowercase a-ogonek
    try tree.insert(key.reference, key.data());
    var name: [255]u16 = undefined;
    _ = testName(&key, &name);
    name[0] = 0x0104;
    try std.testing.expectEqual(key.reference, (try tree.lookup(name[0..key.bytes[64]])).?);
    store.pages.items[@intCast(tree.root_vcn)][510] ^= 1;
    try std.testing.expectError(error.Corrupt, tree.lookup(name[0..key.bytes[64]]));
}
