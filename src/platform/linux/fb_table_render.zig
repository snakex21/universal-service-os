const usos = @import("usos");
const model = @import("fb_menu_table.zig");
const Surface = usos.gui.Surface;
const Theme = usos.gui.Theme;
const text = usos.gui.text;
pub const row_height: u32 = 22;

pub fn clipped(surface: Surface, x: u32, y: u32, width: u32, value: []const u8, color: usos.gui.Color) void {
    const limit: usize = width / 6;
    if (value.len <= limit) {
        text.draw(surface, x, y, value, 1, color);
    } else if (limit > 3) {
        text.draw(surface, x, y, value[0 .. limit - 3], 1, color);
        text.draw(surface, x + @as(u32, @intCast(limit - 3)) * 6, y, "...", 1, color);
    }
}

pub fn render(surface: Surface, table: model.Table, x: u32, top: u32, width: u32, first: usize, visible: usize) void {
    const theme = Theme{};
    drawRow(surface, table, table.headers, x, top, width, theme.selected, theme.text);
    for (table.rows[first..@min(table.count, first + visible)], 0..) |row, i| {
        const y = top + @as(u32, @intCast(i + 1)) * row_height;
        const color: usos.gui.Color = switch (row.tone) {
            .normal => theme.text,
            .warning => .{ .r = 255, .g = 202, .b = 94 },
            .failure => .{ .r = 255, .g = 116, .b = 116 },
        };
        drawRow(surface, table, row.cells, x, y, width, if (i % 2 == 0) theme.panel else theme.panel_alt, color);
    }
}

fn drawRow(surface: Surface, table: model.Table, cells: model.Cells, x: u32, y: u32, width: u32, background: usos.gui.Color, foreground: usos.gui.Color) void {
    surface.fillRect(x, y, width, row_height, background);
    var left = x;
    for (0..table.columns) |column| {
        const w = if (column + 1 == table.columns) x + width - left else width * table.weight(column) / 100;
        clipped(surface, left + 4, y + 7, w -| 8, cells[column], foreground);
        surface.fillRect(left, y, 1, row_height, (Theme{}).border);
        left += w;
    }
    surface.fillRect(x, y + row_height - 1, width, 1, (Theme{}).border);
}
