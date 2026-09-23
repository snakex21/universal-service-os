//! Text rendering for the boot UI: UTF-8, proportional anti-aliased glyphs
//! from the USOS font pack (font.zig), measurement, ellipsis and word wrap.
//! Without a font pack (missing/corrupt usos-font.bin) the built-in 5x7
//! bitmap font draws ASCII in upper case, and lang_file keeps English.
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const Scale = @import("scale.zig").Scale;
const font = @import("font.zig");
const font5x7 = @import("font5x7.zig");
const lang_file = @import("../i18n/lang_file.zig");

pub const Style = font.Role;
const ellipsis = "\u{2026}";

pub const Fonts = struct {
    pack: ?*const font.Pack = null,
    scale: Scale = .{},

    pub fn init(pack: ?*const font.Pack, scale: Scale) Fonts {
        var result = Fonts{ .pack = pack, .scale = scale };
        if (pack) |value| {
            if (!value.hasTier(1)) result.scale.tier = 0;
        }
        return result;
    }

    fn face(self: Fonts, style: Style) ?font.Face {
        const pack = self.pack orelse return null;
        return pack.face(style, self.scale.tier);
    }

    fn legacyScale(self: Fonts, style: Style) u32 {
        const base: u32 = switch (style) {
            .small, .body => 1,
            .strong, .heading => 2,
        };
        return base * self.scale.twice() / 2;
    }

    /// Height of one line of text including leading.
    pub fn lineHeight(self: Fonts, style: Style) u32 {
        if (self.face(style)) |f| return @as(u32, f.line_height) * self.scale.mult;
        return (7 + 5) * self.legacyScale(style);
    }

    /// Distance from the top of the line box to the baseline.
    pub fn ascent(self: Fonts, style: Style) u32 {
        if (self.face(style)) |f| return @as(u32, f.ascent) * self.scale.mult + self.leading(style);
        return 7 * self.legacyScale(style) + self.leading(style);
    }

    /// Height of capital letters, for vertical centring.
    pub fn capHeight(self: Fonts, style: Style) u32 {
        if (self.face(style)) |f| {
            if (f.glyph('H')) |g| return @as(u32, g.height) * self.scale.mult;
            return @as(u32, f.ascent) * self.scale.mult;
        }
        return 7 * self.legacyScale(style);
    }

    fn leading(self: Fonts, style: Style) u32 {
        if (self.face(style)) |f| {
            const content: u32 = @as(u32, f.ascent) + f.descent;
            return (@as(u32, f.line_height) -| content) * self.scale.mult / 2;
        }
        return (5 * self.legacyScale(style)) / 2;
    }

    /// Top y that vertically centres the capital letters of one line on
    /// `center_y`.
    pub fn centeredTop(self: Fonts, style: Style, center_y: u32) u32 {
        return (center_y + self.capHeight(style) / 2) -| self.ascent(style);
    }

    pub fn width(self: Fonts, style: Style, value: []const u8) u32 {
        var total: u32 = 0;
        var index: usize = 0;
        while (index < value.len) {
            const decoded = lang_file.decodeUtf8(value[index..]);
            index += decoded.len;
            total += self.advance(style, decoded.codepoint);
        }
        return total;
    }

    fn advance(self: Fonts, style: Style, codepoint: u21) u32 {
        if (codepoint == '\n') return 0;
        if (self.face(style)) |f| {
            const g = f.glyph(codepoint) orelse f.glyph('?') orelse return 0;
            return @as(u32, g.advance) * self.scale.mult;
        }
        return 6 * self.legacyScale(style);
    }

    /// Draws one line; `y` is the top of the line box. `background` is the
    /// colour under the text (null: read the surface). Returns the width.
    pub fn draw(self: Fonts, surface: Surface, x: u32, y: u32, style: Style, value: []const u8, color: Color, background: ?Color) u32 {
        var pen = x;
        const baseline = y + self.ascent(style);
        var index: usize = 0;
        while (index < value.len) {
            const decoded = lang_file.decodeUtf8(value[index..]);
            index += decoded.len;
            if (decoded.codepoint == '\n') continue;
            pen += self.drawGlyph(surface, pen, baseline, style, decoded.codepoint, color, background);
        }
        return pen - x;
    }

    /// Draws `value` inside `max_width`, ending with an ellipsis when it
    /// does not fit.
    pub fn drawFit(self: Fonts, surface: Surface, x: u32, y: u32, max_width: u32, style: Style, value: []const u8, color: Color, background: ?Color) u32 {
        if (self.width(style, value) <= max_width) return self.draw(surface, x, y, style, value, color, background);
        const dots = self.width(style, ellipsis);
        if (dots > max_width) return 0;
        const cut = self.fitLength(style, value, max_width - dots);
        const used = self.draw(surface, x, y, style, trimRight(value[0..cut]), color, background);
        return used + self.draw(surface, x + used, y, style, ellipsis, color, background);
    }

    pub fn drawRight(self: Fonts, surface: Surface, right: u32, y: u32, style: Style, value: []const u8, color: Color, background: ?Color) u32 {
        const w = self.width(style, value);
        _ = self.draw(surface, right -| w, y, style, value, color, background);
        return w;
    }

    pub fn drawCentered(self: Fonts, surface: Surface, center_x: u32, y: u32, style: Style, value: []const u8, color: Color, background: ?Color) void {
        const w = self.width(style, value);
        _ = self.draw(surface, center_x -| (w / 2), y, style, value, color, background);
    }

    /// Byte length of the longest prefix of value that fits max_width.
    pub fn fitLength(self: Fonts, style: Style, value: []const u8, max_width: u32) usize {
        var used: u32 = 0;
        var index: usize = 0;
        while (index < value.len) {
            const decoded = lang_file.decodeUtf8(value[index..]);
            const next = used + self.advance(style, decoded.codepoint);
            if (next > max_width) break;
            used = next;
            index += decoded.len;
        }
        return index;
    }

    /// Splits value into lines no wider than max_width, breaking at spaces
    /// and newlines (a word longer than a line is split between characters).
    /// Returns the number of lines written to `lines`; `truncated` is set
    /// when text remained.
    pub fn wrap(self: Fonts, style: Style, value: []const u8, max_width: u32, lines: [][]const u8, truncated: ?*bool) usize {
        var count: usize = 0;
        var rest = value;
        if (truncated) |flag| flag.* = false;
        while (rest.len > 0) {
            if (count == lines.len) {
                if (truncated) |flag| flag.* = true;
                break;
            }
            const newline = indexOfScalar(rest, '\n') orelse rest.len;
            const paragraph = rest[0..newline];
            var take = self.fitLength(style, paragraph, max_width);
            if (take < paragraph.len) {
                var space = take;
                while (space > 0 and paragraph[space] != ' ') space -= 1;
                if (space > 0) take = space;
                if (take == 0) take = @max(@as(usize, 1), lang_file.decodeUtf8(paragraph).len);
            }
            lines[count] = trimRight(paragraph[0..take]);
            count += 1;
            if (take == paragraph.len) {
                rest = if (newline < rest.len) rest[newline + 1 ..] else rest[rest.len..];
            } else {
                rest = rest[take..];
                while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            }
        }
        return count;
    }

    fn drawGlyph(self: Fonts, surface: Surface, pen: u32, baseline: u32, style: Style, codepoint: u21, color: Color, background: ?Color) u32 {
        const f = self.face(style) orelse return self.drawLegacyGlyph(surface, pen, baseline, style, codepoint, color);
        const g = f.glyph(codepoint) orelse f.glyph('?') orelse return 0;
        const m: u32 = self.scale.mult;
        const gx = @as(i32, @intCast(pen)) + @as(i32, g.left) * @as(i32, @intCast(m));
        const gy = @as(i32, @intCast(baseline)) - @as(i32, @intCast(@as(u32, f.ascent) * m)) + @as(i32, g.top) * @as(i32, @intCast(m));
        if (m == 1 or @import("scale.zig").legacy_bios) {
            var row: u32 = 0;
            while (row < g.height) : (row += 1) {
                var col: u32 = 0;
                while (col < g.width) : (col += 1) {
                    const c = g.coverage(col, row);
                    if (c == 0) continue;
                    plot(surface, gx + @as(i32, @intCast(col)), gy + @as(i32, @intCast(row)), color, c * 17, background);
                }
            }
        } else {
            drawScaledGlyph(surface, g, gx, gy, m, color, background);
        }
        return @as(u32, g.advance) * m;
    }

    fn drawLegacyGlyph(self: Fonts, surface: Surface, pen: u32, baseline: u32, style: Style, codepoint: u21, color: Color) u32 {
        const scale = self.legacyScale(style);
        const byte: u8 = if (codepoint < 128) @intCast(codepoint) else '?';
        const rows = font5x7.glyph(byte);
        const top = baseline -| (7 * scale);
        for (rows, 0..) |bits, row| {
            var col: u32 = 0;
            while (col < 5) : (col += 1) {
                const shift: u3 = @intCast(4 - col);
                if ((bits & (@as(u5, 1) << shift)) == 0) continue;
                surface.fillRect(pen + col * scale, top + @as(u32, @intCast(row)) * scale, scale, scale, color);
            }
        }
        return 6 * scale;
    }
};

