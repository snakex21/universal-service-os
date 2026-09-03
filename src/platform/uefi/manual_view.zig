const std = @import("std");
const usos = @import("usos");
const collect_boot_info = @import("collect_boot_info.zig");
const console = @import("console.zig");
const file_read = @import("file_read.zig");
const pointer = @import("pointer.zig");

const html_capacity = 8192;
const css_capacity = 2048;
const max_panel_width: u32 = 1040;
const outer_margin: u32 = 32;
const header_height: u32 = 96;
const list_content_y: u32 = 136;
const row_height: u32 = 42;
const card_gap: u32 = 18;
const card_height: u32 = 116;
const card_start_y: u32 = 142;
const cursor_patch_width: u32 = 18;
const cursor_patch_height: u32 = 22;
const cursor_patch_capacity: usize = cursor_patch_width * cursor_patch_height;

var html_buffer: [html_capacity]u8 = undefined;
var html_len: usize = 0;
var css_buffer: [css_capacity]u8 = undefined;
var surface: ?usos.gui.Surface = null;
var theme = usos.gui.Theme{};
var row_y: u32 = 0;
var active_footer: []const u8 = "";
var cursor_under: [cursor_patch_capacity]u32 = undefined;
var cursor_saved = false;
var cursor_saved_x: u32 = 0;
var cursor_saved_y: u32 = 0;
var cursor_saved_width: u32 = 0;
var cursor_saved_height: u32 = 0;

pub fn init(root: *std.os.uefi.protocol.File) void {
    if (file_read.into(root, "\\UI\\index.html", &html_buffer)) |html| html_len = html.len;
    if (file_read.into(root, "\\UI\\theme.css", &css_buffer)) |css| theme = usos.gui.Theme.parse(css);

    const info = collect_boot_info.collect() catch return;
    if (info.framebuffer) |framebuffer| surface = usos.gui.Surface.init(framebuffer);

    if (surface) |canvas| {
        pointer.init(canvas.framebuffer.width, canvas.framebuffer.height);
        if (std.os.uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
    }
}

pub fn beginHome() void {
    if (surface) |canvas| {
        invalidatePointer();
        canvas.fill(theme.background);
        canvas.fillRect(0, 0, canvas.framebuffer.width, 5, theme.accent);

        const content_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const content_x = (canvas.framebuffer.width -| content_width) / 2;
        usos.gui.text.draw(canvas, content_x, 28, "UNIVERSAL SERVICE OS", 3, theme.text);
        usos.gui.text.draw(canvas, content_x, 78, "Choose what you want to boot or service", 1, theme.muted);
        drawMouseStatus(canvas, content_x +| content_width);
        canvas.fillRect(content_x, 108, content_width, 1, theme.border);
        active_footer = "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC/RIGHT CLICK - BACK";
    } else {
        console.clear();
        console.writeAscii("Universal Service OS\nChoose category\n\n");
    }
}

pub fn categoryCard(index: usize, selected: bool, title: []const u8, description: []const u8, symbol: []const u8) void {
    if (surface) |canvas| {
        const geometry = cardGeometry(canvas, index);
        const background = if (selected) theme.selected else theme.panel;
        const border = if (selected) theme.accent else theme.border;
        canvas.fillRect(geometry.x, geometry.y, geometry.width, card_height, background);
        canvas.borderRect(geometry.x, geometry.y, geometry.width, card_height, if (selected) 2 else 1, border);

        const icon_size: u32 = 58;
        const icon_x = geometry.x + 20;
        const icon_y = geometry.y + 29;
        canvas.fillRect(icon_x, icon_y, icon_size, icon_size, if (selected) theme.accent else theme.panel_alt);
        usos.gui.text.draw(canvas, icon_x + 18, icon_y + 15, symbol, 3, if (selected) theme.background else theme.accent);

        usos.gui.text.draw(canvas, geometry.x + 98, geometry.y + 25, title, 2, theme.text);
        usos.gui.text.draw(canvas, geometry.x + 98, geometry.y + 65, description, 1, theme.muted);
        return;
    }

    console.writeAscii(if (selected) "> " else "  ");
    console.writeAscii(title);
    console.writeAscii(" - ");
    console.writeAscii(description);
    console.writeAscii("\n");
}

pub fn hitCategoryCard(x: u32, y: u32, count: usize) ?usize {
    const canvas = surface orelse return null;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const geometry = cardGeometry(canvas, index);
        if (x >= geometry.x and x < geometry.x +| geometry.width and y >= geometry.y and y < geometry.y +| card_height) return index;
    }
    return null;
}

