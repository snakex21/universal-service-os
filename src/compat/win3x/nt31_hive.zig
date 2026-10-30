//! `usos-fb-ui --nt31-hive IN OUT [nvme]` (micro-Linux,
//! tools/nt4_csmwrap_target.sh, native NT 3.1 only; docs/nt-native-plan.md
//! section 8) and the host tool `usos-win3x-display nt31-hive IN OUT [nvme]`.
//! Own implementation, GPL-3.0-or-later.
//!
//! NT 3.1 text-mode Setup (SETUPAPP.EXE inside SETUPLDR) builds the new
//! system's SYSTEM hive from the template SYSTEM._ of the local source
//! (TXTSETUP.INF [WinntFiles] "d2,SYSTEM,3") and only sets Start = 0 on the
//! stock drivers it picked. On the X470 the first GUI-mode boot then has no
//! boot driver for the AHCI / NVMe disk (STOP 0x7B): the VM flow registered
//! AHCINT only at the end of GUI Setup. This tool adds the USOS service keys
//! to the template before text mode copies it, so the first GUI-mode boot
//! already loads them:
//!
//!   ControlSet001\Services\ahcint    Type 1, Start 0, ErrorControl 1, "SCSI miniport"
//!   ControlSet001\Services\usosnvme  (NVMe target only) the same
//!   ControlSet001\Services\usosrst   Type 1, Start 0, ErrorControl 0, "SCSI miniport"
//!                          \Parameters  HpetLegacyOff = 1, RtcFix = 1
//!   ControlSet001\Services\usosusb   Type 1, Start 0, ErrorControl 0, "Keyboard Port"
//!   ControlSet001\Services\Kbdclass\Parameters ConnectMultiplePorts = 1
//!   ControlSet001\Services\Mouclass\Parameters ConnectMultiplePorts = 1
//!
//! the same values the VM flow's INITIAL.INF [UsosNt31Post] writes (which
//! still runs at the end of GUI Setup and finds them in place).
//!
//! REGF 1.1 (the NT 3.1 hive format, measured on the user's CD template):
//! every cell has a 4-byte "previous cell in this bin" field after its size,
//! so the payload starts at cell + 8; nk/vk/sk/li payloads as in later
//! versions with UTF-16 names. Cells of this old format are padded to 16
//! bytes: the hive code of NT 3.1 text-mode Setup (SETUPAPP.EXE,
//! HvIsCellAllocated) rejects a cell index that is not a multiple of 16,
//! and its CmCheckRegistry then fails the whole template (rc 4110 on
//! Services; X470 2026-10-30: "Setup was unable to set Windows NT
//! configuration"). New cells go into new 4 KiB bins appended at the end;
//! existing cells are only changed in place (the Services subkey list
//! pointer and count, the Services MaxNameLen, the shared security
//! descriptor's reference count, two inline DWORDs). Each replaced Services
//! 'li' cell becomes a free cell, as HvFreeCell leaves it, so every
//! allocated cell stays referenced. The header length and checksum are
//! rewritten. Anything unexpected
//! (other version, unclean hive, missing key, keys already present) writes
//! nothing.
//! Exit: 0 patched, 1 not a usable NT 3.1 template, 2 usage, 3 I/O error.
const std = @import("std");
const lz = @import("lz.zig");

const max_file = 4 * 1024 * 1024;
const bin_base = 4096;
const bin_size = 4096;
/// HCELL_PAD of a REGF 1.1 hive (old cell format).
const cell_pad = 16;
const nil: u32 = 0xFFFF_FFFF;

pub const Error = error{ NotTemplate, OutOfMemory, AlreadyPatched };

fn rd16(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .little);
}
fn rd32(d: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, d[o..][0..4], .little);
}
fn wr16(d: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, d[o..][0..2], v, .little);
}
fn wr32(d: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, d[o..][0..4], v, .little);
}

fn checksum(d: []const u8) u32 {
    var x: u32 = 0;
    var i: usize = 0;
    while (i < 508) : (i += 4) x ^= rd32(d, i);
    if (x == 0) return 1;
    if (x == nil) return 0xFFFF_FFFE;
    return x;
}

