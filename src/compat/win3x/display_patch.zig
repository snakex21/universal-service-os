//! Windows 3.x display driver and startup logo patches for the X470 latch
//! fault (docs/win3x-vga-redraw-2026-10-23.md). Own implementation,
//! GPL-3.0-or-later.
//!
//! On the RX 560 legacy VBIOS under CSMWrap a locked read of video memory
//! (XCHG with memory is always locked) loads the VGA latches from byte
//! (address | 3). VGA.DRV / EGA.DRV and the VGALOGO.LGO logo code use
//! `xchg es:[di],reg8` as "load latches + write".
//!
//! Driver (NE file): tools/win3x_vga_patch.py decides on the host which
//! instruction windows become `call stub` (+ NOPs); the plans in
//! display_table.zig record only those windows for each known driver
//! (input sha256 -> windows -> output sha256). `applyPlan` rebuilds the
//! stubs from the user's own file exactly as the Python tool does:
//!     push T / mov T,mem / mov mem,R / mov R,T / pop T   (= xchg mem,R)
//! plus the moved neighbour instructions and RET, identical stubs shared,
//! appended to the segment; the grown segment and its relocation records go
//! to the end of the file, the segment table entry is updated and the fast-
//! load area is switched off. The result is used only if its sha256 equals
//! the recorded one.
//!
//! Logo (VGALOGO.LGO or WIN.COM): `patchLogo` is the byte-pattern patch of
//! tools/win3x_logo_patch.py (the two 17-byte helpers rewritten with plain
//! accesses, the second helper pointer moved).
const std = @import("std");

pub const Window = struct {
    seg: u16,
    lo: u16,
    /// Instruction lengths from `lo`; bit 7 set = the XCHG to replace.
    parts: []const u8,
};

pub const Plan = struct {
    label: []const u8,
    input: [32]u8,
    output: [32]u8,
    output_len: u32,
    sites: u16,
    windows: []const Window,
};

pub const Error = error{ NotNe, Corrupt, Unsupported, OutputMismatch, TooLarge, OutOfMemory, AlreadyPatched, NotFound };