pub fn begin(screen_id: []const u8, fallback_title: []const u8) void {
    const spec = if (html_len > 0) usos.gui.html_screen.find(html_buffer[0..html_len], screen_id) else null;
    const title = if (spec) |value| value.title else fallback_title;
    const subtitle = if (spec) |value| value.subtitle else "";
    active_footer = if (spec) |value| value.footer else "";

    if (surface) |canvas| {
        invalidatePointer();
        canvas.fill(theme.background);
        canvas.fillRect(0, 0, canvas.framebuffer.width, 5, theme.accent);

        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        usos.gui.text.draw(canvas, panel_x, 26, title, 2, theme.text);
        if (subtitle.len > 0) usos.gui.text.draw(canvas, panel_x, 64, subtitle, 1, theme.muted);
        canvas.fillRect(panel_x, header_height, panel_width, 1, theme.border);

        const content_height = canvas.framebuffer.height -| (list_content_y + 74);
        canvas.fillRect(panel_x, list_content_y, panel_width, content_height, theme.panel);
        row_y = list_content_y + 22;
    } else {
        console.clear();
        console.writeAscii("Universal Service OS\n");
        console.writeAscii(title);
        console.writeAscii("\n");
        if (subtitle.len > 0) {
            console.writeAscii(subtitle);
            console.writeAscii("\n");
        }
        console.writeAscii("\n");
    }
}

pub fn row(selected: bool, value: []const u8) void {
    drawRow(selected, value, null);
}

pub fn systemRow(selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage) void {
    drawRow(selected, value, icon);
}

pub fn systemRowDisabled(selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage, reason: []const u8) void {
    drawRowDisabled(selected, value, icon, reason);
}

pub fn rowDisabled(selected: bool, value: []const u8, reason: []const u8) void {
    drawRowDisabled(selected, value, null, reason);
}

fn drawRowDisabled(selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage, reason: []const u8) void {
    if (surface) |canvas| {
        if (value.len == 0) {
            row_y += 16;
            return;
        }
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const x = panel_x + 18;
        const width = panel_width -| 36;
        canvas.fillRect(x, row_y, width, row_height - 6, theme.panel);
        if (selected) canvas.fillRect(x, row_y, 5, row_height - 6, theme.border);
        var text_x = x + 18;
        if (icon) |system_icon| {
            drawRgbaIcon(canvas, x + 12, row_y + 2, system_icon, theme.panel);
            text_x = x + 58;
        }
        const dim = theme.muted;
        usos.gui.text.draw(canvas, text_x, row_y + 10, value, 2, dim);
        usos.gui.text.draw(canvas, text_x + usos.gui.text.width(value, 2) + 16, row_y + 10, reason, 1, dim);
        row_y += row_height;
    } else {
        console.writeAscii(if (selected) "> " else "  ");
        console.writeAscii(value);
        console.writeAscii(" ");
        console.writeAscii(reason);
        console.writeAscii("\n");
    }
}

fn drawRow(selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage) void {
    if (surface) |canvas| {
        if (value.len == 0) {
            row_y += 16;
            return;
        }
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const x = panel_x + 18;
        const width = panel_width -| 36;
        const background = if (selected) theme.selected else theme.panel_alt;
        canvas.fillRect(x, row_y, width, row_height - 6, background);
        if (selected) canvas.fillRect(x, row_y, 5, row_height - 6, theme.accent);

        var text_x = x + 18;
        if (icon) |system_icon| {
            drawRgbaIcon(canvas, x + 12, row_y + 2, system_icon, background);
            text_x = x + 58;
        }
        usos.gui.text.draw(canvas, text_x, row_y + 10, value, 2, if (selected) theme.text else theme.muted);
        row_y += row_height;
    } else {
        console.writeAscii(if (selected) "> " else "  ");
        console.writeAscii(value);
        console.writeAscii("\n");
    }
}

