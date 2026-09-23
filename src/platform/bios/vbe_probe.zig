const std = @import("std");
const console = @import("console.zig");
const graphics = @import("graphics");
const BootFramebuffer = graphics.Framebuffer;
const PixelFormat = graphics.PixelFormat;
const Surface = graphics.Surface;
const Theme = graphics.Theme;
const text = graphics.text;

extern fn bios_vbe_probe(controller_info: [*]u8, mode_ids: [*]u16) callconv(.c) u32;
extern fn bios_vbe_mode_info(mode: u32, mode_info: [*]u8) callconv(.c) u32;
extern fn bios_vbe_set_mode(mode: u32) callconv(.c) u32;
extern fn bios_vbe_text_mode() callconv(.c) u32;
extern fn bios_vbe_current_mode() callconv(.c) u32;
extern fn core_vbe_stage() callconv(.c) u32;
extern fn core_vbe_last_ax() callconv(.c) u32;

const max_modes: usize = 256;
const controller_info_bytes: usize = 512;
const mode_info_bytes: usize = 256;

const Mode = struct {
    id: u16,
    width: u16,
    height: u16,
    pitch: u16,
    framebuffer: u32,
    memory_model: u8,
    pixel_format: ?PixelFormat,
    red_size: u8,
    red_pos: u8,
    green_size: u8,
    green_pos: u8,
    blue_size: u8,
    blue_pos: u8,

    fn usable(self: Mode) bool {
        if (self.width == 0 or self.height == 0 or self.framebuffer == 0) return false;
        if (self.memory_model != 6 or self.pixel_format == null) return false;
        if ((self.pitch & 3) != 0) return false;
        return @as(u32, self.pitch) >= @as(u32, self.width) * 4;
    }
};

pub const Session = struct {
    surface: Surface,
    framebuffer: BootFramebuffer,
    mode_id: u16,

    pub fn enterText(self: *Session) void {
        _ = self;
        _ = bios_vbe_text_mode();
    }

    pub fn currentMode(self: Session) ?u16 {
        _ = self;
        const raw = bios_vbe_current_mode();
        if (raw == 0xFFFFFFFF) return null;
        return @as(u16, @truncate(raw)) & 0x3FFF;
    }

    pub fn currentModeMatches(self: Session) bool {
        const current = self.currentMode() orelse return false;
        return current == self.mode_id;
    }

    pub fn restore(self: *Session) bool {
        if (bios_vbe_set_mode(self.mode_id) != 0) {
            _ = bios_vbe_text_mode();
            return false;
        }
        self.surface = Surface.init(self.framebuffer) orelse {
            _ = bios_vbe_text_mode();
            return false;
        };
        return true;
    }
};

pub fn init() ?Session {
    var controller: [controller_info_bytes]u8 = undefined;
    var mode_ids: [max_modes]u16 = undefined;
    const probe_result = bios_vbe_probe(&controller, &mode_ids);
    if (probe_result == 0xFFFFFFFF) {
        serialProbeFailure();
        return fallback("VBE controller probe failed; VGA text menu will be used.");
    }
    const raw_count: usize = @min(@as(usize, probe_result), max_modes);
    serialControllerRaw(&controller, &mode_ids, raw_count);
    if (raw_count == 0) return fallback("VBE controller returned an empty mode list; VGA text menu will be used.");

    const version = read16(&controller, 4);
    var modes: [max_modes]Mode = undefined;
    var found: usize = 0;
    var best_index: ?usize = null;
    var mode_info: [mode_info_bytes]u8 = undefined;

    var index: usize = 0;
    while (index < raw_count) : (index += 1) {
        const mode_id = mode_ids[index];
        if (bios_vbe_mode_info(mode_id, &mode_info) != 0) continue;
        const mode = parseMode(mode_id, version, &mode_info) orelse continue;
        if (found >= modes.len) break;
        modes[found] = mode;
        serialMode(mode, false);
        if (mode.usable()) {
            if (best_index == null or betterMode(mode, modes[best_index.?])) best_index = found;
        }
        found += 1;
    }

    serialSummary(version, raw_count, found, if (best_index) |best| modes[best] else null);
    if (best_index == null) return fallback("No usable 32-bit linear framebuffer mode; VGA text menu will be used.");

    const selected = modes[best_index.?];
    if (bios_vbe_set_mode(selected.id) != 0) return fallback("VBE 4F02 failed; VGA text menu restored.");

    const framebuffer = BootFramebuffer{
        .address = selected.framebuffer,
        .size = @as(usize, selected.pitch) * selected.height,
        .width = selected.width,
        .height = selected.height,
        .pixels_per_scan_line = selected.pitch / 4,
        .pixel_format = selected.pixel_format.?,
    };
    const surface = Surface.init(framebuffer) orelse return fallback("Selected VBE mode cannot create the shared Surface; VGA text menu restored.");
    return .{ .surface = surface, .framebuffer = framebuffer, .mode_id = selected.id };
}

