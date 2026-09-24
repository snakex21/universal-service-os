//! Pointer input for the UEFI menu: every EFI_SIMPLE_POINTER_PROTOCOL and
//! EFI_ABSOLUTE_POINTER_PROTOCOL handle (mice, touchpads, touchscreens,
//! tablets) plus direct PS/2 when no firmware PS/2 mouse driver exists.
//!
//! All devices drive one cursor. A press that is released without moving
//! further than a small threshold is a click/tap; moving further while
//! pressed is a drag, reported as a pixel delta so lists scroll with the
//! finger. The wheel (RelativeMovementZ, or an absolute Z axis that is not
//! pressure) is accumulated per device into whole notches, positive = up.
const std = @import("std");
const uefi = std.os.uefi;
const ps2 = @import("ps2_mouse");
const usos = @import("usos");
const input_map = usos.gui.input_map;

pub const Event = struct {
    x: u32,
    y: u32,
    /// The cursor position changed (hover).
    moved: bool,
    /// Wheel notches, positive = away from the user (towards the list start).
    scroll: i8 = 0,
    /// Click or tap at (x, y), reported on release unless it became a drag.
    left_click: bool,
    right_click: bool,
    /// Pixel movement while dragging (negative = finger moved up).
    drag_dy: i32 = 0,
    dragging: bool = false,
    /// The event came from an absolute device (touchscreen/tablet).
    touch: bool = false,
};

pub const Backend = enum { none, ps2, uefi_simple, uefi_absolute };

/// EFI_SIMPLE_POINTER_PROTOCOL with an explicit C layout (std declares a
/// plain struct, whose field order Zig does not guarantee).
pub const SimplePointer = extern struct {
    reset: *const fn (*SimplePointer, bool) callconv(uefi.cc) uefi.Status,
    get_state: *const fn (*SimplePointer, *State) callconv(uefi.cc) uefi.Status,
    wait_for_input: uefi.Event,
    mode: *Mode,

    pub const guid align(8) = uefi.protocol.SimplePointer.guid;

    pub const Mode = extern struct {
        resolution_x: u64,
        resolution_y: u64,
        resolution_z: u64,
        left_button: bool,
        right_button: bool,
    };

    pub const State = extern struct {
        relative_movement_x: i32,
        relative_movement_y: i32,
        relative_movement_z: i32,
        left_button: bool,
        right_button: bool,
    };
};

pub const AbsolutePointer = uefi.protocol.AbsolutePointer;

pub const Settings = struct {
    /// Flip the wheel direction (usos-settings.ini wheel_invert=1).
    wheel_invert: bool = false,
    /// Touch panel rotation in degrees (touch_rotation=0/90/180/270);
    /// null = automatic (a portrait panel on a landscape screen turns 90).
    touch_rotation: ?u16 = null,
};

const max_devices = 8;

const SimpleDevice = struct {
    protocol: *SimplePointer,
    handle: uefi.Handle,
    wheel: input_map.WheelAccumulator = .{},
    left: bool = false,
    right: bool = false,
};

const AbsoluteDevice = struct {
    protocol: *AbsolutePointer,
    handle: uefi.Handle,
    /// Range and rotation, recomputed when the protocol's Mode changes
    /// (a driver may publish a placeholder range until its panel is up).
    mapping: input_map.AbsoluteMapping = .{},
    wheel_axis: bool = false,
    /// How often the range changed after the handle was first seen.
    mapping_changes: u16 = 0,
    wheel: input_map.WheelAccumulator = .{},
    last_z: u64 = 0,
    z_known: bool = false,
    touch: bool = false,
    alt: bool = false,
};

var simple_devices: [max_devices]SimpleDevice = undefined;
var simple_count: usize = 0;
var absolute_devices: [max_devices]AbsoluteDevice = undefined;
var absolute_count: usize = 0;
var ps2_ready: bool = false;
var ps2_skipped_for_firmware: bool = false;
var ps2_wheel: input_map.WheelAccumulator = input_map.WheelAccumulator.fixed(1);
var ps2_left = false;
var ps2_right = false;
var settings: Settings = .{};
var screen_width: u32 = 0;
var screen_height: u32 = 0;
var cursor_x: u32 = 0;
var cursor_y: u32 = 0;
var gesture = input_map.Gesture{};
var initialized = false;
var simple_wheel: input_map.WheelSource = .positive_up;
var vendor_buffer: [64]u8 = undefined;
var vendor_len: usize = 0;
var last_handle: ?uefi.Handle = null;
var last_touch: TouchSample = .{};
var mapping_changed = false;

