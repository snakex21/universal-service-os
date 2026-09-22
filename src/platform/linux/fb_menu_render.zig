const std = @import("std");
const usos = @import("usos");
const model = @import("fb_menu_model.zig");
const Surface = usos.gui.Surface;
const Theme = usos.gui.Theme;
const text = usos.gui.text;
const table_render = @import("fb_table_render.zig");

pub const Layout = struct {
    x: u32, top: u32, width: u32, row_height: u32, visible: usize,
    first: usize, info_y: u32, info_lines: usize, footer: u32,
    table_y: u32 = 0,

    pub fn init(surface: Surface, state: model.State) Layout {
        const m = usos.gui.menu_canvas.Metrics.init(surface);
        const row_height: u32 = 62;
        const available = m.list_height -| 24;
        const reserve: u32 = if (state.detailCount() > 0) @min(available / 2, 190) else 0;
        const visible = @min(state.count, @max(@as(usize, 1), (available -| reserve) / row_height));
        const first = (state.selected / visible) * visible;
        const rows = @min(visible, state.count - first);
        const info_y = m.list_top + 12 + @as(u32, @intCast(rows)) * row_height + 12;
        const bottom = m.list_top + m.list_height -| 14;
        const has_table = state.table.columns > 0;
        const table_y = info_y + @as(u32, @intCast(@min(state.info_count, 3))) * 14 + 6;
        return .{ .x = m.content_x + 12, .top = m.list_top + 12, .width = m.content_width -| 24,
            .row_height = row_height, .visible = visible, .first = first, .info_y = info_y,
            .info_lines = if (has_table) (bottom -| table_y -| table_render.row_height) / table_render.row_height else (bottom -| info_y) / 14,
            .table_y = table_y, .footer = m.footer_y };
    }

    pub fn hit(self: Layout, x: i32, y: i32, count: usize) ?usize {
        if (x < self.x or x >= self.x + self.width or y < self.top) return null;
        const row: usize = @intCast(@divTrunc(y - @as(i32, @intCast(self.top)), @as(i32, @intCast(self.row_height))));
        if (row >= self.visible or self.first + row >= count) return null;
        const offset: u32 = @intCast(y - @as(i32, @intCast(self.top)));
        if (offset % self.row_height >= self.row_height - 6) return null;
        return self.first + row;
    }
};

fn clipped(surface: Surface, x: u32, y: u32, width: u32, value: []const u8, scale: u32, color: usos.gui.Color) void {
    text.draw(surface, x, y, value[0..@min(value.len, width / (6 * scale))], scale, color);
}

pub fn render(surface: Surface, state: model.State, mouse_x: i32, mouse_y: i32, mouse_visible: bool) void {
    const theme = Theme{};
    const canvas = usos.gui.menu_canvas.Canvas.init(surface, theme);
    canvas.beginList(state.title, state.subtitle, "USOS", "");
    const l = Layout.init(surface, state);
    const end = @min(state.count, l.first + l.visible);
    for (state.items[l.first..end], l.first..) |item, index| {
        const y = l.top + @as(u32, @intCast(index - l.first)) * l.row_height;
        const selected = index == state.selected;
        surface.fillRect(l.x, y, l.width, l.row_height - 6, if (selected) theme.selected else theme.panel_alt);
        surface.borderRect(l.x, y, l.width, l.row_height - 6, if (selected) 2 else 1, if (selected) theme.accent else theme.border);
        if (selected) surface.fillRect(l.x, y, 5, l.row_height - 6, theme.accent);
        const scale: u32 = if (item.title.len * 12 <= l.width -| 32) 2 else 1;
        clipped(surface, l.x + 16, y + 10, l.width -| 32, item.title, scale, theme.text);
        clipped(surface, l.x + 16, y + 36, l.width -| 32, item.detail, 1, theme.muted);
    }
    const has_table = state.table.columns > 0;
    const info_first = if (has_table) 0 else state.scroll;
    const info_end = if (has_table) @min(state.info_count, 3) else @min(state.info_count, state.scroll + l.info_lines);
    for (state.info[info_first..info_end], 0..) |line, i| {
        clipped(surface, l.x + 6, l.info_y + @as(u32, @intCast(i)) * 14, l.width -| 12, line, 1, theme.text);
    }
    if (has_table) table_render.render(surface, state.table, l.x, l.table_y, l.width, state.scroll, l.info_lines);
    if (state.detailCount() > l.info_lines) {
        var buffer: [80]u8 = undefined;
        canvas.listHelp(std.fmt.bufPrint(&buffer, "Details {d}-{d}/{d}  |  PgUp/PgDn or mouse wheel", .{ state.scroll + 1, @min(state.detailCount(), state.scroll + l.info_lines), state.detailCount() }) catch "");
    }
    canvas.footer("Arrows: move   ENTER / click: select   ESC: back");
    if (mouse_visible) {
        const x: u32 = @intCast(mouse_x);
        const y: u32 = @intCast(mouse_y);
        for (0..14) |i| {
            surface.fillRect(x, y + @as(u32, @intCast(i)), @as(u32, @intCast(i / 2 + 1)), 1, theme.background);
            if (i < 11) surface.fillRect(x + 1, y + @as(u32, @intCast(i)) + 1, @as(u32, @intCast(i / 2 + 1)), 1, theme.text);
        }
    }
}

