//! `usos-fb-ui --bcd-truncatememory <bcd>` (tools/vista_csmwrap_target.sh,
//! micro-Linux): gives the boot manager's default entry of a WinPE BCD store
//! the element 15000007 (truncatememory, BcdLibraryInteger_TruncatePhysicalMemory)
//! = 0x100000000, so the 32-bit WinPE on an NVMe target starts below 4 GiB
//! from its first boot (docs/nvme-nt6-2026-10-12.md sections 14 and 16).
//! The WinPE-side `usos-x86-csmwrap.exe lowmem` stays as the fallback and
//! finds the limit already set.
//!
//! The store is a registry hive (regf). The edit works only on a clean hive
//! (both sequence numbers equal) and only appends: one new 4 KiB hbin holds
//! the new key (nk), its value list, value (vk) and data, and a new lh
//! subkey list of the parent Elements key (old entries + the new one, sorted
//! by the upper-case name); the old list cell is marked free. Nothing else
//! moves. The new key shares the Elements key's security cell (reference
//! count + 1). The base block gets the new hbins size and checksum. Written
//! from the public regf format description (no Microsoft code).
//!
//! `usos-fb-ui --bcd-testsigning <bcd>` (same script, Vista / Server 2008
//! x64 on an NVMe target, docs/vista-x64-nvme-2026-10-21.md): the same edit
//! for element 16000049 (testsigning, BcdLibraryBoolean_AllowPrereleaseSignatures)
//! = 1, so the x64 WinPE 10 loads the test-signed usosnvme that replaces its
//! stornvme image. A boolean is one byte, stored inline in the value cell
//! (data length 0x80000001), as bcdedit writes it.
//!
//! Exit codes: 0 added or updated, 10 already set, 3 not changed (the
//! reason on stdout), 2 bad arguments.
const std = @import("std");
const linux = std.os.linux;

pub const limit: u64 = 0x100000000;
pub const element_name = "15000007";

/// One loader element of the default entry: its key name and REG_BINARY data.
pub const Spec = struct {
    name: *const [8]u8,
    data: []const u8,
    tag: []const u8,
    what: []const u8,
};
pub const truncatememory = Spec{ .name = element_name, .data = &.{ 0, 0, 0, 0, 1, 0, 0, 0 }, .tag = "BCD_LOWMEM", .what = "truncatememory 0x100000000" };
pub const testsigning = Spec{ .name = "16000049", .data = &.{1}, .tag = "BCD_TESTSIGN", .what = "testsigning on" };
const element_name_bytes: u32 = 2 * 8;
const bootmgr_guid = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}";
const default_element = "23000003";
const bin_base: usize = 0x1000;
const bin_size: usize = 0x1000;
pub const max_hive: usize = 1024 * 1024;

pub const Outcome = enum { added, updated, already };
pub const Error = error{ NotHive, Dirty, Corrupt, NoDefault, Unsupported, TooLarge };

fn rd16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Corrupt;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Corrupt;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

/// Absolute position of an allocated cell's data (after the size field).
fn cellData(b: []const u8, off: u32, want_sig: ?[]const u8) Error!usize {
    const pos = bin_base + @as(usize, off);
    const raw: i32 = @bitCast(try rd32(b, pos));
    if (raw >= 0) return error.Corrupt;
    const len: usize = @intCast(-@as(i64, raw));
    if (len < 8 or pos + len > b.len) return error.Corrupt;
    if (want_sig) |sig| {
        if (!std.mem.eql(u8, b[pos + 4 ..][0..2], sig)) return error.Corrupt;
    }
    return pos + 4;
}

fn upper(c: u16) u16 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// Name of a key (nk) as ASCII; UTF-16 names with non-ASCII characters
/// never match the names this file looks for.
const Name = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

fn keyName(b: []const u8, nk: usize) Error!Name {
    const flags = try rd16(b, nk + 2);
    const len = try rd16(b, nk + 72);
    if (nk + 76 + len > b.len) return error.Corrupt;
    var n = Name{};
    if (flags & 0x20 != 0) {
        if (len > n.buf.len) return error.Corrupt;
        @memcpy(n.buf[0..len], b[nk + 76 ..][0..len]);
        n.len = len;
    } else {
        if (len / 2 > n.buf.len) return error.Corrupt;
        var i: usize = 0;
        while (i < len / 2) : (i += 1) {
            const c = try rd16(b, nk + 76 + i * 2);
            n.buf[i] = if (c < 0x80) @intCast(c) else 0xFF;
        }
        n.len = len / 2;
    }
    return n;
}

