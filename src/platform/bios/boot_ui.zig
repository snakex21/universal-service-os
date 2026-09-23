//! Legacy BIOS menu resources. The Core slot (256 KiB) cannot hold the font
//! and icons, so they are read from the ESP (EFI/USOS/bios-ui.bin, built by
//! tools/generate_bios_ui_pack.py) together with the chosen language
//! (EFI/USOS/lang.bin) into a fixed high-memory window.
//!
//! Boot backends may overwrite that window while they load payloads, so the
//! data is re-validated (CRC) before every full screen and progress frame.
//! Menu screens reload it from the ESP when it was overwritten; progress
//! frames drawn while a backend owns memory never write to the window and
//! fall back to the built-in 5x7 font with English for that frame.
const std = @import("std");
const storage = @import("storage");
const graphics = @import("graphics");
const console = @import("console.zig");
const e820 = @import("e820.zig");
const rtc = @import("rtc.zig");

const fat32 = storage.fat32;
const random_reader = storage.random_reader;
const lang_file = graphics.lang_file;
const Ui = graphics.ui.Ui;

pub const window_base: u32 = 0x02000000;
pub const window_bytes: u32 = 0x00100000;
const resource_addr: u32 = window_base;
const resource_capacity: u32 = 0x80000;
const lang_addr: u32 = window_base + 0x80000;
const lang_capacity: u32 = lang_file.max_blob_bytes;
const table_addr: u32 = window_base + 0xC0000;
const sprite_addr: u32 = window_base + 0xD0000;
const patch_addr: u32 = window_base + 0xE0000;
const icon_addr: u32 = window_base + 0xF0000;

const resource_magic = "USOSBUI1";
const resource_header: usize = 32;

const p_efi = [_]u16{ 'E', 'F', 'I' };
const p_usos = [_]u16{ 'U', 'S', 'O', 'S' };
const p_resource = [_]u16{ 'b', 'i', 'o', 's', '-', 'u', 'i', '.', 'b', 'i', 'n' };
const p_lang = [_]u16{ 'l', 'a', 'n', 'g', '.', 'b', 'i', 'n' };
const resource_path = [_][]const u16{ &p_efi, &p_usos, &p_resource };
const lang_path = [_][]const u16{ &p_efi, &p_usos, &p_lang };

var state: struct {
    fs: ?*const fat32.FileSystem = null,
    reader: ?random_reader.Reader = null,
    window_ok: bool = false,
    resource_len: u32 = 0,
    lang_len: u32 = 0,
    pack: graphics.font.Pack = undefined,
    pack_ok: bool = false,
    icons: []const u8 = &.{},
    table_ok: bool = false,
    sprite_scale: u32 = 0,
    marker: u8 = 1,
} linksection(".data") = .{};

const english_table = lang_file.Table.english_only;

/// Remembers the ESP and loads the resources. `fs` must stay valid for the
/// life of the menu (core_main never returns).
pub fn init(fs: *const fat32.FileSystem, reader: random_reader.Reader) void {
    state.fs = fs;
    state.reader = reader;
    state.window_ok = windowUsable();
    if (!state.window_ok) {
        console.line("[BIOS_UI] high-memory window not usable; 5x7 English fallback");
        return;
    }
    reload();
}

fn windowUsable() bool {
    var map: [e820.max_entries]e820.Entry = undefined;
    const count = e820.probe(&map) catch return false;
    const start: u64 = window_base;
    const end: u64 = window_base + window_bytes;
    for (map[0..count]) |entry| {
        if (!entry.isUsable()) continue;
        const entry_end = entry.end() orelse continue;
        if (entry.base <= start and entry_end >= end) return true;
    }
    return false;
}

fn reload() void {
    const fs = state.fs orelse return;
    const reader = state.reader orelse return;
    state.pack_ok = false;
    state.table_ok = false;
    forgetPointer();
    const resources: [*]u8 = @ptrFromInt(resource_addr);
    state.resource_len = @intCast(fat32.readFile(fs.*, reader, &resource_path, resources[0..resource_capacity]) catch 0);
    const lang: [*]u8 = @ptrFromInt(lang_addr);
    state.lang_len = @intCast(fat32.readFile(fs.*, reader, &lang_path, lang[0..lang_capacity]) catch 0);
    _ = validate(@ptrFromInt(table_addr));
    console.line(if (state.pack_ok) "[BIOS_UI] font pack ready" else "[BIOS_UI] bios-ui.bin missing or invalid; 5x7 English fallback");
    console.line(if (state.table_ok) "[BIOS_UI] language ready" else "[BIOS_UI] English (no valid lang.bin)");
}

