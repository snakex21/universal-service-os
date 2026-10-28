//! Offline, memory-backed REGF 1.3/1.5 writer. No host registry or log files.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const upper = @import("unicode_upper.zig").upperUnit;
pub const nil: u32 = 0xffffffff;
pub const max_hive = 64 * 1024 * 1024;
pub const segment_bytes = 16344;
pub const Value = struct { kind: u32, data: []u8 };

fn r16(p: []const u8, at: usize) u16 { return std.mem.readInt(u16, p[at..][0..2], .little); }
fn r32(p: []const u8, at: usize) u32 { return std.mem.readInt(u32, p[at..][0..4], .little); }
fn w16(p: []u8, at: usize, v: u16) void { std.mem.writeInt(u16, p[at..][0..2], v, .little); }
fn w32(p: []u8, at: usize, v: u32) void { std.mem.writeInt(u32, p[at..][0..4], v, .little); }
fn w64(p: []u8, at: usize, v: u64) void { std.mem.writeInt(u64, p[at..][0..8], v, .little); }
pub fn checksum(p: []const u8) u32 {
    var c: u32 = 0;
    var at: usize = 0;
    while (at < 508) : (at += 4) c ^= r32(p, at);
    return if (c == 0) 1 else if (c == nil) 0xfffffffe else c;
}
fn cellSize(raw: u32) !usize {
    const signed: i32 = @bitCast(raw);
    const size: usize = @intCast(if (signed < 0) -@as(i64, signed) else signed);
    if (size < 8 or size & 7 != 0) return error.CorruptHive;
    return size;
}
fn encodedLength(name: []const u16) usize {
    for (name) |c| if (c > 255) return name.len * 2;
    return name.len;
}
fn writeName(out: []u8, name: []const u16) void {
    if (out.len == name.len) {
        for (name, out) |c, *b| b.* = @intCast(c);
    } else for (name, 0..) |c, i| w16(out, i * 2, c);
}
fn compareName(raw: []const u8, compressed: bool, name: []const u16) !std.math.Order {
    if (!compressed and raw.len & 1 != 0) return error.CorruptHive;
    const count = if (compressed) raw.len else raw.len / 2;
    for (0..@min(count, name.len)) |i| {
        const a = upper(if (compressed) raw[i] else r16(raw, i * 2));
        const b = upper(name[i]);
        if (a != b) return std.math.order(a, b);
    }
    return std.math.order(count, name.len);
}

