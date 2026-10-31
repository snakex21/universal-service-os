//! Small bounded UTF-16 WIM inventory reader. No DTDs or external entities.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const wim = @import("wim.zig");
pub const Image = struct { index: u32, files: u64 = 0, directories: u64 = 0, bytes: u64 = 0, name: [256]u16 = undefined, name_len: usize = 0 };
fn same(a: []const u16, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn number(text: []const u16) !u64 {
    if (text.len == 0) return error.CorruptWimXml;
    var value: u64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.CorruptWimXml;
        value = std.math.mul(u64, value, 10) catch return error.CorruptWimXml;
        value = std.math.add(u64, value, c - '0') catch return error.CorruptWimXml;
    }
    return value;
}
fn imageIndex(tag: []const u16) !u32 {
    const key = std.unicode.utf8ToUtf16LeStringLiteral("INDEX=\"");
    const start = std.mem.indexOf(u16, tag, key) orelse return error.CorruptWimXml;
    const tail = tag[start + key.len ..];
    const end = std.mem.indexOfScalar(u16, tail, '"') orelse return error.CorruptWimXml;
    return std.math.cast(u32, try number(tail[0..end])) orelse error.CorruptWimXml;
}
pub fn read(archive: *wim.Archive) !Image {
    if (archive.header.xml.size < 2 or archive.header.xml.size % 2 != 0 or archive.header.xml.size > 4 * 1024 * 1024) return error.CorruptWimXml;
    var resource = try wim.Resource.init(archive.allocator, archive.input, archive.header, archive.header.xml, null);
    defer resource.deinit();
    var pair: [2]u8 = undefined;
    try resource.read(0, &pair);
    if (std.mem.readInt(u16, &pair, .little) != 0xfeff) return error.UnsupportedWimXmlEncoding;
    var tag: [256]u16 = undefined;
    var tag_len: usize = 0;
    var text: [256]u16 = undefined;
    var text_len: usize = 0;
    var leaf: [32]u16 = undefined;
    var leaf_len: usize = 0;
    var in_tag = false;
    var in_image: u32 = 0;
    var selected_seen = false;
    var selected: Image = .{ .index = archive.selected };
    var offset: u64 = 2;
    while (offset < resource.descriptor.size) : (offset += 2) {
        try resource.read(offset, &pair);
        const c = std.mem.readInt(u16, &pair, .little);
        if (c == '<') {
            if (in_tag) return error.CorruptWimXml;
            in_tag = true;
            tag_len = 0;
        } else if (c == '>') {
            if (!in_tag or tag_len == 0) return error.CorruptWimXml;
            in_tag = false;
            const token = tag[0..tag_len];
            if (token[0] == '!') return error.UnsupportedWimXmlDeclaration;
            if (token[0] == '?') {
                text_len = 0;
                continue;
            }
            if (token[0] == '/') {
                if (in_image == archive.selected) {
                    if (same(token[1..], "NAME")) {
                        selected.name_len = text_len;
                        @memcpy(selected.name[0..text_len], text[0..text_len]);
                    }
                    if (same(token[1..], "FILECOUNT")) selected.files = try number(text[0..text_len]);
                    if (same(token[1..], "DIRCOUNT")) selected.directories = try number(text[0..text_len]);
                    if (same(token[1..], "TOTALBYTES")) selected.bytes = try number(text[0..text_len]);
                }
                if (same(token[1..], "IMAGE")) in_image = 0;
                leaf_len = 0;
            } else if (token.len > 6 and token[5] == ' ' and same(token[0..5], "IMAGE")) {
                if (in_image != 0) return error.CorruptWimXml;
                in_image = try imageIndex(token);
                if (in_image == 0 or in_image > archive.header.images) return error.CorruptWimXml;
                if (in_image == archive.selected) {
                    if (selected_seen) return error.CorruptWimXml;
                    selected_seen = true;
                }
            } else {
                leaf_len = @min(leaf.len, token.len);
                @memcpy(leaf[0..leaf_len], token[0..leaf_len]);
            }
            text_len = 0;
        } else if (in_tag) {
            if (tag_len == tag.len) return error.UnsupportedWimXmlTag;
            tag[tag_len] = c;
            tag_len += 1;
        } else if (in_image == archive.selected and (same(leaf[0..leaf_len], "NAME") or same(leaf[0..leaf_len], "FILECOUNT") or same(leaf[0..leaf_len], "DIRCOUNT") or same(leaf[0..leaf_len], "TOTALBYTES"))) {
            if (text_len == text.len or c == '&') return error.UnsupportedWimXmlText;
            text[text_len] = c;
            text_len += 1;
        }
    }
    if (in_tag or in_image != 0 or !selected_seen) return error.CorruptWimXml;
    return selected;
}
fn testRead(comptime text: []const u8, selected: u32) !Image {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(text);
    var bytes: [208 + 2 + wide.len * 2]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[208..210], 0xfeff, .little);
    for (wide, 0..) |c, i| std.mem.writeInt(u16, bytes[210 + i * 2 ..][0..2], c, .little);
    const Memory = struct {
        bytes: []const u8,
        fn read(ctx: *anyopaque, at: u64, out: []u8) @import("platform.zig").Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
            @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
        }
    };
    var memory: Memory = .{ .bytes = &bytes };
    const input: wim.Input = .{ .context = &memory, .size = bytes.len, .read_fn = Memory.read };
    const zero: wim.Descriptor = .{ .offset = 0, .stored = 0, .size = 0, .flags = 0 };
    const header: wim.Header = .{ .version = 0x10d00, .flags = 0, .compression = null, .chunk_size = 0, .images = 2, .lookup = zero, .integrity = zero, .xml = .{ .offset = 208, .stored = bytes.len - 208, .size = bytes.len - 208, .flags = 2 } };
    var archive: wim.Archive = .{ .input = input, .allocator = std.testing.allocator, .header = header, .table = try wim.Resource.init(std.testing.allocator, input, header, zero, null), .index = &.{}, .selected = selected, .resource_count = 0 };
    defer archive.deinit();
    return read(&archive);
}
test "bounded XML selects explicit image counts/name without external entities" {
    const image = try testRead("<?xml version=\"1.0\"?><WIM><IMAGE INDEX=\"1\"><NAME>Other</NAME></IMAGE><IMAGE INDEX=\"2\"><DIRCOUNT>3</DIRCOUNT><FILECOUNT>12</FILECOUNT><TOTALBYTES>44</TOTALBYTES><WINDOWS><IMAGESTATE>STATE</IMAGESTATE></WINDOWS><NAME>Home</NAME></IMAGE></WIM>", 2);
    try std.testing.expectEqual(@as(u64, 12), image.files);
    try std.testing.expectEqual(@as(u64, 3), image.directories);
    try std.testing.expectEqual(@as(u64, 44), image.bytes);
    try std.testing.expectEqualSlices(u16, &.{ 'H', 'o', 'm', 'e' }, image.name[0..image.name_len]);
    try std.testing.expectError(error.UnsupportedWimXmlDeclaration, testRead("<!DOCTYPE WIM><WIM></WIM>", 1));
    try std.testing.expectError(error.UnsupportedWimXmlText, testRead("<WIM><IMAGE INDEX=\"1\"><NAME>&external;</NAME></IMAGE></WIM>", 1));
    try std.testing.expectError(error.CorruptWimXml, testRead("<WIM><IMAGE INDEX=\"1\"><NAME>Only</NAME></IMAGE></WIM>", 2));
}