fn order(a: []const u8, c: []const u8) std.math.Order {
    const n = @min(a.len, c.len);
    for (a[0..n], c[0..n]) |x, y| {
        const ux = upper(x);
        const uy = upper(y);
        if (ux != uy) return std.math.order(ux, uy);
    }
    return std.math.order(a.len, c.len);
}

fn lhHash(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |c| h = h *% 37 +% upper(c);
    return h;
}

const max_subkeys = 480;
const Subkeys = struct {
    offs: [max_subkeys]u32 = undefined,
    n: usize = 0,
    /// list cells to free when the list is replaced (the top list + ri sublists)
    lists: [64]u32 = undefined,
    lists_n: usize = 0,
};

fn collectList(b: []const u8, list: u32, out: *Subkeys, depth: u8) Error!void {
    if (depth > 1) return error.Corrupt;
    const p = try cellData(b, list, null);
    const sig = b[p..][0..2];
    const count = try rd16(b, p + 2);
    if (out.lists_n == out.lists.len) return error.Unsupported;
    out.lists[out.lists_n] = list;
    out.lists_n += 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, sig, "lf") or std.mem.eql(u8, sig, "lh")) {
            if (out.n == max_subkeys) return error.Unsupported;
            out.offs[out.n] = try rd32(b, p + 4 + i * 8);
            out.n += 1;
        } else if (std.mem.eql(u8, sig, "li")) {
            if (out.n == max_subkeys) return error.Unsupported;
            out.offs[out.n] = try rd32(b, p + 4 + i * 4);
            out.n += 1;
        } else if (std.mem.eql(u8, sig, "ri")) {
            try collectList(b, try rd32(b, p + 4 + i * 4), out, depth + 1);
        } else return error.Corrupt;
    }
}

fn subkeys(b: []const u8, nk_off: u32, out: *Subkeys) Error!void {
    const nk = try cellData(b, nk_off, "nk");
    out.* = .{};
    if (try rd32(b, nk + 20) == 0) return;
    try collectList(b, try rd32(b, nk + 28), out, 0);
}

fn findSubkey(b: []const u8, nk_off: u32, name: []const u8) Error!?u32 {
    var list: Subkeys = undefined;
    try subkeys(b, nk_off, &list);
    for (list.offs[0..list.n]) |off| {
        const child = try cellData(b, off, "nk");
        const n = try keyName(b, child);
        if (order(n.slice(), name) == .eq) return off;
    }
    return null;
}

fn path(b: []const u8, from: u32, names: []const []const u8) Error!?u32 {
    var at = from;
    for (names) |name| at = (try findSubkey(b, at, name)) orelse return null;
    return at;
}

const Value = struct { vk: usize, data: usize, len: usize, inline_data: bool };

/// The value "Element" of a key.
fn element(b: []const u8, nk_off: u32) Error!?Value {
    const nk = try cellData(b, nk_off, "nk");
    const count = try rd32(b, nk + 36);
    if (count == 0) return null;
    const vl = try cellData(b, try rd32(b, nk + 40), null);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const vk = try cellData(b, try rd32(b, vl + i * 4), "vk");
        const nlen = try rd16(b, vk + 2);
        const flags = try rd16(b, vk + 16);
        if (flags & 1 == 0 or nlen != 7 or vk + 20 + nlen > b.len) continue;
        if (order(b[vk + 20 ..][0..nlen], "Element") != .eq) continue;
        const size = try rd32(b, vk + 4);
        if (size & 0x80000000 != 0) {
            const len = size & 0x7FFFFFFF;
            if (len > 4) return error.Corrupt;
            return .{ .vk = vk, .data = vk + 8, .len = len, .inline_data = true };
        }
        if (size > 16344) return error.Unsupported; // big data (db) never in a BCD element we read
        const data = try cellData(b, try rd32(b, vk + 8), null);
        if (data + size > b.len) return error.Corrupt;
        return .{ .vk = vk, .data = data, .len = size, .inline_data = false };
    }
    return null;
}

fn checkHeader(b: []const u8) Error!void {
    if (b.len < bin_base + 0x20 or !std.mem.eql(u8, b[0..4], "regf")) return error.NotHive;
    if (try rd32(b, 4) != try rd32(b, 8)) return error.Dirty;
    const bins = try rd32(b, 0x28);
    if (bins == 0 or bins % bin_size != 0 or bin_base + bins > b.len) return error.Corrupt;
}

