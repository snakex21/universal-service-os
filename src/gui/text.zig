const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const font = @import("font5x7.zig");

pub fn draw(surface: Surface, x: u32, y: u32, text: []const u8, scale: u32, color: Color) void {
    var cursor_x = x;
    var cursor_y = y;

    for (text) |byte| {
        if (byte == '\n') {
            cursor_x = x;
            cursor_y += 8 * scale;
            continue;
        }
        drawGlyph(surface, cursor_x, cursor_y, byte, scale, color);
        cursor_x += 6 * scale;
    }
}

pub fn width(text: []const u8, scale: u32) u32 {
    return @intCast(text.len * 6 * scale);
}

fn drawGlyph(surface: Surface, x: u32, y: u32, byte: u8, scale: u32, color: Color) void {
    const rows = font.glyph(byte);
    for (rows, 0..) |bits, row| {
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const shift: u3 = @intCast(4 - col);
            if ((bits & (@as(u5, 1) << shift)) == 0) continue;
            surface.fillRect(
                x + @as(u32, @intCast(col)) * scale,
                y + @as(u32, @intCast(row)) * scale,
                scale,
                scale,
                color,
            );
        }
    }
}
