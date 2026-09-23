//! Mouse pointer drawn in code: the classic arrow with a dark outline, a
//! white body and a soft shadow, rasterized with anti-aliasing at the UI
//! scale into a small ARGB sprite once, then blended over a saved patch.
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const paint = @import("paint.zig");
const mix = @import("surface.zig").mix;

/// Sprite size limit: 3x of the 12x19 design (plus shadow).
pub const max_width: u32 = 44;
pub const max_height: u32 = 64;
pub const max_pixels = max_width * max_height;

// Arrow outline on a 12x19 grid with the hot spot at (0, 0).
const outer = [_][2]i32{ .{ 0, 0 }, .{ 0, 170 }, .{ 38, 132 }, .{ 62, 186 }, .{ 88, 174 }, .{ 64, 122 }, .{ 118, 122 } };
// The white body, inset by about one design pixel.
const inner = [_][2]i32{ .{ 10, 26 }, .{ 10, 146 }, .{ 40, 116 }, .{ 66, 172 }, .{ 76, 167 }, .{ 50, 111 }, .{ 94, 111 } };
const grid_scale: i32 = 10; // grid values are tenths of a design pixel

pub const Sprite = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Premultiplied: colour and alpha per pixel.
    color: [max_pixels]Color = undefined,
    alpha: [max_pixels]u8 = undefined,

    /// Rasterizes the arrow for `scale_twice` (2 = 1x, 3 = 1.5x, 4 = 2x...).
    pub fn build(self: *Sprite, scale_twice: u32) void {
        const factor: i32 = @intCast(@min(scale_twice, 6));
        self.width = @min(max_width, @as(u32, @intCast(@divTrunc(13 * factor, 2) + 2)));
        self.height = @min(max_height, @as(u32, @intCast(@divTrunc(20 * factor, 2) + 2)));
        var outer_points: [outer.len][2]i32 = undefined;
        var inner_points: [inner.len][2]i32 = undefined;
        var shadow_points: [outer.len][2]i32 = undefined;
        for (outer, 0..) |point, index| {
            outer_points[index] = .{ convert(point[0], factor), convert(point[1], factor) };
            shadow_points[index] = .{ outer_points[index][0] + @divTrunc(paint.sub * factor, 2), outer_points[index][1] + @divTrunc(paint.sub * factor, 2) };
        }
        for (inner, 0..) |point, index| inner_points[index] = .{ convert(point[0], factor), convert(point[1], factor) };
        const shadow = paint.Polygon{ .points = &shadow_points };
        const body = paint.Polygon{ .points = &outer_points };
        const fill = paint.Polygon{ .points = &inner_points };
        const black = Color{ .r = 0x05, .g = 0x0a, .b = 0x10 };
        const white = Color{ .r = 0xff, .g = 0xff, .b = 0xff };
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const index = y * max_width + x;
                const a_body = coverage(body, x, y);
                const a_fill = coverage(fill, x, y);
                const a_shadow = coverage(shadow, x, y) / 3;
                // Composite: shadow, then outline, then white body.
                var color = black;
                var alpha: u32 = a_shadow;
                if (a_body > 0) {
                    alpha = a_body + (alpha * (255 - a_body)) / 255;
                    color = black;
                }
                if (a_fill > 0) color = mix(black, white, @intCast(a_fill));
                self.color[index] = color;
                self.alpha[index] = @intCast(@min(alpha, 255));
            }
        }
    }

    /// Blends the sprite at (x, y) using `under`, the saved raw pixels of the
    /// patch (row stride max_width), as the background.
    pub fn draw(self: *const Sprite, surface: Surface, x: u32, y: u32, under: []const u32) void {
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            if (y + row >= surface.framebuffer.height) break;
            var col: u32 = 0;
            while (col < self.width) : (col += 1) {
                if (x + col >= surface.framebuffer.width) break;
                const index = row * max_width + col;
                const alpha = self.alpha[index];
                if (alpha == 0) continue;
                const background = surface.unpackColor(under[index]);
                surface.setPixel(x + col, y + row, mix(background, self.color[index], alpha));
            }
        }
    }
};

fn convert(value: i32, factor: i32) i32 {
    // tenths of a design pixel -> sub-pixels at factor/2 scale
    return @divTrunc(value * paint.sub * factor, grid_scale * 2);
}

fn coverage(shape: paint.Polygon, x: u32, y: u32) u32 {
    var inside: u32 = 0;
    var j: i32 = 1;
    while (j < paint.sub) : (j += 2) {
        var i: i32 = 1;
        while (i < paint.sub) : (i += 2) {
            if (shape.inside(@as(i32, @intCast(x)) * paint.sub + i, @as(i32, @intCast(y)) * paint.sub + j)) inside += 1;
        }
    }
    return (inside * 255 + 8) / 16;
}

/// Saves the pixels under the pointer so it can be erased exactly.
pub const Patch = struct {
    pixels: [max_pixels]u32 = undefined,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    saved: bool = false,

    pub fn save(self: *Patch, surface: Surface, x: u32, y: u32, width: u32, height: u32) void {
        self.x = x;
        self.y = y;
        self.width = @min(width, surface.framebuffer.width -| x);
        self.height = @min(height, surface.framebuffer.height -| y);
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            var col: u32 = 0;
            while (col < self.width) : (col += 1) self.pixels[row * max_width + col] = surface.getRawPixel(x + col, y + row);
        }
        self.saved = true;
    }

    pub fn restore(self: *Patch, surface: Surface) void {
        if (!self.saved) return;
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            var col: u32 = 0;
            while (col < self.width) : (col += 1) surface.setRawPixel(self.x + col, self.y + row, self.pixels[row * max_width + col]);
        }
        self.saved = false;
    }
};

test "pointer sprite has an outlined white body at every scale" {
    const std = @import("std");
    var sprite = Sprite{};
    for ([_]u32{ 2, 3, 4, 6 }) |scale| {
        sprite.build(scale);
        try std.testing.expect(sprite.width <= max_width and sprite.height <= max_height);
        // The hot spot corner is opaque dark outline.
        try std.testing.expect(sprite.alpha[(3 * scale) * max_width] > 200 and sprite.color[(3 * scale) * max_width].r < 40);
        // Somewhere inside the body is white.
        const inside = (sprite.height / 2) * max_width + sprite.width / 6;
        try std.testing.expect(sprite.alpha[inside] == 255 and sprite.color[inside].r > 200);
    }
}
