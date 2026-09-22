const graphics = @import("graphics");
const console = @import("console.zig");
const mouse = @import("ps2_mouse.zig");
const Surface = graphics.Surface;
const Canvas = graphics.menu_canvas.Canvas;

var state: struct {
    surface: ?Surface = null,
    decoder: mouse.Decoder = .{},
    initialized: bool = false,
    enabled: bool = false,
    home: bool = false,
    count: usize = 0,
    selected: usize = 0,
    x: u32 = 0,
    y: u32 = 0,
    saved: bool = false,
    pixels: [8 * 16]u32 = [_]u32{0} ** (8 * 16),
    marker: u8 = 1,
} linksection(".data") = .{};

pub fn configure(surface: Surface, home: bool, count: usize, selected: usize) void {
    hide();
    state.surface = surface;
    state.home = home;
    state.count = count;
    state.selected = selected;
    if (!state.initialized) {
        state.initialized = true;
        state.x = surface.framebuffer.width / 2;
        state.y = surface.framebuffer.height / 2;
        state.enabled = mouse.init();
        console.line(if (state.enabled) "[BIOS_MOUSE] PS2 streaming enabled" else "[BIOS_MOUSE] no PS2/firmware mouse detected");
    }
}

pub fn listen() void {
    console.setAuxiliaryHook(if (state.enabled) feed else null);
    show();
}
pub fn stopListening() void {
    hide();
    console.setAuxiliaryHook(null);
}
pub fn hide() void {
    if (!state.saved) return;
    const surface = state.surface orelse return;
    for (0..16) |y| for (0..8) |x| {
        if (state.x + x < surface.framebuffer.width and state.y + y < surface.framebuffer.height)
            surface.setRawPixel(state.x + @as(u32, @intCast(x)), state.y + @as(u32, @intCast(y)), state.pixels[y * 8 + x]);
    };
    state.saved = false;
}
fn show() void {
    if (!state.enabled or state.saved) return;
    const surface = state.surface orelse return;
    for (0..16) |y| for (0..8) |x| {
        const px = state.x + @as(u32, @intCast(x));
        const py = state.y + @as(u32, @intCast(y));
        if (px >= surface.framebuffer.width or py >= surface.framebuffer.height) continue;
        state.pixels[y * 8 + x] = surface.getRawPixel(px, py);
        if (y < 16 and x <= y / 2) {
            const edge = x == 0 or x == y / 2 or y == 15;
            surface.setPixel(px, py, if (edge) .{ .r = 0, .g = 0, .b = 0 } else .{ .r = 255, .g = 255, .b = 255 });
        }
    };
    state.saved = true;
}
fn hit() ?usize {
    const surface = state.surface orelse return null;
    const canvas = Canvas.init(surface, .{});
    const m = canvas.metrics;
    if (state.home) {
        for (0..state.count) |index| {
            const rect = m.homeCard(index, state.count);
            if (state.x >= rect.x and state.x < rect.x + rect.width and state.y >= rect.y and state.y < rect.y + rect.height) return index;
        }
    } else {
        const x = m.content_x + m.row_inset;
        const y = m.list_top + m.row_inset;
        if (state.x < x or state.x >= m.content_right -| m.row_inset or state.y < y) return null;
        const row = (state.y - y) / m.row_height;
        if (row >= m.visible_rows or (state.y - y) % m.row_height >= m.row_height -| m.row_gap) return null;
        const start = graphics.menu_canvas.listStart(state.selected, state.count, canvas.visibleRows());
        if (start + row < state.count) return start + row;
    }
    return null;
}
fn feed(byte: u8) ?console.Key {
    const event = state.decoder.feed(byte) orelse return null;
    const surface = state.surface orelse return null;
    hide();
    state.x = @intCast(@min(@as(i64, surface.framebuffer.width - 1), @max(0, @as(i64, state.x) + event.dx)));
    state.y = @intCast(@min(@as(i64, surface.framebuffer.height - 1), @max(0, @as(i64, state.y) + event.dy)));
    if (event.right) return .{ .ascii = 27, .scan = 0 };
    if (hit()) |index| {
        if (event.left or ((event.dx != 0 or event.dy != 0) and index != state.selected)) {
            return .{ .ascii = if (event.left) 13 else 0, .scan = 0, .selection = @intCast(index) };
        }
    }
    show();
    return null;
}