fn parseMode(id: u16, controller_version: u16, bytes: *const [mode_info_bytes]u8) ?Mode {
    const attributes = read16(bytes, 0);
    const supported_graphics_lfb: u16 = 0x0001 | 0x0010 | 0x0080;
    if ((attributes & supported_graphics_lfb) != supported_graphics_lfb) return null;
    if (bytes[25] != 32) return null;

    const use_linear_fields = controller_version >= 0x0300 and read16(bytes, 50) != 0;
    const pitch = if (use_linear_fields) read16(bytes, 50) else read16(bytes, 16);
    const red_size = if (use_linear_fields) bytes[54] else bytes[31];
    const red_pos = if (use_linear_fields) bytes[55] else bytes[32];
    const green_size = if (use_linear_fields) bytes[56] else bytes[33];
    const green_pos = if (use_linear_fields) bytes[57] else bytes[34];
    const blue_size = if (use_linear_fields) bytes[58] else bytes[35];
    const blue_pos = if (use_linear_fields) bytes[59] else bytes[36];

    return .{
        .id = id,
        .width = read16(bytes, 18),
        .height = read16(bytes, 20),
        .pitch = pitch,
        .framebuffer = read32(bytes, 40),
        .memory_model = bytes[27],
        .pixel_format = pixelFormat(red_size, red_pos, green_size, green_pos, blue_size, blue_pos),
        .red_size = red_size,
        .red_pos = red_pos,
        .green_size = green_size,
        .green_pos = green_pos,
        .blue_size = blue_size,
        .blue_pos = blue_pos,
    };
}

fn pixelFormat(red_size: u8, red_pos: u8, green_size: u8, green_pos: u8, blue_size: u8, blue_pos: u8) ?PixelFormat {
    if (red_size != 8 or green_size != 8 or blue_size != 8 or green_pos != 8) return null;
    if (red_pos == 0 and blue_pos == 16) return .rgbx8;
    if (red_pos == 16 and blue_pos == 0) return .bgrx8;
    return null;
}

fn betterMode(candidate: Mode, current: Mode) bool {
    const candidate_rank = preferredRank(candidate.width, candidate.height);
    const current_rank = preferredRank(current.width, current.height);
    if (candidate_rank != current_rank) return candidate_rank < current_rank;
    if (candidate_rank < 4) return false;

    const candidate_score = genericScore(candidate.width, candidate.height);
    const current_score = genericScore(current.width, current.height);
    if (candidate_score != current_score) return candidate_score < current_score;
    return @as(u32, candidate.width) * candidate.height > @as(u32, current.width) * current.height;
}

fn preferredRank(width: u16, height: u16) u8 {
    if (width == 1280 and height == 800) return 0;
    if (width == 1280 and height == 1024) return 1;
    if (width == 1024 and height == 768) return 2;
    if (width == 800 and height == 600) return 3;
    return 4;
}

fn genericScore(width: u16, height: u16) u64 {
    const dx = absDiff(width, 1024);
    const dy = absDiff(height, 768);
    const aspect = absDiffU32(@as(u32, width) * 3, @as(u32, height) * 4);
    return @as(u64, dx) * 16 + @as(u64, dy) * 16 + aspect;
}

fn absDiff(value: u16, target: u16) u32 {
    return if (value >= target) value - target else target - value;
}