pub fn rowParts(selected: bool, first: []const u8, second: []const u8) void {
    if (surface) |canvas| {
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const x = panel_x + 18;
        const width = panel_width -| 36;
        canvas.fillRect(x, row_y, width, row_height - 6, if (selected) theme.selected else theme.panel_alt);
        if (selected) canvas.fillRect(x, row_y, 5, row_height - 6, theme.accent);
        const text_color = if (selected) theme.text else theme.muted;
        usos.gui.text.draw(canvas, x + 18, row_y + 10, first, 2, text_color);
        usos.gui.text.draw(canvas, x + 18 + usos.gui.text.width(first, 2), row_y + 10, second, 2, text_color);
        row_y += row_height;
    } else {
        console.writeAscii(if (selected) "> " else "  ");
        console.writeAscii(first);
        console.writeAscii(second);
        console.writeAscii("\n");
    }
}

pub fn number(value: u64) void {
    var buffer: [20]u8 = undefined;
    const text_value = usos.decimal.u64ToAscii(&buffer, value);
    if (surface) |canvas| {
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        usos.gui.text.draw(canvas, panel_x + 18, row_y, text_value, 2, theme.text);
    } else {
        console.writeAscii(text_value);
    }
}

pub fn footer(back_enabled: bool) void {
    if (surface) |canvas| {
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const y = canvas.framebuffer.height -| 48;
        const footer_text = if (active_footer.len > 0) active_footer else if (back_enabled) "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC/RIGHT CLICK - BACK" else "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN";
        usos.gui.text.draw(canvas, panel_x, y, footer_text, 1, theme.muted);
        updatePointer();
    } else {
        console.writeAscii("\n");
        if (active_footer.len > 0) console.writeAscii(active_footer) else console.writeAscii(if (back_enabled) "Arrows - select, Enter - open, Esc - back" else "Arrows - select, Enter - open");
        console.writeAscii("\n");
    }
}

pub fn writeText(label: []const u8, value: []const u8) void {
    rowParts(false, label, value);
}

pub fn hitRow(x: u32, y: u32, visible_count: usize) ?usize {
    const canvas = surface orelse return null;
    const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
    const row_x = panel_x + 18;
    const row_width = panel_width -| 36;
    const first_y = list_content_y + 22;
    if (x < row_x or x >= row_x +| row_width or y < first_y) return null;
    const index: usize = @intCast((y - first_y) / row_height);
    if (index >= visible_count) return null;
    if ((y - first_y) % row_height >= row_height - 6) return null;
    return index;
}

fn cardGeometry(canvas: usos.gui.Surface, index: usize) struct { x: u32, y: u32, width: u32 } {
    const content_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const content_x = (canvas.framebuffer.width -| content_width) / 2;
    const card_width = (content_width -| card_gap) / 2;
    const column: u32 = @intCast(index % 2);
    const row_index: u32 = @intCast(index / 2);
    return .{
        .x = content_x + column * (card_width + card_gap),
        .y = card_start_y + row_index * (card_height + card_gap),
        .width = card_width,
    };
}

fn drawRgbaIcon(canvas: usos.gui.Surface, x: u32, y: u32, icon: *const usos.gui.RgbaImage, background: usos.gui.Color) void {
    var py: usize = 0;
    while (py < usos.gui.rgba_image.icon_height) : (py += 1) {
        var px: usize = 0;
        while (px < usos.gui.rgba_image.icon_width) : (px += 1) {
            const source = icon.pixel(px, py);
            if (source.a == 0) continue;
            const color = if (source.a == 255)
                usos.gui.Color{ .r = source.r, .g = source.g, .b = source.b }
            else
                usos.gui.Color{
                    .r = alphaBlend(source.r, background.r, source.a),
                    .g = alphaBlend(source.g, background.g, source.a),
                    .b = alphaBlend(source.b, background.b, source.a),
                };
            canvas.setPixel(x + @as(u32, @intCast(px)), y + @as(u32, @intCast(py)), color);
        }
    }
}

