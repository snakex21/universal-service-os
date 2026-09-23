const usos = @import("usos");
const model = @import("fb_menu_table.zig");
const Ui = usos.gui.ui.Ui;

pub fn rowHeight(ui: *const Ui) u32 {
    return ui.fonts.lineHeight(.small) + ui.px(8);
}

pub fn render(ui: *const Ui, table: model.Table, x: u32, top: u32, width: u32, first: usize, visible: usize) void {
    const theme = ui.theme;
    const h = rowHeight(ui);
    drawRow(ui, table, table.headers, x, top, width, h, theme.panel_alt, theme.muted, .strong);
    const end = @min(table.count, first + visible);
    if (first < end) for (table.rows[first..end], 0..) |row, i| {
        const y = top + @as(u32, @intCast(i + 1)) * h;
        const color = switch (row.tone) {
            .normal => theme.text,
            .warning => theme.warning,
            .failure => theme.danger,
        };
        drawRow(ui, table, row.cells, x, y, width, h, if (i % 2 == 0) theme.panel else theme.field, color, .small);
    };
}

fn drawRow(ui: *const Ui, table: model.Table, cells: model.Cells, x: u32, y: u32, width: u32, h: u32, background: usos.gui.Color, foreground: usos.gui.Color, style: usos.gui.ui.Style) void {
    ui.surface.fillRect(x, y, width, h, background);
    var left = x;
    for (0..table.columns) |column| {
        const w = if (column + 1 == table.columns) x + width - left else width * table.weight(column) / 100;
        _ = ui.fonts.drawFit(ui.surface, left + ui.px(6), ui.fonts.centeredTop(.small, y + h / 2), w -| ui.px(12), if (style == .strong) .small else style, cells[column], foreground, background);
        if (column > 0) ui.surface.fillRect(left, y, ui.line(1), h, ui.theme.border);
        left += w;
    }
    ui.surface.fillRect(x, y + h -| ui.line(1), width, ui.line(1), ui.theme.border);
}