pub fn hex(comptime text: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

pub fn sha256(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

pub const Match = union(enum) { plan: *const Plan, patched: *const Plan, unknown };

pub fn find(plans: []const Plan, digest: [32]u8) Match {
    for (plans) |*p| {
        if (std.mem.eql(u8, &p.input, &digest)) return .{ .plan = p };
        if (std.mem.eql(u8, &p.output, &digest)) return .{ .patched = p };
    }
    return .unknown;
}

fn rd16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Corrupt;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn isSegPrefix(b: u8) bool {
    return switch (b) {
        0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65 => true,
        else => false,
    };
}

/// Registers used by a 16-bit ModRM memory operand (bit n = register n).
fn addrRegs(modrm: u8) u8 {
    const mod = modrm >> 6;
    const rm = modrm & 7;
    if (mod == 0 and rm == 6) return 0;
    const bx = 1 << 3;
    const bp = 1 << 5;
    const si = 1 << 6;
    const di = 1 << 7;
    return switch (rm) {
        0 => bx | si,
        1 => bx | di,
        2 => bp | si,
        3 => bp | di,
        4 => si,
        5 => di,
        6 => bp,
        else => bx,
    };
}

/// push T / mov T,mem / mov mem,R / mov R,T / pop T == xchg mem,R
/// (tools/win3x_vga_patch.py xchg_seq). Returns the bytes written to `out`.
pub fn xchgSeq(raw: []const u8, out: []u8) Error!usize {
    var i: usize = 0;
    while (i < raw.len and isSegPrefix(raw[i])) i += 1;
    if (i + 2 > raw.len) return error.Corrupt;
    const pfx = raw[0..i];
    const op = raw[i];
    const modrm = raw[i + 1];
    const rest = raw[i + 2 ..];
    if ((op != 0x86 and op != 0x87) or modrm >> 6 == 3) return error.Unsupported;
    const word = op == 0x87;
    const r: u8 = (modrm >> 3) & 7;
    const used = addrRegs(modrm);
    var t: ?u8 = null;
    if (word) {
        if (r == 4) return error.Unsupported;
        for ([_]u8{ 0, 1, 2, 3, 6, 7, 5 }) |c| {
            if (c != r and used & (@as(u8, 1) << @intCast(c)) == 0) {
                t = c;
                break;
            }
        }
    } else {
        for ([_]u8{ 0, 1, 2, 3 }) |c| {
            if (c != (r & 3) and used & (@as(u8, 1) << @intCast(c)) == 0) {
                t = c;
                break;
            }
        }
    }
    const tmp = t orelse return error.Unsupported;
    const need = 1 + 2 * (pfx.len + 2 + rest.len) + 2 + 1;
    if (out.len < need) return error.TooLarge;
    var n: usize = 0;
    out[n] = 0x50 + tmp;
    n += 1;
    inline for (.{ true, false }) |load| {
        @memcpy(out[n..][0..pfx.len], pfx);
        n += pfx.len;
        out[n] = if (load) (if (word) 0x8b else 0x8a) else (if (word) 0x89 else 0x88);
        out[n + 1] = (modrm & 0xc7) | ((if (load) tmp else r) << 3);
        n += 2;
        @memcpy(out[n..][0..rest.len], rest);
        n += rest.len;
    }
    out[n] = if (word) 0x8b else 0x8a;
    out[n + 1] = 0xc0 | (r << 3) | tmp;
    out[n + 2] = 0x58 + tmp;
    return n + 3;
}

/// The patched driver (caller frees). error.OutputMismatch when the result
/// is not the recorded file: then nothing may be written.
pub fn applyPlan(gpa: std.mem.Allocator, plan: *const Plan, raw: []const u8) Error![]u8 {
    if (!std.mem.eql(u8, &sha256(raw), &plan.input)) return error.Unsupported;
    if (raw.len < 0x40 or raw[0] != 'M' or raw[1] != 'Z') return error.NotNe;
    const ne_off: usize = std.mem.readInt(u32, raw[0x3c..0x40], .little);
    if (ne_off + 0x40 > raw.len or raw[ne_off] != 'N' or raw[ne_off + 1] != 'E') return error.NotNe;
    const nseg = try rd16(raw, ne_off + 0x1c);
    const segtab = ne_off + try rd16(raw, ne_off + 0x22);
    const shift: u6 = @intCast(@min(try rd16(raw, ne_off + 0x32), 15));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, raw);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var stubs: std.ArrayList([2]u32) = .empty; // offset, length in `code`
    defer stubs.deinit(gpa);
    var moved = false;
    var seg: u16 = 1;
    while (seg <= nseg) : (seg += 1) {
        var any = false;
        for (plan.windows) |w| any = any or w.seg == seg;
        if (!any) continue;
        const entry = segtab + 8 * @as(usize, seg - 1);
        const so = try rd16(raw, entry);
        const sl = try rd16(raw, entry + 2);
        const flags = try rd16(raw, entry + 4);
        const mn = try rd16(raw, entry + 6);
        if (so == 0) return error.Corrupt;
        const fo = @as(usize, so) << shift;
        const len: usize = if (sl == 0) 0x10000 else sl;
        const minalloc: usize = if (mn == 0) 0x10000 else mn;
        if (minalloc != len) return error.Unsupported;
        if (fo + len > raw.len) return error.Corrupt;
        const data = raw[fo .. fo + len];
        var relocs: []const u8 = &.{};
        if (flags & 0x100 != 0) {
            const count = try rd16(raw, fo + len);
            const end = fo + len + 2 + 8 * @as(usize, count);
            if (end > raw.len) return error.Corrupt;
            relocs = raw[fo + len .. end];
        }
        code.clearRetainingCapacity();
        stubs.clearRetainingCapacity();
        try code.appendSlice(gpa, data);
        for (plan.windows) |w| {
            if (w.seg != seg) continue;
            var body: [256]u8 = undefined;
            var n: usize = 0;
            var k: usize = w.lo;
            for (w.parts) |part| {
                const size: usize = part & 0x7f;
                if (size == 0 or k + size > data.len) return error.Corrupt;
                const insn = data[k .. k + size];
                if (part & 0x80 != 0) {
                    n += try xchgSeq(insn, body[n..]);
                } else {
                    if (n + size > body.len) return error.TooLarge;
                    @memcpy(body[n..][0..size], insn);
                    n += size;
                }
                k += size;
            }
            if (n + 1 > body.len) return error.TooLarge;
            body[n] = 0xc3;
            n += 1;
            const hi = k;
            if (hi - w.lo < 3) return error.Corrupt;
            var stub: ?u32 = null;
            for (stubs.items) |s| {
                if (s[1] == n and std.mem.eql(u8, code.items[s[0]..][0..n], body[0..n])) {
                    stub = s[0];
                    break;
                }
            }
            const at: u32 = stub orelse blk: {
                const off: u32 = @intCast(code.items.len);
                try code.appendSlice(gpa, body[0..n]);
                try stubs.append(gpa, .{ off, @intCast(n) });
                break :blk off;
            };
            const rel: u16 = @truncate(@as(u32, at) -% @as(u32, @intCast(w.lo + 3)));
            code.items[w.lo] = 0xe8;
            std.mem.writeInt(u16, code.items[w.lo + 1 ..][0..2], rel, .little);
            @memset(code.items[w.lo + 3 .. hi], 0x90);
        }
        if (code.items.len > 0xffff) return error.TooLarge;
        const alignment = @as(usize, 1) << shift;
        const pos = std.mem.alignForward(usize, out.items.len, alignment);
        if (pos >> shift > 0xffff) return error.TooLarge;
        try out.appendNTimes(gpa, 0, pos - out.items.len);
        try out.appendSlice(gpa, code.items);
        try out.appendSlice(gpa, relocs);
        const o = out.items[entry..][0..8];
        std.mem.writeInt(u16, o[0..2], @intCast(pos >> shift), .little);
        std.mem.writeInt(u16, o[2..4], @intCast(code.items.len), .little);
        std.mem.writeInt(u16, o[4..6], flags, .little);
        std.mem.writeInt(u16, o[6..8], @intCast(code.items.len), .little);
        moved = true;
    }
    if (moved) {
        out.items[ne_off + 0x37] &= ~@as(u8, 0x08);
        std.mem.writeInt(u16, out.items[ne_off + 0x38 ..][0..2], 0, .little);
        std.mem.writeInt(u16, out.items[ne_off + 0x3a ..][0..2], 0, .little);
    }
    if (out.items.len != plan.output_len or !std.mem.eql(u8, &sha256(out.items), &plan.output))
        return error.OutputMismatch;
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------ logo

/// helper A (send AH to port DX, then latch-load + write AL) directly
/// followed by helper B (latch-load + write AL), as in VGALOGO.LGO 3.0a/3.1.
const orig_helpers = [_]u8{ 0x50, 0x86, 0xe0, 0xee, 0x26, 0x86, 0x25, 0xb0, 0xff, 0x58, 0xc3, 0x50, 0x26, 0x86, 0x05, 0x58, 0xc3 };
const a_len = 11;
const new_a = [_]u8{ 0x50, 0x8a, 0xc4, 0xee, 0x58 }; // push ax / mov al,ah / out dx,al / pop ax
const new_b = [_]u8{ 0x50, 0x26, 0x8a, 0x25, 0x26, 0x88, 0x05, 0x58, 0xc3 }; // push / mov ah,es:[di] / mov es:[di],al / pop / ret

fn countOf(data: []const u8, pattern: []const u8, first: *usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, pattern)) |at| {
        if (n == 0) first.* = at;
        n += 1;
        i = at + 1;
    }
    return n;
}