/// The default entry's Elements key (offset) or NoDefault.
fn defaultElements(b: []const u8) Error!u32 {
    const root = try rd32(b, 0x24);
    const bootmgr = (try path(b, root, &.{ "Objects", bootmgr_guid, "Elements", default_element })) orelse return error.NoDefault;
    const v = (try element(b, bootmgr)) orelse return error.NoDefault;
    if (v.inline_data or v.len < 76) return error.NoDefault;
    var guid: [38]u8 = undefined;
    for (&guid, 0..) |*c, i| {
        const w = try rd16(b, v.data + i * 2);
        if (w >= 0x80) return error.NoDefault;
        c.* = @intCast(w);
    }
    if (guid[0] != '{' or guid[37] != '}') return error.NoDefault;
    return (try path(b, root, &.{ "Objects", &guid, "Elements" })) orelse error.NoDefault;
}

/// State of the element without changing anything: null absent, false
/// present with other data, true set to spec.data.
pub fn check(b: []const u8, spec: Spec) Error!?bool {
    try checkHeader(b);
    const elements = try defaultElements(b);
    const key = (try findSubkey(b, elements, spec.name)) orelse return null;
    const v = (try element(b, key)) orelse return null;
    if (v.len != spec.data.len) return false;
    return std.mem.eql(u8, b[v.data..][0..v.len], spec.data);
}

fn checksum(b: []u8) void {
    var x: u32 = 0;
    var i: usize = 0;
    while (i < 0x1FC) : (i += 4) x ^= std.mem.readInt(u32, b[i..][0..4], .little);
    if (x == 0) x = 1;
    if (x == 0xFFFFFFFF) x = 0xFFFFFFFE;
    wr32(b, 0x1FC, x);
}