/// The last report of an absolute device (touchscreen), raw and mapped.
pub const TouchSample = struct {
    raw_x: u64 = 0,
    raw_y: u64 = 0,
    x: u32 = 0,
    y: u32 = 0,
    active: bool = false,
    /// Increments with every absolute report (0 = none yet).
    serial: u32 = 0,
};

pub fn lastTouch() TouchSample {
    return last_touch;
}

pub fn configure(value: Settings) void {
    settings = value;
}

pub fn init(width: u32, height: u32) void {
    screen_width = width;
    screen_height = height;
    cursor_x = width / 2;
    cursor_y = height / 2;
    gesture = .{ .threshold = input_map.tapThreshold(width, height) };
    // A GOP mode change re-initialises the geometry but keeps the devices.
    if (initialized) {
        for (absolute_devices[0..absolute_count]) |*device| _ = refreshMapping(device);
        return;
    }
    initialized = true;
    vendor_len = 0;
    const vendor = uefi.system_table.firmware_vendor;
    while (vendor[vendor_len] != 0 and vendor_len < vendor_buffer.len) : (vendor_len += 1) {
        const unit = vendor[vendor_len];
        vendor_buffer[vendor_len] = if (unit >= 0x20 and unit < 0x7f) @intCast(unit) else '?';
    }
    simple_wheel = input_map.uefiSimplePointerWheel(vendor_buffer[0..vendor_len]);
    simple_count = 0;
    absolute_count = 0;
    const firmware_ps2 = scanDevices();
    // Direct 8042 access would fight a firmware PS/2 mouse driver.
    ps2_skipped_for_firmware = firmware_ps2;
    ps2_ready = if (firmware_ps2) false else ps2.init();
}

/// Picks up pointer devices connected after start (USB hot plug, or a
/// touch driver USOS started). Known handles keep their state, but their
/// absolute range is re-read; cheap enough to call twice a second.
pub fn rescan() void {
    if (!initialized) return;
    _ = scanDevices();
    for (absolute_devices[0..absolute_count]) |*device| _ = refreshMapping(device);
}

/// Re-reads the device's Mode: a changed range (e.g. TouchI2cDxe's 0xFFFF
/// placeholder becoming 1920x1080) recomputes the rotation and wheel axis.
fn refreshMapping(device: *AbsoluteDevice) bool {
    const mode = device.protocol.mode;
    const range = [4]u64{ mode.absolute_min_x, mode.absolute_max_x, mode.absolute_min_y, mode.absolute_max_y };
    const first = !device.mapping.known;
    if (!device.mapping.update(range, settings.touch_rotation, screen_width, screen_height)) return false;
    const wheel_axis = !mode.attributes.supports_pressure_as_z and mode.absolute_max_z > mode.absolute_min_z;
    if (wheel_axis != device.wheel_axis) {
        device.wheel_axis = wheel_axis;
        device.z_known = false;
        device.wheel.reset();
    }
    if (!first) {
        device.mapping_changes +%= 1;
        mapping_changed = true;
    }
    return true;
}

/// A known absolute device changed its range since the last call (the
/// menu then rewrites input-devices.txt once with the live range).
pub fn takeMappingChanged() bool {
    const value = mapping_changed;
    mapping_changed = false;
    return value;
}

