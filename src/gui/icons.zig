//! Vector icons drawn in code on a 24x24 design grid (like Segoe MDL2 /
//! Material symbols), anti-aliased by paint.fillShape and scaled to any
//! size. Each icon is a union of shapes minus optional cut-outs, evaluated
//! in one pass so overlapping parts blend correctly.
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const paint = @import("paint.zig");

pub const Kind = enum {
    windows,
    terminal,
    flask,
    floppy,
    gear,
    power,
    globe,
    chevron_right,
    chevron_left,
    check,
    close,
    info,
    warning,
    pending,
    spinner,
    check_circle,
    error_circle,
    drive,
    disc,
    restart,
    shutdown,
    firmware,
    chip,
    shield,
};

/// Grid units: 1/64 of a design-grid cell; 24 cells span the icon.
const unit: i32 = 64;

const Shape = struct {
    kind: enum { capsule, circle, ring, box, polygon, ellipse_ring },
    cut: bool = false,
    v: [6]i32 = .{ 0, 0, 0, 0, 0, 0 },
    points: []const [2]i32 = &.{},
    /// For ring: exclude dx in [gap0, gap1] with dy <= gap2 (grid units).
    gap: ?[3]i32 = null,
};

fn g(value: comptime_float) i32 {
    return @intFromFloat(value * @as(comptime_float, unit));
}

fn line(x0: comptime_float, y0: comptime_float, x1: comptime_float, y1: comptime_float, width: comptime_float) Shape {
    return .{ .kind = .capsule, .v = .{ g(x0), g(y0), g(x1), g(y1), g(width / 2.0), 0 } };
}

fn cutLine(x0: comptime_float, y0: comptime_float, x1: comptime_float, y1: comptime_float, width: comptime_float) Shape {
    var result = line(x0, y0, x1, y1, width);
    result.cut = true;
    return result;
}

fn dot(cx: comptime_float, cy: comptime_float, r: comptime_float) Shape {
    return .{ .kind = .circle, .v = .{ g(cx), g(cy), g(r), 0, 0, 0 } };
}

fn cutDot(cx: comptime_float, cy: comptime_float, r: comptime_float) Shape {
    var result = dot(cx, cy, r);
    result.cut = true;
    return result;
}

fn ringShape(cx: comptime_float, cy: comptime_float, r: comptime_float, width: comptime_float) Shape {
    return .{ .kind = .ring, .v = .{ g(cx), g(cy), g(r + width / 2.0), g(r - width / 2.0), 0, 0 } };
}

fn rect(x0: comptime_float, y0: comptime_float, x1: comptime_float, y1: comptime_float) Shape {
    return .{ .kind = .box, .v = .{ g(x0), g(y0), g(x1), g(y1), 0, 0 } };
}

fn cutRect(x0: comptime_float, y0: comptime_float, x1: comptime_float, y1: comptime_float) Shape {
    var result = rect(x0, y0, x1, y1);
    result.cut = true;
    return result;
}

fn poly(comptime points: []const [2]comptime_float) Shape {
    comptime var converted: [points.len][2]i32 = undefined;
    inline for (points, 0..) |point, index| converted[index] = .{ g(point[0]), g(point[1]) };
    const final = converted;
    return .{ .kind = .polygon, .points = &final };
}

fn cutPoly(comptime points: []const [2]comptime_float) Shape {
    var result = poly(points);
    result.cut = true;
    return result;
}

/// Outline of a closed polyline as capsules.
fn outline(comptime points: []const [2]comptime_float, width: comptime_float) [points.len]Shape {
    var result: [points.len]Shape = undefined;
    for (points, 0..) |point, index| {
        const next = points[(index + 1) % points.len];
        result[index] = line(point[0], point[1], next[0], next[1], width);
    }
    return result;
}

fn gearTeeth() [8]Shape {
    const std = @import("std");
    var result: [8]Shape = undefined;
    for (0..8) |index| {
        const angle = @as(comptime_float, @floatFromInt(index)) * std.math.pi / 4.0;
        const c = @cos(angle);
        const s_ = @sin(angle);
        const inner = 6.0;
        const outer = 10.4;
        const half = 1.8;
        const corners = [4][2]comptime_float{
            .{ 12.0 + c * inner - s_ * half, 12.0 + s_ * inner + c * half },
            .{ 12.0 + c * outer - s_ * half, 12.0 + s_ * outer + c * half },
            .{ 12.0 + c * outer + s_ * half, 12.0 + s_ * outer - c * half },
            .{ 12.0 + c * inner + s_ * half, 12.0 + s_ * inner - c * half },
        };
        result[index] = poly(&corners);
    }
    return result;
}

