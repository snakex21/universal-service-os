//! Microsoft cabinet files (MSCF 1.3) with one MSZIP folder, as Windows
//! 95/98/Me Setup ships MINI.CAB (own implementation, GPL-3.0-or-later).
//!
//! `parse` reads the header, the folder and file entries and inflates the
//! folder (MSZIP: every CFDATA block is "CK" + one deflate stream; the LZ77
//! window carries over from the previous blocks, so the whole folder is
//! decoded into one buffer and a distance may reach into earlier blocks).
//! `build` writes the cabinet again: the original header bytes (set ID,
//! cabinet index, flags, reserve fields and the previous/next cabinet names)
//! are kept and only the sizes are updated; one MSZIP folder whose blocks are
//! stored deflate blocks (BTYPE 00, every inflater reads them) of at most
//! 32 KiB, each with the CFDATA checksum. Files keep their order, names,
//! dates and attributes.
const std = @import("std");

pub const Error = error{ NotCab, Corrupt, Unsupported, TooLarge, OutOfMemory };

const max_folder: usize = 16 * 1024 * 1024;
const block_size: usize = 32768;

pub const File = struct {
    name: []const u8,
    data: []const u8,
    date: u16,
    time: u16,
    attribs: u16,
};

pub const Cabinet = struct {
    /// Header bytes up to the first CFFOLDER (fixed part, reserve, names).
    header: []const u8,
    /// Per-folder / per-data reserve sizes (header reserve field).
    folder_reserve: u8,
    data_reserve: u8,
    /// The folder reserve bytes of the original folder entry.
    folder_extra: []const u8,
    compress: u16,
    files: []File,
    /// The inflated folder (File.data slices point into it).
    body: []u8,

    pub fn deinit(self: *Cabinet, gpa: std.mem.Allocator) void {
        gpa.free(self.files);
        gpa.free(self.body);
        self.* = undefined;
    }

    pub fn find(self: *const Cabinet, name: []const u8) ?usize {
        for (self.files, 0..) |f, i| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return i;
        }
        return null;
    }
};

fn rd16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.Corrupt;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.Corrupt;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn cstrEnd(b: []const u8, off: usize) Error!usize {
    const end = std.mem.indexOfScalarPos(u8, b, off, 0) orelse return error.Corrupt;
    return end + 1;
}

pub fn isCab(data: []const u8) bool {
    return data.len >= 36 and std.mem.eql(u8, data[0..4], "MSCF");
}

