//! Anti-aliased drawing primitives in integer arithmetic (no floating point:
//! the same code runs in the i386 Legacy BIOS Core). Coverage is sampled on a
//! 4x4 grid per pixel; shape coordinates are in 1/8 pixel units ("sub").
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;

pub const sub: i32 = 8;

/// Converts pixels to sub-pixel units.
pub fn s(value: anytype) i32 {
    return @as(i32, @intCast(value)) * sub;
}

/// Fills [x, x+w) x [y, y+h) with rounded corners of radius r, blending the
/// corner edges with `background` (or the pixels underneath when null).
pub fn roundRect(surface: Surface, x: u32, y: u32, w: u32, h: u32, r_in: u32, color: Color, background: ?Color) void {
    if (w == 0 or h == 0) return;
    const r = @min(r_in, @min(w, h) / 2);
    if (r == 0) return surface.fillRect(x, y, w, h, color);
    surface.fillRect(x + r, y, w - 2 * r, h, color);
    surface.fillRect(x, y + r, r, h - 2 * r, color);
    surface.fillRect(x + w - r, y + r, r, h - 2 * r, color);
    const radius = s(r);
    const corners = [_][2]u32{ .{ x, y }, .{ x + w - r, y }, .{ x, y + h - r }, .{ x + w - r, y + h - r } };
    for (corners, 0..) |corner, index| {
        // Circle centre relative to the corner square, in sub units.
        const cx: i32 = if (index % 2 == 0) radius else 0;
        const cy: i32 = if (index < 2) radius else 0;
        var py: u32 = 0;
        while (py < r) : (py += 1) {
            var px: u32 = 0;
            while (px < r) : (px += 1) {
                const alpha = circleCoverage(s(px) - cx, s(py) - cy, radius);
                surface.blendPixel(corner[0] + px, corner[1] + py, color, alpha, background);
            }
        }
    }
}

fn circleCoverage(px: i32, py: i32, radius: i32) u8 {
    const limit = radius * radius;
    var inside: u32 = 0;
    var j: i32 = 1;
    while (j < sub) : (j += 2) {
        var i: i32 = 1;
        while (i < sub) : (i += 2) {
            const dx = px + i;
            const dy = py + j;
            if (dx * dx + dy * dy <= limit) inside += 1;
        }
    }
    return coverageAlpha(inside);
}

fn coverageAlpha(inside: u32) u8 {
    return @intCast((inside * 255 + 8) / 16);
}

/// A card: rounded rect with a `border` ring of `thickness` and a `fill`.
pub fn card(surface: Surface, x: u32, y: u32, w: u32, h: u32, r: u32, thickness: u32, border: Color, fill: Color, background: ?Color) void {
    if (thickness == 0) return roundRect(surface, x, y, w, h, r, fill, background);
    roundRect(surface, x, y, w, h, r, border, background);
    if (w <= 2 * thickness or h <= 2 * thickness) return;
    roundRect(surface, x + thickness, y + thickness, w - 2 * thickness, h - 2 * thickness, r -| thickness, fill, border);
}

/// Generic 4x4 supersampled fill over a pixel box; `shape.inside(sx, sy)`
/// receives sub-pixel coordinates.
pub fn fillShape(surface: Surface, x0: i32, y0: i32, x1: i32, y1: i32, shape: anytype, color: Color, background: ?Color) void {
    const width: i32 = @intCast(surface.framebuffer.width);
    const height: i32 = @intCast(surface.framebuffer.height);
    var py = @max(y0, 0);
    while (py < @min(y1, height)) : (py += 1) {
        var px = @max(x0, 0);
        while (px < @min(x1, width)) : (px += 1) {
            var inside: u32 = 0;
            var j: i32 = 1;
            while (j < sub) : (j += 2) {
                var i: i32 = 1;
                while (i < sub) : (i += 2) {
                    if (shape.inside(px * sub + i, py * sub + j)) inside += 1;
                }
            }
            if (inside != 0) surface.blendPixel(@intCast(px), @intCast(py), color, coverageAlpha(inside), background);
        }
    }
}

pub const Circle = struct {
    cx: i32,
    cy: i32,
    r: i32,

    pub fn inside(self: Circle, x: i32, y: i32) bool {
        const dx = x - self.cx;
        const dy = y - self.cy;
        return dx * dx + dy * dy <= self.r * self.r;
    }
};

/// A ring (annulus) with an optional excluded wedge: points with
/// (x - cx) in [gap_x0, gap_x1] and y < gap_y are left out, which cuts the
/// top of the ring for a power symbol or a quarter for a spinner.
pub const Ring = struct {
    cx: i32,
    cy: i32,
    r_outer: i32,
    r_inner: i32,
    gap: ?Wedge = null,

    pub const Wedge = struct { min_dx: i32, max_dx: i32, max_dy: i32 };

    pub fn inside(self: Ring, x: i32, y: i32) bool {
        const dx = x - self.cx;
        const dy = y - self.cy;
        const d = dx * dx + dy * dy;
        if (d > self.r_outer * self.r_outer or d < self.r_inner * self.r_inner) return false;
        if (self.gap) |gap| {
            if (dx >= gap.min_dx and dx <= gap.max_dx and dy <= gap.max_dy) return false;
        }
        return true;
    }
};

