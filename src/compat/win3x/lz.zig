//! Microsoft compressed setup files of Windows 3.x (own implementation).
//!
//!   SZDD  (COMPRESS.EXE of Windows 3.0 / 3.1, LZEXPAND): LZSS, 4 KiB ring
//!         buffer filled with spaces, flag byte per 8 items (1 = literal,
//!         0 = 12-bit position + 4-bit length - 3).
//!   KWAJ  method 3 (Windows 3.11 / WfW 3.11 media): LZ77 with five Huffman
//!         tables (match length after a match or a full literal run, match
//!         length after a short literal run, literal run length, offset
//!         high bits, literal), each sent as one of four length encodings;
//!         bits MSB first, 4 KiB ring buffer filled with spaces.
//!
//! The encoders write the same container with literals only, so Setup reads
//! the file through the decompressor it already uses for that media: SZDD
//! with every flag byte FFh; KWAJ method 3 with fixed-length tables (type 0,
//! as Microsoft's own compressor emits on the same media) and literal runs of
//! 32 bytes, the last one shorter. Both keep the original header (missing
//! name character, KWAJ name/extension fields) and update the stored length.
const std = @import("std");

pub const Error = error{ Corrupt, Unsupported, OutOfMemory };
pub const Kind = enum { plain, szdd, kwaj };

const szdd_magic = "SZDD\x88\xf0\x27\x33";
const kwaj_magic = "KWAJ\x88\xf0\x27\xd1";
const max_output: u32 = 4 * 1024 * 1024;

pub fn kind(data: []const u8) Kind {
    if (data.len >= 14 and std.mem.eql(u8, data[0..8], szdd_magic)) return .szdd;
    if (data.len >= 14 and std.mem.eql(u8, data[0..8], kwaj_magic)) return .kwaj;
    return .plain;
}

fn rd16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Corrupt;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Corrupt;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Decompressed bytes (caller frees); a plain file is copied.
pub fn expand(gpa: std.mem.Allocator, data: []const u8) Error![]u8 {
    return switch (kind(data)) {
        .plain => gpa.dupe(u8, data),
        .szdd => expandSzdd(gpa, data),
        .kwaj => expandKwaj(gpa, data),
    };
}

fn expandSzdd(gpa: std.mem.Allocator, data: []const u8) Error![]u8 {
    if (data[8] != 'A') return error.Unsupported;
    const n = try rd32(data, 10);
    if (n > max_output) return error.Unsupported;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    var window: [4096]u8 = @splat(' ');
    var pos: usize = 4096 - 16;
    var o: usize = 0;
    var i: usize = 14;
    while (o < n) {
        if (i >= data.len) return error.Corrupt;
        const flags = data[i];
        i += 1;
        var bit: u4 = 0;
        while (bit < 8 and o < n) : (bit += 1) {
            if (((flags >> @intCast(bit)) & 1) != 0) {
                if (i >= data.len) return error.Corrupt;
                const c = data[i];
                i += 1;
                out[o] = c;
                o += 1;
                window[pos] = c;
                pos = (pos + 1) & 4095;
            } else {
                if (i + 2 > data.len) return error.Corrupt;
                const lo = data[i];
                const hi = data[i + 1];
                i += 2;
                const src: usize = @as(usize, lo) | (@as(usize, hi & 0xf0) << 4);
                const len: usize = @as(usize, hi & 15) + 3;
                var k: usize = 0;
                while (k < len and o < n) : (k += 1) {
                    const c = window[(src + k) & 4095];
                    out[o] = c;
                    o += 1;
                    window[pos] = c;
                    pos = (pos + 1) & 4095;
                }
            }
        }
    }
    return out;
}

const Bits = struct {
    data: []const u8,
    i: usize,
    buf: u32 = 0,
    n: u5 = 0,
    /// Bits taken after the end of the input (read as zero).
    over: usize = 0,

    fn read(self: *Bits, count: u5) u32 {
        var v: u32 = 0;
        var k: u5 = 0;
        while (k < count) : (k += 1) v = (v << 1) | self.bit();
        return v;
    }

    fn bit(self: *Bits) u32 {
        if (self.n == 0) {
            if (self.i < self.data.len) {
                self.buf = self.data[self.i];
                self.i += 1;
            } else {
                self.buf = 0;
                self.over += 8;
            }
            self.n = 8;
        }
        self.n -= 1;
        return (self.buf >> self.n) & 1;
    }
};

