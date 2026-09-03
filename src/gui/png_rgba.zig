const std = @import("std");
const flate = std.compress.flate;
const image = @import("rgba_image.zig");

pub const max_compressed_bytes: usize = 1024 * 1024;
pub const max_row_bytes: usize = 8192;

pub const Scratch = struct {
    compressed: [max_compressed_bytes]u8 = undefined,
    scanline: [max_row_bytes + 1]u8 = undefined,
    previous: [max_row_bytes]u8 = undefined,
    current: [max_row_bytes]u8 = undefined,
    flate_buffer: [flate.max_window_len]u8 = undefined,
};

pub fn decodeIcon(png: []const u8, output: *image.RgbaImage, scratch: *Scratch) bool {
    if (png.len < 33 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return false;

    var width: usize = 0;
    var height: usize = 0;
    var compressed_len: usize = 0;
    var saw_header = false;
    var offset: usize = 8;

    while (offset + 12 <= png.len) {
        const chunk_len: usize = readBe32(png[offset .. offset + 4]);
        const type_start = offset + 4;
        const data_start = offset + 8;
        const data_end = data_start + chunk_len;
        const chunk_end = data_end + 4;
        if (data_end < data_start or chunk_end > png.len) return false;

        const kind = png[type_start .. type_start + 4];
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (chunk_len != 13) return false;
            width = readBe32(png[data_start .. data_start + 4]);
            height = readBe32(png[data_start + 4 .. data_start + 8]);
            const bit_depth = png[data_start + 8];
            const color_type = png[data_start + 9];
            const compression = png[data_start + 10];
            const filter = png[data_start + 11];
            const interlace = png[data_start + 12];
            if (width == 0 or height == 0 or bit_depth != 8 or color_type != 6 or compression != 0 or filter != 0 or interlace != 0) return false;
            if (width * 4 > max_row_bytes) return false;
            saw_header = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (compressed_len + chunk_len > scratch.compressed.len) return false;
            @memcpy(scratch.compressed[compressed_len .. compressed_len + chunk_len], png[data_start..data_end]);
            compressed_len += chunk_len;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
        offset = chunk_end;
    }

    if (!saw_header or compressed_len == 0) return false;
    const row_bytes = width * 4;
    @memset(scratch.previous[0..row_bytes], 0);

    var input: std.Io.Reader = .fixed(scratch.compressed[0..compressed_len]);
    var decompress: flate.Decompress = .init(&input, .zlib, &scratch.flate_buffer);

    var target_y: usize = 0;
    var source_y: usize = 0;
    while (source_y < height) : (source_y += 1) {
        const scan = scratch.scanline[0 .. row_bytes + 1];
        decompress.reader.readSliceAll(scan) catch return false;
        if (!unfilter(scan[0], scan[1..], scratch.previous[0..row_bytes], scratch.current[0..row_bytes])) return false;

        while (target_y < image.icon_height and (target_y * height) / image.icon_height == source_y) : (target_y += 1) {
            var target_x: usize = 0;
            while (target_x < image.icon_width) : (target_x += 1) {
                const source_x = (target_x * width) / image.icon_width;
                const src = source_x * 4;
                const dst = (target_y * image.icon_width + target_x) * 4;
                output.pixels[dst] = scratch.current[src];
                output.pixels[dst + 1] = scratch.current[src + 1];
                output.pixels[dst + 2] = scratch.current[src + 2];
                output.pixels[dst + 3] = scratch.current[src + 3];
            }
        }

        @memcpy(scratch.previous[0..row_bytes], scratch.current[0..row_bytes]);
    }

    return target_y == image.icon_height;
}

fn unfilter(filter: u8, raw: []const u8, previous: []const u8, current: []u8) bool {
    if (raw.len != previous.len or raw.len != current.len) return false;
    const bpp: usize = 4;
    for (raw, 0..) |value, index| {
        const left: u8 = if (index >= bpp) current[index - bpp] else 0;
        const up: u8 = previous[index];
        const upper_left: u8 = if (index >= bpp) previous[index - bpp] else 0;
        const predictor: u8 = switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, upper_left),
            else => return false,
        };
        current[index] = value +% predictor;
    }
    return true;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const ai: i16 = a;
    const bi: i16 = b;
    const ci: i16 = c;
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn readBe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

test "PNG filter none reconstructs bytes" {
    var current: [4]u8 = undefined;
    const previous = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expect(unfilter(0, &.{ 10, 20, 30, 40 }, &previous, &current));
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, &current);
}
