//! UEFI loading screen: drawn the moment GOP is known, before any slow I/O,
//! and replaced by the first menu frame (manual_view.beginFullFrame calls
//! `end`). Also used as the "Starting…" screen when USOS hands over to
//! micro-Linux, wimboot or the XP kernel.
//!
//! The static splash (logo, name, status) is painted once. A periodic timer
//! event (TPL_NOTIFY) advances the 12-dot spinner, but only after the
//! splash has been visible for `spinner_delay_ms`: a load that finishes
//! sooner never shows an animation that could flicker. The callback paints
//! only the spinner dots; status text is drawn by the main flow, so the two
//! never touch the same pixels. Nothing here waits: the splash only covers
//! loading time that is really spent.
//!
//! `boot_logo=firmware` in usos-settings.ini keeps the firmware's logo
//! (ACPI BGRT) instead of the USOS logo, with the spinner below it, the way
//! Windows starts. A missing or invalid BGRT image falls back to USOS.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const boot_timing = @import("boot_timing.zig");
const serial = @import("serial.zig");

const gui = usos.gui;
const screen = gui.splash_screen;

/// Spinner step and the delay before the first spinner frame.
const tick_ms: u64 = 75;
pub const spinner_delay_ms: u64 = 150;

pub const Logo = enum { usos, firmware };

var active = false;
var ui_state: gui.ui.Ui = undefined;
var layout: screen.Layout = undefined;
var timer: ?uefi.Event = null;
var ticks: u32 = 0;
var frame: u32 = 0;
var pack: ?gui.font.Pack = null;
var english = usos.i18n.Table.english_only;
var strings: *const usos.i18n.Table = &english;
var theme: gui.Theme = .{};

/// The parsed embedded font pack (shared with the menu view).
pub fn fontPack() ?*const gui.font.Pack {
    if (pack == null) pack = gui.font.Pack.parse(gui.font_pack) catch null;
    return if (pack) |*value| value else null;
}

/// Parses `boot_logo=` from usos-settings.ini text.
pub fn logoSetting(settings: []const u8) Logo {
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), "boot_logo")) continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(value, "firmware") or std.ascii.eqlIgnoreCase(value, "bgrt") or std.ascii.eqlIgnoreCase(value, "oem")) return .firmware;
    }
    return .usos;
}

/// Colours of the next `begin` (the chosen menu theme).
pub fn setTheme(value: gui.Theme) void {
    theme = value;
}

/// Shows the splash on `framebuffer` (no-op without a linear framebuffer).
/// `status_text` may be empty: the first status appears once the language
/// is known (`setStrings`), so the screen never flashes English first.
pub fn begin(framebuffer: ?usos.boot_info.Framebuffer, logo: Logo, status_text: []const u8) void {
    const fb = framebuffer orelse return;
    const surface = gui.Surface.init(fb) orelse return;
    ui_state = gui.ui.Ui.init(surface, theme, fontPack(), strings);
    var drew_firmware = false;
    if (logo == .firmware) {
        if (firmwareLogo(surface)) |bottom| {
            layout = screen.firmwareLogoLayout(&ui_state, bottom);
            if (status_text.len > 0) screen.status(&ui_state, layout, status_text);
            drew_firmware = true;
        }
    }
    if (!drew_firmware) {
        layout = screen.usosLayout(&ui_state);
        screen.draw(&ui_state, layout, status_text);
    }
    if (std.os.uefi.system_table.con_out) |out| out.enableCursor(false) catch {};
    active = true;
    ticks = 0;
    status_drawn = status_text.len > 0;
    startTimer();
    boot_timing.mark(if (drew_firmware) "splash shown (firmware logo)" else "splash shown");
}

/// Switches the status line to the chosen language.
pub fn setStrings(table: *const usos.i18n.Table) void {
    strings = table;
    ui_state.strings = table;
}

/// Updates the status line. The first status is drawn at once; later ones
/// only once the spinner runs (the splash has been up for the spinner
/// delay), so quick steps never make the text flicker.
pub fn status(text: []const u8) void {
    if (!active) return;
    if (status_drawn and !spinnerRunning()) return;
    screen.status(&ui_state, layout, text);
    status_drawn = true;
}

var status_drawn = false;

fn spinnerRunning() bool {
    return ticks * tick_ms >= spinner_delay_ms;
}

/// True while the splash is on screen.
pub fn isActive() bool {
    return active;
}

/// Stops the spinner; the next full frame replaces the splash.
pub fn end() void {
    if (!active) return;
    active = false;
    stopTimer();
    boot_timing.mark("splash ended");
}

/// "Starting…" screen for a handover to another loader (micro-Linux,
/// wimboot, the XP kernel): the splash, left on screen when the next
/// program takes over the framebuffer. The spinner keeps turning while
/// firmware and the next loader read their files; call `freeze` before
/// starting a loader that draws its own screen (Windows boot manager).
pub fn handover(framebuffer: ?usos.boot_info.Framebuffer, text: []const u8) void {
    end();
    begin(framebuffer, .usos, text);
}