/// Edits buf[0..len.*] in place; buf must have room for one more hbin.
pub fn apply(buf: []u8, len: *usize, spec: Spec) Error!Outcome {
    const b = buf[0..len.*];
    try checkHeader(b);
    if (spec.data.len == 0 or spec.data.len > 12) return error.Unsupported;
    const elements = try defaultElements(b);
    const small = spec.data.len <= 4; // inline in the vk cell, as Windows does
    if (try findSubkey(b, elements, spec.name)) |key| {
        const v = (try element(b, key)) orelse return error.Unsupported;
        if (v.len != spec.data.len or v.inline_data != small) return error.Unsupported;
        if (std.mem.eql(u8, b[v.data..][0..v.len], spec.data)) return .already;
        @memcpy(buf[v.data..][0..v.len], spec.data);
        checksum(buf);
        return .updated;
    }

    var list: Subkeys = undefined;
    try subkeys(b, elements, &list);
    const parent = try cellData(b, elements, "nk");
    const sec_off = try rd32(b, parent + 44);
    const sk = try cellData(b, sec_off, "sk");

    const bins = try rd32(b, 0x28);
    const bin = bin_base + bins;
    if (bin + bin_size > buf.len) return error.TooLarge;
    const nk_size = 88;
    const vl_size = 8;
    const vk_size = 32;
    const data_size: usize = if (small) 0 else 16;
    const lh_size = std.mem.alignForward(usize, 8 + 8 * (list.n + 1), 8);
    const used = nk_size + vl_size + vk_size + data_size + lh_size;
    if (0x20 + used + 8 > bin_size) return error.Unsupported;

    // insertion point (entries are sorted by the upper-case name)
    var at: usize = list.n;
    for (list.offs[0..list.n], 0..) |off, i| {
        const n = try keyName(b, try cellData(b, off, "nk"));
        if (order(spec.name, n.slice()) == .lt) {
            at = i;
            break;
        }
    }

    const out = buf[bin .. bin + bin_size];
    @memset(out, 0);
    @memcpy(out[0..4], "hbin");
    wr32(out, 4, bins);
    wr32(out, 8, bin_size);
    const rel: u32 = bins + 0x20; // cell offsets are relative to the first hbin
    const nk_off = rel;
    const vl_off = nk_off + nk_size;
    const vk_off = vl_off + vl_size;
    const data_off = vk_off + vk_size;
    const lh_off = data_off + @as(u32, @intCast(data_size));
    const free_off = lh_off + @as(u32, @intCast(lh_size));

    var p: usize = 0x20;
    // nk (the element name)
    wr32(out, p, @bitCast(-@as(i32, nk_size)));
    const nk = p + 4;
    @memcpy(out[nk..][0..2], "nk");
    wr16(out, nk + 2, 0x20);
    @memcpy(out[nk + 4 ..][0..8], b[parent + 4 ..][0..8]);
    wr32(out, nk + 16, elements);
    wr32(out, nk + 28, 0xFFFFFFFF);
    wr32(out, nk + 32, 0xFFFFFFFF);
    wr32(out, nk + 36, 1);
    wr32(out, nk + 40, vl_off);
    wr32(out, nk + 44, sec_off);
    wr32(out, nk + 48, 0xFFFFFFFF);
    wr32(out, nk + 60, 2 * 7);
    wr32(out, nk + 64, 8);
    wr16(out, nk + 72, spec.name.len);
    @memcpy(out[nk + 76 ..][0..spec.name.len], spec.name);
    p += nk_size;
    // value list
    wr32(out, p, @bitCast(-@as(i32, vl_size)));
    wr32(out, p + 4, vk_off);
    p += vl_size;
    // vk "Element" REG_BINARY
    wr32(out, p, @bitCast(-@as(i32, vk_size)));
    const vk = p + 4;
    @memcpy(out[vk..][0..2], "vk");
    wr16(out, vk + 2, 7);
    if (small) {
        wr32(out, vk + 4, 0x80000000 | @as(u32, @intCast(spec.data.len)));
        @memcpy(out[vk + 8 ..][0..spec.data.len], spec.data);
    } else {
        wr32(out, vk + 4, @intCast(spec.data.len));
        wr32(out, vk + 8, data_off);
    }
    wr32(out, vk + 12, 3);
    wr16(out, vk + 16, 1);
    @memcpy(out[vk + 20 ..][0..7], "Element");
    p += vk_size;
    // data (only when not inline)
    if (!small) {
        wr32(out, p, @bitCast(-@as(i32, @intCast(data_size))));
        @memcpy(out[p + 4 ..][0..spec.data.len], spec.data);
        p += data_size;
    }
    // lh list of Elements
    wr32(out, p, @bitCast(-@as(i32, @as(i32, @intCast(lh_size)))));
    @memcpy(out[p + 4 ..][0..2], "lh");
    wr16(out, p + 6, @intCast(list.n + 1));
    var e = p + 8;
    var i: usize = 0;
    while (i <= list.n) : (i += 1) {
        const off = if (i == at) nk_off else list.offs[if (i < at) i else i - 1];
        const n = if (i == at) blk: {
            var nn = Name{};
            @memcpy(nn.buf[0..spec.name.len], spec.name);
            nn.len = spec.name.len;
            break :blk nn;
        } else try keyName(b, try cellData(b, off, "nk"));
        wr32(out, e, off);
        wr32(out, e + 4, lhHash(n.slice()));
        e += 8;
    }
    p += lh_size;
    // the rest of the bin: one free cell
    wr32(out, p, @intCast(bin_size - p));
    std.debug.assert(free_off == bins + p);

    // parent Elements: count, list, max name length (UTF-16 bytes)
    wr32(buf, parent + 20, @intCast(list.n + 1));
    wr32(buf, parent + 28, lh_off);
    const max_name = try rd32(b, parent + 52);
    if (max_name & 0xFFFF < element_name_bytes) wr32(buf, parent + 52, (max_name & 0xFFFF0000) | element_name_bytes);
    // the old list cells become free cells
    for (list.lists[0..list.lists_n]) |old| {
        const pos = bin_base + @as(usize, old);
        const raw: i32 = @bitCast(try rd32(b, pos));
        wr32(buf, pos, @bitCast(-raw));
    }
    // shared security descriptor: one more reference
    wr32(buf, sk + 12, (try rd32(b, sk + 12)) + 1);
    // base block
    wr32(buf, 0x28, bins + @as(u32, bin_size));
    checksum(buf);
    len.* = bin + bin_size;
    return .added;
}

// ------------------------------------------------------------ command

var hive_buffer: [max_hive + bin_size]u8 = undefined;

var say_tag: []const u8 = "BCD_LOWMEM";

fn say(comptime fmt: []const u8, args: anytype) void {
    var line: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "[{s}] " ++ fmt ++ "\n", .{say_tag} ++ args) catch return;
    _ = linux.write(1, text.ptr, text.len);
}

