//! PS/2 mouse pointer for the Legacy BIOS menu: the anti-aliased arrow from
//! src/gui/cursor.zig (sprite and saved patch live in boot_ui's window).
//! Moving over a row or card selects it, a left click opens it, a right
//! click goes back, like Esc, and the wheel (IntelliMouse) moves the
//! selection like the arrow keys.
const graphics = @import("graphics");
const console = @import("console.zig");
const mouse = @import("ps2_mouse.zig");
const boot_ui = @import("boot_ui.zig");
const graphics_menu = @import("graphics_menu.zig");
const Surface = graphics.Surface;

var state: struct {
    surface: ?Surface = null,
    decoder: mouse.Decoder = .{},
    initialized: bool = false,
    enabled: bool = false,
    selected: usize = 0,
    x: u32 = 0,
    y: u32 = 0,
    marker: u8 = 1,
} linksection(".data") = .{};

pub fn configure(surface: Surface, home: bool, count: usize, selected: usize) void {
    _ = home;
    _ = count;
    hide();
    state.surface = surface;
    state.selected = selected;
    if (!state.initialized) {
        state.initialized = true;
        state.x = surface.framebuffer.width / 2;
        state.y = surface.framebuffer.height / 2;
        const result = mouse.init();
        state.enabled = result.enabled;
        state.decoder = .{ .size = if (result.wheel) 4 else 3 };
        console.line(if (!state.enabled) "[BIOS_MOUSE] no PS2/firmware mouse detected" else if (result.wheel) "[BIOS_MOUSE] PS2 streaming enabled, IntelliMouse wheel" else "[BIOS_MOUSE] PS2 streaming enabled, no wheel (3-byte)");
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
    const surface = state.surface orelse return;
    const patch = boot_ui.patch() orelse return;
    patch.restore(surface);
}

fn show() void {
    if (!state.enabled) return;
    const surface = state.surface orelse return;
    const patch = boot_ui.patch() orelse return;
    if (patch.saved) return;
    const ui = boot_ui.partial(surface);
    const sprite = boot_ui.sprite(ui.fonts.scale.twice()) orelse return;
    patch.save(surface, state.x, state.y, sprite.width, sprite.height);
    sprite.draw(surface, state.x, state.y, &patch.pixels);
}

fn feed(byte: u8) ?console.Key {
    const event = state.decoder.feed(byte) orelse return null;
    const surface = state.surface orelse return null;
    hide();
    state.x = @intCast(@min(@as(i64, surface.framebuffer.width - 1), @max(0, @as(i64, state.x) + event.dx)));
    state.y = @intCast(@min(@as(i64, surface.framebuffer.height - 1), @max(0, @as(i64, state.y) + event.dy)));
    if (event.right) return .{ .ascii = 27, .scan = 0 };
    // The wheel moves the selection like the arrow keys (the list scrolls
    // to keep it visible); IntelliMouse Z is negative when turned away.
    if (event.wheel != 0) return .{ .ascii = 0, .scan = mouse.wheelScan(event.wheel) };
    if (graphics_menu.hit(surface, state.x, state.y)) |index| {
        if (event.left or ((event.dx != 0 or event.dy != 0) and index != state.selected)) {
            state.selected = index;
            return .{ .ascii = if (event.left) 13 else 0, .scan = 0, .selection = @intCast(index) };
        }
    }
    show();
    return null;
}