const Hive = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8),
    /// Offset (hive-relative) of the next free byte in the newest bin, and
    /// the previous cell's in-bin offset there.
    alloc_at: u32 = 0,
    alloc_end: u32 = 0,
    alloc_last: u32 = nil,

    fn data(h: *Hive) []u8 {
        return h.buf.items;
    }

    /// Payload file offset of the allocated cell at hive offset `off`.
    fn payload(h: *Hive, off: u32, min: usize) Error!usize {
        const d = h.data();
        const at = @as(usize, bin_base) + off;
        if (off == nil or at + 8 > d.len) return error.NotTemplate;
        const size = std.mem.readInt(i32, d[at..][0..4], .little);
        if (size >= 0 or @as(usize, @intCast(-size)) < 8 + min or at + @as(usize, @intCast(-size)) > d.len) return error.NotTemplate;
        return at + 8;
    }

    fn newBin(h: *Hive) Error!void {
        const d0 = h.data();
        const length = rd32(d0, 40);
        if (@as(usize, bin_base) + length != d0.len) return error.NotTemplate;
        if (h.alloc_at != 0) h.closeBin();
        try h.buf.appendNTimes(h.gpa, 0, bin_size);
        const d = h.data();
        const at = @as(usize, bin_base) + length;
        @memcpy(d[at..][0..4], "hbin");
        wr32(d, at + 4, length);
        wr32(d, at + 8, bin_size);
        wr32(d, at + 28, bin_size);
        wr32(d, 40, length + bin_size);
        h.alloc_at = length + 32;
        h.alloc_end = length + bin_size;
        h.alloc_last = nil;
    }

    /// The rest of the newest bin becomes one free cell.
    fn closeBin(h: *Hive) void {
        const d = h.data();
        const rest = h.alloc_end - h.alloc_at;
        if (rest == 0) return;
        const at = @as(usize, bin_base) + h.alloc_at;
        std.mem.writeInt(i32, d[at..][0..4], @intCast(rest), .little);
        wr32(d, at + 4, h.alloc_last);
        h.alloc_at = h.alloc_end;
    }

    /// A new allocated cell with `n` payload bytes (zeroed); its hive offset.
    fn alloc(h: *Hive, n: usize) Error!u32 {
        const size: u32 = @intCast((n + 8 + cell_pad - 1) & ~@as(usize, cell_pad - 1));
        if (size > bin_size - 32) return error.NotTemplate;
        if (h.alloc_at == 0 or h.alloc_end - h.alloc_at < size) try h.newBin();
        const off = h.alloc_at;
        const d = h.data();
        const at = @as(usize, bin_base) + off;
        std.mem.writeInt(i32, d[at..][0..4], -@as(i32, @intCast(size)), .little);
        wr32(d, at + 4, h.alloc_last);
        @memset(d[at + 8 .. at + size], 0);
        h.alloc_last = (off) % bin_size;
        h.alloc_at = off + size;
        return off;
    }

    fn nkName(h: *Hive, nk: usize, out: []u8) Error![]const u8 {
        const d = h.data();
        const flags = rd16(d, nk + 2);
        const n = rd16(d, nk + 72);
        if (nk + 76 + n > d.len) return error.NotTemplate;
        const raw = d[nk + 76 ..][0..n];
        if (flags & 0x20 != 0) {
            if (n > out.len) return error.NotTemplate;
            for (raw, 0..) |c, i| out[i] = std.ascii.toUpper(c);
            return out[0..n];
        }
        if (n % 2 != 0 or n / 2 > out.len) return error.NotTemplate;
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            const c = rd16(raw, 2 * i);
            out[i] = if (c < 128) std.ascii.toUpper(@intCast(c)) else 0xFF;
        }
        return out[0 .. n / 2];
    }

    /// Hive offset of the subkey `name` (case-insensitive) of the key at
    /// hive offset `key`, or null.
    fn child(h: *Hive, key: u32, name: []const u8) Error!?u32 {
        const nk = try h.payload(key, 76);
        const d = h.data();
        if (!std.mem.eql(u8, d[nk..][0..2], "nk")) return error.NotTemplate;
        const count = rd32(d, nk + 20);
        if (count == 0) return null;
        const li = try h.payload(rd32(d, nk + 28), 4 + 4 * @as(usize, count));
        if (!std.mem.eql(u8, d[li..][0..2], "li") or rd16(d, li + 2) != count) return error.NotTemplate;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const sub = rd32(h.data(), li + 4 + 4 * i);
            const snk = try h.payload(sub, 76);
            var buf: [64]u8 = undefined;
            const got = try h.nkName(snk, &buf);
            if (std.ascii.eqlIgnoreCase(got, name)) return sub;
        }
        return null;
    }

    fn mustChild(h: *Hive, key: u32, name: []const u8) Error!u32 {
        return (try h.child(key, name)) orelse error.NotTemplate;
    }

    /// Sets an existing inline REG_DWORD value of the key at `key`.
    fn setDword(h: *Hive, key: u32, name: []const u8, v: u32) Error!void {
        const nk = try h.payload(key, 76);
        const count = rd32(h.data(), nk + 36);
        if (count == 0) return error.NotTemplate;
        const list = try h.payload(rd32(h.data(), nk + 40), 4 * @as(usize, count));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const vk = try h.payload(rd32(h.data(), list + 4 * i), 20);
            const d = h.data();
            if (!std.mem.eql(u8, d[vk..][0..2], "vk")) return error.NotTemplate;
            const n = rd16(d, vk + 2);
            if (n != 2 * name.len or vk + 20 + n > d.len) continue;
            var same = true;
            for (name, 0..) |c, j| {
                const w = rd16(d, vk + 20 + 2 * j);
                if (w > 127 or std.ascii.toUpper(@intCast(w)) != std.ascii.toUpper(c)) same = false;
            }
            if (!same) continue;
            if (rd32(d, vk + 4) != 0x8000_0004 or rd32(d, vk + 12) != 4) return error.NotTemplate;
            wr32(d, vk + 8, v);
            return;
        }
        return error.NotTemplate;
    }

    const Value = struct { name: []const u8, dword: ?u32 = null, sz: ?[]const u8 = null };

    /// A new key `name` under `parent` (whose subkey list must already be
    /// sorted; the new entry is inserted in order), values as given, the
    /// security cell and timestamp of `like`. Returns the new key's offset.
    fn addKey(h: *Hive, parent: u32, name: []const u8, values: []const Value, like: u32) Error!u32 {
        if (try h.child(parent, name) != null) return error.AlreadyPatched;
        const like_nk = try h.payload(like, 76);
        const sec = rd32(h.data(), like_nk + 44);
        var stamp: [8]u8 = undefined;
        @memcpy(&stamp, h.data()[like_nk + 4 ..][0..8]);
        // Value cells.
        var vks: [8]u32 = undefined;
        var max_vname: u32 = 0;
        var max_vdata: u32 = 0;
        for (values, 0..) |v, i| {
            const vk_off = try h.alloc(20 + 2 * v.name.len);
            const vk = try h.payload(vk_off, 20);
            var d = h.data();
            @memcpy(d[vk..][0..2], "vk");
            wr16(d, vk + 2, @intCast(2 * v.name.len));
            for (v.name, 0..) |c, j| wr16(d, vk + 20 + 2 * j, c);
            max_vname = @max(max_vname, @as(u32, @intCast(2 * v.name.len)));
            if (v.dword) |x| {
                wr32(d, vk + 4, 0x8000_0004);
                wr32(d, vk + 8, x);
                wr32(d, vk + 12, 4);
                max_vdata = @max(max_vdata, 4);
            } else {
                const s = v.sz.?;
                const bytes: u32 = @intCast(2 * s.len + 2);
                const dat = try h.alloc(bytes);
                const dp = try h.payload(dat, bytes);
                d = h.data();
                for (s, 0..) |c, j| wr16(d, dp + 2 * j, c);
                const vk2 = try h.payload(vk_off, 20);
                wr32(d, vk2 + 4, bytes);
                wr32(d, vk2 + 8, dat);
                wr32(d, vk2 + 12, 1);
                max_vdata = @max(max_vdata, bytes);
            }
            vks[i] = vk_off;
        }
        var vlist: u32 = nil;
        if (values.len != 0) {
            vlist = try h.alloc(4 * values.len);
            const lp = try h.payload(vlist, 4 * values.len);
            for (values, 0..) |_, i| wr32(h.data(), lp + 4 * i, vks[i]);
        }
        // The key.
        const key = try h.alloc(76 + 2 * name.len);
        const nk = try h.payload(key, 76);
        var d = h.data();
        @memcpy(d[nk..][0..2], "nk");
        @memcpy(d[nk + 4 ..][0..8], &stamp);
        wr32(d, nk + 16, parent);
        wr32(d, nk + 28, nil);
        wr32(d, nk + 32, nil);
        wr32(d, nk + 36, @intCast(values.len));
        wr32(d, nk + 40, vlist);
        wr32(d, nk + 44, sec);
        wr32(d, nk + 48, nil);
        wr32(d, nk + 60, max_vname);
        wr32(d, nk + 64, max_vdata);
        wr16(d, nk + 72, @intCast(2 * name.len));
        for (name, 0..) |c, j| wr16(d, nk + 76 + 2 * j, c);
        // One more reference to the shared security descriptor.
        const sk = try h.payload(sec, 20);
        d = h.data();
        if (!std.mem.eql(u8, d[sk..][0..2], "sk")) return error.NotTemplate;
        wr32(d, sk + 12, rd32(d, sk + 12) + 1);
        // The parent's subkey list: a new, sorted 'li' cell.
        const pnk = try h.payload(parent, 76);
        const count = rd32(h.data(), pnk + 20);
        const old_li_off = rd32(h.data(), pnk + 28);
        const old_li: ?usize = if (count == 0) null else try h.payload(old_li_off, 4 + 4 * @as(usize, count));
        const new_li_off = try h.alloc(4 + 4 * (@as(usize, count) + 1));
        const new_li = try h.payload(new_li_off, 4);
        d = h.data();
        @memcpy(d[new_li..][0..2], "li");
        wr16(d, new_li + 2, @intCast(count + 1));
        var upper: [64]u8 = undefined;
        for (name, 0..) |c, j| upper[j] = std.ascii.toUpper(c);
        var o: usize = 0;
        var placed = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const sub = rd32(h.data(), old_li.? + 4 + 4 * i);
            var buf: [64]u8 = undefined;
            const got = try h.nkName(try h.payload(sub, 76), &buf);
            if (!placed and std.mem.order(u8, upper[0..name.len], got) == .lt) {
                wr32(h.data(), new_li + 4 + 4 * o, key);
                o += 1;
                placed = true;
            }
            wr32(h.data(), new_li + 4 + 4 * o, sub);
            o += 1;
        }
        if (!placed) wr32(h.data(), new_li + 4 + 4 * o, key);
        const pnk2 = try h.payload(parent, 76);
        d = h.data();
        wr32(d, pnk2 + 20, count + 1);
        wr32(d, pnk2 + 28, new_li_off);
        if (rd32(d, pnk2 + 52) < 2 * name.len) wr32(d, pnk2 + 52, @intCast(2 * name.len));
        // The replaced list becomes a free cell (positive size; its "last"
        // field stays, the next cell's still points at it).
        if (old_li != null) {
            const at = @as(usize, bin_base) + old_li_off;
            const size = std.mem.readInt(i32, d[at..][0..4], .little);
            std.mem.writeInt(i32, d[at..][0..4], -size, .little);
        }
        return key;
    }
};