pub const Hive = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    root: u32 = nil,
    timestamp: u64,

    pub fn init(a: std.mem.Allocator, root_name: []const u16, timestamp: u64) !Hive {
        var self: Hive = .{ .allocator = a, .timestamp = timestamp };
        errdefer self.deinit();
        try self.bytes.resize(a, 4096);
        @memset(self.bytes.items, 0);
        @memcpy(self.bytes.items[0..4], "regf");
        w32(self.bytes.items, 4, 1); w32(self.bytes.items, 8, 1);
        w32(self.bytes.items, 20, 1); w32(self.bytes.items, 24, 5);
        w32(self.bytes.items, 32, 1); w32(self.bytes.items, 44, 1);
        const security = try self.createSecurity();
        self.root = try self.createKey(root_name, nil, security, true);
        try self.seal();
        return self;
    }
    pub fn open(a: std.mem.Allocator, input: []const u8, timestamp: u64) !Hive {
        if (input.len < 8192 or input.len > max_hive or !std.mem.eql(u8, input[0..4], "regf")) return error.NotHive;
        if (r32(input, 4) != r32(input, 8)) return error.DirtyHive;
        if (checksum(input) != r32(input, 508)) return error.BadChecksum;
        if (r32(input, 20) != 1 or (r32(input, 24) != 3 and r32(input, 24) != 5) or r32(input, 28) != 0 or r32(input, 32) != 1) return error.UnsupportedHive;
        const bins: usize = r32(input, 40);
        if (bins > input.len - 4096 or bins < 4096 or bins & 4095 != 0) return error.CorruptHive;
        const total = 4096 + bins;
        var self: Hive = .{ .allocator = a, .timestamp = timestamp, .root = r32(input, 36) };
        errdefer self.deinit();
        try self.bytes.appendSlice(a, input[0..total]);
        try self.validateBins();
        _ = try self.key(self.root);
        return self;
    }
    pub fn deinit(self: *Hive) void { self.bytes.deinit(self.allocator); self.* = undefined; }
    pub fn seal(self: *Hive) !void {
        try self.validateBins();
        const p = self.bytes.items;
        const sequence = r32(p, 4) +% 1;
        w32(p, 4, sequence); w32(p, 8, sequence);
        w64(p, 12, self.timestamp); w32(p, 36, self.root);
        w32(p, 40, @intCast(p.len - 4096));
        w32(p, 508, checksum(p));
    }
    fn validateBins(self: *Hive) !void {
        const p = self.bytes.items;
        var bin: usize = 4096;
        var budget: usize = 0;
        while (bin < p.len) {
            if (p.len - bin < 4096 or !std.mem.eql(u8, p[bin..][0..4], "hbin") or r32(p, bin + 4) != bin - 4096) return error.CorruptHive;
            const size: usize = r32(p, bin + 8);
            if (size < 4096 or size & 4095 != 0 or size > p.len - bin) return error.CorruptHive;
            var at = bin + 32;
            while (at < bin + size) {
                budget += 1;
                if (budget > 1000000) return error.HiveTooLarge;
                const n = try cellSize(r32(p, at));
                if (n > bin + size - at) return error.CorruptHive;
                at += n;
            }
            bin += size;
        }
    }
    /// Resolve only real allocated cell boundaries, never an interior pointer.
    fn cell(self: *Hive, offset: u32, need: usize) ![]u8 {
        if (offset == nil or offset & 7 != 0 or offset > self.bytes.items.len - 4096 - 4) return error.CorruptHive;
        const want = 4096 + @as(usize, offset);
        const p = self.bytes.items;
        var bin: usize = 4096;
        while (bin < p.len) {
            const size: usize = r32(p, bin + 8);
            if (want >= bin + 32 and want < bin + size) {
                var at = bin + 32;
                while (at < bin + size) {
                    const raw = r32(p, at); const n = try cellSize(raw);
                    if (n > bin + size - at) return error.CorruptHive;
                    if (at == want) {
                        if (raw & 0x80000000 == 0 or need > n - 4) return error.CorruptHive;
                        return p[at + 4 .. at + n];
                    }
                    if (at > want) return error.CorruptHive;
                    at += n;
                }
                return error.CorruptHive;
            }
            bin += size;
        }
        return error.CorruptHive;
    }
    fn allocate(self: *Hive, need: usize) !u32 {
        if (need > max_hive - 8192) return error.HiveTooLarge;
        const wanted = std.mem.alignForward(usize, need + 4, 8);
        var bin: usize = 4096;
        while (bin < self.bytes.items.len) {
            const size: usize = r32(self.bytes.items, bin + 8);
            var at = bin + 32;
            while (at < bin + size) {
                const raw = r32(self.bytes.items, at); const n = try cellSize(raw);
                if (raw & 0x80000000 == 0 and n >= wanted) {
                    const used = if (n - wanted < 8) n else wanted;
                    w32(self.bytes.items, at, 0 -% @as(u32, @intCast(used)));
                    @memset(self.bytes.items[at + 4 .. at + used], 0);
                    if (used != n) w32(self.bytes.items, at + used, @intCast(n - used));
                    return @intCast(at - 4096);
                }
                at += n;
            }
            bin += size;
        }
        const size = std.mem.alignForward(usize, wanted + 40, 4096);
        const at = self.bytes.items.len;
        if (size > max_hive - at) return error.HiveTooLarge;
        try self.bytes.resize(self.allocator, at + size);
        @memset(self.bytes.items[at..], 0);
        @memcpy(self.bytes.items[at..][0..4], "hbin");
        w32(self.bytes.items, at + 4, @intCast(at - 4096));
        w32(self.bytes.items, at + 8, @intCast(size));
        w32(self.bytes.items, at + 32, 0 -% @as(u32, @intCast(wanted)));
        w32(self.bytes.items, at + 32 + wanted, @intCast(size - 32 - wanted));
        return @intCast(at + 32 - 4096);
    }
    fn release(self: *Hive, offset: u32) !void {
        _ = try self.cell(offset, 0);
        const want = 4096 + @as(usize, offset);
        w32(self.bytes.items, want, 0 -% r32(self.bytes.items, want));
        var bin: usize = 4096;
        while (bin < self.bytes.items.len) {
            const size: usize = r32(self.bytes.items, bin + 8);
            if (want < bin + size) {
                var at = bin + 32;
                while (at < bin + size) {
                    const raw = r32(self.bytes.items, at); var n = try cellSize(raw);
                    if (raw & 0x80000000 == 0) {
                        while (at + n < bin + size and r32(self.bytes.items, at + n) & 0x80000000 == 0) n += try cellSize(r32(self.bytes.items, at + n));
                        w32(self.bytes.items, at, @intCast(n));
                    }
                    at += n;
                }
                return;
            }
            bin += size;
        }
        return error.CorruptHive;
    }
    fn key(self: *Hive, offset: u32) ![]u8 {
        const p = try self.cell(offset, 76);
        if (!std.mem.eql(u8, p[0..2], "nk") or r16(p, 72) > p.len - 76) return error.CorruptHive;
        return p;
    }
    fn createSecurity(self: *Hive) !u32 {
        // Self-relative descriptor: owner SYSTEM, group Administrators,
        // inheritable KEY_ALL_ACCESS ACEs for those two principals.
        const off = try self.allocate(120);
        const p = try self.cell(off, 120);
        @memcpy(p[0..2], "sk"); w32(p, 4, off); w32(p, 8, off); w32(p, 16, 100);
        const sd = p[20..120]; sd[0] = 1; w16(sd, 2, 0x8004);
        w32(sd, 4, 20); w32(sd, 8, 32); w32(sd, 16, 48);
        sd[20] = 1; sd[21] = 1; sd[27] = 5; w32(sd, 28, 18);
        sd[32] = 1; sd[33] = 2; sd[39] = 5; w32(sd, 40, 32); w32(sd, 44, 544);
        sd[48] = 2; w16(sd, 50, 52); w16(sd, 52, 2);
        sd[57] = 2; w16(sd, 58, 20); w32(sd, 60, 0xf003f); @memcpy(sd[64..76], sd[20..32]);
        sd[77] = 2; w16(sd, 78, 24); w32(sd, 80, 0xf003f); @memcpy(sd[84..100], sd[32..48]);
        return off;
    }
    fn createKey(self: *Hive, name: []const u16, parent: u32, security: u32, root: bool) !u32 {
        if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u16, name, '\\') != null or std.mem.indexOfScalar(u16, name, 0) != null) return error.InvalidKeyName;
        const n = encodedLength(name); const off = try self.allocate(76 + n);
        const p = try self.cell(off, 76 + n);
        @memcpy(p[0..2], "nk"); w16(p, 2, (if (n == name.len) @as(u16, 32) else 0) | (if (root) @as(u16, 4) else 0));
        w64(p, 4, self.timestamp); w32(p, 16, parent);
        for ([_]usize{ 28, 32, 40, 48 }) |at| w32(p, at, nil);
        w32(p, 44, security); w16(p, 72, @intCast(n)); writeName(p[76..][0..n], name);
        if (security != nil) {
            const sk = try self.cell(security, 20);
            if (!std.mem.eql(u8, sk[0..2], "sk") or r32(sk, 12) == nil) return error.CorruptHive;
            w32(sk, 12, r32(sk, 12) + 1);
        }
        return off;
    }
    fn collectList(self: *Hive, offset: u32, out: *std.ArrayList(u32), lists: *std.ArrayList(u32), depth: usize) !void {
        if (depth > 32 or out.items.len > 100000 or lists.items.len > 4096 or std.mem.indexOfScalar(u32, lists.items, offset) != null) return error.CyclicHive;
        try lists.append(self.allocator, offset);
        const p = try self.cell(offset, 4); const n = r16(p, 2);
        const nested = std.mem.eql(u8, p[0..2], "ri");
        const stride: usize = if (std.mem.eql(u8, p[0..2], "lh") or std.mem.eql(u8, p[0..2], "lf")) 8 else 4;
        if ((!nested and stride == 4 and !std.mem.eql(u8, p[0..2], "li")) or @as(usize, n) * stride > p.len - 4) return error.CorruptHive;
        for (0..n) |i| {
            const off = r32(p, 4 + i * stride);
            if (nested) try self.collectList(off, out, lists, depth + 1) else {
                _ = try self.key(off);
                try out.append(self.allocator, off);
            }
        }
    }
    fn children(self: *Hive, offset: u32, out: *std.ArrayList(u32), lists: *std.ArrayList(u32)) !void {
        const p = try self.key(offset); const n = r32(p, 20);
        if (n > 100000) return error.HiveTooLarge;
        if (n != 0) try self.collectList(r32(p, 28), out, lists, 0);
        if (out.items.len != n) return error.CorruptHive;
    }
    pub fn findKey(self: *Hive, path: []const u16) !?u32 { return self.walk(path, false); }
    pub fn ensureKey(self: *Hive, path: []const u16) !u32 { return (try self.walk(path, true)).?; }
    fn walk(self: *Hive, path: []const u16, create: bool) !?u32 {
        var at = self.root; var parts = std.mem.splitScalar(u16, path, '\\'); var depth: usize = 0;
        if (path.len == 0) return at;
        while (parts.next()) |name| {
            depth += 1;
            if (depth > 512 or name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u16, name, 0) != null) return error.InvalidKeyName;
            var subs: std.ArrayList(u32) = .empty; defer subs.deinit(self.allocator);
            var lists: std.ArrayList(u32) = .empty; defer lists.deinit(self.allocator);
            try self.children(at, &subs, &lists);
            var found: ?u32 = null; var insertion: usize = subs.items.len;
            for (subs.items, 0..) |off, i| {
                const p = try self.key(off);
                const cmp = try compareName(p[76..][0..r16(p, 72)], r16(p, 2) & 32 != 0, name);
                if (cmp == .eq) { found = off; break; }
                if (cmp == .gt and insertion == subs.items.len) insertion = i;
            }
            if (found) |off| { at = off; continue; }
            if (!create) return null;
            const parent = try self.key(at); const security = r32(parent, 44);
            const new = try self.createKey(name, at, security, false);
            try subs.insert(self.allocator, insertion, new);
            const list = try self.makeList(subs.items);
            const refreshed = try self.key(at);
            w32(refreshed, 20, @intCast(subs.items.len)); w32(refreshed, 28, list);
            w32(refreshed, 52, @max(r32(refreshed, 52), @as(u32, @intCast(name.len * 2))));
            w64(refreshed, 4, self.timestamp);
            for (lists.items) |old| try self.release(old);
            at = new;
        }
        return at;
    }
    fn makeList(self: *Hive, children_: []const u32) !u32 {
        if (children_.len > 100000) return error.HiveTooLarge;
        if (children_.len > 1022) {
            const count = std.math.divCeil(usize, children_.len, 1022) catch unreachable;
            const off = try self.allocate(4 + count * 4);
            @memcpy((try self.cell(off, 4))[0..2], "ri"); w16(try self.cell(off, 4), 2, @intCast(count));
            for (0..count) |i| {
                const child = try self.makeList(children_[i * 1022 .. @min((i + 1) * 1022, children_.len)]);
                w32(try self.cell(off, 4 + count * 4), 4 + i * 4, child);
            }
            return off;
        }
        const off = try self.allocate(4 + children_.len * 8);
        const p = try self.cell(off, 4 + children_.len * 8); @memcpy(p[0..2], "lh"); w16(p, 2, @intCast(children_.len));
        for (children_, 0..) |child, i| {
            const nk = try self.key(child); const n = r16(nk, 72); const compressed = r16(nk, 2) & 32 != 0;
            var hash: u32 = 0;
            for (0..if (compressed) n else n / 2) |j| hash = hash *% 37 +% upper(if (compressed) nk[76 + j] else r16(nk, 76 + j * 2));
            w32(p, 4 + i * 8, child); w32(p, 8 + i * 8, hash);
        }
        return off;
    }
    fn valueAt(self: *Hive, key_off: u32, name: []const u16) !?u32 {
        const p = try self.key(key_off); const n = r32(p, 36);
        if (n > 100000) return error.HiveTooLarge;
        if (n == 0) return null;
        const list = try self.cell(r32(p, 40), @as(usize, n) * 4);
        for (0..n) |i| {
            const off = r32(list, i * 4); const v = try self.cell(off, 20); const len = r16(v, 2);
            if (!std.mem.eql(u8, v[0..2], "vk") or len > v.len - 20) return error.CorruptHive;
            if (try compareName(v[20..][0..len], r16(v, 16) & 1 != 0, name) == .eq) return off;
        }
        return null;
    }
    pub fn getValue(self: *Hive, key_off: u32, name: []const u16) !?Value {
        const v = try self.cell((try self.valueAt(key_off, name)) orelse return null, 20);
        const raw = r32(v, 4); const n = raw & 0x7fffffff;
        if (n > 16 * 1024 * 1024) return error.HiveTooLarge;
        const out = try self.allocator.alloc(u8, n); errdefer self.allocator.free(out);
        if (raw & 0x80000000 != 0) {
            if (n > 4) return error.CorruptHive;
            @memcpy(out, v[8..][0..n]);
        } else if (n != 0) {
            const data = try self.cell(r32(v, 8), if (n > segment_bytes) 8 else n);
            if (n > segment_bytes and std.mem.eql(u8, data[0..2], "db")) {
                const count = r16(data, 2);
                if (count != (n + segment_bytes - 1) / segment_bytes) return error.CorruptHive;
                const list = try self.cell(r32(data, 4), @as(usize, count) * 4);
                var copied: usize = 0;
                for (0..count) |i| {
                    const take = @min(segment_bytes, n - copied);
                    @memcpy(out[copied..][0..take], (try self.cell(r32(list, i * 4), take))[0..take]); copied += take;
                }
            } else { if (data.len < n) return error.CorruptHive; @memcpy(out, data[0..n]); }
        }
        return .{ .kind = r32(v, 12), .data = out };
    }
    fn writeData(self: *Hive, bytes: []const u8) !u32 {
        if (bytes.len <= segment_bytes) {
            const off = try self.allocate(bytes.len); @memcpy((try self.cell(off, bytes.len))[0..bytes.len], bytes); return off;
        }
        const count = (bytes.len + segment_bytes - 1) / segment_bytes;
        // Segmented values are a1.5 feature. Windows validates the physical
        // capacity of EVERY segment, including the partly-used last one.
        w32(self.bytes.items, 24, 5);
        const list = try self.allocate(count * 4);
        for (0..count) |i| {
            const data = bytes[i * segment_bytes .. @min(bytes.len, (i + 1) * segment_bytes)];
            const off = try self.allocate(segment_bytes);
            @memcpy((try self.cell(off, segment_bytes))[0..data.len], data);
            w32(try self.cell(list, count * 4), i * 4, off);
        }
        const db = try self.allocate(8); const p = try self.cell(db, 8);
        @memcpy(p[0..2], "db"); w16(p, 2, @intCast(count)); w32(p, 4, list); return db;
    }
    fn releaseValue(self: *Hive, off: u32) !void {
        const v = try self.cell(off, 20); const raw = r32(v, 4); const n = raw & 0x7fffffff; const at = r32(v, 8);
        if (raw & 0x80000000 == 0 and n != 0) {
            const data = try self.cell(at, if (n > segment_bytes) 8 else n);
            if (n > segment_bytes and std.mem.eql(u8, data[0..2], "db")) {
                const count = r16(data, 2); const list_off = r32(data, 4);
                // Keep offsets independent of coalescing and future allocation.
                const entries = try self.allocator.dupe(u8, (try self.cell(list_off, @as(usize, count) * 4))[0 .. @as(usize, count) * 4]); defer self.allocator.free(entries);
                for (0..count) |i| try self.release(r32(entries, i * 4));
                try self.release(list_off);
            }
            try self.release(at);
        }
        try self.release(off);
    }
    pub fn setValue(self: *Hive, key_off: u32, name: []const u16, kind: u32, data: []const u8) !void {
        if (name.len > 16383 or std.mem.indexOfScalar(u16, name, 0) != null or data.len > 16 * 1024 * 1024) return error.InvalidValue;
        const old = try self.valueAt(key_off, name);
        const nk = try self.key(key_off); const count = r32(nk, 36); const old_list = r32(nk, 40);
        if (count > 100000) return error.HiveTooLarge;
        var entries: std.ArrayList(u32) = .empty; defer entries.deinit(self.allocator);
        if (count != 0) {
            const list = try self.cell(old_list, @as(usize, count) * 4);
            for (0..count) |i| try entries.append(self.allocator, r32(list, i * 4));
        }
        const n = encodedLength(name); const off = try self.allocate(20 + n);
        const payload = if (data.len > 4) try self.writeData(data) else nil;
        const v = try self.cell(off, 20 + n); @memcpy(v[0..2], "vk"); w16(v, 2, @intCast(n));
        w32(v, 4, @as(u32, @intCast(data.len)) | (if (data.len <= 4) @as(u32, 0x80000000) else 0));
        if (data.len <= 4) @memcpy(v[8..][0..data.len], data) else w32(v, 8, payload);
        w32(v, 12, kind); w16(v, 16, if (n == name.len) 1 else 0); writeName(v[20..][0..n], name);
        if (old) |prev| { for (entries.items) |*entry| if (entry.* == prev) { entry.* = off; break; }; } else try entries.append(self.allocator, off);
        const list = try self.allocate(entries.items.len * 4);
        const l = try self.cell(list, entries.items.len * 4); for (entries.items, 0..) |entry, i| w32(l, i * 4, entry);
        const refreshed = try self.key(key_off); w32(refreshed, 36, @intCast(entries.items.len)); w32(refreshed, 40, list);
        w32(refreshed, 60, @max(r32(refreshed, 60), @as(u32, @intCast(name.len * 2))));
        w32(refreshed, 64, @max(r32(refreshed, 64), @as(u32, @intCast(data.len)))); w64(refreshed, 4, self.timestamp);
        if (old_list != nil and count != 0) try self.release(old_list);
        if (old) |prev| try self.releaseValue(prev);
    }
};

test "REGF segmented last cell keeps full Windows capacity and upgrades1.3" {
    const a = std.testing.allocator;
    var hive = try Hive.init(a, std.unicode.utf8ToUtf16LeStringLiteral("ROOT"), 1); defer hive.deinit();
    w32(hive.bytes.items, 24, 3);
    const bytes = try a.alloc(u8, segment_bytes + 1); defer a.free(bytes); @memset(bytes, 37);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Big");
    try hive.setValue(hive.root, name, 3, bytes);
    const vk = try hive.cell((try hive.valueAt(hive.root, name)).?, 20);
    const db = try hive.cell(r32(vk, 8), 8);
    const list = try hive.cell(r32(db, 4), 8);
    try std.testing.expectEqual(@as(u16, 2), r16(db, 2));
    const last = try hive.cell(r32(list, 4), segment_bytes);
    try std.testing.expectEqual(@as(u8, 37), last[0]);
    try std.testing.expect(std.mem.allEqual(u8, last[1..segment_bytes], 0));
    try std.testing.expectEqual(@as(u32, 5), r32(hive.bytes.items, 24));
}
