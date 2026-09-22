const Surface = @import("surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const text = @import("text.zig");

pub const HomeItem = struct {
    title: []const u8,
    description: []const u8,
    symbol: []const u8,
};

pub const Row = struct {
    value: []const u8,
    detail: []const u8 = "",
    icon_rgba: ?[]const u8 = null,
    icon_symbol: []const u8 = "",
    selected: bool = false,
    unavailable: bool = false,
};

pub const Canvas = struct {
    surface: Surface,
    theme: Theme,
    metrics: Metrics,

    pub fn init(surface: Surface, theme: Theme) Canvas {
        return .{ .surface = surface, .theme = theme, .metrics = Metrics.init(surface) };
    }

    pub fn beginHome(self: Canvas, firmware: []const u8, status: []const u8) void {
        self.clear();
        const m = self.metrics;
        const title_scale: u32 = if (self.surface.framebuffer.width >= 1000 and self.surface.framebuffer.height >= 700) 3 else 2;
        text.draw(self.surface, m.content_x, m.header_y, "UNIVERSAL SERVICE OS", title_scale, self.theme.text);
        drawRight(self.surface, m.content_right, m.header_y + 4, firmware, 1, self.theme.accent);
        const status_width = if (status.len > 0) @min(m.content_width, header_status_width) else 0;
        const subtitle_width = m.content_width -| status_width -| 20;
        drawClipped(self.surface, m.content_x, m.header_subtitle_y, subtitle_width, "Choose what you want to boot or service", 1, self.theme.muted);
        if (status.len > 0) drawRight(self.surface, m.content_right, m.header_subtitle_y, status, 1, self.theme.muted);
        self.surface.fillRect(m.content_x, m.header_rule_y, m.content_width, 1, self.theme.border);
    }

    pub fn homeItem(self: Canvas, index: usize, count: usize, item: HomeItem, selected: bool) void {
        if (count == 0) return;
        const geometry = self.metrics.homeCard(index, count);
        const background = if (selected) self.theme.selected else self.theme.panel;
        const border = if (selected) self.theme.accent else self.theme.border;
        self.surface.fillRect(geometry.x, geometry.y, geometry.width, geometry.height, background);
        self.surface.borderRect(geometry.x, geometry.y, geometry.width, geometry.height, if (selected) 2 else 1, border);

        const pad = @max(@as(u32, 12), geometry.height / 10);
        const icon_size = @min(@as(u32, 58), geometry.height -| (pad * 2));
        const icon_x = geometry.x + pad;
        const icon_y = geometry.y + (geometry.height -| icon_size) / 2;
        self.surface.fillRect(icon_x, icon_y, icon_size, icon_size, if (selected) self.theme.accent else self.theme.panel_alt);
        const symbol_scale: u32 = if (icon_size >= 48) 3 else 2;
        const symbol_width = text.width(item.symbol, symbol_scale);
        const symbol_x = icon_x + (icon_size -| symbol_width) / 2;
        const symbol_y = icon_y + (icon_size -| (7 * symbol_scale)) / 2;
        text.draw(self.surface, symbol_x, symbol_y, item.symbol, symbol_scale, if (selected) self.theme.background else self.theme.accent);

        const text_x = icon_x + icon_size + pad;
        const text_width = geometry.x + geometry.width -| pad -| text_x;
        const title_y = geometry.y + geometry.height / 4;
        drawClipped(self.surface, text_x, title_y, text_width, item.title, 2, self.theme.text);
        drawClipped(self.surface, text_x, title_y + 30, text_width, item.description, 1, self.theme.muted);
    }

    pub fn beginList(self: Canvas, title: []const u8, subtitle: []const u8, firmware: []const u8, status: []const u8) void {
        self.clear();
        const m = self.metrics;
        text.draw(self.surface, m.content_x, m.header_y, title, 2, self.theme.text);
        drawRight(self.surface, m.content_right, m.header_y + 3, firmware, 1, self.theme.accent);
        const status_width = if (status.len > 0) @min(m.content_width, header_status_width) else 0;
        const subtitle_width = m.content_width -| status_width -| 20;
        if (subtitle.len > 0) drawClipped(self.surface, m.content_x, m.header_subtitle_y, subtitle_width, subtitle, 1, self.theme.muted);
        if (status.len > 0) drawRight(self.surface, m.content_right, m.header_subtitle_y, status, 1, self.theme.muted);
        self.surface.fillRect(m.content_x, m.header_rule_y, m.content_width, 1, self.theme.border);
        self.surface.fillRect(m.content_x, m.list_top, m.content_width, m.list_height, self.theme.panel);
        self.surface.borderRect(m.content_x, m.list_top, m.content_width, m.list_height, 1, self.theme.border);
    }

    pub fn listRow(self: Canvas, visible_index: usize, row: Row) void {
        if (visible_index >= self.metrics.visible_rows) return;
        const m = self.metrics;
        const x = m.content_x + m.row_inset;
        const y = m.list_top + m.row_inset + @as(u32, @intCast(visible_index)) * m.row_height;
        const width = m.content_width -| (m.row_inset * 2);
        const height = m.row_height -| m.row_gap;
        const background = if (row.unavailable)
            self.theme.disabled
        else if (row.selected)
            self.theme.selected
        else
            self.theme.panel_alt;
        self.surface.fillRect(x, y, width, height, background);
        if (row.selected) self.surface.fillRect(x, y, 5, height, if (row.unavailable) self.theme.border else self.theme.accent);

        const text_y = y + (height -| 14) / 2;
        const primary_color = if (row.unavailable) self.theme.muted else if (row.selected) self.theme.text else self.theme.muted;
        var primary_x = x + 18;
        if (row.icon_rgba) |rgba| {
            const icon_size: u32 = 32;
            const icon_y = y + (height -| icon_size) / 2;
            drawRgba32(self.surface, x + 12, icon_y, rgba, background);
            primary_x = x + 54;
        } else if (row.icon_symbol.len > 0) {
            const icon_size: u32 = 32;
            const icon_y = y + (height -| icon_size) / 2;
            const icon_x = x + 12;
            self.surface.fillRect(icon_x, icon_y, icon_size, icon_size, self.theme.panel);
            self.surface.borderRect(icon_x, icon_y, icon_size, icon_size, 1, if (row.selected) self.theme.accent else self.theme.border);
            const symbol = row.icon_symbol[0..@min(row.icon_symbol.len, 1)];
            const symbol_width = text.width(symbol, 2);
            text.draw(self.surface, icon_x + (icon_size -| symbol_width) / 2, icon_y + 9, symbol, 2, self.theme.accent);
            primary_x = x + 54;
        }
        const max_primary_width = x + width -| primary_x -| 18;
        drawClipped(self.surface, primary_x, text_y, max_primary_width, row.value, 2, primary_color);
        if (row.detail.len > 0) {
            const after = primary_x + text.width(row.value, 2) + 16;
            if (after < x + width - 12) {
                drawClipped(self.surface, after, text_y + 4, x + width -| after -| 12, row.detail, 1, self.theme.muted);
            }
        }
    }

    pub fn clearListRows(self: Canvas) void {
        const m = self.metrics;
        self.surface.fillRect(
            m.content_x + m.row_inset,
            m.list_top + m.row_inset,
            m.content_width -| (m.row_inset * 2),
            m.list_height -| (m.row_inset * 2),
            self.theme.panel,
        );
    }

    pub fn progressBar(self: Canvas, percent: u8, label: []const u8) void {
        const m = self.metrics;
        const x = m.content_x + m.row_inset + 18;
        const width = m.content_width -| (m.row_inset * 2) -| 36;
        const y = m.list_top + m.row_inset + @as(u32, 5) * m.row_height + 8;
        const bar_y = y + 18;
        if (bar_y + 20 >= m.list_top + m.list_height) return;
        self.surface.fillRect(x, y, width, 46, self.theme.panel);
        drawClipped(self.surface, x, y, width, label, 1, self.theme.muted);
        self.surface.fillRect(x, bar_y, width, 18, self.theme.background);
        self.surface.borderRect(x, bar_y, width, 18, 1, self.theme.border);
        const inner = width -| 4;
        const filled: u32 = @intCast((inner * @as(u32, percent)) / 100);
        self.surface.fillRect(x + 2, bar_y + 2, filled, 14, self.theme.accent);
    }

    pub fn refreshHeaderStatus(self: Canvas, value: []const u8) void {
        if (value.len == 0) return;
        const width = @min(self.metrics.content_width, header_status_width);
        const x = self.metrics.content_right -| width;
        self.surface.fillRect(x, self.metrics.header_subtitle_y, width, 8, self.theme.background);
        drawRight(self.surface, self.metrics.content_right, self.metrics.header_subtitle_y, value, 1, self.theme.muted);
    }

    pub fn listHelp(self: Canvas, value: []const u8) void {
        const y = self.metrics.footer_y -| 18;
        self.surface.fillRect(self.metrics.content_x, y, self.metrics.content_width, 8, self.theme.background);
        drawClipped(self.surface, self.metrics.content_x, y, self.metrics.content_width, value, 1, self.theme.muted);
    }

    pub fn footer(self: Canvas, value: []const u8) void {
        drawClipped(self.surface, self.metrics.content_x, self.metrics.footer_y, self.metrics.content_width, value, 1, self.theme.muted);
    }

    pub fn notice(self: Canvas, title: []const u8, lines: []const []const u8, footer_text: []const u8) void {
        self.clear();
        const m = self.metrics;
        text.draw(self.surface, m.content_x, m.header_y, "UNIVERSAL SERVICE OS", 2, self.theme.text);
        drawRight(self.surface, m.content_right, m.header_y + 3, "FIRMWARE: BIOS", 1, self.theme.accent);
        self.surface.fillRect(m.content_x, m.header_rule_y, m.content_width, 1, self.theme.border);

        const line_step: u32 = 24;
        const wanted_height = @as(u32, @intCast(lines.len)) * line_step + 82;
        const panel_height = @min(@max(@as(u32, 150), wanted_height), m.list_height);
        const panel_y = m.list_top + (m.list_height -| panel_height) / 2;
        self.surface.fillRect(m.content_x, panel_y, m.content_width, panel_height, self.theme.panel);
        self.surface.borderRect(m.content_x, panel_y, m.content_width, panel_height, 1, self.theme.border);
        self.surface.fillRect(m.content_x, panel_y, 5, panel_height, self.theme.accent);
        drawClipped(self.surface, m.content_x + 22, panel_y + 22, m.content_width -| 44, title, 2, self.theme.accent);
        for (lines, 0..) |line, index| {
            const y = panel_y + 62 + @as(u32, @intCast(index)) * line_step;
            if (y + 7 >= panel_y + panel_height) break;
            drawClipped(self.surface, m.content_x + 22, y, m.content_width -| 44, line, 1, if (index == 0) self.theme.text else self.theme.muted);
        }
        self.footer(footer_text);
    }

    pub fn visibleRows(self: Canvas) usize {
        return self.metrics.visible_rows;
    }

    fn clear(self: Canvas) void {
        self.surface.fill(self.theme.background);
        self.surface.fillRect(0, 0, self.surface.framebuffer.width, @max(@as(u32, 3), self.surface.framebuffer.height / 160), self.theme.accent);
    }
};

const header_status_width: u32 = 26 * 6;

pub const Metrics = struct {
    width: u32,
    height: u32,
    margin_x: u32,
    margin_y: u32,
    content_x: u32,
    content_width: u32,
    content_right: u32,
    header_y: u32,
    header_subtitle_y: u32,
    header_rule_y: u32,
    list_top: u32,
    list_height: u32,
    footer_y: u32,
    row_height: u32,
    row_gap: u32,
    row_inset: u32,
    visible_rows: usize,
    card_gap: u32,
    card_height: u32,
    card_start_y: u32,

    pub fn init(surface: Surface) Metrics {
        const width = surface.framebuffer.width;
        const height = surface.framebuffer.height;
        const margin_x = clamp(width / 32, 20, 40);
        const margin_y = clamp(height / 32, 16, 32);
        const content_width = width -| (margin_x * 2);
        const content_x = (width -| content_width) / 2;
        const header_y = margin_y;
        const header_subtitle_y = header_y + clamp(height / 22, 28, 44);
        const header_rule_y = header_subtitle_y + clamp(height / 36, 18, 28);
        const footer_y = height -| margin_y -| 10;
        const list_top = header_rule_y + clamp(height / 48, 12, 22);
        const list_bottom = footer_y -| clamp(height / 24, 26, 44);
        const list_height = list_bottom -| list_top;
        const row_height = clamp(height / 18, 40, 48);
        const row_gap = clamp(row_height / 7, 4, 7);
        const row_inset = clamp(width / 64, 12, 20);
        const usable_rows_height = list_height -| (row_inset * 2);
        const visible_rows = @max(@as(usize, 1), @as(usize, @intCast(usable_rows_height / row_height)));

        const card_gap = clamp(width / 64, 12, 20);
        const card_height = clamp(height / 8, 92, 140);
        const cards_area_top = header_rule_y + clamp(height / 48, 12, 22);
        const cards_area_bottom = footer_y -| 26;
        const cards_available = cards_area_bottom -| cards_area_top;
        const cards_total = card_height * 3 + card_gap * 2;
        const card_start_y = cards_area_top + (cards_available -| @min(cards_available, cards_total)) / 2;

        return .{
            .width = width,
            .height = height,
            .margin_x = margin_x,
            .margin_y = margin_y,
            .content_x = content_x,
            .content_width = content_width,
            .content_right = content_x + content_width,
            .header_y = header_y,
            .header_subtitle_y = header_subtitle_y,
            .header_rule_y = header_rule_y,
            .list_top = list_top,
            .list_height = list_height,
            .footer_y = footer_y,
            .row_height = row_height,
            .row_gap = row_gap,
            .row_inset = row_inset,
            .visible_rows = visible_rows,
            .card_gap = card_gap,
            .card_height = card_height,
            .card_start_y = card_start_y,
        };
    }

    pub fn homeCard(self: Metrics, index: usize, count: usize) struct { x: u32, y: u32, width: u32, height: u32 } {
        const columns: usize = if (self.width >= 700 and count > 1) 2 else 1;
        const rows = (count + columns - 1) / columns;
        const card_width = if (columns == 2) (self.content_width -| self.card_gap) / 2 else self.content_width;
        const used_height = @as(u32, @intCast(rows)) * self.card_height + @as(u32, @intCast(rows -| 1)) * self.card_gap;
        const max_area = self.footer_y -| 26 -| self.card_start_y;
        const start_y = self.card_start_y + (max_area -| @min(max_area, used_height)) / 2;
        const column: u32 = @intCast(index % columns);
        const row: u32 = @intCast(index / columns);
        return .{
            .x = self.content_x + column * (card_width + self.card_gap),
            .y = start_y + row * (self.card_height + self.card_gap),
            .width = card_width,
            .height = self.card_height,
        };
    }
};

pub fn listStart(selected: usize, count: usize, visible_rows: usize) usize {
    if (count == 0 or visible_rows == 0 or count <= visible_rows) return 0;
    const wanted = if (selected >= visible_rows) selected - visible_rows + 1 else 0;
    return @min(wanted, count - visible_rows);
}

fn drawRgba32(surface: Surface, x: u32, y: u32, rgba: []const u8, background: @import("color.zig").Color) void {
    if (rgba.len < 32 * 32 * 4) return;
    var py: usize = 0;
    while (py < 32) : (py += 1) {
        var px: usize = 0;
        while (px < 32) : (px += 1) {
            const source = (py * 32 + px) * 4;
            const alpha = rgba[source + 3];
            if (alpha == 0) continue;
            const color = if (alpha == 255)
                @import("color.zig").Color{ .r = rgba[source], .g = rgba[source + 1], .b = rgba[source + 2] }
            else
                @import("color.zig").Color{
                    .r = alphaBlend(rgba[source], background.r, alpha),
                    .g = alphaBlend(rgba[source + 1], background.g, alpha),
                    .b = alphaBlend(rgba[source + 2], background.b, alpha),
                };
            surface.setPixel(x + @as(u32, @intCast(px)), y + @as(u32, @intCast(py)), color);
        }
    }
}

fn alphaBlend(foreground: u8, background: u8, alpha: u8) u8 {
    const inverse: u16 = 255 - alpha;
    return @intCast((@as(u16, foreground) * alpha + @as(u16, background) * inverse + 127) / 255);
}

fn drawRight(surface: Surface, right_edge: u32, y: u32, value: []const u8, scale: u32, color: @import("color.zig").Color) void {
    const width = text.width(value, scale);
    text.draw(surface, right_edge -| width, y, value, scale, color);
}

fn drawClipped(surface: Surface, x: u32, y: u32, max_width: u32, value: []const u8, scale: u32, color: @import("color.zig").Color) void {
    if (scale == 0) return;
    const chars: usize = @intCast(max_width / (6 * scale));
    if (chars == 0) return;
    text.draw(surface, x, y, value[0..@min(value.len, chars)], scale, color);
}

fn clamp(value: u32, minimum: u32, maximum: u32) u32 {
    return @min(maximum, @max(minimum, value));
}

test "responsive menu metrics fit 1280x1024 and 1024x768" {
    const std = @import("std");
    const Framebuffer = @import("framebuffer.zig").Framebuffer;
    const formats = @import("framebuffer.zig");
    const cases = [_]struct { width: u32, height: u32 }{
        .{ .width = 1280, .height = 1024 },
        .{ .width = 1024, .height = 768 },
        .{ .width = 800, .height = 600 },
    };
    for (cases) |case| {
        const surface = Surface.init(Framebuffer{
            .address = 0x1000,
            .size = @as(usize, case.width) * case.height * 4,
            .width = case.width,
            .height = case.height,
            .pixels_per_scan_line = case.width,
            .pixel_format = formats.PixelFormat.bgrx8,
        }).?;
        const metrics = Metrics.init(surface);
        try std.testing.expect(metrics.visible_rows >= 8);
        const last = metrics.homeCard(5, 6);
        try std.testing.expect(last.x + last.width <= case.width);
        try std.testing.expect(last.y + last.height < metrics.footer_y);
    }
}

test "responsive canvas renders complete screens into exact-size framebuffers" {
    const std = @import("std");
    const Framebuffer = @import("framebuffer.zig").Framebuffer;
    const formats = @import("framebuffer.zig");
    const cases = [_]struct { width: u32, height: u32 }{
        .{ .width = 1280, .height = 1024 },
        .{ .width = 1024, .height = 768 },
    };
    const items = [_]HomeItem{
        .{ .title = "Windows", .description = "Install and repair Microsoft Windows", .symbol = "W" },
        .{ .title = "Linux", .description = "Linux installers and live systems", .symbol = "L" },
        .{ .title = "Beta builds", .description = "Whistler, Longhorn and other builds", .symbol = "B" },
        .{ .title = "DOS", .description = "DOS systems and legacy boot images", .symbol = "D" },
        .{ .title = "Utilities", .description = "Diagnostics and recovery tools", .symbol = "+" },
        .{ .title = "POWER", .description = "Restart or shut down", .symbol = "P" },
    };

    for (cases) |case| {
        const pixel_count = @as(usize, case.width) * case.height;
        const pixels = try std.testing.allocator.alloc(u32, pixel_count);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        const surface = Surface.init(Framebuffer{
            .address = @intFromPtr(pixels.ptr),
            .size = pixels.len * @sizeOf(u32),
            .width = case.width,
            .height = case.height,
            .pixels_per_scan_line = case.width,
            .pixel_format = formats.PixelFormat.bgrx8,
        }).?;
        const canvas = Canvas.init(surface, Theme{});
        canvas.beginHome("FIRMWARE: BIOS", "SUN 06.09.2026 15:42");
        for (items, 0..) |item, index| canvas.homeItem(index, items.len, item, index == 0);
        canvas.footer("ARROWS - SELECT    ENTER - OPEN    ESC - POWER");
        try std.testing.expect(pixels[0] != pixels[pixel_count / 2]);

        canvas.beginList("Windows", "Supported systems and image availability", "FIRMWARE: BIOS", "SUN 06.09.2026 15:42");
        const count = @min(canvas.visibleRows(), 12);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            canvas.listRow(index, .{ .value = "Windows entry", .detail = "[no image]", .selected = index == 1 });
        }
        canvas.footer("ARROWS - SELECT    ENTER - OPEN    ESC - BACK");
        try std.testing.expect(pixels[0] != pixels[pixel_count / 2]);
    }
}