fn shapes(comptime kind: Kind) []const Shape {
    const list: []const Shape = comptime switch (kind) {
        .windows => &.{ rect(3, 3, 11.2, 11.2), rect(12.8, 3, 21, 11.2), rect(3, 12.8, 11.2, 21), rect(12.8, 12.8, 21, 21) },
        .terminal => &(outline(&.{ .{ 3, 5 }, .{ 21, 5 }, .{ 21, 19 }, .{ 3, 19 } }, 1.8) ++ [_]Shape{
            line(7, 9.5, 10, 12, 1.8), line(10, 12, 7, 14.5, 1.8), line(12, 15, 17, 15, 1.8),
        }),
        .flask => &(outline(&.{ .{ 10, 4 }, .{ 10, 9.5 }, .{ 4.6, 19 }, .{ 5.8, 20.6 }, .{ 18.2, 20.6 }, .{ 19.4, 19 }, .{ 14, 9.5 }, .{ 14, 4 } }, 1.7) ++ [_]Shape{
            line(8.5, 3.6, 15.5, 3.6, 1.7),
            poly(&.{ .{ 7.2, 15 }, .{ 16.8, 15 }, .{ 19.4, 19 }, .{ 18.2, 20.6 }, .{ 5.8, 20.6 }, .{ 4.6, 19 } }),
        }),
        .floppy => &(outline(&.{ .{ 3.5, 3.5 }, .{ 17, 3.5 }, .{ 20.5, 7 }, .{ 20.5, 20.5 }, .{ 3.5, 20.5 } }, 1.7) ++ [_]Shape{
            line(7.5, 3.5, 7.5, 8.5, 1.7), line(7.5, 8.5, 15, 8.5, 1.7), line(15, 8.5, 15, 3.5, 1.7),
            line(7, 13, 17, 13, 1.7), line(7, 13, 7, 20.5, 1.7), line(17, 13, 17, 20.5, 1.7),
        }),
        .gear => &(gearTeeth() ++ [_]Shape{ ringShape(12, 12, 5.4, 3.4) }),
        .power => &.{
            .{ .kind = .ring, .v = .{ g(12), g(13), g(8.8), g(7.0), 0, 0 }, .gap = .{ g(-4.2), g(4.2), g(-2) } },
            line(12, 3, 12, 11.5, 1.8),
        },
        .globe => &.{
            ringShape(12, 12, 8.6, 1.6),
            .{ .kind = .ellipse_ring, .v = .{ g(12), g(12), g(4.2), g(9.4), g(1.6), 0 } },
            line(3.8, 12, 20.2, 12, 1.5),
            line(5.5, 7.6, 18.5, 7.6, 1.3),
            line(5.5, 16.4, 18.5, 16.4, 1.3),
        },
        .chevron_right => &.{ line(9, 5.5, 15.5, 12, 2.0), line(15.5, 12, 9, 18.5, 2.0) },
        .chevron_left => &.{ line(15, 5.5, 8.5, 12, 2.0), line(8.5, 12, 15, 18.5, 2.0) },
        .check => &.{ line(5.5, 12.5, 9.8, 16.8, 2.2), line(9.8, 16.8, 18.5, 7.5, 2.2) },
        .close => &.{ line(6.5, 6.5, 17.5, 17.5, 2.0), line(17.5, 6.5, 6.5, 17.5, 2.0) },
        .info => &.{ ringShape(12, 12, 9, 1.8), dot(12, 7.8, 1.25), line(12, 11, 12, 16.8, 2.0) },
        .warning => &(outline(&.{ .{ 12, 3.2 }, .{ 21.2, 19.8 }, .{ 2.8, 19.8 } }, 1.8) ++ [_]Shape{ line(12, 9, 12, 14, 2.0), dot(12, 17, 1.2) }),
        .pending => &.{ringShape(12, 12, 8.6, 1.6)},
        .spinner => &.{
            .{ .kind = .ring, .v = .{ g(12), g(12), g(9.6), g(7.4), 0, 0 }, .gap = .{ 0, g(12), 0 } },
        },
        .check_circle => &.{ dot(12, 12, 10), cutLine(7, 12.4, 10.6, 16, 2.2), cutLine(10.6, 16, 17.4, 8.6, 2.2) },
        .error_circle => &.{ dot(12, 12, 10), cutLine(8.4, 8.4, 15.6, 15.6, 2.0), cutLine(15.6, 8.4, 8.4, 15.6, 2.0) },
        .drive => &(outline(&.{ .{ 3, 8 }, .{ 21, 8 }, .{ 21, 17 }, .{ 3, 17 } }, 1.7) ++ [_]Shape{ dot(17, 12.5, 1.3), line(6.5, 12.5, 12, 12.5, 1.5) }),
        .disc => &.{ ringShape(12, 12, 8.7, 1.6), ringShape(12, 12, 2.6, 1.6) },
        .restart => &.{
            .{ .kind = .ring, .v = .{ g(12), g(12.5), g(8.6), g(6.8), 0, 0 }, .gap = .{ 0, g(12), g(-1) } },
            poly(&.{ .{ 11, 1.2 }, .{ 17.2, 3.9 }, .{ 11.6, 8.2 } }),
        },
        .shutdown => &.{
            .{ .kind = .ring, .v = .{ g(12), g(13), g(8.8), g(7.0), 0, 0 }, .gap = .{ g(-4.2), g(4.2), g(-2) } },
            line(12, 3, 12, 11.5, 1.8),
        },
        .firmware => &(outline(&.{ .{ 6, 6 }, .{ 18, 6 }, .{ 18, 18 }, .{ 6, 18 } }, 1.7) ++ [_]Shape{
            rect(9.5, 9.5, 14.5, 14.5),
            line(9, 2.5, 9, 6, 1.4), line(15, 2.5, 15, 6, 1.4), line(9, 18, 9, 21.5, 1.4), line(15, 18, 15, 21.5, 1.4),
            line(2.5, 9, 6, 9, 1.4), line(2.5, 15, 6, 15, 1.4), line(18, 9, 21.5, 9, 1.4), line(18, 15, 21.5, 15, 1.4),
        }),
        .chip => &(outline(&.{ .{ 4, 6 }, .{ 20, 6 }, .{ 20, 18 }, .{ 4, 18 } }, 1.7) ++ [_]Shape{ line(8, 10, 16, 10, 1.5), line(8, 14, 13, 14, 1.5) }),
        // Shield with a check mark (Secure Boot).
        .shield => &(outline(&.{ .{ 12, 2.5 }, .{ 19.5, 5.5 }, .{ 19.5, 11 }, .{ 17, 16.8 }, .{ 12, 21.2 }, .{ 7, 16.8 }, .{ 4.5, 11 }, .{ 4.5, 5.5 } }, 1.7) ++ [_]Shape{ line(8.6, 12, 11.2, 14.6, 1.8), line(11.2, 14.6, 15.8, 9.4, 1.8) }),
    };
    return list;
}

