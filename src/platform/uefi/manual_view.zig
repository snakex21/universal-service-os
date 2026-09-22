const std = @import("std");
const usos = @import("usos");
const console = @import("console.zig");
const file_read = @import("file_read.zig");
const input = @import("input.zig");
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
var video_surface: ?usos.gui.Surface = null;
var screen_buffer: ?usos.gui.ScreenBuffer = null;
var screen_buffer_pool: ?[]align(8) u8 = null;
var graphics_output: ?*std.os.uefi.protocol.GraphicsOutput = null;
var full_frame_buffered = false;
var theme = usos.gui.Theme{};
var row_y: u32 = 0;
var active_footer: []const u8 = "";
var runtime_firmware: ?usos.firmware.Firmware = null;
var header_clock_active = false;
var header_clock_right_edge: u32 = 0;
var last_clock_valid = false;
var last_clock_year: u16 = 0;
var last_clock_month: u8 = 0;
var last_clock_day: u8 = 0;
var last_clock_hour: u8 = 0;
var last_clock_minute: u8 = 0;
var cursor_under: [cursor_patch_capacity]u32 = undefined;
var cursor_saved = false;
var cursor_saved_x: u32 = 0;
var cursor_saved_y: u32 = 0;
var cursor_saved_width: u32 = 0;
var cursor_saved_height: u32 = 0;

pub const ListRow = union(enum) {
    plain: []const u8,
    parts: struct { first: []const u8, second: []const u8 },
    disabled: struct { value: []const u8, reason: []const u8 },
    system: struct { value: []const u8, icon: ?*const usos.gui.RgbaImage },
    system_disabled: struct { value: []const u8, icon: ?*const usos.gui.RgbaImage, reason: []const u8 },
};

pub const ListHelp = struct {
    title: []const u8,
    line1: []const u8,
    line2: []const u8,
    status: []const u8,
};

pub const ListScreen = struct {
    screen_id: []const u8,
    title: []const u8,
    rows: []const ListRow,
    selected: usize,
    start: usize,
    visible_rows: usize,
    help: ?ListHelp,

    pub fn open(screen_id: []const u8, title: []const u8, rows: []const ListRow, selected: usize, visible_rows: usize, help: ?ListHelp) ListScreen {
        var self = ListScreen{
            .screen_id = screen_id,
            .title = title,
            .rows = rows,
            .selected = selected,
            .start = initialListStart(selected, rows.len, visible_rows),
            .visible_rows = visible_rows,
            .help = help,
        };
        self.redrawFull(selected, help);
        return self;
    }

    pub fn visibleStart(self: *const ListScreen) usize {
        return self.start;
    }

    pub fn visibleCount(self: *const ListScreen) usize {
        if (self.start >= self.rows.len) return 0;
        return @min(self.visible_rows, self.rows.len - self.start);
    }

    pub fn redrawFull(self: *ListScreen, selected: usize, help: ?ListHelp) void {
        self.selected = selected;
        self.start = initialListStart(selected, self.rows.len, self.visible_rows);
        self.help = help;
        begin(self.screen_id, self.title);
        drawVisibleList(self);
        if (help) |box| helpBox(box.title, box.line1, box.line2, box.status);
        footer(true);
    }

    pub fn updateSelection(self: *ListScreen, selected: usize, help: ?ListHelp) void {
        if (selected >= self.rows.len) return;
        if (surface == null) {
            if (selected != self.selected or !listHelpEqual(self.help, help)) self.redrawFull(selected, help);
            return;
        }

        const previous = self.selected;
        const old_start = self.start;
        const next_start = adjustedListStart(old_start, selected, self.rows.len, self.visible_rows);
        const help_changed = !listHelpEqual(self.help, help);
        if (previous == selected and old_start == next_start and !help_changed) return;

        const canvas = surface.?;
        const had_cursor = cursor_saved;
        if (had_cursor) restorePointerBackground(canvas);

        self.selected = selected;
        self.start = next_start;
        self.help = help;

        if (old_start == next_start) {
            if (previous != selected) {
                if (previous >= self.start and previous < self.start + self.visibleCount()) {
                    drawListRowAt(canvas, self.rows[previous], listRowY(previous, self.start), false);
                }
                if (selected >= self.start and selected < self.start + self.visibleCount()) {
                    drawListRowAt(canvas, self.rows[selected], listRowY(selected, self.start), true);
                }
            }
        } else {
            redrawVisibleListRegion(canvas, self);
        }

        if (help_changed) redrawListHelp(canvas, self, help);

        if (had_cursor and pointer.available()) {
            savePointerBackground(canvas);
            drawPointer(canvas);
        }
    }
};

