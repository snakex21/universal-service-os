//! UEFI boot menu view: draws the shared USOS screens (src/gui/menu_screens,
//! preparation_screen) into an off-screen buffer that is presented with one
//! GOP Blt, keeps the header clock current, tracks mouse hover and draws the
//! anti-aliased pointer. Strings come from \EFI\USOS\lang.bin (the language
//! chosen in the installer) with the built-in English as per-string fallback.
const std = @import("std");
const usos = @import("usos");
const console = @import("console.zig");
const file_read = @import("file_read.zig");
const input = @import("input.zig");
const pointer = @import("pointer.zig");

const gui = usos.gui;
const Ui = gui.ui.Ui;
const Row = gui.ui.Row;
const Hint = gui.ui.Hint;
const screens = gui.menu_screens;
pub const Key = usos.i18n.Key;

const css_capacity = 2048;

var css_buffer: [css_capacity]u8 = undefined;
var lang_buffer: [usos.i18n.max_blob_bytes]u8 = undefined;
var font_pack: ?gui.font.Pack = null;
var strings: usos.i18n.Table = usos.i18n.Table.english_only;
var theme = gui.Theme{};
var surface: ?gui.Surface = null;
var video_surface: ?gui.Surface = null;
var screen_buffer: ?gui.ScreenBuffer = null;
var screen_buffer_pool: ?[]align(8) u8 = null;
var graphics_output: ?*std.os.uefi.protocol.GraphicsOutput = null;
var full_frame_buffered = false;
var runtime_firmware: ?usos.firmware.Firmware = null;

var header_clock_active = false;
var last_clock_minute: u16 = 0xFFFF;

var sprite = gui.cursor.Sprite{};
var sprite_scale: u32 = 0;
var patch = gui.cursor.Patch{};

const Active = enum { none, home, list, summary };
var active: Active = .none;
var active_home: ?*Home = null;
var active_list: ?*ListScreen = null;
var summary_button: gui.ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var summary_spec: screens.SummarySpec = undefined;

