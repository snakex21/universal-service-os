//! UDF 1.02/2.01 physical and 2.50/2.60 metadata partition reads.
//! SPDX-License-Identifier: GPL-3.0-or-later
//! OSTA UDF 2.60 2.2.10/2.2.13; ECMA-167 parts 3 and 4.
const std = @import("std");
const o = @import("optical.zig");
const Part = struct { number: u16 = 0, start: u32 = 0, blocks: u32 = 0 };
const Map = struct {
    number: u16 = 0,
    metadata: bool = false,
    file_lba: u32 = 0,
    ready: bool = false,
    extents: [32]o.Extent = undefined,
    count: usize = 0,
    size: u64 = 0,
};
pub const State = struct {
    revision: u16 = 0,
    parts: [8]Part = undefined,
    part_count: usize = 0,
    maps: [8]Map = undefined,
    map_count: usize = 0,
    fn part(self: *const State, number: u16) !Part {
        for (self.parts[0..self.part_count]) |p| if (p.number == number) return p;
        return error.InvalidUdfPartition;
    }
    fn physical(self: *const State, number: u16, block: u32, lba: u32, length: u64) !u64 {
        const p = try self.part(number);
        const relative = try o.mul(lba, block);
        const bytes = try o.mul(p.blocks, block);
        if (relative > bytes or length > bytes - relative) return error.OpticalBounds;
        return o.add(try o.mul(p.start, 2048), relative);
    }
    fn span(self: *const State, block: u32, ref: u16, lba: u32, length: u64) !o.Extent {
        if (ref >= self.map_count) return error.InvalidUdfPartition;
        const map = &self.maps[ref];
        if (!map.metadata) return .{ .offset = try self.physical(map.number, block, lba, length), .length = length, .tag_lba = lba };
        if (!map.ready) return error.UdfMetadataLoop;
        var skip = try o.mul(lba, block);
        if (skip > map.size or length > map.size - skip) return error.OpticalBounds;
        for (map.extents[0..map.count]) |extent| {
            if (skip >= extent.length) { skip -= extent.length; continue; }
            if (extent.offset == std.math.maxInt(u64)) return error.InvalidUdfMetadata;
            return .{ .offset = try o.add(extent.offset, skip), .length = @min(length, extent.length - skip), .tag_lba = lba };
        }
        return error.InvalidUdfMetadata;
    }
};
const Ad = struct { length: u32, lba: u32, ref: u16 };
fn lba32(value: u64) !u32 { return std.math.cast(u32,value) orelse error.OpticalBounds; }
fn long(b: []const u8, at: usize) Ad { return .{ .length = o.le(u32,b,at), .lba = o.le(u32,b,at+4), .ref = o.le(u16,b,at+8) }; }
pub fn crc16(bytes: []const u8) u16 {
    var crc: u16 = 0;
    for (bytes) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
    }
    return crc;
}
pub fn tag(b: []const u8, lba: u32, id: ?u16, minimum: usize) !usize {
    if (b.len < 16 or minimum < 16) return error.InvalidUdfTag;
    if (id) |wanted| if (o.le(u16,b,0) != wanted) return error.InvalidUdfTag;
    const version = o.le(u16,b,2);
    if (version != 2 and version != 3 or b[5] != 0 or o.le(u32,b,12) != lba) return error.InvalidUdfTag;
    var sum: u8 = 0;
    for (b[0..16],0..) |v,i| if (i != 4) { sum +%= v; };
    if (sum != b[4]) return error.UdfTagChecksum;
    const length = o.le(u16,b,10);
    if (length > b.len - 16 or @as(usize,length) + 16 < minimum) return error.InvalidUdfTag;
    if (crc16(b[16..][0..length]) != o.le(u16,b,8)) return error.UdfDescriptorCrc;
    return 16 + @as(usize,length);
}
pub fn recognized(input: o.Input) !bool {
    var b: [2048]u8 = undefined;
    for (16..80) |lba| {
        if ((lba + 1) * 2048 > input.size) break;
        try input.read(lba * 2048,&b);
        if (std.mem.eql(u8,b[1..6],"NSR02") or std.mem.eql(u8,b[1..6],"NSR03")) return true;
        if (std.mem.eql(u8,b[1..6],"TEA01")) break;
    }
    return false;
}
pub fn mount(input: o.Input) !o.Volume {
    var result: o.Volume = undefined;
    try mountInto(input,&result);
    return result;
}
pub fn mountInto(input: o.Input, out: *o.Volume) !void {
    var b: [2048]u8 = undefined;
    const blocks = input.size / 2048;
    const candidates = [_]u64{256, blocks -| 257, blocks -| 1};
    var anchor: ?[2048]u8 = null;
    var anchor_error: anyerror = error.MissingUdfAnchor;
    for (candidates) |lba| {
        if (lba >= blocks or lba > std.math.maxInt(u32)) continue;
        input.read(lba * 2048,&b) catch |err| {
            anchor_error = err;
            continue;
        };
        if (o.le(u16,&b,0) != 2) continue;
        _ = tag(&b,@intCast(lba),2,512) catch |err| {
            anchor_error = err;
            continue;
        };
        const length = o.le(u32,&b,16);
        const start = o.le(u32,&b,20);
        if (length < 2048 or length > 1024 * 1024 or length % 2048 != 0) {
            anchor_error = error.InvalidUdfSequence;
            continue;
        }
        // The fields are u32, so the u64 arithmetic below cannot overflow.
        if (@as(u64,start) * 2048 + length > input.size) {
            anchor_error = error.OpticalBounds;
            continue;
        }
        anchor = b;
        break;
    }
    b = anchor orelse return anchor_error;
    const sequence_length = o.le(u32,&b,16);
    const sequence_lba = o.le(u32,&b,20);
    if (sequence_length < 2048 or sequence_length > 1024 * 1024 or sequence_length % 2048 != 0) return error.InvalidUdfSequence;
    const sequence_end = try o.add(try o.mul(sequence_lba,2048),sequence_length);
    if (sequence_end > input.size) return error.OpticalBounds;
    var state: State = .{};
    var block: u32 = 0;
    var file_set: ?Ad = null;
    var terminated = false;
    var logical_found = false;
    for (0..sequence_length / 2048) |i| {
        const lba = try lba32(try o.add(sequence_lba,i));
        try input.read(@as(u64,lba) * 2048,&b);
        const used = try tag(&b,lba,null,16);
        switch (o.le(u16,&b,0)) {
            5 => {
                if (used < 512 or state.part_count == state.parts.len) return error.InvalidUdfPartition;
                const part: Part = .{ .number = o.le(u16,&b,22), .start = o.le(u32,&b,188), .blocks = o.le(u32,&b,192) };
                for (state.parts[0..state.part_count]) |prior| if (prior.number == part.number) return error.InvalidUdfPartition;
                if (try o.mul(try o.add(part.start,part.blocks),2048) > input.size) return error.OpticalBounds;
                state.parts[state.part_count] = part; state.part_count += 1;
            },
            6 => {
                if (logical_found or used < 440) return error.InvalidUdfLogicalVolume;
                logical_found = true;
                block = o.le(u32,&b,212);
                if (block != 2048) return error.UnsupportedOpticalBlockSize;
                if (!std.mem.startsWith(u8,b[217..240],"*OSTA UDF Compliant")) return error.UnsupportedUdfDomain;
                state.revision = o.le(u16,&b,240);
                if (state.revision != 0x102 and state.revision != 0x150 and state.revision != 0x200 and state.revision != 0x201 and state.revision != 0x250 and state.revision != 0x260) return error.UnsupportedUdfRevision;
                file_set = long(&b,248);
                const len = o.le(u32,&b,264);
                const count = o.le(u32,&b,268);
                if (count == 0 or count > state.maps.len or len > used - 440) return error.InvalidUdfPartition;
                var at: usize = 440;
                for (0..count) |n| {
                    if (at + 2 > 440 + len) return error.InvalidUdfPartition;
                    const size: usize = b[at+1];
                    if (size < 2 or size > 440 + len - at) return error.InvalidUdfPartition;
                    var map: Map = .{};
                    if (b[at] == 1 and size == 6) {
                        if (o.le(u16,&b,at+2) != 1) return error.UnsupportedVolumeSet;
                        map.number = o.le(u16,&b,at+4);
                    } else if (b[at] == 2 and size == 64 and std.mem.eql(u8,b[at+5..][0..23],"*UDF Metadata Partition")) {
                        if (state.revision < 0x250 or o.le(u16,&b,at+36) != 1) return error.InvalidUdfPartition;
                        map.metadata = true; map.number = o.le(u16,&b,at+38); map.file_lba = o.le(u32,&b,at+40);
                    } else return error.UnsupportedUdfPartitionMap;
                    state.maps[n] = map; at += size;
                }
                if (at != 440 + len) return error.InvalidUdfPartition;
                state.map_count = count;
            },
            8 => { if (used < 512) return error.InvalidUdfSequence; terminated = true; break; },
            1,4 => if (used < 512) { return error.InvalidUdfSequence; },
            7 => if (used < 24) { return error.InvalidUdfSequence; },
            else => return error.InvalidUdfSequence,
        }
    }
    if (!terminated or !logical_found or state.part_count == 0) return error.InvalidUdfSequence;
    var volume: o.Volume = .{ .input = input, .kind = .udf, .block_size = block, .root = .{}, .udf_state = state };
    for (0..volume.udf_state.map_count) |n| {
        const map = &volume.udf_state.maps[n];
        _ = try volume.udf_state.part(map.number);
        if (!map.metadata) continue;
        var physical_ref: ?u16 = null;
        for (volume.udf_state.maps[0..volume.udf_state.map_count],0..) |other,j| {
            if (!other.metadata and other.number == map.number) physical_ref = @intCast(j);
        }
        const ref = physical_ref orelse return error.InvalidUdfMetadata;
        const meta = try readNode(&volume,.{ .length = block, .lba = map.file_lba, .ref = ref },true);
        if (meta.directory or meta.count > map.extents.len) return error.InvalidUdfMetadata;
        for (meta.extents[0..meta.count]) |extent| {
            if (extent.offset == std.math.maxInt(u64) or extent.offset % block != 0 or extent.length % block != 0) return error.InvalidUdfMetadata;
        }
        if (meta.size % block != 0) return error.InvalidUdfMetadata;
        @memcpy(map.extents[0..meta.count],meta.extents[0..meta.count]); map.count = meta.count; map.size = meta.size; map.ready = true;
    }
    const fsd = file_set orelse return error.InvalidUdfLogicalVolume;
    try descriptor(&volume,fsd,&b);
    _ = try tag(&b,fsd.lba,256,512);
    if (o.le(u32,&b,448) != 0) return error.UnsupportedUdfFileSetChain;
    volume.root = try readNode(&volume,long(&b,400),false);
    if (!volume.root.directory) return error.InvalidUdfFileEntry;
    out.* = volume;
}
fn descriptor(v: *const o.Volume, ad: Ad, b: *[2048]u8) !void {
    if (ad.length >> 30 != 0 or ad.length & 0x3fffffff < 2048) return error.InvalidUdfAllocation;
    const span = try v.udf_state.span(v.block_size,ad.ref,ad.lba,2048);
    if (span.length != 2048) return error.InvalidUdfMetadata;
    try v.input.read(span.offset,b);
}
fn allocation(v: *const o.Volume, node: *o.Node, ref: u16, lba: u32, length: u32, zero: bool) !void {
    if (zero) { try node.append(v.input,std.math.maxInt(u64),length); return; }
    var done: u64 = 0;
    while (done < length) {
        const block = try lba32(try o.add(lba,done / v.block_size));
        const span = try v.udf_state.span(v.block_size,ref,block,length - done);
        try node.append(v.input,span.offset,span.length);
        node.extents[node.count-1].tag_lba = block;
        done += span.length;
        if (done < length and done % v.block_size != 0) return error.InvalidUdfMetadata;
    }
}
fn readNode(v: *const o.Volume, icb: Ad, metadata_file: bool) anyerror!o.Node {
    var result: o.Node = undefined;
    try readNodeInto(v,icb,metadata_file,&result);
    return result;
}
fn readNodeInto(v: *const o.Volume, icb: Ad, metadata_file: bool, out: *o.Node) anyerror!void {
    var b: [2048]u8 = undefined;
    try descriptor(v,icb,&b);
    const used = try tag(&b,icb.lba,null,36);
    const id = o.le(u16,&b,0);
    if (id != 261 and id != 266) return error.InvalidUdfFileEntry;
    if (o.le(u16,&b,20) != 4) return error.UnsupportedUdfIcbStrategy;
    const file_type = b[27];
    if (!metadata_file and file_type == 12) return error.UnsupportedUdfSymbolicLink;
    if (!metadata_file and (file_type == 13 or o.le(u16,&b,34) & 0x2000 != 0)) return error.UnsupportedUdfStream;
    if (if (metadata_file) file_type != 250 else file_type != 4 and file_type != 5) return error.UnsupportedUdfFileType;
    const base: usize = if (id == 266) 216 else 176;
    if (used < base) return error.InvalidUdfFileEntry;
    const flags = o.le(u16,&b,34);
    // ICB bit 10 is the System attribute; only compression/encryption
    // (bits 11/12) require a transformed-data reader.
    if (flags & 0x1800 != 0) return error.UnsupportedUdfTransform;
    const kind = flags & 7;
    const ea = o.le(u32,&b,base-8);
    var len: usize = o.le(u32,&b,base-4);
    if (ea > used-base or len > used-base-ea) return error.InvalidUdfFileEntry;
    var start: usize = base+ea;
    var node: o.Node = .{ .size = o.le(u64,&b,56), .directory = file_type == 4, .identity = (@as(u64,icb.ref)<<32)|icb.lba, .udf_partition = icb.ref, .udf_lba = icb.lba };
    if (kind == 3) {
        if (node.size > len) return error.InvalidUdfAllocation;
        const span = try v.udf_state.span(v.block_size,icb.ref,icb.lba,2048);
        try node.append(v.input,try o.add(span.offset,start),node.size);
        if (node.count != 0) node.extents[0].tag_lba = icb.lba;
        out.* = node;
        return;
    }
    const stride: usize = if (kind == 0) 8 else if (kind == 1) 16 else return error.UnsupportedUdfAllocation;
    var chain: [64]u64 = undefined;
    var chain_count: usize = 0;
    var allocated: u64 = 0;
    var current_ref = icb.ref;
    while (true) {
        if (len % stride != 0) return error.InvalidUdfAllocation;
        var continuation: ?Ad = null;
        var at = start;
        while (at < start+len) : (at += stride) {
            const encoded = o.le(u32,&b,at);
            const extent_kind = encoded >> 30;
            const extent_len = encoded & 0x3fffffff;
            const lba = o.le(u32,&b,at+4);
            const ref = if (kind == 0) current_ref else o.le(u16,&b,at+8);
            if (extent_len == 0) continue;
            if (extent_kind == 3) {
                if (at+stride != start+len) return error.InvalidUdfAllocation;
                continuation = .{ .length = extent_len, .lba = lba, .ref = ref }; break;
            }
            if (extent_kind == 1) {
                _ = try v.udf_state.span(v.block_size,ref,lba,extent_len);
            }
            if (node.directory and extent_kind != 0) return error.InvalidUdfAllocation;
            try allocation(v,&node,ref,lba,extent_len,extent_kind != 0);
            allocated = try o.add(allocated,extent_len);
        }
        if (continuation) |next_ad| {
            const key = (@as(u64,next_ad.ref)<<32)|next_ad.lba;
            for (chain[0..chain_count]) |old| if (old == key) return error.UdfAllocationLoop;
            if (chain_count == chain.len) return error.ExtentBudget;
            chain[chain_count] = key; chain_count += 1;
            try descriptor(v,next_ad,&b);
            const ad_used = try tag(&b,next_ad.lba,258,24);
            len = o.le(u32,&b,20); start = 24; current_ref = next_ad.ref;
            if (len > ad_used - start) return error.InvalidUdfAllocation;
        } else break;
    }
    if (allocated < node.size) return error.TruncatedOpticalFile;
    out.* = node;
}
fn location(node: *const o.Node, offset: u64, block: u32) !u32 {
    var skip = offset;
    for (node.extents[0..node.count]) |extent| {
        if (skip >= extent.length) { skip -= extent.length; continue; }
        return lba32(try o.add(extent.tag_lba,skip/block));
    }
    return error.InvalidUdfDirectory;
}
pub fn next(it: *o.Iterator, entry: *o.Entry) !bool {
    var b: [2048]u8 = undefined;
    while (it.offset < it.directory.size) {
        try it.record();
        if (it.directory.size-it.offset < 38) return error.InvalidUdfDirectory;
        const begin = it.offset;
        try it.directory.read(it.volume.input,begin,b[0..38]);
        const flags = b[18]; const name_len: usize = b[19]; const extra = o.le(u16,&b,36);
        const total: usize = (38+@as(usize,extra)+name_len+3)&~@as(usize,3);
        if (total > b.len or total > it.directory.size-begin) return error.InvalidUdfDirectory;
        try it.directory.read(it.volume.input,begin,b[0..total]);
        _ = try tag(b[0..total],try location(&it.directory,begin,it.volume.block_size),257,total);
        it.offset += total;
        if (flags & ~@as(u8,31) != 0 or o.le(u16,&b,16) != 1) return error.InvalidUdfDirectory;
        for (b[38+@as(usize,extra)+name_len..total]) |byte| if (byte != 0) return error.InvalidUdfDirectory;
        if (flags & 8 != 0) {
            if (name_len != 0 or flags & 2 == 0) return error.InvalidUdfDirectory;
            continue;
        }
        if (name_len != 0) {
            const compression = b[38+@as(usize,extra)];
            // CS0 254/255 decode to an empty, unique identifier (OSTA 2.1.1).
            // They cannot name a path component; count even deleted records.
            if (compression == 254 or compression == 255) {
                it.skipped.nameless += 1;
                continue;
            }
        }
        if (flags & 4 != 0) continue;
        if (name_len < 1) return error.InvalidUdfDirectory;
        const raw = b[38+@as(usize,extra)..][0..name_len];
        entry.name_len = 0;
        if (raw[0] == 8) {
            for (raw[1..],0..) |c,i| entry.name[i] = c;
            entry.name_len = name_len-1;
        } else if (raw[0] == 16 and (name_len-1)%2 == 0) {
            for (0..(name_len-1)/2) |i| entry.name[i] = o.be(u16,raw,1+i*2);
            entry.name_len = (name_len-1)/2;
        } else return error.InvalidOpticalName;
        try o.validateName(entry.nameSlice());
        entry.unsupported = null;
        entry.node = readNode(it.volume,long(&b,20),false) catch |err| {
            switch (err) {
                error.UnsupportedUdfSymbolicLink => it.skipped.symbolic_links += 1,
                error.UnsupportedUdfStream => it.skipped.streams += 1,
                error.UnsupportedUdfFileType, error.UnsupportedUdfTransform,
                error.UnsupportedUdfIcbStrategy, error.UnsupportedUdfAllocation => it.skipped.other += 1,
                else => return err,
            }
            if (!it.include_unsupported) continue;
            entry.unsupported = err;
            entry.node = .{};
            return true;
        };
        if (entry.node.directory != (flags & 2 != 0)) return error.InvalidUdfDirectory;
        if (entry.node.directory and entry.node.identity == it.directory.identity) return error.DirectoryLoop;
        return true;
    }
    return false;
}