pub fn init(root: *std.os.uefi.protocol.File, info: usos.boot_info.BootInfo) void {
    if (file_read.into(root, "\\UI\\index.html", &html_buffer)) |html| html_len = html.len;
    if (file_read.into(root, "\\UI\\theme.css", &css_buffer)) |css| theme = usos.gui.Theme.parse(css);

    runtime_firmware = info.firmware;
    input.setIdleHook(updateClock);
    if (info.framebuffer) |framebuffer| video_surface = usos.gui.Surface.init(framebuffer);
    surface = video_surface;

    if (video_surface) |canvas| {
        pointer.init(canvas.framebuffer.width, canvas.framebuffer.height);
        if (std.os.uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
        initScreenBuffer(canvas);
    }
}

fn initScreenBuffer(canvas: usos.gui.Surface) void {
    const boot_services = std.os.uefi.system_table.boot_services orelse return;
    const GraphicsOutput = std.os.uefi.protocol.GraphicsOutput;
    graphics_output = boot_services.locateProtocol(GraphicsOutput, null) catch null;
    const needed = usos.gui.ScreenBuffer.requiredBytes(canvas.framebuffer.width, canvas.framebuffer.height) orelse return;
    const pool = boot_services.allocatePool(.boot_services_data, needed) catch return;
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pool.ptr), pool.len, canvas.framebuffer.width, canvas.framebuffer.height, .bgrx8) orelse {
        boot_services.freePool(pool.ptr) catch {};
        return;
    };
    screen_buffer_pool = pool;
    screen_buffer = buffer;
}

// An EFI application may return after changing the GOP mode. Discard every
// cached pixel address/stride before drawing the error or the menu again.
pub fn refreshFramebuffer() void {
    cursor_saved = false;
    header_clock_active = false;
    last_clock_valid = false;
    surface = null;
    video_surface = null;
    screen_buffer = null;
    graphics_output = null;
    full_frame_buffered = false;
    if (screen_buffer_pool) |pool| {
        if (std.os.uefi.system_table.boot_services) |bs| bs.freePool(pool.ptr) catch {};
    }
    screen_buffer_pool = null;
    const framebuffer = (@import("framebuffer.zig").locate() catch null) orelse return;
    const canvas = usos.gui.Surface.init(framebuffer) orelse return;
    video_surface = canvas;
    surface = canvas;
    pointer.init(framebuffer.width, framebuffer.height);
    initScreenBuffer(canvas);
}

fn beginFullFrame() void {
    invalidatePointer();
    surface = video_surface;
    full_frame_buffered = false;
    if (screen_buffer) |buffer| {
        surface = buffer.surface;
        full_frame_buffered = true;
    }
}

fn presentFullFrame() void {
    if (!full_frame_buffered) {
        surface = video_surface;
        return;
    }
    const buffer = screen_buffer orelse {
        surface = video_surface;
        full_frame_buffered = false;
        return;
    };
    const video = video_surface orelse {
        surface = null;
        full_frame_buffered = false;
        return;
    };

    var presented = false;
    if (graphics_output) |graphics| {
        const GraphicsOutput = std.os.uefi.protocol.GraphicsOutput;
        const pixels: [*]GraphicsOutput.BltPixel = @ptrFromInt(buffer.surface.framebuffer.address);
        const width: usize = buffer.surface.framebuffer.width;
        const height: usize = buffer.surface.framebuffer.height;
        graphics.blt(pixels, .blt_buffer_to_video, 0, 0, 0, 0, width, height, width * @sizeOf(GraphicsOutput.BltPixel)) catch {
            buffer.copyTo(video);
            surface = video;
            full_frame_buffered = false;
            return;
        };
        presented = true;
    }
    if (!presented) buffer.copyTo(video);
    surface = video;
    full_frame_buffered = false;
}

