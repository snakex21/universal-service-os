//! ISO9660 levels 1-3, Joliet UCS-2, streamed multi-extent files.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const o = @import("optical.zig");
fn both(comptime T: type, b: []const u8, at: usize) !T {
    const v = o.le(T, b, at);
    if (v != o.be(T, b, at + @sizeOf(T))) return error.IsoEndianMismatch;
    return v;
}
fn node(input: o.Input, block: u32, raw: []const u8) !o.Node {
    var result: o.Node = undefined;
    try nodeInto(input,block,raw,&result);
    return result;
}
fn nodeInto(input: o.Input, block: u32, raw: []const u8, out: *o.Node) !void {
    if (raw.len < 34 or raw[0] != raw.len or 33 + @as(usize, raw[32]) > raw.len or raw[26] != 0 or raw[27] != 0 or raw[25] & 0x60 != 0) return error.InvalidIsoRecord;
    if (try both(u16, raw, 28) != 1) return error.UnsupportedVolumeSet;
    const lba = try o.add(try both(u32, raw, 2), raw[1]);
    const offset = try o.mul(lba, block);
    const size = try both(u32, raw, 10);
    var result: o.Node = .{ .size = size, .directory = raw[25] & 2 != 0, .identity = offset };
    if (result.directory and raw[25] & 0x80 != 0) return error.InvalidIsoRecord;
    try result.append(input, offset, size);
    out.* = result;
}
pub fn mount(input: o.Input) !o.Volume {
    var result: o.Volume = undefined;
    try mountInto(input,&result);
    return result;
}
pub fn mountInto(input: o.Input, out: *o.Volume) !void {
    var b: [2048]u8 = undefined;
    var primary: ?[2048]u8 = null;
    var joliet: ?[2048]u8 = null;
    var terminated = false;
    for (16..144) |sector| {
        try input.read(sector * 2048, &b);
        if (!std.mem.eql(u8, b[1..6], "CD001") or b[6] != 1) return error.InvalidIsoDescriptor;
        switch (b[0]) {
            1 => { if (primary != null) return error.InvalidIsoDescriptor; primary = b; },
            2 => if (std.mem.eql(u8, b[88..90], "%/") and (b[90] == '@' or b[90] == 'C' or b[90] == 'E')) { joliet = b; },
            255 => { terminated = true; break; },
            0, 3 => {},
            else => return error.InvalidIsoDescriptor,
        }
    }
    if (!terminated or primary == null) return error.InvalidIsoDescriptor;
    b = joliet orelse primary.?;
    const block = try both(u16, &b, 128);
    if (block != 2048) return error.UnsupportedOpticalBlockSize;
    if (try both(u16, &b, 120) != 1 or try both(u16, &b, 124) != 1) return error.UnsupportedVolumeSet;
    const declared = try o.mul(try both(u32, &b, 80), block);
    if (declared > input.size or declared < 17 * 2048) return error.OpticalBounds;
    out.* = .{ .input = .{ .context = input.context, .size = declared, .read_fn = input.read_fn }, .kind = if (joliet != null) .joliet else .iso9660, .block_size = block, .root = .{} };
    try nodeInto(out.input,block,b[156..][0..b[156]],&out.root);
    if (!out.root.directory) return error.InvalidIsoRecord;
}
fn record(it: *o.Iterator, b: *[255]u8) !?[]const u8 {
    const block = it.volume.block_size;
    while (it.offset < it.directory.size) {
        try it.directory.read(it.volume.input, it.offset, b[0..1]);
        const len: usize = b[0];
        if (len == 0) {
            it.offset = @min(it.directory.size, try o.mul(it.offset / block + 1, block));
            continue;
        }
        if (len < 34 or len > it.directory.size - it.offset or len > block - it.offset % block) return error.InvalidIsoRecord;
        try it.record();
        try it.directory.read(it.volume.input, it.offset, b[0..len]);
        it.offset += len;
        return b[0..len];
    }
    return null;
}
pub fn next(it: *o.Iterator, entry: *o.Entry) !bool {
    entry.unsupported = null;
    var b: [255]u8 = undefined;
    while (try record(it, &b)) |raw| {
        var result = try node(it.volume.input, it.volume.block_size, raw);
        const raw_name = raw[33..][0..raw[32]];
        if (raw_name.len == 1 and raw_name[0] <= 1) continue;
        const associated = raw[25] & 4 != 0;
        entry.name_len = 0;
        if (it.volume.kind == .joliet) {
            if (raw_name.len % 2 != 0) return error.InvalidOpticalName;
            for (0..raw_name.len / 2) |i| { entry.name[i] = o.be(u16, raw_name, i * 2); }
            entry.name_len = raw_name.len / 2;
        } else {
            for (raw_name, 0..) |c, i| entry.name[i] = c;
            entry.name_len = raw_name.len;
        }
        if (std.mem.indexOfScalar(u16, entry.nameSlice(), ';')) |at| entry.name_len = at;
        if (entry.name_len > 0 and entry.name[entry.name_len - 1] == '.') entry.name_len -= 1;
        try o.validateName(entry.nameSlice());
        var name_copy: [255]u8 = undefined;
        @memcpy(name_copy[0..raw_name.len], raw_name);
        const raw_len = raw_name.len;
        const base_flags = raw[25] & 0x7f;
        var more = raw[25] & 0x80 != 0;
        while (more) {
            if (result.directory or result.size == 0 or result.size % it.volume.block_size != 0) return error.InvalidIsoMultiExtent;
            const part_raw = (try record(it, &b)) orelse return error.InvalidIsoMultiExtent;
            const part = try node(it.volume.input, it.volume.block_size, part_raw);
            if (part_raw[32] != raw_len or !std.mem.eql(u8, name_copy[0..raw_len], part_raw[33..][0..part_raw[32]]) or part_raw[25] & 0x7f != base_flags) return error.InvalidIsoMultiExtent;
            for (part.extents[0..part.count]) |extent| try result.append(it.volume.input, extent.offset, extent.length);
            result.size = try o.add(result.size, part.size);
            more = part_raw[25] & 0x80 != 0;
        }
        if (result.directory and result.identity == it.directory.identity) return error.DirectoryLoop;
        if (associated) {
            it.skipped.streams += 1;
            if (!it.include_unsupported) continue;
            entry.unsupported = error.UnsupportedAssociatedFile;
        }
        entry.node = result;
        return true;
    }
    return false;
}