fn scanDevices() bool {
    const services = uefi.system_table.boot_services orelse return false;
    const console_in = uefi.system_table.console_in_handle;
    var firmware_ps2 = false;

    if (services.locateHandleBuffer(.{ .by_protocol = &SimplePointer.guid }) catch null) |handles| {
        defer services.freePool(@ptrCast(handles.ptr)) catch {};
        // The console splitter's virtual pointer (on the ConIn handle) sums
        // the physical devices but drops Z when a child reports
        // ResolutionZ = 0. Poll the physical devices directly instead.
        const skip_virtual = handles.len > 1;
        if (skip_virtual) dropSimple(console_in);
        for (handles) |handle| {
            if (skip_virtual and console_in != null and handle == console_in.?) continue;
            if (isPs2Mouse(services, handle)) firmware_ps2 = true;
            if (knownSimple(handle)) continue;
            if (simple_count == max_devices) break;
            const protocol = (services.handleProtocol(SimplePointer, handle) catch null) orelse continue;
            _ = protocol.reset(protocol, false);
            simple_devices[simple_count] = .{ .protocol = protocol, .handle = handle };
            simple_count += 1;
        }
    }

    if (services.locateHandleBuffer(.{ .by_protocol = &AbsolutePointer.guid }) catch null) |handles| {
        defer services.freePool(@ptrCast(handles.ptr)) catch {};
        const skip_virtual = handles.len > 1;
        if (skip_virtual) dropAbsolute(console_in);
        for (handles) |handle| {
            if (skip_virtual and console_in != null and handle == console_in.?) continue;
            if (knownAbsolute(handle)) continue;
            if (absolute_count == max_devices) break;
            const protocol = (services.handleProtocol(AbsolutePointer, handle) catch null) orelse continue;
            protocol.reset(false) catch {};
            const mode = protocol.mode;
            absolute_devices[absolute_count] = .{
                .protocol = protocol,
                .handle = handle,
                .wheel_axis = !mode.attributes.supports_pressure_as_z and mode.absolute_max_z > mode.absolute_min_z,
            };
            _ = refreshMapping(&absolute_devices[absolute_count]);
            absolute_count += 1;
        }
    }
    return firmware_ps2;
}

/// Stops polling the console splitter once physical devices exist (it
/// would take their state and lose the wheel).
fn dropSimple(handle: ?uefi.Handle) void {
    const target = handle orelse return;
    var index: usize = 0;
    while (index < simple_count) {
        if (simple_devices[index].handle == target) {
            simple_count -= 1;
            simple_devices[index] = simple_devices[simple_count];
        } else index += 1;
    }
}

fn dropAbsolute(handle: ?uefi.Handle) void {
    const target = handle orelse return;
    var index: usize = 0;
    while (index < absolute_count) {
        if (absolute_devices[index].handle == target) {
            absolute_count -= 1;
            absolute_devices[index] = absolute_devices[absolute_count];
        } else index += 1;
    }
}

fn knownSimple(handle: uefi.Handle) bool {
    for (simple_devices[0..simple_count]) |device| if (device.handle == handle) return true;
    return false;
}

fn knownAbsolute(handle: uefi.Handle) bool {
    for (absolute_devices[0..absolute_count]) |device| if (device.handle == handle) return true;
    return false;
}

pub fn available() bool {
    return backend() != .none;
}