pub fn beginHome() void {
    header_clock_active = true;
    last_clock_valid = false;
    beginFullFrame();
    if (surface) |canvas| {
        canvas.fill(theme.background);
        canvas.fillRect(0, 0, canvas.framebuffer.width, 5, theme.accent);

        const content_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const content_x = (canvas.framebuffer.width -| content_width) / 2;
        usos.gui.text.draw(canvas, content_x, 28, "UNIVERSAL SERVICE OS", 3, theme.text);
        usos.gui.text.draw(canvas, content_x, 78, "Choose what you want to boot or service", 1, theme.muted);
        drawHeaderStatus(canvas, content_x +| content_width);
        canvas.fillRect(content_x, 108, content_width, 1, theme.border);
        active_footer = "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC/RIGHT CLICK - POWER";
    } else {
        console.clear();
        console.writeAscii("Universal Service OS\nFirmware: ");
        console.writeAscii(firmwareLabel());
        var date_buffer: [20]u8 = undefined;
        var time_buffer: [5]u8 = undefined;
        if (readClock(&date_buffer, &time_buffer)) |clock| {
            console.writeAscii("\nDate: ");
            console.writeAscii(clock.date);
            console.writeAscii("  Time: ");
            console.writeAscii(clock.time);
        }
        console.writeAscii("\nChoose category\n\n");
    }
}

pub fn categoryCard(index: usize, selected: bool, title: []const u8, description: []const u8, symbol: []const u8) void {
    if (surface) |canvas| {
        drawCategoryCard(canvas, index, selected, title, description, symbol);
        return;
    }

    console.writeAscii(if (selected) "> " else "  ");
    console.writeAscii(title);
    console.writeAscii(" - ");
    console.writeAscii(description);
    console.writeAscii("\n");
}

pub fn redrawCategoryCard(index: usize, selected: bool, title: []const u8, description: []const u8, symbol: []const u8) void {
    const canvas = surface orelse return;
    const had_cursor = cursor_saved;
    if (had_cursor) restorePointerBackground(canvas);
    drawCategoryCard(canvas, index, selected, title, description, symbol);
    if (had_cursor and pointer.available()) {
        savePointerBackground(canvas);
        drawPointer(canvas);
    }
}

