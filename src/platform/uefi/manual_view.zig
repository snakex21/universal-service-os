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
const input_report = @import("input_report.zig");
const pointer = @import("pointer.zig");
const usb_gamepad = @import("usb_gamepad.zig");
const serial = @import("serial.zig");
const boot_timing = @import("boot_timing.zig");
const splash = @import("splash.zig");
const touch_driver = @import("touch_driver.zig");
const uefi_drivers = @import("uefi_drivers.zig");
const acpi_dump = @import("acpi_dump.zig");

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

// Flicker-free presentation (src/gui/compositor.zig): every screen is drawn
// into the back buffer, the pointer is composited per dirty rectangle and
// each rectangle reaches the screen in one GOP Blt. Without the three
// buffers (allocation failed) the menu draws straight to the framebuffer
// with the saved-patch pointer as before.
var presenter: ?gui.compositor.Presenter = null;
var front_pool: ?[]align(8) u8 = null;
var scratch_pool: ?[]align(8) u8 = null;
var pointer_visible = false;
var pointer_pending = false;
var last_pointer_present: u64 = 0;
/// Pointer-driven redraws are limited to about 60 per second.
const pointer_frame_ms: u64 = 16;

const Active = enum { none, home, list, summary };
var active: Active = .none;
var active_home: ?*Home = null;
var active_list: ?*ListScreen = null;
var summary_button: gui.ui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var summary_spec: screens.SummarySpec = undefined;
// Footer hints of the screen on display: tapping one acts like its key.
var footer_hints: []const Hint = &.{};
var footer_note: []const u8 = "";
var home_hints: [3]Hint = undefined;
var summary_hints: [2]Hint = undefined;
var notice_hints: [1]Hint = undefined;
var boot_root: ?*std.os.uefi.protocol.File = null;
var timing_reported = false;

/// Reads EFI\USOS\usos-settings.ini (empty when missing) into the shared
/// settings store. Read before the splash so `boot_logo=` can choose the logo.
pub fn readSettings(root: *std.os.uefi.protocol.File) []const u8 {
    return @import("settings_store.zig").load(root);
}