test "menu hit testing rejects gaps and supports paged disks" {
    const l = Layout{ .x = 20, .top = 100, .width = 500, .row_height = 62, .visible = 3, .first = 3, .info_y = 300, .info_lines = 4, .footer = 450 };
    try std.testing.expectEqual(@as(?usize, 3), l.hit(30, 110, 8));
    try std.testing.expectEqual(@as(?usize, null), l.hit(30, 159, 8));
    try std.testing.expectEqual(@as(?usize, null), l.hit(30, 290, 8));
    try std.testing.expectEqual(@as(?usize, null), l.hit(600, 110, 8));
}

test "confirmation choices and scrollable detail fit 640 by 480" {
    const pixels = try std.testing.allocator.alloc(u32, 640 * 480);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 640, 480, .bgrx8).?;
    const state = try model.parse("title=Confirm\nitem=Confirm\nitem=Cancel\nselected=1\ninfo=Disk identity");
    const layout = Layout.init(buffer.surface, state);
    try std.testing.expect(layout.top + 2 * layout.row_height < layout.footer);
    try std.testing.expect(layout.info_lines > 0);
    render(buffer.surface, state, 639, 479, true);
    const selected_pixel = buffer.surface.getRawPixel(layout.x + 1, layout.top + layout.row_height + 10);
    const unselected_pixel = buffer.surface.getRawPixel(layout.x + 1, layout.top + 10);
    try std.testing.expect(selected_pixel != unselected_pixel);
}

test "SMART table remains inside a small framebuffer and scrolls rows under a fixed header" {
    const pixels = try std.testing.allocator.alloc(u32, 640 * 480);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 640, 480, .bgrx8).?;
    var state = try model.parse("title=SMART\nitem=Refresh\nitem=Report\nitem=Back\nselected=2\ninfo=Serial number: sample\ninfo=Manufacturer-specific values\ntable_header=ID|Attribute|Value|Worst|Limit|RAW value|State");
    for (0..40) |_| try state.table.append("normal|5|Reallocated Sector Ct|100|100|010|0|-");
    const layout = Layout.init(buffer.surface, state);
    try std.testing.expect(layout.info_lines >= 1);
    try std.testing.expect(layout.table_y + @as(u32, @intCast(layout.info_lines + 1)) * table_render.row_height < layout.footer);
    for (0..100) |_| state.scrollInfo(true, layout.info_lines);
    try std.testing.expectEqual(state.table.count - layout.info_lines, state.scroll);
    render(buffer.surface, state, 639, 479, false);
    const header_pixel = buffer.surface.getRawPixel(layout.x + 2, layout.table_y + 2);
    const row_pixel = buffer.surface.getRawPixel(layout.x + 2, layout.table_y + table_render.row_height + 2);
    try std.testing.expect(header_pixel != row_pixel);
}