fn drawCategoryCard(canvas: usos.gui.Surface, index: usize, selected: bool, title: []const u8, description: []const u8, symbol: []const u8) void {
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
    header_clock_active = true;
    beginFullFrame();
    const spec = if (html_len > 0) usos.gui.html_screen.find(html_buffer[0..html_len], screen_id) else null;
    const title = if (spec) |value| value.title else fallback_title;
    const subtitle = if (spec) |value| value.subtitle else "";
    active_footer = if (spec) |value| value.footer else "";

    if (surface) |canvas| {
        canvas.fill(theme.background);
        canvas.fillRect(0, 0, canvas.framebuffer.width, 5, theme.accent);

        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const title_chars = (panel_width -| 220) / 12;
        usos.gui.text.draw(canvas, panel_x, 26, title[0..@min(title.len, title_chars)], 2, theme.text);
        const subtitle_chars = (panel_width -| 180) / 6;
        if (subtitle.len > 0) usos.gui.text.draw(canvas, panel_x, 64, subtitle[0..@min(subtitle.len, subtitle_chars)], 1, theme.muted);
        header_clock_right_edge = panel_x +| panel_width;
        drawClock(canvas, header_clock_right_edge, true);
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

pub fn helpBox(title: []const u8, line1: []const u8, line2: []const u8, status: []const u8) void {
    if (surface) |canvas| {
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const x = panel_x + 18;
        const width = panel_width -| 36;
        const y = row_y + 14;
        const height: u32 = if (status.len > 0) 110 else 88;

        canvas.fillRect(x, y, width, height, theme.background);
        canvas.borderRect(x, y, width, height, 1, theme.border);
        canvas.fillRect(x, y, 5, height, theme.accent);
        usos.gui.text.draw(canvas, x + 18, y + 14, title, 1, theme.accent);
        usos.gui.text.draw(canvas, x + 18, y + 37, line1, 1, theme.text);
        usos.gui.text.draw(canvas, x + 18, y + 59, line2, 1, theme.muted);
        if (status.len > 0) usos.gui.text.draw(canvas, x + 18, y + 81, status, 1, theme.accent);
        row_y = y + height + 8;
        return;
    }

    console.writeAscii("\n");
    console.writeAscii(title);
    console.writeAscii("\n");
    console.writeAscii(line1);
    console.writeAscii("\n");
    console.writeAscii(line2);
    console.writeAscii("\n");
    if (status.len > 0) {
        console.writeAscii(status);
        console.writeAscii("\n");
    }
}

pub fn windowsIsoStatus(stage: usos.flow.preparation_boot_progress.DirectIsoStage, detail: []const u8) void {
    const Stage = usos.flow.preparation_boot_progress.DirectIsoStage;
    header_clock_active = true;
    active_footer = "";
    beginFullFrame();
    if (surface) |canvas| {
        usos.gui.preparation_screen.render(canvas, theme, .{
            .mode = .stage,
            .current = stage.number(),
            .total = Stage.labels.len,
            .labels = &Stage.labels,
            .title = "STARTING WINDOWS FROM ISO",
            .detail = detail,
        });
        drawPreparationHeader(canvas);
        presentFullFrame();
        return;
    }
    console.clear();
    console.writeAscii("UNIVERSAL SERVICE OS\nSTARTING WINDOWS FROM ISO\n\n");
    for (Stage.labels, 1..) |label, index| {
        console.writeAscii(if (index < stage.number()) "[OK]      " else if (index == stage.number()) "[RUNNING] " else "[WAITING] ");
        console.writeAscii(label);
        console.writeAscii("\n");
    }
    console.writeAscii("\n");
    console.writeAscii(detail);
    console.writeAscii("\n");
}

pub fn handoffStatus(detail: []const u8) void {
    header_clock_active = true;
    active_footer = "";
    beginFullFrame();
    if (surface) |canvas| {
        usos.gui.preparation_screen.render(canvas, theme, .{
            .mode = .stage,
            .current = 1,
            .total = 5,
            .title = "STARTING ENVIRONMENT",
            .detail = detail,
        });
        drawPreparationHeader(canvas);
        presentFullFrame();
        return;
    }

    console.clear();
    console.writeAscii("UNIVERSAL SERVICE OS\nPREPARING WINDOWS INSTALLER\n\n");
    console.writeAscii("[1/5] STARTING ENVIRONMENT                 RUNNING\n");
    console.writeAscii("[2/5] VERIFYING TARGET DEVICE             WAITING\n");
    console.writeAscii("[3/5] PREPARING WORKSPACE                 WAITING\n");
    console.writeAscii("[4/5] COPYING FILES                       WAITING\n");
    console.writeAscii("[5/5] VERIFICATION AND FINALIZATION       WAITING\n\n");
    console.writeAscii(detail);
    console.writeAscii("\n");
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
        canvas.fillRect(x, row_y, width, row_height - 6, theme.disabled);
        if (selected) canvas.fillRect(x, row_y, 5, row_height - 6, theme.border);
        var text_x = x + 18;
        if (icon) |system_icon| {
            drawRgbaIcon(canvas, x + 12, row_y + 2, system_icon, theme.disabled);
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

fn initialListStart(selected: usize, count: usize, visible_rows: usize) usize {
    if (count == 0 or visible_rows == 0 or count <= visible_rows) return 0;
    const wanted = if (selected >= visible_rows) selected - visible_rows + 1 else 0;
    return @min(wanted, count - visible_rows);
}

fn adjustedListStart(current: usize, selected: usize, count: usize, visible_rows: usize) usize {
    if (count == 0 or visible_rows == 0 or count <= visible_rows) return 0;
    var next = current;
    if (selected < current) {
        next = selected;
    } else if (selected >= current + visible_rows) {
        next = selected - visible_rows + 1;
    }
    return @min(next, count - visible_rows);
}

fn listRowY(index: usize, start: usize) u32 {
    return list_content_y + 22 + @as(u32, @intCast(index - start)) * row_height;
}

fn drawVisibleList(screen: *const ListScreen) void {
    const count = screen.visibleCount();
    if (surface) |canvas| {
        var visible_index: usize = 0;
        while (visible_index < count) : (visible_index += 1) {
            const index = screen.start + visible_index;
            drawListRowAt(canvas, screen.rows[index], listRowY(index, screen.start), index == screen.selected);
        }
        row_y = list_content_y + 22 + @as(u32, @intCast(count)) * row_height;
        return;
    }

    var visible_index: usize = 0;
    while (visible_index < count) : (visible_index += 1) {
        const index = screen.start + visible_index;
        writeListRowConsole(screen.rows[index], index == screen.selected);
    }
}

fn redrawVisibleListRegion(canvas: usos.gui.Surface, screen: *const ListScreen) void {
    const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
    const x = panel_x + 18;
    const width = panel_width -| 36;
    const y = list_content_y + 22;
    const height = @as(u32, @intCast(screen.visible_rows)) * row_height;
    canvas.fillRect(x, y, width, height, theme.panel);

    const count = screen.visibleCount();
    var visible_index: usize = 0;
    while (visible_index < count) : (visible_index += 1) {
        const index = screen.start + visible_index;
        drawListRowAt(canvas, screen.rows[index], listRowY(index, screen.start), index == screen.selected);
    }
}

fn drawListRowAt(canvas: usos.gui.Surface, item: ListRow, y: u32, selected: bool) void {
    const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
    const x = panel_x + 18;
    const width = panel_width -| 36;

    switch (item) {
        .plain => |value| {
            const background = if (selected) theme.selected else theme.panel_alt;
            canvas.fillRect(x, y, width, row_height - 6, background);
            if (selected) canvas.fillRect(x, y, 5, row_height - 6, theme.accent);
            usos.gui.text.draw(canvas, x + 18, y + 10, value, 2, if (selected) theme.text else theme.muted);
        },
        .parts => |parts| {
            const background = if (selected) theme.selected else theme.panel_alt;
            canvas.fillRect(x, y, width, row_height - 6, background);
            if (selected) canvas.fillRect(x, y, 5, row_height - 6, theme.accent);
            const text_color = if (selected) theme.text else theme.muted;
            usos.gui.text.draw(canvas, x + 18, y + 10, parts.first, 2, text_color);
            usos.gui.text.draw(canvas, x + 18 + usos.gui.text.width(parts.first, 2), y + 10, parts.second, 2, text_color);
        },
        .disabled => |disabled| drawDisabledListRow(canvas, x, y, width, selected, disabled.value, null, disabled.reason),
        .system => |system| drawEnabledListRow(canvas, x, y, width, selected, system.value, system.icon),
        .system_disabled => |disabled| drawDisabledListRow(canvas, x, y, width, selected, disabled.value, disabled.icon, disabled.reason),
    }
}

fn drawEnabledListRow(canvas: usos.gui.Surface, x: u32, y: u32, width: u32, selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage) void {
    const background = if (selected) theme.selected else theme.panel_alt;
    canvas.fillRect(x, y, width, row_height - 6, background);
    if (selected) canvas.fillRect(x, y, 5, row_height - 6, theme.accent);
    var text_x = x + 18;
    if (icon) |system_icon| {
        drawRgbaIcon(canvas, x + 12, y + 2, system_icon, background);
        text_x = x + 58;
    }
    usos.gui.text.draw(canvas, text_x, y + 10, value, 2, if (selected) theme.text else theme.muted);
}

fn drawDisabledListRow(canvas: usos.gui.Surface, x: u32, y: u32, width: u32, selected: bool, value: []const u8, icon: ?*const usos.gui.RgbaImage, reason: []const u8) void {
    canvas.fillRect(x, y, width, row_height - 6, theme.disabled);
    if (selected) canvas.fillRect(x, y, 5, row_height - 6, theme.border);
    var text_x = x + 18;
    if (icon) |system_icon| {
        drawRgbaIcon(canvas, x + 12, y + 2, system_icon, theme.disabled);
        text_x = x + 58;
    }
    usos.gui.text.draw(canvas, text_x, y + 10, value, 2, theme.muted);
    usos.gui.text.draw(canvas, text_x + usos.gui.text.width(value, 2) + 16, y + 10, reason, 1, theme.muted);
}

fn writeListRowConsole(item: ListRow, selected: bool) void {
    console.writeAscii(if (selected) "> " else "  ");
    switch (item) {
        .plain => |value| console.writeAscii(value),
        .parts => |parts| {
            console.writeAscii(parts.first);
            console.writeAscii(parts.second);
        },
        .disabled => |disabled| {
            console.writeAscii(disabled.value);
            console.writeAscii(" ");
            console.writeAscii(disabled.reason);
        },
        .system => |system| console.writeAscii(system.value),
        .system_disabled => |disabled| {
            console.writeAscii(disabled.value);
            console.writeAscii(" ");
            console.writeAscii(disabled.reason);
        },
    }
    console.writeAscii("\n");
}

fn redrawListHelp(canvas: usos.gui.Surface, screen: *const ListScreen, help: ?ListHelp) void {
    const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
    const x = panel_x + 18;
    const width = panel_width -| 36;
    const base_y = list_content_y + 22 + @as(u32, @intCast(screen.visibleCount())) * row_height;
    const y = base_y + 14;
    canvas.fillRect(x, y, width, 110, theme.panel);
    row_y = base_y;
    if (help) |box| helpBox(box.title, box.line1, box.line2, box.status);
}

fn listHelpEqual(a: ?ListHelp, b: ?ListHelp) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    return std.mem.eql(u8, left.title, right.title) and
        std.mem.eql(u8, left.line1, right.line1) and
        std.mem.eql(u8, left.line2, right.line2) and
        std.mem.eql(u8, left.status, right.status);
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
    drawFooter(back_enabled, true);
}

pub fn passiveFooter() void {
    invalidatePointer();
    drawFooter(false, false);
}

fn drawFooter(back_enabled: bool, pointer_enabled: bool) void {
    if (surface) |canvas| {
        const panel_width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
        const panel_x = (canvas.framebuffer.width -| panel_width) / 2;
        const y = canvas.framebuffer.height -| 48;
        const footer_text = if (active_footer.len > 0) active_footer else if (back_enabled) "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC/RIGHT CLICK - BACK" else "PLEASE WAIT";
        usos.gui.text.draw(canvas, panel_x, y, footer_text, 1, theme.muted);
        presentFullFrame();
        if (pointer_enabled) updatePointer();
    } else {
        console.writeAscii("\n");
        if (active_footer.len > 0) console.writeAscii(active_footer) else console.writeAscii(if (back_enabled) "Arrows - select, Enter - open, Esc - back" else "Please wait");
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

fn drawHeaderStatus(canvas: usos.gui.Surface, right_edge: u32) void {
    header_clock_right_edge = right_edge;
    const firmware_prefix = "FIRMWARE: ";
    const firmware_label = firmwareLabel();
    const mouse_prefix = "MOUSE: ";
    const mouse_label = pointer.backendLabel();
    const gap: u32 = 28;
    const firmware_width = usos.gui.text.width(firmware_prefix, 1) + usos.gui.text.width(firmware_label, 1);
    const mouse_width = usos.gui.text.width(mouse_prefix, 1) + usos.gui.text.width(mouse_label, 1);
    const total_width = firmware_width + gap + mouse_width;
    const x = right_edge -| total_width;

    usos.gui.text.draw(canvas, x, 34, firmware_prefix, 1, theme.muted);
    usos.gui.text.draw(canvas, x + usos.gui.text.width(firmware_prefix, 1), 34, firmware_label, 1, theme.accent);

    const mouse_x = x + firmware_width + gap;
    usos.gui.text.draw(canvas, mouse_x, 34, mouse_prefix, 1, theme.muted);
    usos.gui.text.draw(canvas, mouse_x + usos.gui.text.width(mouse_prefix, 1), 34, mouse_label, 1, if (pointer.available()) theme.accent else theme.muted);

    drawBuildId(canvas, right_edge);
    drawClock(canvas, right_edge, true);
}

fn drawBuildId(canvas: usos.gui.Surface, right_edge: u32) void {
    const prefix = "BUILD ";
    const id = usos.build_info.id;
    const clock_sample = "WEDNESDAY 00.00.0000 00:00";
    const gap: u32 = 28;
    const width = usos.gui.text.width(prefix, 1) + usos.gui.text.width(id, 1);
    const clock_width = usos.gui.text.width(clock_sample, 1);
    const x = right_edge -| clock_width -| gap -| width;
    usos.gui.text.draw(canvas, x, 58, prefix, 1, theme.muted);
    usos.gui.text.draw(canvas, x + usos.gui.text.width(prefix, 1), 58, id, 1, theme.accent);
}

fn drawPreparationHeader(canvas: usos.gui.Surface) void {
    const width = @min(max_panel_width, canvas.framebuffer.width -| (outer_margin * 2));
    const right = (canvas.framebuffer.width -| width) / 2 +| width;
    drawHeaderStatus(canvas, right);
}

pub fn updateClock() void {
    if (!header_clock_active) return;
    const canvas = surface orelse return;
    drawClock(canvas, header_clock_right_edge, false);
}

fn drawClock(canvas: usos.gui.Surface, right_edge: u32, force: bool) void {
    const result = std.os.uefi.system_table.runtime_services.getTime() catch return;
    const current = result[0];
    if (!force and last_clock_valid and
        current.year == last_clock_year and
        current.month == last_clock_month and
        current.day == last_clock_day and
        current.hour == last_clock_hour and
        current.minute == last_clock_minute)
    {
        return;
    }

    last_clock_valid = true;
    last_clock_year = current.year;
    last_clock_month = current.month;
    last_clock_day = current.day;
    last_clock_hour = current.hour;
    last_clock_minute = current.minute;

    var date_buffer: [20]u8 = undefined;
    var time_buffer: [5]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buffer, "{s} {d:0>2}.{d:0>2}.{d:0>4}", .{ usos.calendar.weekdayName(current.year, current.month, current.day), current.day, current.month, current.year }) catch return;
    const time = std.fmt.bufPrint(&time_buffer, "{d:0>2}:{d:0>2}", .{ current.hour, current.minute }) catch return;
    const separator = " ";
    const clock_width = usos.gui.text.width(date, 1) + usos.gui.text.width(separator, 1) + usos.gui.text.width(time, 1);
    const clock_x = right_edge -| clock_width;

    const had_cursor = cursor_saved;
    if (had_cursor) restorePointerBackground(canvas);
    canvas.fillRect(clock_x, 56, clock_width, 20, theme.background);
    usos.gui.text.draw(canvas, clock_x, 58, date, 1, theme.muted);
    usos.gui.text.draw(canvas, clock_x + usos.gui.text.width(date, 1), 58, separator, 1, theme.muted);
    usos.gui.text.draw(canvas, clock_x + usos.gui.text.width(date, 1) + usos.gui.text.width(separator, 1), 58, time, 1, theme.accent);
    if (had_cursor and pointer.available()) {
        savePointerBackground(canvas);
        drawPointer(canvas);
    }
}

const ClockText = struct {
    date: []const u8,
    time: []const u8,
};

fn readClock(date_buffer: *[20]u8, time_buffer: *[5]u8) ?ClockText {
    const result = std.os.uefi.system_table.runtime_services.getTime() catch return null;
    const current = result[0];
    const date = std.fmt.bufPrint(date_buffer, "{s} {d:0>2}.{d:0>2}.{d:0>4}", .{ usos.calendar.weekdayName(current.year, current.month, current.day), current.day, current.month, current.year }) catch return null;
    const time = std.fmt.bufPrint(time_buffer, "{d:0>2}:{d:0>2}", .{ current.hour, current.minute }) catch return null;
    return .{ .date = date, .time = time };
}

fn firmwareLabel() []const u8 {
    return if (runtime_firmware) |firmware| firmware.label() else "UNKNOWN";
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