fn ok(rc: usize) bool {
    return @as(isize, @bitCast(rc)) >= 0;
}

pub fn run(file: []const u8, spec: Spec) u8 {
    say_tag = spec.tag;
    var path_buffer: [1024]u8 = undefined;
    if (file.len >= path_buffer.len) return 2;
    @memcpy(path_buffer[0..file.len], file);
    path_buffer[file.len] = 0;
    const zpath: [*:0]const u8 = path_buffer[0..file.len :0];
    const opened = linux.open(zpath, .{ .ACCMODE = .RDONLY }, 0);
    if (!ok(opened)) {
        say("cannot open {s}", .{file});
        return 3;
    }
    var len: usize = 0;
    {
        const fd: i32 = @intCast(opened);
        defer _ = linux.close(fd);
        while (len < max_hive) {
            const got = linux.read(fd, hive_buffer[len..max_hive].ptr, max_hive - len);
            if (!ok(got)) {
                say("read error", .{});
                return 3;
            }
            if (got == 0) break;
            len += got;
        }
        var probe: [1]u8 = undefined;
        if (len == max_hive and linux.read(fd, &probe, 1) != 0) {
            say("store larger than {d} bytes; not changed", .{max_hive});
            return 3;
        }
    }
    const outcome = apply(&hive_buffer, &len, spec) catch |err| {
        say("not changed: {s}", .{@errorName(err)});
        return 3;
    };
    if (outcome == .already) {
        say("{s} already set", .{spec.what});
        return 10;
    }
    // read back from the edited image before writing it
    const now = check(hive_buffer[0..len], spec) catch |err| {
        say("self-check failed: {s}; not written", .{@errorName(err)});
        return 3;
    };
    if (now != true) {
        say("self-check failed: element not found; not written", .{});
        return 3;
    }
    const wfd = linux.open(zpath, .{ .ACCMODE = .WRONLY, .TRUNC = true }, 0);
    if (!ok(wfd)) {
        say("cannot open {s} for writing", .{file});
        return 3;
    }
    const fd: i32 = @intCast(wfd);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < len) {
        const put = linux.write(fd, hive_buffer[done..len].ptr, len - done);
        if (!ok(put) or put == 0) {
            say("write error", .{});
            return 3;
        }
        done += put;
    }
    _ = linux.fsync(fd);
    say("{s} {s} ({d} bytes)", .{ spec.what, @tagName(outcome), len });
    return 0;
}

// ------------------------------------------------------------ tests