/// Parses a single-folder MSZIP or stored cabinet. File names and the
/// header slices point into `data`; the caller keeps `data` alive.
pub fn parse(gpa: std.mem.Allocator, data: []const u8) Error!Cabinet {
    if (!isCab(data)) return error.NotCab;
    if (data[24] != 3 or data[25] != 1) return error.Unsupported;
    const coff_files = try rd32(data, 16);
    const n_folders = try rd16(data, 26);
    const n_files = try rd16(data, 28);
    const flags = try rd16(data, 30);
    var o: usize = 36;
    var header_reserve: usize = 0;
    var folder_reserve: u8 = 0;
    var data_reserve: u8 = 0;
    if (flags & 4 != 0) {
        header_reserve = try rd16(data, 36);
        if (40 > data.len) return error.Corrupt;
        folder_reserve = data[38];
        data_reserve = data[39];
        o = 40 + header_reserve;
    }
    if (flags & 1 != 0) o = try cstrEnd(data, try cstrEnd(data, o));
    if (flags & 2 != 0) o = try cstrEnd(data, try cstrEnd(data, o));
    if (o > data.len) return error.Corrupt;
    if (n_folders != 1) return error.Unsupported;
    const header = data[0..o];
    const coff_cab = try rd32(data, o);
    const n_data = try rd16(data, o + 4);
    const compress = try rd16(data, o + 6);
    if (o + 8 + folder_reserve > data.len) return error.Corrupt;
    const folder_extra = data[o + 8 .. o + 8 + folder_reserve];
    if (compress != 0 and compress != 1) return error.Unsupported;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    var p: usize = coff_cab;
    var k: usize = 0;
    while (k < n_data) : (k += 1) {
        const cb_data = try rd16(data, p + 4);
        const cb_uncomp = try rd16(data, p + 6);
        const start = p + 8 + data_reserve;
        if (start + cb_data > data.len or cb_uncomp == 0) return error.Corrupt;
        const block = data[start .. start + cb_data];
        const before = body.items.len;
        if (before + cb_uncomp > max_folder) return error.TooLarge;
        if (compress == 0) {
            if (cb_data != cb_uncomp) return error.Corrupt;
            try body.appendSlice(gpa, block);
        } else {
            if (block.len < 2 or block[0] != 'C' or block[1] != 'K') return error.Corrupt;
            try inflate(gpa, &body, block[2..], before + cb_uncomp);
        }
        if (body.items.len != before + cb_uncomp) return error.Corrupt;
        p = start + cb_data;
    }

    const files = try gpa.alloc(File, n_files);
    errdefer gpa.free(files);
    const offsets = try gpa.alloc(u32, n_files);
    defer gpa.free(offsets);
    var q: usize = coff_files;
    for (files, offsets) |*f, *off| {
        const size = try rd32(data, q);
        off.* = try rd32(data, q + 4);
        const ifolder = try rd16(data, q + 8);
        if (ifolder != 0) return error.Unsupported;
        const name_end = try cstrEnd(data, q + 16);
        if (@as(usize, off.*) + size > body.items.len) return error.Corrupt;
        f.* = .{
            .name = data[q + 16 .. name_end - 1],
            .data = &.{},
            .date = try rd16(data, q + 10),
            .time = try rd16(data, q + 12),
            .attribs = try rd16(data, q + 14),
        };
        f.data.len = size;
        q = name_end;
    }
    const owned = try body.toOwnedSlice(gpa);
    for (files, offsets) |*f, off| f.data = owned[off .. off + f.data.len];
    return .{
        .header = header,
        .folder_reserve = folder_reserve,
        .data_reserve = data_reserve,
        .folder_extra = folder_extra,
        .compress = compress,
        .files = files,
        .body = owned,
    };
}

/// The CFDATA checksum (the cabinet SDK's CSUMCompute): 32-bit little-endian
/// words XORed, the 1-3 trailing bytes as one word (first byte highest).
pub fn checksum(data: []const u8, seed: u32) u32 {
    var csum = seed;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) csum ^= std.mem.readInt(u32, data[i..][0..4], .little);
    var ul: u32 = 0;
    switch (data.len - i) {
        3 => ul = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8) | data[i + 2],
        2 => ul = (@as(u32, data[i]) << 8) | data[i + 1],
        1 => ul = data[i],
        else => {},
    }
    return csum ^ ul;
}

fn put16(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) Error!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn put32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