/// The patched hive (plain REGF 1.1 in, plain out). Caller frees.
pub fn patch(gpa: std.mem.Allocator, hive: []const u8, nvme: bool) Error![]u8 {
    if (hive.len < 2 * bin_base or hive.len > max_file or !std.mem.eql(u8, hive[0..4], "regf")) return error.NotTemplate;
    if (rd32(hive, 20) != 1 or rd32(hive, 24) != 1) return error.NotTemplate; // version 1.1
    if (rd32(hive, 4) != rd32(hive, 8) or checksum(hive) != rd32(hive, 508)) return error.NotTemplate;
    if (@as(usize, bin_base) + rd32(hive, 40) != hive.len) return error.NotTemplate;
    var h = Hive{ .gpa = gpa, .buf = .empty };
    errdefer h.buf.deinit(gpa);
    try h.buf.appendSlice(gpa, hive);
    const root = rd32(hive, 36);
    const cs = try h.mustChild(root, "ControlSet001");
    const services = try h.mustChild(cs, "Services");
    const like = try h.mustChild(services, "Beep");
    const kbd = try h.mustChild(try h.mustChild(services, "Kbdclass"), "Parameters");
    const mou = try h.mustChild(try h.mustChild(services, "Mouclass"), "Parameters");
    try h.setDword(kbd, "ConnectMultiplePorts", 1);
    try h.setDword(mou, "ConnectMultiplePorts", 1);
    const miniport = [_]Hive.Value{
        .{ .name = "Type", .dword = 1 },        .{ .name = "Start", .dword = 0 },
        .{ .name = "ErrorControl", .dword = 1 }, .{ .name = "Group", .sz = "SCSI miniport" },
    };
    _ = try h.addKey(services, "ahcint", &miniport, like);
    if (nvme) _ = try h.addKey(services, "usosnvme", &miniport, like);
    const rst = try h.addKey(services, "usosrst", &[_]Hive.Value{
        .{ .name = "Type", .dword = 1 },        .{ .name = "Start", .dword = 0 },
        .{ .name = "ErrorControl", .dword = 0 }, .{ .name = "Group", .sz = "SCSI miniport" },
    }, like);
    _ = try h.addKey(rst, "Parameters", &[_]Hive.Value{
        .{ .name = "HpetLegacyOff", .dword = 1 }, .{ .name = "RtcFix", .dword = 1 },
    }, like);
    _ = try h.addKey(services, "usosusb", &[_]Hive.Value{
        .{ .name = "Type", .dword = 1 },        .{ .name = "Start", .dword = 0 },
        .{ .name = "ErrorControl", .dword = 0 }, .{ .name = "Group", .sz = "Keyboard Port" },
    }, like);
    h.closeBin();
    wr32(h.data(), 508, checksum(h.data()));
    return h.buf.toOwnedSlice(gpa);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, in_path: []const u8, out_path: []const u8, nvme: bool) u8 {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, in_path, gpa, .limited(max_file)) catch |err| {
        std.debug.print("[NT31_HIVE] {s}: {s}\n", .{ in_path, @errorName(err) });
        return 3;
    };
    defer gpa.free(raw);
    const packed_kind = lz.kind(raw);
    if (packed_kind == .kwaj) return 1;
    const plain = if (packed_kind == .szdd) lz.expand(gpa, raw) catch {
        std.debug.print("[NT31_HIVE] {s}: SZDD data does not expand\n", .{in_path});
        return 1;
    } else raw;
    defer if (packed_kind == .szdd) gpa.free(plain);
    const hive = patch(gpa, plain, nvme) catch |err| {
        std.debug.print("[NT31_HIVE] {s}: not patched ({s})\n", .{ in_path, @errorName(err) });
        return 1;
    };
    defer gpa.free(hive);
    const out = lz.compressLike(gpa, raw, hive) catch return 3;
    defer gpa.free(out);
    cwd.writeFile(io, .{ .sub_path = out_path, .data = out }) catch |err| {
        std.debug.print("[NT31_HIVE] {s}: {s}\n", .{ out_path, @errorName(err) });
        return 3;
    };
    std.debug.print("[NT31_HIVE] {s}: ahcint{s} usosrst usosusb Start 0, Kbdclass/Mouclass ConnectMultiplePorts 1 ({s}, hive {d} -> {d} bytes)\n", .{ in_path, if (nvme) " usosnvme" else "", @tagName(packed_kind), plain.len, hive.len });
    return 0;
}