const TestHive = struct {
    buf: [0x4000]u8 = undefined,
    used: usize = 0x20,

    fn cell(self: *TestHive, size: usize) usize {
        const s = std.mem.alignForward(usize, size + 4, 8);
        const pos = bin_base + self.used;
        wr32(&self.buf, pos, @bitCast(-@as(i32, @intCast(s))));
        self.used += s;
        return pos + 4;
    }

    fn off(pos: usize) u32 {
        return @intCast(pos - 4 - bin_base);
    }

    fn key(self: *TestHive, name: []const u8, parent: u32, sk: u32) u32 {
        const p = self.cell(76 + name.len);
        @memcpy(self.buf[p..][0..2], "nk");
        wr16(&self.buf, p + 2, 0x20);
        wr32(&self.buf, p + 16, parent);
        wr32(&self.buf, p + 28, 0xFFFFFFFF);
        wr32(&self.buf, p + 32, 0xFFFFFFFF);
        wr32(&self.buf, p + 40, 0xFFFFFFFF);
        wr32(&self.buf, p + 44, sk);
        wr32(&self.buf, p + 48, 0xFFFFFFFF);
        wr16(&self.buf, p + 72, @intCast(name.len));
        @memcpy(self.buf[p + 76 ..][0..name.len], name);
        return off(p);
    }

    fn children(self: *TestHive, parent: u32, kids: []const u32, sig: []const u8) void {
        const p = self.cell(4 + 8 * kids.len);
        @memcpy(self.buf[p..][0..2], sig);
        wr16(&self.buf, p + 2, @intCast(kids.len));
        for (kids, 0..) |k, i| {
            wr32(&self.buf, p + 4 + i * 8, k);
            const n = keyName(&self.buf, bin_base + k + 4) catch unreachable;
            wr32(&self.buf, p + 8 + i * 8, lhHash(n.slice()));
        }
        const nk = bin_base + parent + 4;
        wr32(&self.buf, nk + 20, @intCast(kids.len));
        wr32(&self.buf, nk + 28, off(p));
        wr32(&self.buf, nk + 52, 16);
    }

    fn value(self: *TestHive, key_off: u32, data: []const u8, kind: u32) void {
        const vl = self.cell(4);
        const vk = self.cell(27);
        const d = self.cell(data.len);
        wr32(&self.buf, vl, off(vk));
        @memcpy(self.buf[vk..][0..2], "vk");
        wr16(&self.buf, vk + 2, 7);
        wr32(&self.buf, vk + 4, @intCast(data.len));
        wr32(&self.buf, vk + 8, off(d));
        wr32(&self.buf, vk + 12, kind);
        wr16(&self.buf, vk + 16, 1);
        @memcpy(self.buf[vk + 20 ..][0..7], "Element");
        @memcpy(self.buf[d..][0..data.len], data);
        const nk = bin_base + key_off + 4;
        wr32(&self.buf, nk + 36, 1);
        wr32(&self.buf, nk + 40, off(vl));
    }

    /// A store like a WinPE boot\bcd: {bootmgr} default -> the loader entry.
    fn build(self: *TestHive) usize {
        @memset(&self.buf, 0);
        @memcpy(self.buf[0..4], "regf");
        wr32(&self.buf, 4, 7);
        wr32(&self.buf, 8, 7);
        wr32(&self.buf, 0x28, bin_size);
        @memcpy(self.buf[bin_base..][0..4], "hbin");
        wr32(&self.buf, bin_base + 8, bin_size);
        const skp = self.cell(20);
        @memcpy(self.buf[skp..][0..2], "sk");
        wr32(&self.buf, skp + 12, 1);
        const sk = off(skp);
        const root = self.key("System", 0, sk);
        wr32(&self.buf, 0x24, root);
        const objects = self.key("Objects", root, sk);
        self.children(root, &.{objects}, "lh");
        const loader_guid = "{7619dcc9-fafe-11d9-b411-000476eba25f}";
        const loader = self.key(loader_guid, objects, sk);
        const bootmgr = self.key(bootmgr_guid, objects, sk);
        self.children(objects, &.{ loader, bootmgr }, "lh");
        const le = self.key("Elements", loader, sk);
        const be = self.key("Elements", bootmgr, sk);
        self.children(loader, &.{le}, "lh");
        self.children(bootmgr, &.{be}, "lh");
        const a = self.key("12000002", le, sk);
        const c = self.key("26000010", le, sk);
        self.children(le, &.{ a, c }, "lf");
        const d = self.key(default_element, be, sk);
        self.children(be, &.{d}, "lh");
        var utf16: [78]u8 = undefined;
        for (loader_guid, 0..) |ch, i| {
            utf16[i * 2] = ch;
            utf16[i * 2 + 1] = 0;
        }
        utf16[76] = 0;
        utf16[77] = 0;
        self.value(d, &utf16, 1);
        // the rest of the bin is one free cell
        wr32(&self.buf, bin_base + self.used, @intCast(bin_size - self.used));
        checksum(&self.buf);
        return bin_base + bin_size;
    }
};

test "bcd truncatememory: added once, then already set" {
    var h = TestHive{};
    var len = h.build();
    try std.testing.expectEqual(@as(?bool, null), try check(h.buf[0..len], truncatememory));
    try std.testing.expectEqual(Outcome.added, try apply(&h.buf, &len, truncatememory));
    try std.testing.expectEqual(@as(usize, bin_base + 2 * bin_size), len);
    try std.testing.expectEqual(@as(?bool, true), try check(h.buf[0..len], truncatememory));
    try std.testing.expectEqual(@as(u64, limit), std.mem.readInt(u64, truncatememory.data[0..8], .little));
    try std.testing.expectEqual(Outcome.already, try apply(&h.buf, &len, truncatememory));
    // the loader's Elements: 12000002, 15000007, 26000010 in this order
    const root = try rd32(&h.buf, 0x24);
    const le = (try path(h.buf[0..len], root, &.{ "Objects", "{7619dcc9-fafe-11d9-b411-000476eba25f}", "Elements" })).?;
    var list: Subkeys = undefined;
    try subkeys(h.buf[0..len], le, &list);
    try std.testing.expectEqual(@as(usize, 3), list.n);
    const want = [_][]const u8{ "12000002", "15000007", "26000010" };
    for (want, list.offs[0..3]) |w, o| {
        const n = try keyName(&h.buf, try cellData(&h.buf, o, "nk"));
        try std.testing.expectEqualStrings(w, n.slice());
    }
    // lh hash of the new entry
    const lh = try cellData(&h.buf, try rd32(&h.buf, bin_base + le + 4 + 28), "lh");
    try std.testing.expectEqual(lhHash("15000007"), try rd32(&h.buf, lh + 4 + 8 + 4));
    // the old lf list is a free cell now; the sk has one more reference
    var xor: u32 = 0;
    var i: usize = 0;
    while (i < 0x1FC) : (i += 4) xor ^= try rd32(&h.buf, i);
    try std.testing.expectEqual(xor, try rd32(&h.buf, 0x1FC));
    try std.testing.expectEqual(@as(u32, 2 * bin_size), try rd32(&h.buf, 0x28));
}