/// A new cabinet with `files` in one MSZIP folder of stored deflate blocks,
/// header metadata taken from `like` (the parsed original).
pub fn build(gpa: std.mem.Allocator, like: *const Cabinet, files: []const File) Error![]u8 {
    var total: usize = 0;
    for (files) |f| total += f.data.len;
    if (total > max_folder or files.len > 0xffff) return error.TooLarge;
    const n_blocks = (total + block_size - 1) / block_size;
    if (n_blocks > 0xffff) return error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, like.header);
    const folder_at = out.items.len;
    try put32(&out, gpa, 0); // coffCabStart, set below
    try put16(&out, gpa, @intCast(n_blocks));
    try put16(&out, gpa, 1); // MSZIP
    try out.appendSlice(gpa, like.folder_extra);
    const files_at = out.items.len;
    var offset: u32 = 0;
    for (files) |f| {
        try put32(&out, gpa, @intCast(f.data.len));
        try put32(&out, gpa, offset);
        try put16(&out, gpa, 0);
        try put16(&out, gpa, f.date);
        try put16(&out, gpa, f.time);
        try put16(&out, gpa, f.attribs);
        try out.appendSlice(gpa, f.name);
        try out.append(gpa, 0);
        offset += @intCast(f.data.len);
    }
    const data_at = out.items.len;
    // The folder as one byte stream, cut into 32 KiB blocks.
    const stream = try gpa.alloc(u8, total);
    defer gpa.free(stream);
    var w: usize = 0;
    for (files) |f| {
        @memcpy(stream[w .. w + f.data.len], f.data);
        w += f.data.len;
    }
    var i: usize = 0;
    while (i < total) {
        const n = @min(block_size, total - i);
        var payload: [7]u8 = undefined;
        payload[0] = 'C';
        payload[1] = 'K';
        payload[2] = 0x01; // BFINAL = 1, BTYPE = 00 (stored), rest of the byte padding
        std.mem.writeInt(u16, payload[3..5], @intCast(n), .little);
        std.mem.writeInt(u16, payload[5..7], ~@as(u16, @intCast(n)), .little);
        const cb_data: u16 = @intCast(n + payload.len);
        var sizes: [4]u8 = undefined;
        std.mem.writeInt(u16, sizes[0..2], cb_data, .little);
        std.mem.writeInt(u16, sizes[2..4], @intCast(n), .little);
        // checksum over the compressed data, then over cbData/cbUncomp
        const joined = try gpa.alloc(u8, cb_data);
        defer gpa.free(joined);
        @memcpy(joined[0..payload.len], &payload);
        @memcpy(joined[payload.len..], stream[i .. i + n]);
        try put32(&out, gpa, checksum(sizes[0..4], checksum(joined, 0)));
        try out.appendSlice(gpa, &sizes);
        try out.appendNTimes(gpa, 0, like.data_reserve);
        try out.appendSlice(gpa, joined);
        i += n;
    }
    if (out.items.len > std.math.maxInt(u32)) return error.TooLarge;
    std.mem.writeInt(u32, out.items[8..12], @intCast(out.items.len), .little); // cbCabinet
    std.mem.writeInt(u32, out.items[16..20], @intCast(files_at), .little); // coffFiles
    std.mem.writeInt(u16, out.items[28..30], @intCast(files.len), .little); // cFiles
    std.mem.writeInt(u32, out.items[folder_at..][0..4], @intCast(data_at), .little);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------- inflate

const BitReader = struct {
    in: []const u8,
    pos: usize = 0,
    acc: u32 = 0,
    n: u5 = 0,

    fn bits(self: *BitReader, count: u5) Error!u32 {
        while (self.n < count) {
            if (self.pos >= self.in.len) return error.Corrupt;
            self.acc |= @as(u32, self.in[self.pos]) << self.n;
            self.pos += 1;
            self.n += 8;
        }
        const v = if (count == 0) 0 else self.acc & ((@as(u32, 1) << count) - 1);
        self.acc = if (count == 0) self.acc else self.acc >> count;
        self.n -= count;
        return v;
    }

    fn alignByte(self: *BitReader) void {
        self.acc = 0;
        self.n = 0;
    }
};