const Table = struct {
    lens: [256]u8 = @splat(0),
    count: u16,
    /// Symbols per code length and the symbols sorted by (length, symbol).
    per_len: [17]u16 = @splat(0),
    sorted: [256]u16 = undefined,

    fn finish(self: *Table) Error!void {
        for (self.lens[0..self.count]) |l| {
            if (l > 16) return error.Corrupt;
            self.per_len[l] += 1;
        }
        var k: usize = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            for (self.lens[0..self.count], 0..) |l, s| {
                if (l != len) continue;
                self.sorted[k] = @intCast(s);
                k += 1;
            }
        }
    }

    /// Canonical code: shorter codes first, equal lengths in symbol order.
    fn decode(self: *const Table, bits: *Bits) Error!u16 {
        var code: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var len: usize = 1;
        while (len <= 16) : (len += 1) {
            code |= bits.bit();
            const count: u32 = self.per_len[len];
            if (code -% first < count) return self.sorted[index + code - first];
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        return error.Corrupt;
    }
};

fn readLens(bits: *Bits, kind_: u32, count: u16) Error!Table {
    var t = Table{ .count = count };
    const lens = t.lens[0..count];
    switch (kind_) {
        0 => {
            const c: u8 = switch (count) {
                16 => 4,
                32 => 5,
                64 => 6,
                256 => 8,
                else => return error.Corrupt,
            };
            @memset(lens, c);
        },
        1 => {
            var c: u8 = @intCast(bits.read(4));
            lens[0] = c;
            for (lens[1..]) |*l| {
                if (bits.read(1) == 0) {
                    l.* = c;
                } else if (bits.read(1) == 0) {
                    c +%= 1;
                    l.* = c;
                } else {
                    c = @intCast(bits.read(4));
                    l.* = c;
                }
            }
        },
        2 => {
            var c: u8 = @intCast(bits.read(4));
            lens[0] = c;
            for (lens[1..]) |*l| {
                const sel = bits.read(2);
                if (sel == 3) c = @intCast(bits.read(4)) else c = c +% @as(u8, @intCast(sel)) -% 1;
                l.* = c;
            }
        },
        3 => for (lens) |*l| {
            l.* = @intCast(bits.read(4));
        },
        else => return error.Corrupt,
    }
    try t.finish();
    return t;
}

const KwajHeader = struct { data_offset: u16, length: u32, length_at: usize };

fn kwajHeader(data: []const u8) Error!KwajHeader {
    const method = try rd16(data, 8);
    const data_offset = try rd16(data, 10);
    const flags = try rd16(data, 12);
    if (method != 3) return error.Unsupported;
    // The uncompressed length must be stored (bit 0): it ends the output.
    if (flags & 1 == 0) return error.Unsupported;
    const length = try rd32(data, 14);
    if (length > max_output or data_offset > data.len or data_offset < 18) return error.Corrupt;
    return .{ .data_offset = data_offset, .length = length, .length_at = 14 };
}