fn plot(surface: Surface, x: i32, y: i32, color: Color, alpha: u32, background: ?Color) void {
    if (x < 0 or y < 0) return;
    surface.blendPixel(@intCast(x), @intCast(y), color, @intCast(@min(alpha, 255)), background);
}

/// Bilinear upscale of 4-bit coverage by an integer factor.
fn drawScaledGlyph(surface: Surface, g: font.Glyph, gx: i32, gy: i32, m: u32, color: Color, background: ?Color) void {
    const w: i32 = g.width;
    const h: i32 = g.height;
    const mi: i32 = @intCast(m);
    var oy: i32 = 0;
    while (oy < h * mi) : (oy += 1) {
        // Source position in 1/256 pixel: (o + 0.5) / m - 0.5.
        const v = @divFloor((2 * oy + 1) * 256, 2 * mi) - 128;
        const y0 = @divFloor(v, 256);
        const fy: u32 = @intCast(v - y0 * 256);
        var ox: i32 = 0;
        while (ox < w * mi) : (ox += 1) {
            const u = @divFloor((2 * ox + 1) * 256, 2 * mi) - 128;
            const x0 = @divFloor(u, 256);
            const fx: u32 = @intCast(u - x0 * 256);
            const c00 = sample(g, x0, y0);
            const c10 = sample(g, x0 + 1, y0);
            const c01 = sample(g, x0, y0 + 1);
            const c11 = sample(g, x0 + 1, y0 + 1);
            const top = c00 * (256 - fx) + c10 * fx;
            const bottom = c01 * (256 - fx) + c11 * fx;
            const value = (top * (256 - fy) + bottom * fy) >> 16; // 0..15
            const alpha = ((top * (256 - fy) + bottom * fy) * 17) >> 16;
            if (value == 0 and alpha == 0) continue;
            plot(surface, gx + ox, gy + oy, color, alpha, background);
        }
    }
}