fn absDiffU32(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn render(surface: Surface, version: u16, raw_count: usize, modes: []const Mode, selected_index: usize) void {
    const theme = Theme{};
    surface.fill(theme.background);
    surface.fillRect(0, 0, surface.framebuffer.width, 5, theme.accent);

    text.legacy.draw(surface, 20, 18, "UNIVERSAL SERVICE OS - VESA-1", 2, theme.text);
    text.legacy.draw(surface, 20, 46, "PROBE / MODE SET TEST - MENU IS DELIBERATELY DISABLED", 1, theme.muted);

    const selected = modes[selected_index];
    var line: [96]u8 = undefined;
    const version_line = std.fmt.bufPrint(&line, "VBE: {d}.{d}   BIOS MODE IDS: {d}   32-BIT LFB: {d}", .{ version >> 8, version & 0xFF, raw_count, modes.len }) catch "VBE INFO";
    text.legacy.draw(surface, 20, 70, version_line, 1, theme.text);

    var selected_line: [112]u8 = undefined;
    const selected_text = selectedSummary(&selected_line, selected);
    text.legacy.draw(surface, 20, 86, selected_text, 1, theme.accent);

    var fb_line: [96]u8 = undefined;
    const fb_text = framebufferSummary(&fb_line, selected);
    text.legacy.draw(surface, 20, 102, fb_text, 1, theme.text);

    text.legacy.draw(surface, 20, 126, "ALL 32-BIT LINEAR FRAMEBUFFER MODES:", 1, theme.text);

    const margin: u32 = 20;
    const usable_width = surface.framebuffer.width -| (margin * 2);
    const min_cell_width: u32 = 150;
    const columns: usize = @max(1, @as(usize, @intCast(usable_width / min_cell_width)));
    const cell_width: u32 = usable_width / @as(u32, @intCast(columns));
    const rows: usize = (modes.len + columns - 1) / columns;
    const list_y: u32 = 144;
    const line_height: u32 = if (rows <= @as(usize, @intCast((surface.framebuffer.height -| list_y -| 8) / 8))) 8 else 7;

    for (modes, 0..) |mode, mode_index| {
        const column = mode_index / rows;
        const row = mode_index % rows;
        if (column >= columns) break;
        const x = margin + @as(u32, @intCast(column)) * cell_width;
        const y = list_y + @as(u32, @intCast(row)) * line_height;
        if (y + 7 > surface.framebuffer.height) break;
        var mode_buffer: [40]u8 = undefined;
        const mode_text = compactMode(&mode_buffer, mode, mode_index == selected_index);
        drawClipped(surface, x, y, cell_width -| 4, mode_text, theme, mode_index == selected_index);
    }
}

fn drawClipped(surface: Surface, x: u32, y: u32, width: u32, value: []const u8, theme: Theme, selected: bool) void {
    const chars: usize = @intCast(width / 6);
    if (chars == 0) return;
    text.legacy.draw(surface, x, y, value[0..@min(value.len, chars)], 1, if (selected) theme.accent else theme.muted);
}

fn compactMode(out: *[40]u8, mode: Mode, selected: bool) []const u8 {
    out[0] = if (selected) '>' else ' ';
    writeHex16(out[1..5], mode.id);
    out[5] = ' ';
    const tail = std.fmt.bufPrint(out[6..], "{d}x{d} p{d} {s}", .{ mode.width, mode.height, mode.pitch, shortFormat(mode) }) catch return out[0..6];
    return out[0 .. 6 + tail.len];
}

fn selectedSummary(out: []u8, mode: Mode) []const u8 {
    var id: [4]u8 = undefined;
    writeHex16(&id, mode.id);
    return std.fmt.bufPrint(out, "SELECTED: 0x{s}   {d}x{d}x32   PITCH={d}   FORMAT={s}", .{ id[0..], mode.width, mode.height, mode.pitch, formatName(mode) }) catch "SELECTED MODE";
}

fn framebufferSummary(out: []u8, mode: Mode) []const u8 {
    var address: [8]u8 = undefined;
    writeHex32(&address, mode.framebuffer);
    return std.fmt.bufPrint(out, "FRAMEBUFFER: 0x{s}   RGB MASK POS: R{d}@{d} G{d}@{d} B{d}@{d}", .{ address[0..], mode.red_size, mode.red_pos, mode.green_size, mode.green_pos, mode.blue_size, mode.blue_pos }) catch "FRAMEBUFFER";
}

fn serialProbeFailure() void {
    var ax: [4]u8 = undefined;
    writeHex16(&ax, @truncate(core_vbe_last_ax()));
    var line: [80]u8 = undefined;
    const value = std.fmt.bufPrint(&line, "VBE PROBE FAIL stage={d} last_ax=0x{s}", .{ core_vbe_stage(), ax[0..] }) catch "VBE PROBE FAIL";
    console.line(value);
}

fn serialControllerRaw(controller: *const [controller_info_bytes]u8, mode_ids: *const [max_modes]u16, raw_count: usize) void {
    var signature: [8]u8 = undefined;
    var mode_ptr: [8]u8 = undefined;
    writeHex32(&signature, read32(controller, 0));
    writeHex32(&mode_ptr, read32(controller, 14));
    var line: [128]u8 = undefined;
    const value = std.fmt.bufPrint(&line, "VBE RAW signature=0x{s} version_word={d} mode_ptr=0x{s} count={d}", .{ signature[0..], read16(controller, 4), mode_ptr[0..], raw_count }) catch "VBE RAW";
    console.line(value);
    var index: usize = 0;
    while (index < @min(raw_count, 8)) : (index += 1) {
        var id: [4]u8 = undefined;
        writeHex16(&id, mode_ids[index]);
        var id_line: [40]u8 = undefined;
        const id_value = std.fmt.bufPrint(&id_line, "VBE RAW MODE[{d}]=0x{s}", .{ index, id[0..] }) catch "VBE RAW MODE";
        console.line(id_value);
    }
}

fn serialSummary(version: u16, raw_count: usize, found: usize, selected: ?Mode) void {
    var line: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&line, "VBE CONTROLLER version={d}.{d} mode_ids={d} lfb32={d}", .{ version >> 8, version & 0xFF, raw_count, found }) catch "VBE CONTROLLER";
    console.line(header);
    if (selected) |mode| {
        var selected_line: [112]u8 = undefined;
        console.line(selectedSummary(&selected_line, mode));
        var fb_line: [96]u8 = undefined;
        console.line(framebufferSummary(&fb_line, mode));
    }
}