const Huffman = struct {
    count: [16]u16 = @splat(0),
    symbol: [320]u16 = @splat(0),

    fn init(lengths: []const u8) Error!Huffman {
        var h = Huffman{};
        for (lengths) |l| h.count[l] += 1;
        h.count[0] = 0;
        var left: i32 = 1;
        for (1..16) |len| {
            left = left * 2 - @as(i32, h.count[len]);
            if (left < 0) return error.Corrupt; // over-subscribed
        }
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        for (1..15) |len| offs[len + 1] = offs[len] + h.count[len];
        for (lengths, 0..) |l, sym| {
            if (l != 0) {
                h.symbol[offs[l]] = @intCast(sym);
                offs[l] += 1;
            }
        }
        return h;
    }

    fn decode(self: *const Huffman, br: *BitReader) Error!u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |len| {
            code |= @intCast(try br.bits(1));
            const count: i32 = self.count[len];
            if (code - count < first) return self.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.Corrupt;
    }
};

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const cl_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Inflates one deflate stream (until BFINAL) and appends it to `out`;
/// back-references may reach into what `out` already holds (MSZIP).
/// Fails when the output would pass `limit`.
pub fn inflate(gpa: std.mem.Allocator, out: *std.ArrayList(u8), in: []const u8, limit: usize) Error!void {
    var br = BitReader{ .in = in };
    while (true) {
        const final = try br.bits(1);
        const btype = try br.bits(2);
        switch (btype) {
            0 => {
                br.alignByte();
                if (br.pos + 4 > in.len) return error.Corrupt;
                const len = std.mem.readInt(u16, in[br.pos..][0..2], .little);
                const nlen = std.mem.readInt(u16, in[br.pos + 2 ..][0..2], .little);
                if (len != ~nlen) return error.Corrupt;
                br.pos += 4;
                if (br.pos + len > in.len or out.items.len + len > limit) return error.Corrupt;
                try out.appendSlice(gpa, in[br.pos .. br.pos + len]);
                br.pos += len;
            },
            1 => {
                var lengths: [288 + 30]u8 = undefined;
                for (0..144) |s| lengths[s] = 8;
                for (144..256) |s| lengths[s] = 9;
                for (256..280) |s| lengths[s] = 7;
                for (280..288) |s| lengths[s] = 8;
                for (288..318) |s| lengths[s] = 5;
                const lit = try Huffman.init(lengths[0..288]);
                const dist = try Huffman.init(lengths[288..318]);
                try codes(gpa, out, &br, &lit, &dist, limit);
            },
            2 => {
                const nlen = try br.bits(5) + 257;
                const ndist = try br.bits(5) + 1;
                const ncode = try br.bits(4) + 4;
                if (nlen > 286 or ndist > 30) return error.Corrupt;
                var cl: [19]u8 = @splat(0);
                for (0..ncode) |k| cl[cl_order[k]] = @intCast(try br.bits(3));
                const clh = try Huffman.init(&cl);
                var lengths: [320]u8 = @splat(0);
                var idx: usize = 0;
                while (idx < nlen + ndist) {
                    const sym = try clh.decode(&br);
                    if (sym < 16) {
                        lengths[idx] = @intCast(sym);
                        idx += 1;
                        continue;
                    }
                    var rep: usize = 0;
                    var val: u8 = 0;
                    switch (sym) {
                        16 => {
                            if (idx == 0) return error.Corrupt;
                            val = lengths[idx - 1];
                            rep = 3 + try br.bits(2);
                        },
                        17 => rep = 3 + try br.bits(3),
                        18 => rep = 11 + try br.bits(7),
                        else => return error.Corrupt,
                    }
                    if (idx + rep > nlen + ndist) return error.Corrupt;
                    @memset(lengths[idx .. idx + rep], val);
                    idx += rep;
                }
                if (lengths[256] == 0) return error.Corrupt;
                const lit = try Huffman.init(lengths[0..nlen]);
                const dist = try Huffman.init(lengths[nlen .. nlen + ndist]);
                try codes(gpa, out, &br, &lit, &dist, limit);
            },
            else => return error.Corrupt,
        }
        if (final == 1) return;
    }
}

fn codes(gpa: std.mem.Allocator, out: *std.ArrayList(u8), br: *BitReader, lit: *const Huffman, dist: *const Huffman, limit: usize) Error!void {
    while (true) {
        const sym = try lit.decode(br);
        if (sym < 256) {
            if (out.items.len >= limit) return error.Corrupt;
            try out.append(gpa, @intCast(sym));
        } else if (sym == 256) {
            return;
        } else {
            const li = sym - 257;
            if (li >= 29) return error.Corrupt;
            const len: usize = len_base[li] + try br.bits(len_extra[li]);
            const ds = try dist.decode(br);
            if (ds >= 30) return error.Corrupt;
            const d: usize = dist_base[ds] + try br.bits(dist_extra[ds]);
            if (d > out.items.len or out.items.len + len > limit) return error.Corrupt;
            const from = out.items.len - d;
            try out.ensureUnusedCapacity(gpa, len);
            for (0..len) |k| out.appendAssumeCapacity(out.items[from + k]);
        }
    }
}