/// `--szdd-get IN OUT`: the expanded body of an SZDD (or plain) file.
pub fn runGet(io: std.Io, gpa: std.mem.Allocator, in_path: []const u8, out_path: []const u8) u8 {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, in_path, gpa, .limited(max_file)) catch return 3;
    defer gpa.free(raw);
    if (lz.kind(raw) == .kwaj) return 1;
    const body = lz.expand(gpa, raw) catch return 1;
    defer gpa.free(body);
    cwd.writeFile(io, .{ .sub_path = out_path, .data = body }) catch return 3;
    return 0;
}

/// `--szdd-put ORIGINAL BODY OUT`: BODY in ORIGINAL's container (SZDD
/// literals, or plain when ORIGINAL is plain).
pub fn runPut(io: std.Io, gpa: std.mem.Allocator, orig_path: []const u8, body_path: []const u8, out_path: []const u8) u8 {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, orig_path, gpa, .limited(max_file)) catch return 3;
    defer gpa.free(raw);
    if (lz.kind(raw) == .kwaj) return 1;
    const body = cwd.readFileAlloc(io, body_path, gpa, .limited(max_file)) catch return 3;
    defer gpa.free(body);
    const out = lz.compressLike(gpa, raw, body) catch return 1;
    defer gpa.free(out);
    // Read back: the container must expand to BODY exactly.
    const check = lz.expand(gpa, out) catch return 1;
    defer gpa.free(check);
    if (!std.mem.eql(u8, check, body)) return 1;
    cwd.writeFile(io, .{ .sub_path = out_path, .data = out }) catch return 3;
    return 0;
}