/// Loads the theme, font and language and prepares the screen. The splash
/// (splash.begin) is already on screen; it switches to the chosen language
/// as soon as lang.bin is parsed.
pub fn init(root: *std.os.uefi.protocol.File, info: usos.boot_info.BootInfo, settings: []const u8) void {
    boot_root = root;
    font_pack = if (splash.fontPack()) |pack| pack.* else (gui.font.Pack.parse(gui.font_pack) catch null);
    const coverage: ?usos.i18n.Coverage = if (font_pack) |*pack| .{ .context = @ptrCast(pack), .has = gui.font.coverageHas } else null;
    strings = usos.i18n.Table.parseOrEnglish(file_read.into(root, usos.i18n.path, &lang_buffer), coverage);
    boot_timing.mark("lang.bin read and parsed");
    splash.setStrings(&strings);
    splash.status(t(.splash_loading));
    if (file_read.into(root, "\\UI\\theme.css", &css_buffer)) |css| theme = gui.Theme.parse(css);
    boot_timing.mark("theme.css read");

    runtime_firmware = info.firmware;
    input.setIdleHook(idle);
    input.setHintHook(hintAt);
    input.setModeHook(inputModeChanged);
    input.setFrameHook(flushPointer);
    pointer.configure(parseSettings(settings));
    // The handheld touch driver installs its AbsolutePointer at entry, so it
    // starts before the pointer layer enumerates (and never blocks the menu).
    touch_driver.start(root, settings);
    boot_timing.mark("touch driver checked");
    // User drivers from DATA\Drivers\UEFI (after the built-in one, before
    // the pointer layer and the DATA catalog enumerate devices).
    uefi_drivers.start(root);
    boot_timing.mark("user UEFI drivers checked");
    if (info.framebuffer) |framebuffer| video_surface = gui.Surface.init(framebuffer);
    surface = video_surface;

    if (video_surface) |canvas| {
        pointer.init(canvas.framebuffer.width, canvas.framebuffer.height);
        boot_timing.mark("pointer devices initialised");
        if (std.os.uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
        initScreenBuffer(canvas);
        boot_timing.mark("off-screen buffer allocated");
    }
}

/// Work that must not delay the first menu frame: the input-devices report
/// (a file write plus several KiB on the serial port, ~50 ms in QEMU and far
/// more on a board whose UART runs at 115200 baud) and the timing log.
fn afterFirstFrame() void {
    const root = boot_root orelse return;
    const serial_before = serial.bytes_written;
    // ACPI tables (DSDT/SSDTs) once per machine, for touch/I2C bring-up.
    acpi_dump.write(root);
    boot_timing.mark("ACPI dump checked");
    uefi_drivers.writeReport(root);
    boot_timing.mark("drivers.txt written");
    // One report per boot of what the firmware exposes as input devices
    // (EFI\USOS\Logs\input-devices.txt), for touch/gamepad bring-up.
    input_report.write(root, if (video_surface) |canvas| canvas.framebuffer.width else 0, if (video_surface) |canvas| canvas.framebuffer.height else 0);
    boot_timing.mark("input-devices.txt written (after the menu)");
    boot_timing.report(root, "boot-timing.txt", serial_before);
}

/// Replaces the screen with the "Starting…" splash before a handover to
/// another loader; the spinner turns while that loader reads its files.
pub fn handover(text: []const u8) void {
    input.stopGamepads();
    patch.saved = false;
    header_clock_active = false;
    active = .none;
    setFooter(&.{}, "");
    pointer_visible = false;
    if (presenter) |*p| p.invalidate();
    const canvas = video_surface orelse return console_clear(text);
    splash.handover(canvas.framebuffer, text);
}

/// Handover status line (shown only once the spinner runs, so quick
/// steps do not flicker).
pub fn handoverStatus(text: []const u8) void {
    splash.status(text);
}

/// Input options from usos-settings.ini (written by the installer; these
/// keys are optional and may be added by hand):
///   wheel_invert=1               reverse the mouse wheel
///   touch_rotation=0|90|180|270  touch panel rotation (default: automatic)
///   touch_driver=auto|off        handheld I2C touch driver (touch_driver.zig)
pub fn parseSettings(text: []const u8) pointer.Settings {
    var result = pointer.Settings{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "wheel_invert")) {
            result.wheel_invert = std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
        } else if (std.ascii.eqlIgnoreCase(key, "touch_rotation")) {
            const degrees = std.fmt.parseInt(u16, value, 10) catch continue;
            if (degrees == 0 or degrees == 90 or degrees == 180 or degrees == 270) result.touch_rotation = degrees;
        }
    }
    return result;
}

fn setFooter(hints: []const Hint, note: []const u8) void {
    footer_hints = hints;
    footer_note = note;
}

/// A tap or click on a footer hint acts like pressing its key.
fn hintAt(x: u32, y: u32) ?input.Event {
    if (footer_hints.len == 0) return null;
    var u = ui() orelse return null;
    const index = u.footerHit(footer_hints, footer_note, x, y) orelse return null;
    const key = footer_hints[index].key;
    if (std.mem.eql(u8, key, "Enter") or std.mem.eql(u8, key, "A")) return .enter;
    if (std.mem.eql(u8, key, "Esc") or std.mem.eql(u8, key, "B")) return .back;
    return null;
}

/// Idle work (~every 0.5 s while waiting for input): the header clock, and
/// a fresh input-devices.txt when a USB gamepad was plugged in or removed.
fn idle() void {
    updateClock();
    if (!timing_reported) return;
    // A touch driver's panel came up (placeholder range -> panel range):
    // the report then shows the live range.
    const touch_changed = pointer.takeMappingChanged();
    if (!usb_gamepad.takeChanged() and !touch_changed) return;
    const root = boot_root orelse return;
    input_report.write(root, if (video_surface) |canvas| canvas.framebuffer.width else 0, if (video_surface) |canvas| canvas.framebuffer.height else 0);
}