test "stored and fixed-Huffman deflate streams inflate" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // zlib.compress(b"abcabcabcabc", wbits=-15) (fixed Huffman, one match)
    const fixed = [_]u8{ 0x4b, 0x4c, 0x4a, 0x4e, 0x84, 0x21, 0x00 };
    try inflate(gpa, &out, &fixed, 64);
    try std.testing.expectEqualStrings("abcabcabcabc", out.items);
    // a stored block after it
    const stored = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'x', 'y', 'z' };
    try inflate(gpa, &out, &stored, 64);
    try std.testing.expectEqualStrings("abcabcabcabcxyz", out.items);
    // a stream that only matches into the earlier ones (the MSZIP window
    // across blocks; zlib with zdict = the 15 bytes so far)
    const cross = [_]u8{ 0x83, 0x33, 0x00 };
    try inflate(gpa, &out, &cross, 64);
    try std.testing.expectEqualStrings("abcabcabcabcxyzabcabcxyz", out.items);
    // the limit is enforced
    try std.testing.expectError(error.Corrupt, inflate(gpa, &out, &fixed, out.items.len + 4));
}

test "cabinet build round-trips through parse with valid checksums" {
    const gpa = std.testing.allocator;
    // minimal header: MSCF, sizes patched by build, version 1.3, 1 folder
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3;
    header[25] = 1;
    header[26] = 1;
    std.mem.writeInt(u16, header[32..34], 0x1234, .little);
    var like = Cabinet{
        .header = &header,
        .folder_reserve = 0,
        .data_reserve = 0,
        .folder_extra = &.{},
        .compress = 1,
        .files = &.{},
        .body = &.{},
    };
    const big = try gpa.alloc(u8, 70000);
    defer gpa.free(big);
    for (big, 0..) |*b, k| b.* = @truncate(k * 13 + k / 7);
    const files = [_]File{
        .{ .name = "A.TXT", .data = "hello", .date = 1, .time = 2, .attribs = 0x20 },
        .{ .name = "BIG.BIN", .data = big, .date = 3, .time = 4, .attribs = 0x21 },
    };
    const cab_bytes = try build(gpa, &like, &files);
    defer gpa.free(cab_bytes);
    try std.testing.expectEqual(@as(u32, @intCast(cab_bytes.len)), std.mem.readInt(u32, cab_bytes[8..12], .little));
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, cab_bytes[32..34], .little));
    var cab = try parse(gpa, cab_bytes);
    defer cab.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), cab.files.len);
    try std.testing.expectEqualStrings("BIG.BIN", cab.files[1].name);
    try std.testing.expectEqualSlices(u8, big, cab.files[1].data);
    try std.testing.expectEqual(@as(u16, 0x21), cab.files[1].attribs);
    try std.testing.expectEqualStrings("hello", cab.files[0].data);
    // every CFDATA checksum is right
    const coff = std.mem.readInt(u32, cab_bytes[36..40], .little);
    const n = std.mem.readInt(u16, cab_bytes[40..42], .little);
    try std.testing.expectEqual(@as(u16, 3), n);
    var p: usize = coff;
    for (0..n) |_| {
        const stored_sum = std.mem.readInt(u32, cab_bytes[p..][0..4], .little);
        const cb = std.mem.readInt(u16, cab_bytes[p + 4 ..][0..2], .little);
        try std.testing.expectEqual(stored_sum, checksum(cab_bytes[p + 4 .. p + 8], checksum(cab_bytes[p + 8 .. p + 8 + cb], 0)));
        p += 8 + cb;
    }
    try std.testing.expectEqual(cab_bytes.len, p);
}
