const std = @import("std");
const uefi = std.os.uefi;
const ps2 = @import("ps2_mouse");

pub const Event = struct {
    x: u32,
    y: u32,
    moved: bool,
    scroll: i8 = 0,
    left_click: bool,
    right_click: bool,
};

pub const Backend = enum {
    none,
    ps2,
    uefi_simple,
    uefi_absolute,
};

var simple: ?*uefi.protocol.SimplePointer = null;
var absolute: ?*uefi.protocol.AbsolutePointer = null;
var ps2_ready: bool = false;
var screen_width: u32 = 0;
var screen_height: u32 = 0;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var last_left: bool = false;
var last_right: bool = false;

pub fn init(width: u32, height: u32) void {
    screen_width = width;
    screen_height = height;
    cursor_x = width / 2;
    cursor_y = height / 2;
    last_left = false;
    last_right = false;

    ps2_ready = ps2.init();

    const services = uefi.system_table.boot_services orelse return;
    simple = services.locateProtocol(uefi.protocol.SimplePointer, null) catch null;
    if (simple) |device| device.reset(false) catch {};

    absolute = services.locateProtocol(uefi.protocol.AbsolutePointer, null) catch null;
    if (absolute) |device| device.reset(false) catch {};
}

pub fn available() bool {
    return backend() != .none;
}

pub fn backend() Backend {
    if (ps2_ready) return .ps2;
    if (simple != null) return .uefi_simple;
    if (absolute != null) return .uefi_absolute;
    return .none;
}

pub fn backendLabel() []const u8 {
    return switch (backend()) {
        .none => "NONE",
        .ps2 => "PS/2",
        .uefi_simple => "UEFI SIMPLE",
        .uefi_absolute => "UEFI ABSOLUTE",
    };
}

pub fn position() struct { x: u32, y: u32 } {
    return .{ .x = cursor_x, .y = cursor_y };
}

pub fn poll() ?Event {
    if (ps2_ready) {
        if (pollPs2()) |event| return event;
    }
    if (simple) |device| {
        if (pollSimple(device)) |event| return event;
    }
    if (absolute) |device| {
        if (pollAbsolute(device)) |event| return event;
    }
    return null;
}

fn pollPs2() ?Event {
    const state = ps2.poll() orelse return null;
    const next_x = applyDelta(cursor_x, state.dx, screen_width);
    const next_y = applyDelta(cursor_y, state.dy, screen_height);
    return commit(next_x, next_y, -state.wheel, state.left, state.right);
}

fn pollAbsolute(device: *uefi.protocol.AbsolutePointer) ?Event {
    const state = device.getState() catch return null;
    const mode = device.mode;
    const next_x = scaleAbsolute(state.current_x, mode.absolute_min_x, mode.absolute_max_x, screen_width);
    const next_y = scaleAbsolute(state.current_y, mode.absolute_min_y, mode.absolute_max_y, screen_height);
    return commit(next_x, next_y, 0, state.active_buttons.touch_active, state.active_buttons.alt_active);
}

fn pollSimple(device: *uefi.protocol.SimplePointer) ?Event {
    const state = device.getState() catch return null;
    const dx = normalizedDelta(state.relative_movement_x, device.mode.resolution_x);
    const dy = normalizedDelta(state.relative_movement_y, device.mode.resolution_y);
    const next_x = applyDelta(cursor_x, dx, screen_width);
    const next_y = applyDelta(cursor_y, dy, screen_height);
    const scroll = scrollDirection(state.relative_movement_z);
    return commit(next_x, next_y, scroll, state.left_button, state.right_button);
}

fn commit(next_x: u32, next_y: u32, scroll: i8, left: bool, right: bool) Event {
    const result = Event{
        .x = next_x,
        .y = next_y,
        .moved = next_x != cursor_x or next_y != cursor_y,
        .scroll = scroll,
        .left_click = left and !last_left,
        .right_click = right and !last_right,
    };
    cursor_x = next_x;
    cursor_y = next_y;
    last_left = left;
    last_right = right;
    return result;
}

fn scaleAbsolute(value: u64, minimum: u64, maximum: u64, extent: u32) u32 {
    if (extent <= 1 or maximum <= minimum) return 0;
    const clamped = @min(@max(value, minimum), maximum) - minimum;
    const range = maximum - minimum;
    return @intCast((@as(u128, clamped) * (extent - 1)) / range);
}

fn normalizedDelta(value: i32, resolution: u64) i32 {
    if (value == 0) return 0;
    if (resolution == 0) return value;

    const magnitude: i64 = if (value < 0) -@as(i64, value) else value;
    var scaled: i64 = @divTrunc(magnitude * 8, @as(i64, @intCast(@min(resolution, @as(u64, std.math.maxInt(i32))))));
    if (scaled == 0) scaled = 1;
    return @intCast(if (value < 0) -scaled else scaled);
}

fn scrollDirection(value: i32) i8 {
    if (value > 0) return 1;
    if (value < 0) return -1;
    return 0;
}

fn applyDelta(value: u32, delta: anytype, extent: u32) u32 {
    if (extent == 0) return 0;
    const signed_delta: i64 = @intCast(delta);
    const next = @as(i64, value) + signed_delta;
    return @intCast(@min(@max(next, 0), @as(i64, extent - 1)));
}

test "absolute pointer coordinates scale to framebuffer" {
    try std.testing.expectEqual(@as(u32, 0), scaleAbsolute(100, 100, 1100, 1000));
    try std.testing.expectEqual(@as(u32, 999), scaleAbsolute(1100, 100, 1100, 1000));
}

test "relative pointer stays inside framebuffer" {
    try std.testing.expectEqual(@as(u32, 0), applyDelta(2, @as(i16, -10), 100));
    try std.testing.expectEqual(@as(u32, 99), applyDelta(95, @as(i16, 20), 100));
}

test "wheel movement becomes a direction" {
    try std.testing.expectEqual(@as(i8, 1), scrollDirection(120));
    try std.testing.expectEqual(@as(i8, -1), scrollDirection(-120));
    try std.testing.expectEqual(@as(i8, 0), scrollDirection(0));
}