/// The last input switched between a USB gamepad and keyboard/pointer:
/// redraw the screen so the footer names A/B or Enter/Esc.
fn inputModeChanged() void {
    switch (active) {
        .home => if (active_home) |home| home.redraw(),
        .list => if (active_list) |list| list.redrawFull(list.spec.selected, list.spec.help),
        .summary => summary(summary_spec),
        // Notices and the input test build their hints on the next draw.
        .none => {},
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

    const front_bytes = boot_services.allocatePool(.boot_services_data, needed) catch return;
    const scratch_bytes = boot_services.allocatePool(.boot_services_data, needed) catch {
        boot_services.freePool(front_bytes.ptr) catch {};
        return;
    };
    const front = gui.ScreenBuffer.init(@intFromPtr(front_bytes.ptr), front_bytes.len, canvas.framebuffer.width, canvas.framebuffer.height, .bgrx8) orelse {
        boot_services.freePool(front_bytes.ptr) catch {};
        boot_services.freePool(scratch_bytes.ptr) catch {};
        return;
    };
    front_pool = front_bytes;
    scratch_pool = scratch_bytes;
    const scratch: [*]u32 = @ptrCast(scratch_bytes.ptr);
    presenter = .{ .back = buffer.surface, .front = front.surface, .scratch = scratch[0 .. needed / 4] };
    surface = buffer.surface;
}

fn releaseBuffers() void {
    presenter = null;
    const bs = std.os.uefi.system_table.boot_services orelse return;
    inline for (.{ &screen_buffer_pool, &front_pool, &scratch_pool }) |slot| {
        if (slot.*) |pool| bs.freePool(pool.ptr) catch {};
        slot.* = null;
    }
}

fn bltSink() gui.compositor.Sink {
    return .{ .context = undefined, .write = bltRect };
}

fn bltRect(_: *anyopaque, rect: gui.compositor.Rect, pixels: []const u32) void {
    const GraphicsOutput = std.os.uefi.protocol.GraphicsOutput;
    if (graphics_output) |graphics| {
        const source: [*]GraphicsOutput.BltPixel = @ptrCast(@constCast(pixels.ptr));
        if (graphics.blt(source, .blt_buffer_to_video, 0, 0, rect.x, rect.y, rect.w, rect.h, @as(usize, rect.w) * @sizeOf(GraphicsOutput.BltPixel))) |_| return else |_| {}
    }
    // No Blt: row copies into the linear framebuffer (format converted).
    const video = video_surface orelse return;
    const back = (presenter orelse return).back;
    var row: u32 = 0;
    while (row < rect.h) : (row += 1) {
        var column: u32 = 0;
        while (column < rect.w) : (column += 1) {
            video.setPixel(rect.x + column, rect.y + row, back.unpackColor(pixels[@as(usize, row) * rect.w + column]));
        }
    }
}

/// Sends the back buffer's changes and the pointer to the screen.
fn present() void {
    const p = if (presenter) |*value| value else return;
    p.pointer = if (pointer_visible and pointer.available()) pointerSprite() else null;
    p.present(bltSink());
}

fn pointerSprite() ?gui.compositor.Pointer {
    var u = ui() orelse return null;
    const scale = u.fonts.scale.twice();
    if (scale != sprite_scale) {
        sprite.build(scale);
        sprite_scale = scale;
    }
    const pos = pointer.position();
    return .{ .sprite = &sprite, .x = pos.x, .y = pos.y };
}

// An EFI application may return after changing the GOP mode. Discard every
// cached pixel address/stride before drawing the error or the menu again.
pub fn refreshFramebuffer() void {
    patch.saved = false;
    header_clock_active = false;
    active = .none;
    setFooter(&.{}, "");
    surface = null;
    video_surface = null;
    screen_buffer = null;
    graphics_output = null;
    full_frame_buffered = false;
    pointer_visible = false;
    releaseBuffers();
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
    // The first full frame (menu, resume status or error) replaces the splash.
    splash.end();
    if (presenter) |*p| {
        // Something else may have drawn on the screen (splash, an EFI
        // application): send the whole next frame.
        p.invalidate();
        surface = p.back;
        return;
    }
    patch.saved = false;
    surface = video_surface;
    full_frame_buffered = false;
    if (screen_buffer) |buffer| {
        surface = buffer.surface;
        full_frame_buffered = true;
    }
}

fn presentFullFrame(interactive: bool) void {
    if (presenter != null) {
        pointer_visible = interactive;
        present();
        firstFrameDone();
        return;
    }
    presentDirect();
    if (interactive) showPointer();
}

fn firstFrameDone() void {
    if (!timing_reported) {
        timing_reported = true;
        boot_timing.mark("first frame presented");
        afterFirstFrame();
    }
}

fn presentDirect() void {
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
    firstFrameDone();
}

/// Partial redraw on the visible surface: hide the pointer, draw, show it.
fn beginPartial() ?Ui {
    const canvas = surface orelse return null;
    if (presenter == null) hidePointer(canvas);
    return ui();
}

fn endPartial() void {
    if (presenter != null) return present();
    showPointer();
}

// ------------------------------------------------------------------ hints

fn listHints(buffer: *[3]Hint) []const Hint {
    buffer.* = .{
        .{ .key = input.moveKey("\u{2191}\u{2193}"), .label = t(.key_select) },
        .{ .key = input.enterKey(), .label = t(.key_open) },
        .{ .key = input.backKey(), .label = t(.key_back) },
    };
    return buffer;
}

fn dismissHints(buffer: *[1]Hint) []const Hint {
    buffer.* = .{.{ .key = input.backKey(), .label = t(.key_back) }};
    return buffer;
}

// ------------------------------------------------------------------ home

pub const Home = struct {
    items: []const screens.HomeItem,
    selected: usize,
    hover: ?usize = null,
    /// Optional offer strip under the cards (index items.len when shown):
    /// message and its action label.
    banner: ?[2][]const u8 = null,

    pub fn open(self: *Home, items: []const screens.HomeItem, selected: usize, banner: ?[2][]const u8) void {
        self.* = .{ .items = items, .selected = selected, .banner = banner };
        self.redraw();
    }

    /// Number of selectable things: the cards plus the banner when it fits.
    pub fn count(self: *const Home) usize {
        return self.items.len + @intFromBool(self.bannerShown());
    }

    pub fn bannerShown(self: *const Home) bool {
        if (self.banner == null) return false;
        var u = ui() orelse return true; // console: listed as a line
        return screens.homeBannerRect(&u, self.items.len) != null;
    }

    pub fn setBanner(self: *Home, banner: ?[2][]const u8) void {
        self.banner = banner;
        if (self.selected >= self.count()) self.selected = 0;
        self.redraw();
    }

    pub fn redraw(self: *Home) void {
        active = .home;
        active_home = self;
        header_clock_active = true;
        beginFullFrame();
        var u = ui() orelse return self.console();
        var clock: [48]u8 = undefined;
        home_hints = .{
            .{ .key = input.moveKey("\u{2191}\u{2193}\u{2190}\u{2192}"), .label = t(.key_select) },
            .{ .key = input.enterKey(), .label = t(.key_open) },
            .{ .key = input.backKey(), .label = t(.key_power) },
        };
        setFooter(&home_hints, "");
        screens.home(&u, headerInfo(&clock, &u), self.items, self.selected, self.hover, &home_hints);
        self.drawBanner(&u);
        presentFullFrame(true);
    }

    fn drawBanner(self: *const Home, u: *const gui.ui.Ui) void {
        const banner = self.banner orelse return;
        screens.homeBanner(u, self.items.len, banner[0], banner[1], screens.stateOf(self.items.len, self.selected, self.hover));
    }

    fn console(self: *Home) void {
        console_clear(t(.menu_title));
        for (self.items, 0..) |item, index| {
            consoleLine(if (index == self.selected) "> " else "  ", item.title, item.description);
        }
        if (self.banner) |banner| consoleLine(if (self.selected == self.items.len) "> " else "  ", banner[0], banner[1]);
    }

    fn drawEntry(self: *const Home, u: *const gui.ui.Ui, index: usize) void {
        if (index == self.items.len) return self.drawBanner(u);
        screens.homeItem(u, self.items, index, screens.stateOf(index, self.selected, self.hover));
    }

    pub fn select(self: *Home, index: usize) void {
        if (index == self.selected or index >= self.count()) return;
        const previous = self.selected;
        self.selected = index;
        if (surface == null) return self.redraw();
        var u = beginPartial() orelse return;
        self.drawEntry(&u, previous);
        self.drawEntry(&u, index);
        endPartial();
    }

    pub fn hit(self: *const Home, x: u32, y: u32) ?usize {
        var u = ui() orelse return null;
        if (screens.homeHit(&u, self.items.len, x, y)) |index| return index;
        if (self.banner != null) {
            if (screens.homeBannerRect(&u, self.items.len)) |rect| {
                if (rect.contains(x, y)) return self.items.len;
            }
        }
        return null;
    }

    fn setHover(self: *Home, index: ?usize) void {
        if (std.meta.eql(index, self.hover)) return;
        const previous = self.hover;
        self.hover = index;
        var u = ui() orelse return;
        if (previous) |value| self.drawEntry(&u, value);
        if (index) |value| self.drawEntry(&u, value);
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
        setFooter(self.spec.hints, self.spec.note);
        self.geometry = screens.listScreen(&u, headerInfo(&clock, &u), self.spec, self.first);
        self.first = self.geometry.first;
        self.trace();
        presentFullFrame(true);
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
        defer self.trace();
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

    /// More rows than fit: the wheel and drags scroll the view.
    pub fn overflows(self: *const ListScreen) bool {
        return surface != null and self.spec.rows.len > self.geometry.list.visible;
    }

    /// Vertical distance between rows, for drag-to-scroll.
    pub fn rowPitch(self: *const ListScreen) u32 {
        return self.geometry.list.row_step;
    }

    /// Scrolls the view by `delta` rows (positive = further down the list)
    /// and keeps the selection on a visible, selectable row. Returns the
    /// selection after scrolling; the rows are already redrawn.
    pub fn scrollBy(self: *ListScreen, delta: i32, selectable: ?[]const bool) usize {
        if (!self.overflows()) return self.spec.selected;
        const count = self.spec.rows.len;
        const visible = self.geometry.list.visible;
        const first = gui.input_map.scrollFirst(self.first, delta, count, visible);
        if (first == self.first) return self.spec.selected;
        self.first = first;
        self.geometry.first = first;
        self.spec.selected = gui.input_map.clampSelection(self.spec.selected, first, visible, count, selectable);
        self.spec.hover = null;
        defer self.trace();
        var u = beginPartial() orelse return self.spec.selected;
        screens.drawRows(&u, self.geometry, self.spec);
        endPartial();
        return self.spec.selected;
    }

    /// Serial trace of the list state (QEMU input tests read it).
    fn trace(self: *const ListScreen) void {
        var buffer: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "[UI_LIST] first={d} selected={d} visible={d} rows={d}\n", .{ self.first, self.spec.selected, self.geometry.list.visible, self.spec.rows.len }) catch return;
        serial.writeAscii(line);
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
    drawNotice(title, icon, tone, heading, lines, dismissHints(&notice_hints), true);
}

/// A passive status (no input expected, no pointer).
pub fn status(title: []const u8, heading: []const u8, lines: NoticeLines) void {
    const hints = [_]Hint{};
    drawNotice(title, .info, .neutral, heading, lines, &hints, false);
}

fn drawNotice(title: []const u8, icon: gui.icons.Kind, tone: gui.ui.Tone, heading: []const u8, lines: NoticeLines, hints: []const Hint, interactive: bool) void {
    active = .none;
    header_clock_active = true;
    setFooter(if (interactive) hints else &.{}, "");
    beginFullFrame();
    var u = ui() orelse {
        console_clear(title);
        if (heading.len > 0) consoleLine("", heading, "");
        for (lines) |line| consoleLine("", line, "");
        return;
    };
    var clock: [48]u8 = undefined;
    screens.notice(&u, headerInfo(&clock, &u), .{ .title = title, .icon = icon, .tone = tone, .heading = heading, .lines = lines, .hints = if (interactive) hints else &.{} });
    presentFullFrame(interactive);
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
    summary_hints = .{
        .{ .key = input.enterKey(), .label = t(.key_start) },
        .{ .key = input.backKey(), .label = t(.key_back) },
    };
    summary_spec.hints = if (spec.action_enabled) &summary_hints else summary_hints[1..];
    setFooter(summary_spec.hints, "");
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
    presentFullFrame(true);
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

/// Windows XP from UEFI: the same progress page as the Vista/7 ISO path,
/// headed by the chosen system's name, with only the steps the XP path runs.
pub fn xpStatus(stage: usos.flow.preparation_boot_progress.XpStage, heading: []const u8) void {
    const Stage = usos.flow.preparation_boot_progress.XpStage;
    progress(.{
        .mode = .stage,
        .current = stage.number(),
        .total = Stage.labels.len,
        .labels = &Stage.labels,
        .heading = heading,
        .title = Stage.labels[stage.number() - 1],
        .detail = stage.detail(),
    });
}

fn progress(state: gui.preparation_screen.State) void {
    active = .none;
    setFooter(&.{}, "");
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
    presentFullFrame(false);
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
    if (presenter != null) {
        u.headerClockAt(u.headerClockRight(info), info.clock);
        return present();
    }
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
    if (presenter != null) {
        // At most one pointer frame per ~16 ms; the input loop's frame hook
        // draws the last position when the pointer stops.
        const now = boot_timing.now();
        if (now -% last_pointer_present < boot_timing.ticksFor(pointer_frame_ms)) {
            pointer_pending = true;
            return;
        }
        last_pointer_present = now;
        pointer_pending = false;
    } else hidePointer(canvas);
    const pos = pointer.position();
    switch (active) {
        .home => if (active_home) |home| home.setHover(home.hit(pos.x, pos.y)),
        .list => if (active_list) |list| {
            const hit = if (pointer.isDragging()) null else screens.listHit(list.geometry, list.spec.rows.len, pos.x, pos.y);
            list.setHover(if (hit) |index| (if (index != list.spec.selected and list.spec.rows[index].enabled) index else null) else null);
        },
        .summary => {
            const hover = summary_button.contains(pos.x, pos.y) and summary_spec.action_enabled;
            if (hover != summary_spec.action_hover) {
                summary_spec.action_hover = hover;
                if (ui()) |u| screens.summaryButton(&u, summary_button, summary_spec);
            }
        },
        .none => {},
    }
    showPointer();
}

/// Input-loop hook (every ~2 ms): draws a throttled pointer move.
fn flushPointer() void {
    if (!pointer_pending) return;
    if (boot_timing.now() -% last_pointer_present < boot_timing.ticksFor(pointer_frame_ms)) return;
    updatePointer();
}

fn hidePointer(canvas: gui.Surface) void {
    if (presenter != null) return;
    patch.restore(canvas);
}

fn showPointer() void {
    if (presenter != null) {
        pointer_visible = true;
        return present();
    }
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

// ------------------------------------------------------------------ input test

var input_test_hints: [1]Hint = undefined;

/// One frame of the input test screen: live input lines and a marker at
/// the last tap/click (touch bring-up on new hardware).
pub fn inputTestFrame(lines: NoticeLines, marker: ?[2]u32, dragging: bool, touch_points: []const [2]u32) void {
    active = .none;
    header_clock_active = true;
    input_test_hints = .{.{ .key = input.backKey(), .label = t(.key_back) }};
    setFooter(&input_test_hints, "");
    beginFullFrame();
    var u = ui() orelse {
        console_clear(t(.input_test_title));
        for (lines) |line| consoleLine("", line, "");
        return;
    };
    var clock: [48]u8 = undefined;
    screens.notice(&u, headerInfo(&clock, &u), .{ .title = t(.input_test_title), .subtitle = t(.input_test_help), .icon = .gear, .tone = .neutral, .heading = "", .lines = lines, .hints = &input_test_hints });
    // Touch trail: small dots for the recent touch points, oldest first.
    for (touch_points) |point| {
        gui.paint.circle(u.surface, gui.paint.s(point[0]), gui.paint.s(point[1]), gui.paint.s(u.px(6)), theme.success, null);
    }
    if (marker) |point| {
        const theme_color = if (dragging) theme.warning else theme.accent;
        gui.paint.circle(u.surface, gui.paint.s(point[0]), gui.paint.s(point[1]), gui.paint.s(u.px(14)), theme_color, null);
    }
    presentFullFrame(true);
}