const Placed = struct {
    list: []const Shape,
    x: i32,
    y: i32,
    size: i32,

    fn map(self: Placed, value: i32) i32 {
        return @divTrunc(value * self.size, 24 * unit / paint.sub);
    }

    fn inShape(self: Placed, shape: Shape, px: i32, py: i32) bool {
        const lx = px - self.x;
        const ly = py - self.y;
        return switch (shape.kind) {
            .capsule => (paint.Capsule{ .x0 = self.map(shape.v[0]), .y0 = self.map(shape.v[1]), .x1 = self.map(shape.v[2]), .y1 = self.map(shape.v[3]), .r = self.map(shape.v[4]) }).inside(lx, ly),
            .circle => (paint.Circle{ .cx = self.map(shape.v[0]), .cy = self.map(shape.v[1]), .r = self.map(shape.v[2]) }).inside(lx, ly),
            .ring => (paint.Ring{
                .cx = self.map(shape.v[0]),
                .cy = self.map(shape.v[1]),
                .r_outer = self.map(shape.v[2]),
                .r_inner = self.map(shape.v[3]),
                .gap = if (shape.gap) |gap| .{ .min_dx = self.map(gap[0]), .max_dx = self.map(gap[1]), .max_dy = self.map(gap[2]) } else null,
            }).inside(lx, ly),
            .box => lx >= self.map(shape.v[0]) and lx < self.map(shape.v[2]) and ly >= self.map(shape.v[1]) and ly < self.map(shape.v[3]),
            .polygon => polygonInside(self, shape.points, lx, ly),
            .ellipse_ring => ellipseRing(self, shape, lx, ly),
        };
    }

    pub fn inside(self: Placed, px: i32, py: i32) bool {
        var hit = false;
        for (self.list) |shape| {
            if (shape.cut) continue;
            if (self.inShape(shape, px, py)) {
                hit = true;
                break;
            }
        }
        if (!hit) return false;
        for (self.list) |shape| {
            if (shape.cut and self.inShape(shape, px, py)) return false;
        }
        return true;
    }
};