fn serialMode(mode: Mode, selected: bool) void {
    _ = selected;
    var id: [4]u8 = undefined;
    var fb: [8]u8 = undefined;
    writeHex16(&id, mode.id);
    writeHex32(&fb, mode.framebuffer);
    var line: [160]u8 = undefined;
    const value = std.fmt.bufPrint(&line, "VBE MODE 0x{s} {d}x{d}x32 pitch={d} fb=0x{s} memory={d} format={s} masks=R{d}@{d}/G{d}@{d}/B{d}@{d}", .{ id[0..], mode.width, mode.height, mode.pitch, fb[0..], mode.memory_model, formatName(mode), mode.red_size, mode.red_pos, mode.green_size, mode.green_pos, mode.blue_size, mode.blue_pos }) catch "VBE MODE";
    console.line(value);
}

fn formatName(mode: Mode) []const u8 {
    return if (mode.pixel_format) |format| switch (format) {
        .rgbx8 => "RGBX8",
        .bgrx8 => "BGRX8",
        .bit_mask => "BITMASK",
    } else "UNSUPPORTED";
}

fn shortFormat(mode: Mode) []const u8 {
    return if (mode.pixel_format) |format| switch (format) {
        .rgbx8 => "RG",
        .bgrx8 => "BG",
        .bit_mask => "??",
    } else "??";
}

fn fallback(message: []const u8) ?Session {
    _ = bios_vbe_text_mode();
    console.line(message);
    return null;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeHex16(out: []u8, value: u16) void {
    out[0] = hex(@intCast((value >> 12) & 0xF));
    out[1] = hex(@intCast((value >> 8) & 0xF));
    out[2] = hex(@intCast((value >> 4) & 0xF));
    out[3] = hex(@intCast(value & 0xF));
}

fn writeHex32(out: []u8, value: u32) void {
    var shift: u5 = 28;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        out[index] = hex(@intCast((value >> shift) & 0xF));
        if (shift >= 4) shift -= 4 else shift = 0;
    }
}

fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

test "preferred VBE mode order includes common 5:4 desktop mode" {
    try std.testing.expect(preferredRank(1280, 800) < preferredRank(1280, 1024));
    try std.testing.expect(preferredRank(1280, 1024) < preferredRank(1024, 768));
    try std.testing.expect(preferredRank(1024, 768) < preferredRank(800, 600));
}

test "VBE pixel masks map onto the shared Surface formats" {
    try std.testing.expectEqual(PixelFormat.rgbx8, pixelFormat(8, 0, 8, 8, 8, 16).?);
    try std.testing.expectEqual(PixelFormat.bgrx8, pixelFormat(8, 16, 8, 8, 8, 0).?);
    try std.testing.expect(pixelFormat(5, 11, 6, 5, 5, 0) == null);
}