fn alphaBlend(foreground: u8, background: u8, alpha: u8) u8 {
    const inverse: u16 = 255 - alpha;
    return @intCast((@as(u16, foreground) * alpha + @as(u16, background) * inverse + 127) / 255);
}

fn drawMouseStatus(canvas: usos.gui.Surface, right_edge: u32) void {
    const label = pointer.backendLabel();
    const prefix = "MOUSE: ";
    const total_width = usos.gui.text.width(prefix, 1) + usos.gui.text.width(label, 1);
    const x = right_edge -| total_width;
    usos.gui.text.draw(canvas, x, 34, prefix, 1, theme.muted);
    usos.gui.text.draw(canvas, x + usos.gui.text.width(prefix, 1), 34, label, 1, if (pointer.available()) theme.accent else theme.muted);
}

pub fn updatePointer() void {
    const canvas = surface orelse return;
    if (!pointer.available()) return;
    restorePointerBackground(canvas);
    savePointerBackground(canvas);
    drawPointer(canvas);
}

fn invalidatePointer() void {
    cursor_saved = false;
}

fn restorePointerBackground(canvas: usos.gui.Surface) void {
    if (!cursor_saved) return;
    var y: u32 = 0;
    while (y < cursor_saved_height) : (y += 1) {
        var x: u32 = 0;
        while (x < cursor_saved_width) : (x += 1) {
            const index: usize = @as(usize, y) * cursor_patch_width + x;
            canvas.setRawPixel(cursor_saved_x + x, cursor_saved_y + y, cursor_under[index]);
        }
    }
    cursor_saved = false;
}

fn savePointerBackground(canvas: usos.gui.Surface) void {
    const pos = pointer.position();
    cursor_saved_x = pos.x;
    cursor_saved_y = pos.y;
    cursor_saved_width = @min(cursor_patch_width, canvas.framebuffer.width -| pos.x);
    cursor_saved_height = @min(cursor_patch_height, canvas.framebuffer.height -| pos.y);

    var y: u32 = 0;
    while (y < cursor_saved_height) : (y += 1) {
        var x: u32 = 0;
        while (x < cursor_saved_width) : (x += 1) {
            const index: usize = @as(usize, y) * cursor_patch_width + x;
            cursor_under[index] = canvas.getRawPixel(pos.x + x, pos.y + y);
        }
    }
    cursor_saved = true;
}

const cursor_bitmap = [_][]const u8{
    "B.................",
    "BB................",
    "BWB...............",
    "BWWB..............",
    "BWWWB.............",
    "BWWWWB............",
    "BWWWWWB...........",
    "BWWWWWWB..........",
    "BWWWWWWWB.........",
    "BWWWWWWWWB........",
    "BWWWWWWWWWB.......",
    "BWWWWWWWWWWB......",
    "BWWWWWWBBBBBBB....",
    "BWWWWB............",
    "BWWWB.BB...........",
    "BWWB..BWB..........",
    "BWB...BWWB.........",
    "BB....BWWWB........",
    "B.....BWWWB........",
    "......BWWWB........",
    "......BWWWB........",
    ".......BBB.........",
};

fn drawPointer(canvas: usos.gui.Surface) void {
    if (!pointer.available()) return;
    const pos = pointer.position();
    const outline = usos.gui.Color{ .r = 0x00, .g = 0x00, .b = 0x00 };
    const fill = usos.gui.Color{ .r = 0xff, .g = 0xff, .b = 0xff };

    for (cursor_bitmap, 0..) |bitmap_row, y| {
        for (bitmap_row, 0..) |pixel, x| {
            const color = switch (pixel) {
                'B' => outline,
                'W' => fill,
                else => continue,
            };
            canvas.setPixel(pos.x + @as(u32, @intCast(x)), pos.y + @as(u32, @intCast(y)), color);
        }
    }
}

pub fn isGraphical() bool {
    return surface != null;
}