/// Stops the spinner but leaves the splash on screen.
pub fn freeze() void {
    if (!active) return;
    active = false;
    stopTimer();
}

fn startTimer() void {
    const bs = uefi.system_table.boot_services orelse return;
    if (timer != null) return;
    // TPL_NOTIFY: disk drivers (USB mass storage, ATA) keep TPL_CALLBACK
    // raised for the whole read, which would freeze a TPL_CALLBACK spinner
    // exactly while loading. The callback only writes framebuffer pixels
    // (no boot services), so it is safe at this level.
    const event = bs.createEvent(.{ .timer = true, .signal = true }, .{ .tpl = .notify, .function = &tick }) catch |err| {
        serial.writeAscii("[SPLASH] timer unavailable: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
        return;
    };
    bs.setTimer(event, .periodic, tick_ms * 10_000) catch {
        bs.closeEvent(event) catch {};
        return;
    };
    timer = event;
}

fn stopTimer() void {
    const event = timer orelse return;
    timer = null;
    const bs = uefi.system_table.boot_services orelse return;
    bs.setTimer(event, .cancel, 0) catch {};
    bs.closeEvent(event) catch {};
}

fn tick(_: uefi.Event, _: ?*anyopaque) callconv(uefi.cc) void {
    if (!active) return;
    ticks += 1;
    if (ticks * tick_ms < spinner_delay_ms) return;
    screen.spinner(&ui_state, layout, frame);
    frame +%= 1;
}

// ------------------------------------------------------------ firmware logo

const Bgrt = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
    version: u16 align(1),
    status: u8,
    image_type: u8,
    image_address: u64 align(1),
    offset_x: u32 align(1),
    offset_y: u32 align(1),
};

/// Redraws the firmware logo (ACPI BGRT) on black and returns its bottom
/// edge, or null when there is no usable BGRT image.
fn firmwareLogo(surface: gui.Surface) ?u32 {
    const table = findAcpiTable("BGRT") orelse return null;
    const bgrt: *align(1) const Bgrt = @ptrCast(table);
    if (bgrt.length < @sizeOf(Bgrt) or bgrt.image_type != 0 or bgrt.image_address == 0) return null;
    // Status bits 1..2 give a rotation; only an unrotated logo is kept.
    if ((bgrt.status >> 1) & 3 != 0) return null;
    const header: [*]const u8 = @ptrFromInt(@as(usize, @intCast(bgrt.image_address)));
    const size = gui.bmp.declaredSize(header[0..6]) orelse return null;
    const image = gui.bmp.parse(header[0..size]) catch return null;
    if (@as(u64, bgrt.offset_x) + image.width > surface.framebuffer.width) return null;
    if (@as(u64, bgrt.offset_y) + image.height > surface.framebuffer.height) return null;
    surface.fill(.{ .r = 0, .g = 0, .b = 0 });
    image.draw(surface, bgrt.offset_x, bgrt.offset_y);
    return bgrt.offset_y + image.height;
}

const AcpiHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
};

fn findAcpiTable(signature: *const [4]u8) ?*align(1) const anyopaque {
    const system = uefi.system_table;
    const entries = system.configuration_table[0..system.number_of_table_entries];
    var rsdp: ?[*]const u8 = null;
    for (entries) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            rsdp = @ptrCast(entry.vendor_table);
            break;
        }
    }
    const root = rsdp orelse return null;
    if (!std.mem.eql(u8, root[0..8], "RSD PTR ")) return null;
    const revision = root[15];
    if (revision >= 2) {
        const xsdt_address = std.mem.readInt(u64, root[24..32], .little);
        if (xsdt_address != 0) return scan(@ptrFromInt(@as(usize, @intCast(xsdt_address))), 8, signature);
    }
    const rsdt_address = std.mem.readInt(u32, root[16..20], .little);
    if (rsdt_address == 0) return null;
    return scan(@ptrFromInt(rsdt_address), 4, signature);
}

fn scan(table: [*]const u8, pointer_bytes: usize, signature: *const [4]u8) ?*align(1) const anyopaque {
    const header: *align(1) const AcpiHeader = @ptrCast(table);
    if (header.length < 36 or header.length > 64 * 1024) return null;
    var offset: usize = 36;
    while (offset + pointer_bytes <= header.length) : (offset += pointer_bytes) {
        const address: u64 = if (pointer_bytes == 8) std.mem.readInt(u64, table[offset..][0..8], .little) else std.mem.readInt(u32, table[offset..][0..4], .little);
        if (address == 0) continue;
        const candidate: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
        if (std.mem.eql(u8, candidate[0..4], signature)) return @ptrCast(candidate);
    }
    return null;
}

test "boot_logo setting" {
    try std.testing.expectEqual(Logo.usos, logoSetting(""));
    try std.testing.expectEqual(Logo.firmware, logoSetting("language=pl\r\nboot_logo = Firmware\r\n"));
    try std.testing.expectEqual(Logo.usos, logoSetting("boot_logo=usos\n"));
}