test "bcd truncatememory: other value updated, dirty store refused" {
    var h = TestHive{};
    var len = h.build();
    _ = try apply(&h.buf, &len, truncatememory);
    const v = blk: {
        const elements = try defaultElements(h.buf[0..len]);
        const key = (try findSubkey(h.buf[0..len], elements, element_name)).?;
        break :blk (try element(h.buf[0..len], key)).?;
    };
    std.mem.writeInt(u64, h.buf[v.data..][0..8], 0x80000000, .little);
    try std.testing.expectEqual(@as(?bool, false), try check(h.buf[0..len], truncatememory));
    try std.testing.expectEqual(Outcome.updated, try apply(&h.buf, &len, truncatememory));
    try std.testing.expectEqual(@as(?bool, true), try check(h.buf[0..len], truncatememory));
    wr32(&h.buf, 8, 9);
    try std.testing.expectError(error.Dirty, apply(&h.buf, &len, truncatememory));
    @memcpy(h.buf[0..4], "xxxx");
    try std.testing.expectError(error.NotHive, apply(&h.buf, &len, truncatememory));
}

test "bcd testsigning: inline boolean added next to truncatememory, then updated" {
    var h = TestHive{};
    var len = h.build();
    try std.testing.expectEqual(Outcome.added, try apply(&h.buf, &len, testsigning));
    try std.testing.expectEqual(@as(?bool, true), try check(h.buf[0..len], testsigning));
    try std.testing.expectEqual(@as(?bool, null), try check(h.buf[0..len], truncatememory));
    // both elements coexist (a second appended hbin)
    try std.testing.expectEqual(Outcome.added, try apply(&h.buf, &len, truncatememory));
    try std.testing.expectEqual(@as(usize, bin_base + 3 * bin_size), len);
    try std.testing.expectEqual(@as(?bool, true), try check(h.buf[0..len], testsigning));
    try std.testing.expectEqual(Outcome.already, try apply(&h.buf, &len, testsigning));
    const elements = try defaultElements(h.buf[0..len]);
    // sorted: 12000002, 15000007, 16000049, 26000010
    var list: Subkeys = undefined;
    try subkeys(h.buf[0..len], elements, &list);
    try std.testing.expectEqual(@as(usize, 4), list.n);
    const want = [_][]const u8{ "12000002", "15000007", "16000049", "26000010" };
    for (want, list.offs[0..4]) |w, o| {
        const n = try keyName(&h.buf, try cellData(&h.buf, o, "nk"));
        try std.testing.expectEqualStrings(w, n.slice());
    }
    // the boolean is inline: data length 0x80000001, the byte in the offset field
    const key = (try findSubkey(h.buf[0..len], elements, testsigning.name)).?;
    const v = (try element(h.buf[0..len], key)).?;
    try std.testing.expect(v.inline_data);
    try std.testing.expectEqual(@as(u32, 0x80000001), try rd32(&h.buf, v.vk + 4));
    try std.testing.expectEqual(@as(u8, 1), h.buf[v.vk + 8]);
    // a donor store with testsigning off (0) is switched on in place
    h.buf[v.vk + 8] = 0;
    checksum(&h.buf);
    try std.testing.expectEqual(@as(?bool, false), try check(h.buf[0..len], testsigning));
    try std.testing.expectEqual(Outcome.updated, try apply(&h.buf, &len, testsigning));
    try std.testing.expectEqual(@as(?bool, true), try check(h.buf[0..len], testsigning));
}