/// Checks the loaded font pack and parses lang.bin into `table`.
fn validate(table: *lang_file.Table) bool {
    state.pack_ok = false;
    state.icons = &.{};
    if (!state.window_ok or state.resource_len < resource_header) return false;
    const bytes: [*]const u8 = @ptrFromInt(resource_addr);
    const resource = bytes[0..state.resource_len];
    if (!std.mem.eql(u8, resource[0..8], resource_magic)) return false;
    const payload_len = std.mem.readInt(u32, resource[8..12], .little);
    if (payload_len != resource.len - resource_header) return false;
    const payload = resource[resource_header..];
    if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, resource[12..16], .little)) return false;
    const font_offset = std.mem.readInt(u32, resource[16..20], .little);
    const font_len = std.mem.readInt(u32, resource[20..24], .little);
    const icons_offset = std.mem.readInt(u32, resource[24..28], .little);
    const icons_len = std.mem.readInt(u32, resource[28..32], .little);
    if (@as(u64, font_offset) + font_len > payload.len or @as(u64, icons_offset) + icons_len > payload.len) return false;
    state.pack = graphics.font.Pack.parse(payload[font_offset .. font_offset + font_len]) catch return false;
    state.pack_ok = true;
    state.icons = payload[icons_offset .. icons_offset + icons_len];

    state.table_ok = false;
    if (state.lang_len == 0) return true;
    const lang: [*]const u8 = @ptrFromInt(lang_addr);
    const coverage = lang_file.Coverage{ .context = @ptrCast(&state.pack), .has = graphics.font.coverageHas };
    table.* = lang_file.Table.parse(lang[0..state.lang_len], coverage) catch return true;
    state.table_ok = true;
    return true;
}

/// Toolkit for a full menu screen: re-validates, and reloads from the ESP
/// when a backend overwrote the window. The table lives in the window.
pub fn menu(surface: graphics.Surface) Ui {
    const table: *lang_file.Table = @ptrFromInt(table_addr);
    if (state.window_ok and !validate(table)) {
        reload();
    }
    return make(surface, table);
}

/// Toolkit for frames drawn while a backend owns memory: never writes to
/// the window; `scratch` (caller's stack) receives the parsed language.
pub fn progress(surface: graphics.Surface, scratch: *lang_file.Table) Ui {
    _ = validate(scratch);
    return make(surface, scratch);
}

/// Toolkit for partial redraws right after a full menu screen.
pub fn partial(surface: graphics.Surface) Ui {
    return make(surface, @ptrFromInt(table_addr));
}

fn make(surface: graphics.Surface, table: *const lang_file.Table) Ui {
    const strings: *const lang_file.Table = if (state.pack_ok and state.table_ok) table else &english_table;
    return Ui.init(surface, graphics.Theme{}, if (state.pack_ok) &state.pack else null, strings);
}

pub const icon_slots: usize = 16;

/// Decoded 32x32 RGBA system icon, or null. Each of the 16 slots holds one
/// decoded icon; rows use slot = row index % 16 (fewer rows are visible).
pub fn icon(id: []const u8, slot: usize) ?[]const u8 {
    if (!state.pack_ok or state.icons.len < 2) return null;
    const icons = state.icons;
    const count = std.mem.readInt(u16, icons[0..2], .little);
    var offset: usize = 2;
    for (0..count) |_| {
        if (offset + 1 > icons.len) return null;
        const name_len = icons[offset];
        offset += 1;
        if (offset + name_len + 2 > icons.len) return null;
        const name = icons[offset .. offset + name_len];
        offset += name_len;
        const rle_len = std.mem.readInt(u16, icons[offset..][0..2], .little);
        offset += 2;
        if (offset + rle_len > icons.len) return null;
        const rle = icons[offset .. offset + rle_len];
        offset += rle_len;
        if (!std.mem.eql(u8, name, id)) continue;
        const output: [*]u8 = @ptrFromInt(icon_addr + (slot % icon_slots) * 32 * 32 * 4);
        return graphics.rgba_rle.decode(rle, output[0 .. 32 * 32 * 4]) catch null;
    }
    return null;
}

pub fn sprite(scale_twice: u32) ?*graphics.cursor.Sprite {
    if (!state.window_ok) return null;
    const value: *graphics.cursor.Sprite = @ptrFromInt(sprite_addr);
    if (state.sprite_scale != scale_twice) {
        value.* = .{};
        value.build(scale_twice);
        state.sprite_scale = scale_twice;
    }
    return value;
}

pub fn patch() ?*graphics.cursor.Patch {
    if (!state.window_ok) return null;
    return @ptrFromInt(patch_addr);
}

/// Invalidates cached pointer data after a backend may have used the window.
pub fn forgetPointer() void {
    state.sprite_scale = 0;
    if (patch()) |value| value.saved = false;
}

pub fn clock(ui: *const Ui, buffer: []u8) []const u8 {
    const now = rtc.read() orelse return "";
    return graphics.ui.clockText(ui, buffer, .{ .year = now.year, .month = now.month, .day = now.day, .hour = now.hour, .minute = now.minute });
}

pub fn header(ui: *const Ui, clock_buffer: []u8) graphics.ui.HeaderInfo {
    return .{ .firmware = "BIOS", .build = build_id, .language = ui.t(.language_name), .clock = clock(ui, clock_buffer) };
}

const build_id = @import("build_info").id;