fn sample(g: font.Glyph, x: i32, y: i32) u32 {
    if (x < 0 or y < 0 or x >= g.width or y >= g.height) return 0;
    return g.coverage(@intCast(x), @intCast(y));
}

fn trimRight(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == ' ') end -= 1;
    return value[0..end];
}

fn indexOfScalar(value: []const u8, byte: u8) ?usize {
    for (value, 0..) |item, index| {
        if (item == byte) return index;
    }
    return null;
}

/// The original fixed 6-pixel 5x7 renderer, kept for low-level diagnostic
/// screens (VBE probe) that must not depend on the font pack.
pub const legacy = struct {
    pub fn draw(surface: Surface, x: u32, y: u32, value: []const u8, scale: u32, color: Color) void {
        var cursor_x = x;
        var cursor_y = y;
        for (value) |byte| {
            if (byte == '\n') {
                cursor_x = x;
                cursor_y += 8 * scale;
                continue;
            }
            const rows = font5x7.glyph(byte);
            for (rows, 0..) |bits, row| {
                var col: u32 = 0;
                while (col < 5) : (col += 1) {
                    const shift: u3 = @intCast(4 - col);
                    if ((bits & (@as(u5, 1) << shift)) == 0) continue;
                    surface.fillRect(cursor_x + col * scale, cursor_y + @as(u32, @intCast(row)) * scale, scale, scale, color);
                }
            }
            cursor_x += 6 * scale;
        }
    }

    pub fn width(value: []const u8, scale: u32) u32 {
        return @intCast(value.len * 6 * scale);
    }
};

test "measurement, ellipsis and wrapping use proportional glyphs" {
    const std = @import("std");
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const fonts = Fonts.init(&pack, .{});
    try std.testing.expect(fonts.width(.body, "iiii") < fonts.width(.body, "WWWW"));
    try std.testing.expect(fonts.width(.body, "Zażółć") > 0);
    try std.testing.expect(fonts.width(.heading, "USOS") > fonts.width(.body, "USOS"));
    const text_value = "Wybierz, co chcesz uruchomić lub serwisować";
    const limit = fonts.width(.body, "Wybierz, co chcesz");
    var lines: [8][]const u8 = undefined;
    var truncated = false;
    const count = fonts.wrap(.body, text_value, limit, &lines, &truncated);
    try std.testing.expect(count >= 2 and !truncated);
    for (lines[0..count]) |line| try std.testing.expect(fonts.width(.body, line) <= limit);
    try std.testing.expectEqualStrings("Wybierz, co chcesz", lines[0]);
    const cut = fonts.fitLength(.body, "Zażółć gęślą jaźń", fonts.width(.body, "Zaż"));
    try std.testing.expectEqualStrings("Zaż", "Zażółć gęślą jaźń"[0..cut]);
    const double = Fonts.init(&pack, .{ .mult = 2 });
    try std.testing.expectEqual(2 * fonts.width(.body, "USOS"), double.width(.body, "USOS"));
}

test "text renders into a buffer at every scale and without a pack" {
    const std = @import("std");
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const pixels = try std.testing.allocator.alloc(u32, 400 * 120);
    defer std.testing.allocator.free(pixels);
    const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 400, 120, .bgrx8).?;
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };
    for ([_]?*const font.Pack{ &pack, null }) |maybe| {
        for ([_]Scale{ .{}, .{ .tier = 1 }, .{ .mult = 2 }, .{ .tier = 1, .mult = 2 } }) |scale| {
            @memset(pixels, 0);
            const fonts = Fonts.init(maybe, scale);
            const drawn = fonts.drawFit(buffer.surface, 2, 2, 390, .heading, "Ελληνικά Русский Łódź", white, black);
            try std.testing.expect(drawn > 0 and drawn <= 390);
            var lit: usize = 0;
            for (pixels) |pixel| lit += @intFromBool(pixel != 0);
            try std.testing.expect(lit > 50);
        }
    }
}
