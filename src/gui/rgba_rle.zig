//! Decode build-owned RGBA pixel runs into a caller-owned row buffer.
const std = @import("std");
pub const Error = error{InvalidRgbaRle};

pub fn decode(input: []const u8, output: []u8) Error![]const u8 {
    if (output.len % 4 != 0) return error.InvalidRgbaRle;
    var source: usize = 0;
    var target: usize = 0;
    while (source < input.len) {
        const control = input[source];
        source += 1;
        // Opaque RGB literals omit a redundant alpha byte without changing pixels.
        if (control == 0x7f) {
            if (source == input.len) return error.InvalidRgbaRle;
            if (input[source] & 0x80 != 0) {
                const bytes = (@as(usize, input[source] & 0x7f) + 3) * 4;
                source += 1;
                if (input.len - source < 2 or bytes > output.len - target) return error.InvalidRgbaRle;
                const distance = (@as(usize, input[source]) | (@as(usize, input[source + 1]) << 8)) * 4;
                source += 2;
                if (distance == 0 or distance > target) return error.InvalidRgbaRle;
                for (0..bytes) |_| {
                    output[target] = output[target - distance];
                    target += 1;
                }
                continue;
            }
            const count = @as(usize, input[source]) + 1;
            source += 1;
            if (count > 128 or count * 4 > output.len - target or count * 3 > input.len - source) return error.InvalidRgbaRle;
            for (0..count) |_| {
                @memcpy(output[target..][0..3], input[source..][0..3]);
                output[target + 3] = 255;
                source += 3;
                target += 4;
            }
            continue;
        }
        const size = (@as(usize, control & 0x7f) + 1) * 4;
        const encoded = if (control & 0x80 != 0) 4 else size;
        if (size > output.len - target or encoded > input.len - source) return error.InvalidRgbaRle;
        if (control & 0x80 != 0) {
            var pixel: usize = 0;
            while (pixel < size) : (pixel += 4) @memcpy(output[target + pixel ..][0..4], input[source..][0..4]);
        } else @memcpy(output[target..][0..size], input[source..][0..size]);
        source += encoded;
        target += size;
    }
    if (target != output.len) return error.InvalidRgbaRle;
    return output;
}

test "RGBA RLE preserves literal pixels, repeated colors and alpha" {
    var out: [20]u8 = undefined;
    const encoded = [_]u8{ 1, 1, 2, 3, 0, 4, 5, 6, 255, 0x82, 7, 8, 9, 42 };
    const expected = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 255, 7, 8, 9, 42, 7, 8, 9, 42, 7, 8, 9, 42 };
    try std.testing.expectEqualSlices(u8, &expected, try decode(&encoded, &out));
}

test "RGBA RLE rejects truncation, output overflow and incomplete output" {
    var out: [4]u8 = undefined;
    for ([_][]const u8{ &.{}, &.{0}, &.{ 0, 1, 2, 3 }, &.{ 0x81, 1, 2, 3, 4 }, &.{ 0, 1, 2, 3, 4, 0 }, &.{0x7f}, &.{ 0x7f, 0, 1, 2 }, &.{ 0x7f, 128 } }) |encoded|
        try std.testing.expectError(error.InvalidRgbaRle, decode(encoded, &out));
    try std.testing.expectError(error.InvalidRgbaRle, decode(&.{ 0, 1, 2, 3, 4 }, out[0..3]));
}

test "opaque RGB literals restore full alpha and mix with RGBA runs" {
    var output: [12]u8 = undefined;
    const encoded = [_]u8{ 0x7f, 1, 1, 2, 3, 4, 5, 6, 0x80, 7, 8, 9, 42 };
    const expected = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 42 };
    try std.testing.expectEqualSlices(u8, &expected, try decode(&encoded, &output));
}

test "pixel backreferences overlap safely and reject invalid distances" {
    var output: [16]u8 = undefined;
    const encoded = [_]u8{ 0, 1, 2, 3, 4, 0x7f, 0x80, 1, 0 };
    const expected = [_]u8{ 1, 2, 3, 4 } ** 4;
    try std.testing.expectEqualSlices(u8, &expected, try decode(&encoded, &output));
    for ([_][]const u8{ &.{ 0x7f, 0x80, 1, 0 }, &.{ 0x7f, 0x80, 0, 0 }, &.{ 0x7f, 0x80, 1 } }) |invalid|
        try std.testing.expectError(error.InvalidRgbaRle, decode(invalid, &output));
}