pub fn backend() Backend {
    if (ps2_ready) return .ps2;
    if (simple_count > 0) return .uefi_simple;
    if (absolute_count > 0) return .uefi_absolute;
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

pub fn isDragging() bool {
    return gesture.dragging;
}

/// The EFI_SIMPLE_POINTER_PROTOCOL handle of the last polled event (null:
/// PS/2 or an absolute device), to tell a handheld's stick-as-mouse apart.
pub fn lastHandle() ?uefi.Handle {
    return last_handle;
}

pub fn poll() ?Event {
    last_handle = null;
    if (ps2_ready) {
        if (pollPs2()) |event| return event;
    }
    const services = uefi.system_table.boot_services orelse return null;
    var index: usize = 0;
    while (index < simple_count) {
        // A hot-unplugged device's interface is freed; the handle database
        // validates stale handles safely, so re-check before every call.
        const current = services.handleProtocol(SimplePointer, simple_devices[index].handle) catch null;
        if (current == null or current.? != simple_devices[index].protocol) {
            simple_count -= 1;
            simple_devices[index] = simple_devices[simple_count];
            continue;
        }
        if (pollSimple(&simple_devices[index])) |event| {
            last_handle = simple_devices[index].handle;
            return event;
        }
        index += 1;
    }
    index = 0;
    while (index < absolute_count) {
        const current = services.handleProtocol(AbsolutePointer, absolute_devices[index].handle) catch null;
        if (current == null or current.? != absolute_devices[index].protocol) {
            absolute_count -= 1;
            absolute_devices[index] = absolute_devices[absolute_count];
            continue;
        }
        if (pollAbsolute(&absolute_devices[index])) |event| return event;
        index += 1;
    }
    return null;
}

fn pollPs2() ?Event {
    const state = ps2.poll() orelse return null;
    const next_x = applyDelta(cursor_x, state.dx, screen_width);
    const next_y = applyDelta(cursor_y, state.dy, screen_height);
    // IntelliMouse reports negative Z for the wheel turned away.
    const notches = ps2_wheel.feed(input_map.orientWheel(.negative_up, state.wheel));
    const event = commit(next_x, next_y, wheelSign(notches), state.left, ps2_left, state.right, ps2_right, false);
    ps2_left = state.left;
    ps2_right = state.right;
    return event;
}

fn pollSimple(device: *SimpleDevice) ?Event {
    var state: SimplePointer.State = undefined;
    if (device.protocol.get_state(device.protocol, &state) != .success) return null;
    const dx = normalizedDelta(state.relative_movement_x, device.protocol.mode.resolution_x);
    const dy = normalizedDelta(state.relative_movement_y, device.protocol.mode.resolution_y);
    const next_x = applyDelta(cursor_x, dx, screen_width);
    const next_y = applyDelta(cursor_y, dy, screen_height);
    // The sign depends on the firmware (see input_map.uefiSimplePointerWheel).
    const notches = device.wheel.feed(input_map.orientWheel(simple_wheel, state.relative_movement_z));
    const event = commit(next_x, next_y, wheelSign(notches), state.left_button, device.left, state.right_button, device.right, false);
    device.left = state.left_button;
    device.right = state.right_button;
    return event;
}

fn pollAbsolute(device: *AbsoluteDevice) ?Event {
    const state = device.protocol.getState() catch return null;
    // The range may have changed since the last report (driver bring-up).
    _ = refreshMapping(device);
    const mapped = device.mapping.map(.{ state.current_x, state.current_y }, screen_width, screen_height);
    var notches: i32 = 0;
    if (device.wheel_axis) {
        if (device.z_known) {
            const delta: i64 = @as(i64, @bitCast(state.current_z)) -% @as(i64, @bitCast(device.last_z));
            notches = device.wheel.feed(@intCast(std.math.clamp(delta, -1_000_000, 1_000_000)));
        }
        device.last_z = state.current_z;
        device.z_known = true;
    }
    const touch = state.active_buttons.touch_active;
    const alt = state.active_buttons.alt_active;
    last_touch = .{ .raw_x = state.current_x, .raw_y = state.current_y, .x = mapped[0], .y = mapped[1], .active = touch, .serial = last_touch.serial +% 1 };
    const event = commit(mapped[0], mapped[1], wheelSign(notches), touch, device.touch, alt, device.alt, true);
    device.touch = touch;
    device.alt = alt;
    return event;
}

fn wheelSign(notches: i32) i8 {
    const value: i32 = if (settings.wheel_invert) -notches else notches;
    return @intCast(std.math.clamp(value, -100, 100));
}

fn commit(next_x: u32, next_y: u32, scroll: i8, left: bool, was_left: bool, right: bool, was_right: bool, touch: bool) Event {
    var result = Event{
        .x = next_x,
        .y = next_y,
        .moved = next_x != cursor_x or next_y != cursor_y,
        .scroll = scroll,
        .left_click = false,
        .right_click = right and !was_right,
        .touch = touch,
    };
    const x: i32 = @intCast(next_x);
    const y: i32 = @intCast(next_y);
    if (left and !was_left) gesture.press(x, y);
    if (left and gesture.pressed) {
        if (gesture.move(x, y)) |drag| result.drag_dy = drag.dy;
    }
    if (!left and was_left) {
        if (gesture.release()) |tap| {
            result.left_click = true;
            result.x = @intCast(tap.x);
            result.y = @intCast(tap.y);
        }
    }
    result.dragging = gesture.dragging;
    cursor_x = next_x;
    cursor_y = next_y;
    return result;
}

fn normalizedDelta(value: i32, resolution: u64) i32 {
    if (value == 0) return 0;
    if (resolution == 0) return value;

    const magnitude: i64 = if (value < 0) -@as(i64, value) else value;
    var scaled: i64 = @divTrunc(magnitude * 8, @as(i64, @intCast(@min(resolution, @as(u64, std.math.maxInt(i32))))));
    if (scaled == 0) scaled = 1;
    return @intCast(if (value < 0) -scaled else scaled);
}

fn applyDelta(value: u32, delta: anytype, extent: u32) u32 {
    if (extent == 0) return 0;
    const signed_delta: i64 = @intCast(delta);
    const next = @as(i64, value) + signed_delta;
    return @intCast(@min(@max(next, 0), @as(i64, extent - 1)));
}

// ------------------------------------------------------------ diagnostics

const pnp_ps2_mouse = [_]u32{ 0x0F0341D0, 0x0F1341D0, 0x0F0E41D0 };

fn isPs2Mouse(services: *uefi.tables.BootServices, handle: uefi.Handle) bool {
    const path = (services.handleProtocol(uefi.protocol.DevicePath, handle) catch null) orelse return false;
    var node: *const uefi.protocol.DevicePath = path;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const bytes: [*]const u8 = @ptrCast(node);
        if (bytes[0] == 0x02 and bytes[1] == 0x01 and node.length >= 12) {
            const hid = std.mem.readInt(u32, bytes[4..8], .little);
            for (pnp_ps2_mouse) |value| if (hid == value) return true;
        }
        if (node.length < 4) return false;
        node = node.next() orelse return false;
    }
    return false;
}