// ------------------------------------------------------------------ tests

/// A minimal REGF 1.1 hive: System \ ControlSet001 \ Services \ {Beep,
/// Kbdclass\Parameters, Mouclass\Parameters}, one security cell.
fn testHive(gpa: std.mem.Allocator) ![]u8 {
    var h = Hive{ .gpa = gpa, .buf = .empty };
    errdefer h.buf.deinit(gpa);
    try h.buf.appendNTimes(gpa, 0, bin_base);
    const d0 = h.data();
    @memcpy(d0[0..4], "regf");
    wr32(d0, 4, 2);
    wr32(d0, 8, 2);
    wr32(d0, 20, 1);
    wr32(d0, 24, 1);
    wr32(d0, 40, 0);
    const sk = try h.alloc(20 + 20);
    {
        const p = try h.payload(sk, 20);
        @memcpy(h.data()[p..][0..2], "sk");
        wr32(h.data(), p + 12, 1);
        wr32(h.data(), p + 16, 20);
    }
    const mk = struct {
        fn key(hh: *Hive, parent: u32, name: []const u8, sec: u32) !u32 {
            const k = try hh.alloc(76 + 2 * name.len);
            const p = try hh.payload(k, 76);
            const d = hh.data();
            @memcpy(d[p..][0..2], "nk");
            wr32(d, p + 16, parent);
            wr32(d, p + 28, nil);
            wr32(d, p + 32, nil);
            wr32(d, p + 40, nil);
            wr32(d, p + 44, sec);
            wr32(d, p + 48, nil);
            wr16(d, p + 72, @intCast(2 * name.len));
            for (name, 0..) |c, j| wr16(d, p + 76 + 2 * j, c);
            if (parent != nil) {
                const pp = try hh.payload(parent, 76);
                const count = rd32(hh.data(), pp + 20);
                const li = try hh.alloc(4 + 4 * (@as(usize, count) + 1));
                const lp = try hh.payload(li, 4);
                const dd = hh.data();
                @memcpy(dd[lp..][0..2], "li");
                wr16(dd, lp + 2, @intCast(count + 1));
                var i: usize = 0;
                while (i < count) : (i += 1) wr32(dd, lp + 4 + 4 * i, rd32(dd, (try hh.payload(rd32(dd, pp + 28), 4)) + 4 + 4 * i));
                if (count != 0) {
                    const at = @as(usize, bin_base) + rd32(dd, pp + 28);
                    std.mem.writeInt(i32, dd[at..][0..4], -std.mem.readInt(i32, dd[at..][0..4], .little), .little);
                }
                wr32(dd, lp + 4 + 4 * count, k);
                wr32(dd, pp + 20, count + 1);
                wr32(dd, pp + 28, li);
            }
            return k;
        }
        fn dword(hh: *Hive, owner: u32, name: []const u8, v: u32) !void {
            const vk = try hh.alloc(20 + 2 * name.len);
            const p = try hh.payload(vk, 20);
            var d = hh.data();
            @memcpy(d[p..][0..2], "vk");
            wr16(d, p + 2, @intCast(2 * name.len));
            wr32(d, p + 4, 0x8000_0004);
            wr32(d, p + 8, v);
            wr32(d, p + 12, 4);
            for (name, 0..) |c, j| wr16(d, p + 20 + 2 * j, c);
            const l = try hh.alloc(4);
            const lp = try hh.payload(l, 4);
            d = hh.data();
            wr32(d, lp, vk);
            const kp = try hh.payload(owner, 76);
            wr32(d, kp + 36, 1);
            wr32(d, kp + 40, l);
        }
    };
    const root = try mk.key(&h, nil, "System", sk);
    const cs = try mk.key(&h, root, "ControlSet001", sk);
    const sv = try mk.key(&h, cs, "Services", sk);
    _ = try mk.key(&h, sv, "Beep", sk);
    const kb = try mk.key(&h, sv, "Kbdclass", sk);
    try mk.dword(&h, try mk.key(&h, kb, "Parameters", sk), "ConnectMultiplePorts", 0);
    const mo = try mk.key(&h, sv, "Mouclass", sk);
    try mk.dword(&h, try mk.key(&h, mo, "Parameters", sk), "ConnectMultiplePorts", 1);
    _ = try mk.key(&h, sv, "Ultra124", sk);
    h.closeBin();
    wr32(h.data(), 36, root);
    wr32(h.data(), 508, checksum(h.data()));
    return h.buf.toOwnedSlice(gpa);
}