pub fn init(root: *std.os.uefi.protocol.File, info: usos.boot_info.BootInfo) void {
    if (file_read.into(root, "\\UI\\theme.css", &css_buffer)) |css| theme = gui.Theme.parse(css);
    font_pack = gui.font.Pack.parse(gui.font_pack) catch null;
    const coverage: ?usos.i18n.Coverage = if (font_pack) |*pack| .{ .context = @ptrCast(pack), .has = gui.font.coverageHas } else null;
    strings = usos.i18n.Table.parseOrEnglish(file_read.into(root, usos.i18n.path, &lang_buffer), coverage);

    runtime_firmware = info.firmware;
    input.setIdleHook(updateClock);
    if (info.framebuffer) |framebuffer| video_surface = gui.Surface.init(framebuffer);
    surface = video_surface;

    if (video_surface) |canvas| {
        pointer.init(canvas.framebuffer.width, canvas.framebuffer.height);
        if (std.os.uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
        initScreenBuffer(canvas);
    }
}

/// The string table (for screens that format their own text).
pub fn t(key: Key) []const u8 {
    return strings.get(key);
}

pub fn format(buffer: []u8, key: Key, args: []const []const u8) []const u8 {
    return strings.format(buffer, key, args);
}

/// Translates an English catalog value (labels from shared catalog code).
pub fn tr(english: []const u8) []const u8 {
    return strings.lookup(english);
}

pub fn trFormat(buffer: []u8, english: []const u8) []const u8 {
    return strings.translate(buffer, english);
}

pub fn isGraphical() bool {
    return surface != null;
}

fn initScreenBuffer(canvas: gui.Surface) void {
    const boot_services = std.os.uefi.system_table.boot_services orelse return;
    const GraphicsOutput = std.os.uefi.protocol.GraphicsOutput;
    graphics_output = boot_services.locateProtocol(GraphicsOutput, null) catch null;
    const needed = gui.ScreenBuffer.requiredBytes(canvas.framebuffer.width, canvas.framebuffer.height) orelse return;
    const pool = boot_services.allocatePool(.boot_services_data, needed) catch return;
    const buffer = gui.ScreenBuffer.init(@intFromPtr(pool.ptr), pool.len, canvas.framebuffer.width, canvas.framebuffer.height, .bgrx8) orelse {
        boot_services.freePool(pool.ptr) catch {};
        return;
    };
    screen_buffer_pool = pool;
    screen_buffer = buffer;
}

// An EFI application may return after changing the GOP mode. Discard every
// cached pixel address/stride before drawing the error or the menu again.
pub fn refreshFramebuffer() void {
    patch.saved = false;
    header_clock_active = false;
    active = .none;
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
    const canvas = gui.Surface.init(framebuffer) orelse return;
    video_surface = canvas;
    surface = canvas;
    pointer.init(framebuffer.width, framebuffer.height);
    initScreenBuffer(canvas);
}

fn ui() ?Ui {
    const canvas = surface orelse return null;
    return Ui.init(canvas, theme, if (font_pack) |*pack| pack else null, &strings);
}

fn headerInfo(clock_buffer: []u8, u: *const Ui) gui.ui.HeaderInfo {
    return .{
        .firmware = if (runtime_firmware) |firmware| firmware.label() else "",
        .build = usos.build_info.id,
        .language = t(.language_name),
        .clock = clockNow(clock_buffer, u),
    };
}

fn clockNow(buffer: []u8, u: *const Ui) []const u8 {
    const result = std.os.uefi.system_table.runtime_services.getTime() catch return "";
    const now = result[0];
    last_clock_minute = @as(u16, now.hour) * 60 + now.minute;
    return gui.ui.clockText(u, buffer, .{ .year = now.year, .month = now.month, .day = now.day, .hour = now.hour, .minute = now.minute });
}

fn beginFullFrame() void {
    patch.saved = false;
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

/// Partial redraw on the visible surface: hide the pointer, draw, show it.
fn beginPartial() ?Ui {
    const canvas = surface orelse return null;
    hidePointer(canvas);
    return ui();
}

fn endPartial() void {
    showPointer();
}

// ------------------------------------------------------------------ hints

fn listHints(buffer: *[3]Hint) []const Hint {
    buffer.* = .{
        .{ .key = "\u{2191}\u{2193}", .label = t(.key_select) },
        .{ .key = "Enter", .label = t(.key_open) },
        .{ .key = "Esc", .label = t(.key_back) },
    };
    return buffer;
}

fn dismissHints(buffer: *[1]Hint) []const Hint {
    buffer.* = .{.{ .key = "Esc", .label = t(.key_back) }};
    return buffer;
}

// ------------------------------------------------------------------ home

pub const Home = struct {
    items: []const screens.HomeItem,
    selected: usize,
    hover: ?usize = null,

    pub fn open(self: *Home, items: []const screens.HomeItem, selected: usize) void {
        self.* = .{ .items = items, .selected = selected };
        self.redraw();
    }

    pub fn redraw(self: *Home) void {
        active = .home;
        active_home = self;
        header_clock_active = true;
        beginFullFrame();
        var u = ui() orelse return self.console();
        var clock: [48]u8 = undefined;
        const hints = [_]Hint{
            .{ .key = "\u{2191}\u{2193}\u{2190}\u{2192}", .label = t(.key_select) },
            .{ .key = "Enter", .label = t(.key_open) },
            .{ .key = "Esc", .label = t(.key_power) },
        };
        screens.home(&u, headerInfo(&clock, &u), self.items, self.selected, self.hover, &hints);
        presentFullFrame();
        showPointer();
    }

    fn console(self: *Home) void {
        console_clear(t(.menu_title));
        for (self.items, 0..) |item, index| {
            consoleLine(if (index == self.selected) "> " else "  ", item.title, item.description);
        }
    }

    pub fn select(self: *Home, index: usize) void {
        if (index == self.selected or index >= self.items.len) return;
        const previous = self.selected;
        self.selected = index;
        if (surface == null) return self.redraw();
        var u = beginPartial() orelse return;
        screens.homeItem(&u, self.items, previous, screens.stateOf(previous, self.selected, self.hover));
        screens.homeItem(&u, self.items, index, .selected);
        endPartial();
    }

    pub fn hit(self: *const Home, x: u32, y: u32) ?usize {
        var u = ui() orelse return null;
        return screens.homeHit(&u, self.items.len, x, y);
    }

    fn setHover(self: *Home, index: ?usize) void {
        if (std.meta.eql(index, self.hover)) return;
        const previous = self.hover;
        self.hover = index;
        var u = ui() orelse return;
        if (previous) |value| screens.homeItem(&u, self.items, value, screens.stateOf(value, self.selected, self.hover));
        if (index) |value| screens.homeItem(&u, self.items, value, screens.stateOf(value, self.selected, self.hover));
    }
};

// ------------------------------------------------------------------ lists

pub const ListScreen = struct {
    spec: screens.ListSpec,
    geometry: screens.ListGeometry = undefined,
    first: usize = 0,
    hint_storage: [3]Hint = undefined,

    /// Opens a list in place (the view keeps a pointer for hover handling).
    pub fn open(self: *ListScreen, title: []const u8, subtitle: []const u8, rows: []const Row, selected: usize, two_line: bool, help: ?screens.Help) void {
        self.* = .{ .spec = .{ .title = title, .subtitle = subtitle, .rows = rows, .selected = selected, .two_line = two_line, .help = help } };
        self.spec.hints = listHints(&self.hint_storage);
        self.redrawFull(selected, help);
    }

    pub fn visibleStart(self: *const ListScreen) usize {
        return self.first;
    }

    pub fn visibleCount(self: *const ListScreen) usize {
        if (surface == null) return self.spec.rows.len;
        return @min(self.geometry.list.visible, self.spec.rows.len -| self.first);
    }

    pub fn redrawFull(self: *ListScreen, selected: usize, help: ?screens.Help) void {
        active = .list;
        active_list = self;
        header_clock_active = true;
        self.spec.selected = selected;
        self.spec.help = help;
        self.spec.hints = listHints(&self.hint_storage);
        beginFullFrame();
        var u = ui() orelse return self.console();
        var clock: [48]u8 = undefined;
        self.geometry = screens.listScreen(&u, headerInfo(&clock, &u), self.spec, self.first);
        self.first = self.geometry.first;
        presentFullFrame();
        showPointer();
    }

    fn console(self: *ListScreen) void {
        console_clear(self.spec.title);
        for (self.spec.rows, 0..) |row, index| consoleLine(if (index == self.spec.selected) "> " else "  ", row.title, row.detail);
        if (self.spec.help) |help| {
            consoleLine("", help.title, "");
            for (help.lines) |line| consoleLine("  ", line, "");
        }
    }

    pub fn updateSelection(self: *ListScreen, selected: usize, help: ?screens.Help) void {
        if (selected >= self.spec.rows.len) return;
        if (surface == null) return self.redrawFull(selected, help);
        const previous = self.spec.selected;
        self.spec.selected = selected;
        self.spec.help = help;
        var u = beginPartial() orelse return;
        const first = screens.firstVisible(selected, self.spec.rows.len, self.geometry.list.visible, self.first);
        if (first != self.first) {
            self.first = first;
            self.geometry.first = first;
            screens.drawRows(&u, self.geometry, self.spec);
        } else {
            screens.drawRow(&u, self.geometry, self.spec, previous);
            screens.drawRow(&u, self.geometry, self.spec, selected);
        }
        if (self.geometry.help) |rect| {
            if (help) |value| screens.drawHelp(&u, rect, value);
        }
        endPartial();
    }

    fn setHover(self: *ListScreen, index: ?usize) void {
        if (std.meta.eql(index, self.spec.hover)) return;
        const previous = self.spec.hover;
        self.spec.hover = index;
        var u = ui() orelse return;
        if (previous) |value| screens.drawRow(&u, self.geometry, self.spec, value);
        if (index) |value| screens.drawRow(&u, self.geometry, self.spec, value);
    }
};

/// Visible row index under the pointer on the active list screen.
pub fn hitRow(x: u32, y: u32, visible_count: usize) ?usize {
    const list = active_list orelse return null;
    if (active != .list or surface == null) return null;
    _ = visible_count;
    const index = screens.listHit(list.geometry, list.spec.rows.len, x, y) orelse return null;
    return index - list.first;
}

pub fn hitCategoryCard(x: u32, y: u32) ?usize {
    const home = active_home orelse return null;
    if (active != .home) return null;
    return home.hit(x, y);
}

// ------------------------------------------------------------------ notices

pub const NoticeLines = []const []const u8;

/// A notice the user dismisses with Enter/Esc/click.
pub fn notice(title: []const u8, icon: gui.icons.Kind, tone: gui.ui.Tone, heading: []const u8, lines: NoticeLines) void {
    var hints: [1]Hint = undefined;
    drawNotice(title, icon, tone, heading, lines, dismissHints(&hints), true);
}

/// A passive status (no input expected, no pointer).
pub fn status(title: []const u8, heading: []const u8, lines: NoticeLines) void {
    const hints = [_]Hint{};
    drawNotice(title, .info, .neutral, heading, lines, &hints, false);
}

fn drawNotice(title: []const u8, icon: gui.icons.Kind, tone: gui.ui.Tone, heading: []const u8, lines: NoticeLines, hints: []const Hint, interactive: bool) void {
    active = .none;
    header_clock_active = true;
    beginFullFrame();
    var u = ui() orelse {
        console_clear(title);
        if (heading.len > 0) consoleLine("", heading, "");
        for (lines) |line| consoleLine("", line, "");
        return;
    };
    var clock: [48]u8 = undefined;
    screens.notice(&u, headerInfo(&clock, &u), .{ .title = title, .icon = icon, .tone = tone, .heading = heading, .lines = lines, .hints = if (interactive) hints else &.{} });
    presentFullFrame();
    if (interactive) showPointer();
}

/// Blocks until Enter, Esc or a mouse click.
pub fn waitForDismiss() void {
    while (true) switch (input.readBlocking()) {
        .enter, .back => return,
        .pointer => |mouse| {
            if (mouse.left_click or mouse.right_click) return;
            if (mouse.moved) updatePointer();
        },
        else => {},
    };
}

// ------------------------------------------------------------------ summary

pub fn summary(spec: screens.SummarySpec) void {
    active = .summary;
    header_clock_active = true;
    summary_spec = spec;
    var hints: [2]Hint = .{
        .{ .key = "Enter", .label = t(.key_start) },
        .{ .key = "Esc", .label = t(.key_back) },
    };
    summary_spec.hints = if (spec.action_enabled) &hints else hints[1..];
    beginFullFrame();
    var u = ui() orelse {
        console_clear(spec.title);
        for (spec.labels, spec.values) |label, value| consoleLine("", label, value);
        for (spec.notes) |note| consoleLine("! ", note, "");
        consoleLine("> ", spec.action, "");
        return;
    };
    var clock: [48]u8 = undefined;
    summary_button = screens.summary(&u, headerInfo(&clock, &u), summary_spec);
    summary_spec.hints = &.{};
    presentFullFrame();
    showPointer();
}

pub fn hitSummaryButton(x: u32, y: u32) bool {
    return active == .summary and surface != null and summary_button.contains(x, y);
}

// ------------------------------------------------------------------ progress

pub fn windowsIsoStatus(stage: usos.flow.preparation_boot_progress.DirectIsoStage, detail: []const u8) void {
    const Stage = usos.flow.preparation_boot_progress.DirectIsoStage;
    progress(.{
        .mode = .stage,
        .current = stage.number(),
        .total = Stage.labels.len,
        .labels = &Stage.labels,
        .heading = "Starting Windows from ISO",
        .title = Stage.labels[stage.number() - 1],
        .detail = detail,
    });
}

pub fn handoffStatus(detail: []const u8) void {
    progress(.{ .mode = .stage, .current = 1, .total = 5, .title = "Starting environment", .detail = detail });
}

fn progress(state: gui.preparation_screen.State) void {
    active = .none;
    header_clock_active = true;
    beginFullFrame();
    var u = ui() orelse {
        var buffer: [256]u8 = undefined;
        console_clear(if (state.heading.len > 0) trFormat(&buffer, state.heading) else t(.prep_title));
        for (state.labels[0..gui.preparation_screen.stageCount(state)], 1..) |label, index| {
            consoleLine(if (index < state.current) "[OK] " else if (index == state.current) "[..] " else "[  ] ", tr(label), "");
        }
        consoleLine("", trFormat(&buffer, state.detail), "");
        return;
    };
    var clock: [48]u8 = undefined;
    gui.preparation_screen.render(&u, state, headerInfo(&clock, &u));
    presentFullFrame();
}

// ------------------------------------------------------------------ clock

pub fn updateClock() void {
    if (!header_clock_active) return;
    const canvas = surface orelse return;
    const result = std.os.uefi.system_table.runtime_services.getTime() catch return;
    const minute = @as(u16, result[0].hour) * 60 + result[0].minute;
    if (minute == last_clock_minute) return;
    var u = ui() orelse return;
    var buffer: [48]u8 = undefined;
    const info = headerInfo(&buffer, &u);
    const pos = pointer.position();
    const covers = patch.saved and pos.y < u.headerHeight();
    if (covers) hidePointer(canvas);
    u.headerClockAt(u.headerClockRight(info), info.clock);
    if (covers) showPointer();
}

// ------------------------------------------------------------------ pointer

/// Moves the pointer to its current position and updates hover highlight.
pub fn updatePointer() void {
    const canvas = surface orelse return;
    if (!pointer.available()) return;
    hidePointer(canvas);
    const pos = pointer.position();
    switch (active) {
        .home => if (active_home) |home| home.setHover(home.hit(pos.x, pos.y)),
        .list => if (active_list) |list| {
            const hit = screens.listHit(list.geometry, list.spec.rows.len, pos.x, pos.y);
            list.setHover(if (hit) |index| (if (index != list.spec.selected and list.spec.rows[index].enabled) index else null) else null);
        },
        .summary => {
            const hover = summary_button.contains(pos.x, pos.y) and summary_spec.action_enabled;
            if (hover != summary_spec.action_hover) {
                summary_spec.action_hover = hover;
                var u = ui() orelse return;
                screens.summaryButton(&u, summary_button, summary_spec);
            }
        },
        .none => {},
    }
    showPointer();
}

fn hidePointer(canvas: gui.Surface) void {
    patch.restore(canvas);
}

fn showPointer() void {
    const canvas = surface orelse return;
    if (!pointer.available() or full_frame_buffered) return;
    var u = ui() orelse return;
    const scale = u.fonts.scale.twice();
    if (scale != sprite_scale) {
        sprite.build(scale);
        sprite_scale = scale;
    }
    const pos = pointer.position();
    patch.save(canvas, pos.x, pos.y, sprite.width, sprite.height);
    sprite.draw(canvas, pos.x, pos.y, &patch.pixels);
}

pub fn passiveFooter() void {
    patch.saved = false;
}

// ------------------------------------------------------------------ console

fn console_clear(title: []const u8) void {
    console.clear();
    console.writeAscii("Universal Service OS\n");
    console.writeUtf8(title);
    console.writeAscii("\n\n");
}

fn consoleLine(prefix: []const u8, first: []const u8, second: []const u8) void {
    console.writeAscii(prefix);
    console.writeUtf8(first);
    if (second.len > 0) {
        console.writeAscii(" - ");
        console.writeUtf8(second);
    }
    console.writeAscii("\n");
}