/// Writes one line per pointer device for the input-devices report.
pub const Report = struct {
    pub fn simpleCount() usize {
        return simple_count;
    }
    pub fn absoluteCount() usize {
        return absolute_count;
    }
    pub fn simpleHandle(index: usize) uefi.Handle {
        return simple_devices[index].handle;
    }
    pub fn simpleMode(index: usize) SimplePointer.Mode {
        return simple_devices[index].protocol.mode.*;
    }
    pub fn absoluteHandle(index: usize) uefi.Handle {
        return absolute_devices[index].handle;
    }
    pub fn absoluteMode(index: usize) AbsolutePointer.Mode {
        return absolute_devices[index].protocol.mode.*;
    }
    pub fn absoluteRotation(index: usize) u16 {
        return absolute_devices[index].mapping.rotation;
    }
    pub fn absoluteMappingChanges(index: usize) u16 {
        return absolute_devices[index].mapping_changes;
    }
    pub fn absoluteWheel(index: usize) bool {
        return absolute_devices[index].wheel_axis;
    }
    pub fn ps2Direct() bool {
        return ps2_ready;
    }
    pub fn ps2Wheel() bool {
        return ps2_ready and ps2.wheelAvailable();
    }
    pub fn ps2SkippedForFirmware() bool {
        return ps2_skipped_for_firmware;
    }
    pub fn firmwareVendor() []const u8 {
        return vendor_buffer[0..vendor_len];
    }
    pub fn simpleWheelSource() []const u8 {
        return @tagName(simple_wheel);
    }
    pub fn wheelInverted() bool {
        return settings.wheel_invert;
    }
};

test "absolute pointer coordinates scale to framebuffer" {
    try std.testing.expectEqual([2]u32{ 0, 0 }, input_map.mapAbsolute(.{ 100, 0 }, .{ 100, 1100, 0, 1000 }, 0, 1000, 500));
    try std.testing.expectEqual([2]u32{ 999, 499 }, input_map.mapAbsolute(.{ 1100, 1000 }, .{ 100, 1100, 0, 1000 }, 0, 1000, 500));
}

test "portrait touch panel on a landscape screen is rotated" {
    try std.testing.expectEqual(@as(u16, 90), input_map.autoRotation(1080, 1920, 1920, 1080));
    try std.testing.expectEqual(@as(u16, 0), input_map.autoRotation(32767, 32767, 1920, 1080));
    try std.testing.expectEqual(@as(u16, 0), input_map.autoRotation(1920, 1080, 1920, 1080));
    // Portrait top-left (x=0,y=0) lands on the landscape bottom-left.
    try std.testing.expectEqual([2]u32{ 0, 1079 }, input_map.mapAbsolute(.{ 0, 0 }, .{ 0, 1080, 0, 1920 }, 90, 1920, 1080));
    try std.testing.expectEqual([2]u32{ 1919, 1079 }, input_map.mapAbsolute(.{ 0, 1920 }, .{ 0, 1080, 0, 1920 }, 90, 1920, 1080));
}

test "relative pointer stays inside framebuffer" {
    try std.testing.expectEqual(@as(u32, 0), applyDelta(2, @as(i16, -10), 100));
    try std.testing.expectEqual(@as(u32, 99), applyDelta(95, @as(i16, 20), 100));
}