fn polygonInside(self: Placed, points: []const [2]i32, x: i32, y: i32) bool {
    var result = false;
    var j = points.len - 1;
    for (points, 0..) |point, i| {
        const ax = self.map(point[0]);
        const ay = self.map(point[1]);
        const bx = self.map(points[j][0]);
        const by = self.map(points[j][1]);
        if ((ay > y) != (by > y)) {
            const num: i64 = @as(i64, y - ay) * (bx - ax);
            const den: i64 = by - ay;
            const lhs: i64 = @as(i64, x - ax) * den;
            if (if (den > 0) lhs < num else lhs > num) result = !result;
        }
        j = i;
    }
    return result;
}

fn ellipseRing(self: Placed, shape: Shape, x: i32, y: i32) bool {
    const dx: i64 = x - self.map(shape.v[0]);
    const dy: i64 = y - self.map(shape.v[1]);
    const half = @divTrunc(self.map(shape.v[4]), 2);
    const a_out: i64 = self.map(shape.v[2]) + half;
    const b_out: i64 = self.map(shape.v[3]) + half;
    const a_in: i64 = @max(self.map(shape.v[2]) - half, 1);
    const b_in: i64 = @max(self.map(shape.v[3]) - half, 1);
    const outer = dx * dx * b_out * b_out + dy * dy * a_out * a_out <= a_out * a_out * b_out * b_out;
    const inner = dx * dx * b_in * b_in + dy * dy * a_in * a_in < a_in * a_in * b_in * b_in;
    return outer and !inner;
}

/// Draws `kind` in a size x size pixel box at (x, y).
pub fn draw(surface: Surface, comptime kind: Kind, x: u32, y: u32, size: u32, color: Color, background: ?Color) void {
    drawList(surface, shapes(kind), x, y, size, color, background);
}

/// Runtime-selected variant of `draw`.
pub fn drawKind(surface: Surface, kind: Kind, x: u32, y: u32, size: u32, color: Color, background: ?Color) void {
    switch (kind) {
        inline else => |value| draw(surface, value, x, y, size, color, background),
    }
}

fn drawList(surface: Surface, list: []const Shape, x: u32, y: u32, size: u32, color: Color, background: ?Color) void {
    if (size == 0) return;
    const placed = Placed{ .list = list, .x = paint.s(x), .y = paint.s(y), .size = @intCast(size) };
    const x0: i32 = @intCast(x);
    const y0: i32 = @intCast(y);
    const extent: i32 = @intCast(size);
    paint.fillShape(surface, x0, y0, x0 + extent, y0 + extent, placed, color, background);
}

test "every icon draws inside its box at several sizes" {
    const std = @import("std");
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    var pixels = [_]u32{0} ** (72 * 72);
    const buffer = ScreenBuffer.init(@intFromPtr(&pixels), pixels.len * 4, 72, 72, .bgrx8).?;
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    inline for (@typeInfo(Kind).@"enum".fields) |field| {
        for ([_]u32{ 16, 24, 48 }) |size| {
            @memset(&pixels, 0);
            draw(buffer.surface, @field(Kind, field.name), 12, 12, size, white, null);
            var lit: usize = 0;
            for (pixels, 0..) |pixel, index| {
                if (pixel == 0) continue;
                lit += 1;
                const px = index % 72;
                const py = index / 72;
                try std.testing.expect(px >= 12 and px < 12 + size and py >= 12 and py < 12 + size);
            }
            try std.testing.expect(lit > size);
        }
    }
}