test "the USOS services are added in order and the hive stays consistent" {
    const gpa = std.testing.allocator;
    const base = try testHive(gpa);
    defer gpa.free(base);
    const out = try patch(gpa, base, true);
    defer gpa.free(out);
    try std.testing.expectEqual(checksum(out), rd32(out, 508));
    try std.testing.expectEqual(@as(usize, bin_base) + rd32(out, 40), out.len);
    // REGF 1.1: every cell at a 16-byte boundary with a 16-byte multiple
    // size (NT 3.1 SETUPAPP HvIsCellAllocated), the bins add up, and no
    // allocated 'li' cell is left behind unreferenced.
    {
        var p: usize = bin_base;
        var lists: usize = 0;
        while (p < out.len) {
            try std.testing.expectEqualStrings("hbin", out[p..][0..4]);
            const bs = rd32(out, p + 8);
            var c = p + 32;
            while (c < p + bs) {
                try std.testing.expectEqual(@as(usize, 0), (c - bin_base) % cell_pad);
                const sz = std.mem.readInt(i32, out[c..][0..4], .little);
                const n: usize = @intCast(if (sz < 0) -sz else sz);
                try std.testing.expect(n != 0 and n % cell_pad == 0);
                if (sz < 0 and std.mem.eql(u8, out[c + 8 ..][0..2], "li")) lists += 1;
                c += n;
            }
            try std.testing.expectEqual(p + bs, c);
            p += bs;
        }
        // One live list per key with subkeys: root, ControlSet001,
        // Services, Kbdclass, Mouclass, usosrst.
        try std.testing.expectEqual(@as(usize, 6), lists);
    }
    var h = Hive{ .gpa = gpa, .buf = .empty };
    defer h.buf.deinit(gpa);
    try h.buf.appendSlice(gpa, out);
    const sv = try h.mustChild(try h.mustChild(rd32(out, 36), "ControlSet001"), "Services");
    // Sorted: Ahcint Beep Kbdclass Mouclass Ultra124 usosnvme usosrst usosusb.
    const nk = try h.payload(sv, 76);
    const li = try h.payload(rd32(out, nk + 28), 4);
    const want = [_][]const u8{ "AHCINT", "BEEP", "KBDCLASS", "MOUCLASS", "ULTRA124", "USOSNVME", "USOSRST", "USOSUSB" };
    try std.testing.expectEqual(@as(u16, want.len), rd16(out, li + 2));
    for (want, 0..) |w, i| {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(w, try h.nkName(try h.payload(rd32(out, li + 4 + 4 * i), 76), &buf));
    }
    _ = try h.mustChild(try h.mustChild(sv, "usosrst"), "Parameters");
    // A second run refuses (keys present).
    try std.testing.expectError(error.AlreadyPatched, patch(gpa, out, true));
    // Without NVMe: no usosnvme.
    const sata = try patch(gpa, base, false);
    defer gpa.free(sata);
    var h2 = Hive{ .gpa = gpa, .buf = .empty };
    defer h2.buf.deinit(gpa);
    try h2.buf.appendSlice(gpa, sata);
    const sv2 = try h2.mustChild(try h2.mustChild(rd32(sata, 36), "ControlSet001"), "Services");
    try std.testing.expect(try h2.child(sv2, "usosnvme") == null);
    // Not 1.1 / bad checksum: refused.
    var bad = try gpa.dupe(u8, base);
    defer gpa.free(bad);
    bad[100] ^= 1;
    try std.testing.expectError(error.NotTemplate, patch(gpa, bad, false));
}