fn expandKwaj(gpa: std.mem.Allocator, data: []const u8) Error![]u8 {
    const h = try kwajHeader(data);
    const out = try gpa.alloc(u8, h.length);
    errdefer gpa.free(out);
    var bits = Bits{ .data = data, .i = h.data_offset };
    var types: [6]u32 = undefined;
    for (&types) |*t| t.* = bits.read(4);
    const matchlen1 = try readLens(&bits, types[0], 16);
    const matchlen2 = try readLens(&bits, types[1], 16);
    const litlen = try readLens(&bits, types[2], 32);
    const offset = try readLens(&bits, types[3], 64);
    const literal = try readLens(&bits, types[4], 256);
    var window: [4096]u8 = @splat(' ');
    var pos: usize = 0;
    var o: usize = 0;
    var lit_run = false;
    while (o < out.len) {
        if (bits.over > 8) return error.Corrupt;
        var len: usize = try (if (lit_run) matchlen2 else matchlen1).decode(&bits);
        if (len > 0) {
            len += 2;
            lit_run = false;
            const off: usize = (@as(usize, try offset.decode(&bits)) << 6) | bits.read(6);
            var k: usize = 0;
            while (k < len and o < out.len) : (k += 1) {
                const c = window[(pos + 4096 - off) & 4095];
                window[pos] = c;
                out[o] = c;
                o += 1;
                pos = (pos + 1) & 4095;
            }
        } else {
            len = @as(usize, try litlen.decode(&bits)) + 1;
            lit_run = len != 32;
            var k: usize = 0;
            while (k < len and o < out.len) : (k += 1) {
                const c: u8 = @intCast(try literal.decode(&bits));
                window[pos] = c;
                out[o] = c;
                o += 1;
                pos = (pos + 1) & 4095;
            }
        }
    }
    return out;
}

/// `body` in the container of `original` (same header fields, new length).
pub fn compressLike(gpa: std.mem.Allocator, original: []const u8, body: []const u8) Error![]u8 {
    if (body.len > max_output) return error.Unsupported;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (kind(original)) {
        .plain => try out.appendSlice(gpa, body),
        .szdd => {
            try out.appendSlice(gpa, original[0..14]);
            std.mem.writeInt(u32, out.items[10..14], @intCast(body.len), .little);
            var i: usize = 0;
            while (i < body.len) : (i += 8) {
                try out.append(gpa, 0xff);
                try out.appendSlice(gpa, body[i..@min(i + 8, body.len)]);
            }
        },
        .kwaj => {
            const h = try kwajHeader(original);
            try out.appendSlice(gpa, original[0..h.data_offset]);
            std.mem.writeInt(u32, out.items[h.length_at..][0..4], @intCast(body.len), .little);
            var w = BitWriter{ .out = &out, .gpa = gpa };
            try w.put(0, 24); // six table types 0 (fixed lengths)
            var i: usize = 0;
            while (i < body.len) {
                const n = @min(32, body.len - i);
                try w.put(0, 4); // match length 0 = literal run
                try w.put(@intCast(n - 1), 5);
                for (body[i .. i + n]) |c| try w.put(c, 8);
                i += n;
            }
            try w.flush();
        },
    }
    return out.toOwnedSlice(gpa);
}

const BitWriter = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acc: u32 = 0,
    n: u5 = 0,

    fn put(self: *BitWriter, value: u32, count: u5) Error!void {
        var k: u5 = count;
        while (k > 0) {
            k -= 1;
            self.acc = (self.acc << 1) | ((value >> k) & 1);
            self.n += 1;
            if (self.n == 8) {
                try self.out.append(self.gpa, @intCast(self.acc & 0xff));
                self.acc = 0;
                self.n = 0;
            }
        }
    }

    fn flush(self: *BitWriter) Error!void {
        if (self.n != 0) try self.put(0, 8 - @as(u5, self.n));
    }
};

test "SZDD and KWAJ literal containers round-trip" {
    const gpa = std.testing.allocator;
    var body: [300]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    const szdd = szdd_magic ++ "A\x56\x00\x00\x00\x00";
    const a = try compressLike(gpa, szdd, &body);
    defer gpa.free(a);
    try std.testing.expectEqual(Kind.szdd, kind(a));
    const ea = try expand(gpa, a);
    defer gpa.free(ea);
    try std.testing.expectEqualSlices(u8, &body, ea);
    // KWAJ method 3, data offset 26, flags: length + name + extension
    const kwaj = kwaj_magic ++ "\x03\x00\x1a\x00\x19\x00\x00\x00\x00\x00VGA\x00DRV\x00";
    const b = try compressLike(gpa, kwaj, &body);
    defer gpa.free(b);
    try std.testing.expectEqual(Kind.kwaj, kind(b));
    try std.testing.expectEqualSlices(u8, kwaj[18..26], b[18..26]);
    const eb = try expand(gpa, b);
    defer gpa.free(eb);
    try std.testing.expectEqualSlices(u8, &body, eb);
}