/// A line segment with round caps (a capsule) of radius r.
pub const Capsule = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    r: i32,

    pub fn inside(self: Capsule, x: i32, y: i32) bool {
        const dx: i64 = self.x1 - self.x0;
        const dy: i64 = self.y1 - self.y0;
        const px: i64 = x - self.x0;
        const py: i64 = y - self.y0;
        const r2: i64 = @as(i64, self.r) * self.r;
        const dot = px * dx + py * dy;
        const len2 = dx * dx + dy * dy;
        if (dot <= 0 or len2 == 0) return px * px + py * py <= r2;
        if (dot >= len2) {
            const qx: i64 = x - self.x1;
            const qy: i64 = y - self.y1;
            return qx * qx + qy * qy <= r2;
        }
        // |p|^2 - dot^2/len2 <= r^2, multiplied through by len2.
        return (px * px + py * py - r2) * len2 <= dot * dot;
    }
};

pub const Box = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    pub fn inside(self: Box, x: i32, y: i32) bool {
        return x >= self.x0 and x < self.x1 and y >= self.y0 and y < self.y1;
    }
};

/// Closed polygon, even-odd rule, vertices in sub units.
pub const Polygon = struct {
    points: []const [2]i32,

    pub fn inside(self: Polygon, x: i32, y: i32) bool {
        var result = false;
        var j = self.points.len - 1;
        for (self.points, 0..) |point, i| {
            const other = self.points[j];
            if ((point[1] > y) != (other[1] > y)) {
                // x < point.x + (y - point.y) * (other.x - point.x) / (other.y - point.y)
                const num: i64 = @as(i64, y - point[1]) * (other[0] - point[0]);
                const den: i64 = other[1] - point[1];
                const lhs: i64 = @as(i64, x - point[0]) * den;
                if (if (den > 0) lhs < num else lhs > num) result = !result;
            }
            j = i;
        }
        return result;
    }
};

/// Union of shapes of one type.
pub fn Union(comptime T: type) type {
    return struct {
        items: []const T,

        pub fn inside(self: @This(), x: i32, y: i32) bool {
            for (self.items) |item| {
                if (item.inside(x, y)) return true;
            }
            return false;
        }
    };
}

pub fn circle(surface: Surface, cx: i32, cy: i32, r: i32, color: Color, background: ?Color) void {
    const shape = Circle{ .cx = cx, .cy = cy, .r = r };
    fillShape(surface, @divFloor(cx - r, sub) - 1, @divFloor(cy - r, sub) - 1, @divFloor(cx + r, sub) + 2, @divFloor(cy + r, sub) + 2, shape, color, background);
}

pub fn ring(surface: Surface, shape: Ring, color: Color, background: ?Color) void {
    const r = shape.r_outer;
    fillShape(surface, @divFloor(shape.cx - r, sub) - 1, @divFloor(shape.cy - r, sub) - 1, @divFloor(shape.cx + r, sub) + 2, @divFloor(shape.cy + r, sub) + 2, shape, color, background);
}

pub fn capsule(surface: Surface, shape: Capsule, color: Color, background: ?Color) void {
    const x0 = @min(shape.x0, shape.x1) - shape.r;
    const x1 = @max(shape.x0, shape.x1) + shape.r;
    const y0 = @min(shape.y0, shape.y1) - shape.r;
    const y1 = @max(shape.y0, shape.y1) + shape.r;
    fillShape(surface, @divFloor(x0, sub) - 1, @divFloor(y0, sub) - 1, @divFloor(x1, sub) + 2, @divFloor(y1, sub) + 2, shape, color, background);
}

pub fn polygon(surface: Surface, points: []const [2]i32, color: Color, background: ?Color) void {
    var x0: i32 = points[0][0];
    var x1: i32 = points[0][0];
    var y0: i32 = points[0][1];
    var y1: i32 = points[0][1];
    for (points) |point| {
        x0 = @min(x0, point[0]);
        x1 = @max(x1, point[0]);
        y0 = @min(y0, point[1]);
        y1 = @max(y1, point[1]);
    }
    fillShape(surface, @divFloor(x0, sub), @divFloor(y0, sub), @divFloor(x1, sub) + 1, @divFloor(y1, sub) + 1, Polygon{ .points = points }, color, background);
}

/// Vertical two-stop gradient fill (used by the header logo tile).
pub fn verticalGradient(surface: Surface, x: u32, y: u32, w: u32, h: u32, top: Color, bottom: Color) void {
    if (h == 0) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const alpha: u8 = @intCast((row * 255) / @max(h - 1, 1));
        surface.fillRect(x, y + row, w, 1, @import("surface.zig").mix(top, bottom, alpha));
    }
}

test "rounded rectangles blend only their corners" {
    const std = @import("std");
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    var pixels = [_]u32{0} ** (32 * 32);
    const buffer = ScreenBuffer.init(@intFromPtr(&pixels), pixels.len * 4, 32, 32, .bgrx8).?;
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    roundRect(buffer.surface, 4, 4, 20, 12, 6, white, black);
    try std.testing.expectEqual(@as(u32, 0), buffer.surface.getRawPixel(4, 4));
    try std.testing.expectEqual(@as(u32, 0x00ffffff), buffer.surface.getRawPixel(14, 10));
    const edge = buffer.surface.getRawPixel(5, 6) & 0xff;
    try std.testing.expect(edge > 0 and edge < 255);
}

test "capsule and polygon coverage are symmetric and bounded" {
    const std = @import("std");
    const line = Capsule{ .x0 = 0, .y0 = 0, .x1 = 80, .y1 = 0, .r = 8 };
    try std.testing.expect(line.inside(40, 7));
    try std.testing.expect(!line.inside(40, 9));
    try std.testing.expect(line.inside(-7, 0));
    const triangle = Polygon{ .points = &.{ .{ 0, 0 }, .{ 80, 0 }, .{ 0, 80 } } };
    try std.testing.expect(triangle.inside(10, 10));
    try std.testing.expect(!triangle.inside(70, 70));
}