/// Patched copy of VGALOGO.LGO / WIN.COM (caller frees).
pub fn patchLogo(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var pos: usize = 0;
    if (countOf(raw, &orig_helpers, &pos) != 1) {
        var other: usize = 0;
        if (countOf(raw, &(new_a ++ new_b), &other) == 1) return error.AlreadyPatched;
        return error.NotFound;
    }
    // mov ax,A / mov [bp-36h],ax / mov ax,B / mov [bp-38h],ax before the helpers
    var found: usize = 0;
    var base: usize = 0;
    var load: usize = 0;
    var m: usize = 0;
    while (m + 12 <= pos) : (m += 1) {
        const b = raw[m..][0..12];
        if (b[0] != 0xb8 or b[3] != 0x89 or b[4] != 0x46 or b[5] != 0xca or
            b[6] != 0xb8 or b[9] != 0x89 or b[10] != 0x46 or b[11] != 0xc8) continue;
        const a = std.mem.readInt(u16, b[1..3], .little);
        const bb = std.mem.readInt(u16, b[7..9], .little);
        if (@as(u32, bb) != @as(u32, a) + a_len or a > pos or pos - a > m) continue;
        found += 1;
        base = pos - a;
        load = m - base;
    }
    if (found != 1) return error.NotFound;
    const out = try gpa.dupe(u8, raw);
    @memcpy(out[pos..][0..new_a.len], &new_a);
    @memcpy(out[pos + new_a.len ..][0..new_b.len], &new_b);
    @memset(out[pos + new_a.len + new_b.len .. pos + orig_helpers.len], 0x90);
    const imm_b = base + load + 7;
    std.mem.writeInt(u16, out[imm_b..][0..2], @intCast(pos - base + new_a.len), .little);
    return out;
}

test "xchg stub sequence" {
    var buf: [32]u8 = undefined;
    // xchg es:[di],al -> push cx / mov cl,es:[di] / mov es:[di],al / mov al,cl / pop cx
    const n = try xchgSeq(&.{ 0x26, 0x86, 0x05 }, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x51, 0x26, 0x8a, 0x0d, 0x26, 0x88, 0x05, 0x8a, 0xc1, 0x59 }, buf[0..n]);
    // xchg [bx+si+12h],dx -> T = AX
    const w = try xchgSeq(&.{ 0x87, 0x50, 0x12 }, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x50, 0x8b, 0x40, 0x12, 0x89, 0x50, 0x12, 0x8b, 0xd0, 0x58 }, buf[0..w]);
    try std.testing.expectError(error.Unsupported, xchgSeq(&.{ 0x86, 0xc4 }, &buf));
}

test "logo helpers" {
    const gpa = std.testing.allocator;
    var img: [0x60]u8 = @splat(0x90);
    // pointer loads at 0x10, helpers at 0x30
    @memcpy(img[0x10..0x1c], &[_]u8{ 0xb8, 0x30, 0x00, 0x89, 0x46, 0xca, 0xb8, 0x3b, 0x00, 0x89, 0x46, 0xc8 });
    @memcpy(img[0x30..][0..orig_helpers.len], &orig_helpers);
    const out = try patchLogo(gpa, &img);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &new_a, out[0x30..0x35]);
    try std.testing.expectEqual(@as(u16, 0x35), std.mem.readInt(u16, out[0x17..0x19], .little));
    try std.testing.expectError(error.AlreadyPatched, patchLogo(gpa, out));
}
