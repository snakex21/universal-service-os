//! Platform-independent input mapping shared by the UEFI menu, the Legacy
//! BIOS menu and the micro-Linux framebuffer UI: wheel accumulation, tap
//! versus drag on a pointer or touchscreen, drag-to-scroll in rows, and a
//! gamepad stick with deadzone, hysteresis and hold-to-repeat.
//!
//! Sign conventions used everywhere in USOS: wheel notches are positive
//! when the wheel turns away from the user ("up", towards the start of a
//! list); a drag delta is the finger's movement in pixels (negative = up).
const std = @import("std");

/// Turns raw wheel counts into whole notches, keeping the remainder so a
/// high-resolution wheel or touchpad (many small counts per notch) scrolls
/// exactly once per notch and never loses movement.
pub const WheelAccumulator = struct {
    /// Counts per notch. 0 = learn it: the smallest non-zero report seen
    /// (firmware reports 1, 120 or a resolution-scaled value per notch).
    unit: i32 = 0,
    remainder: i32 = 0,
    learn: bool = true,

    pub fn fixed(unit: i32) WheelAccumulator {
        return .{ .unit = @max(1, unit), .learn = false };
    }

    pub fn feed(self: *WheelAccumulator, raw: i32) i32 {
        if (raw == 0) return 0;
        const magnitude: i32 = @intCast(@min(@abs(raw), std.math.maxInt(i32)));
        if (self.learn and (self.unit == 0 or magnitude < self.unit)) {
            self.unit = magnitude;
            self.remainder = 0;
        }
        const unit = @max(1, self.unit);
        // A direction change drops the partial notch of the old direction.
        if ((self.remainder > 0 and raw < 0) or (self.remainder < 0 and raw > 0)) self.remainder = 0;
        const total = self.remainder +| raw;
        const notches = @divTrunc(total, unit);
        self.remainder = total - notches * unit;
        return notches;
    }

    pub fn reset(self: *WheelAccumulator) void {
        self.remainder = 0;
    }
};

/// Wheel sign conventions of the raw sources USOS reads. Every path turns
/// its raw value into USOS notches (positive = wheel turned away from the
/// user = scroll up, towards the start), like Windows WM_MOUSEWHEEL.
pub const WheelSource = enum {
    /// HID Wheel usage, Linux REL_WHEEL/REL_WHEEL_HI_RES, WM_MOUSEWHEEL and
    /// EDK2's USB mouse driver: positive = away (up).
    positive_up,
    /// IntelliMouse PS/2 Z (4th byte) and AMI Aptio's
    /// EFI_SIMPLE_POINTER_PROTOCOL: negative = away (up).
    negative_up,
};

pub fn orientWheel(source: WheelSource, raw: i32) i32 {
    return switch (source) {
        .positive_up => raw,
        .negative_up => if (raw == std.math.minInt(i32)) std.math.maxInt(i32) else -raw,
    };
}

/// RelativeMovementZ has no sign in the UEFI spec. EDK2 (OVMF, most
/// open-source based firmware) passes the HID value through; AMI Aptio
/// (ASRock, ASUS incl. ROG Ally, MSI, Gigabyte desktops) reports it the
/// PS/2 way round, as confirmed on hardware. `vendor` is the ASCII-folded
/// EFI_SYSTEM_TABLE.FirmwareVendor.
pub fn uefiSimplePointerWheel(vendor: []const u8) WheelSource {
    if (std.ascii.indexOfIgnoreCase(vendor, "American Megatrends") != null) return .negative_up;
    if (vendor.len >= 3 and std.ascii.eqlIgnoreCase(vendor[0..3], "AMI")) return .negative_up;
    return .positive_up;
}

/// Press/move/release classifier: a press that ends within `threshold`
/// pixels of where it started is a tap (click); once the pointer travels
/// further while pressed it becomes a drag and never turns into a tap.
pub const Gesture = struct {
    threshold: u32 = 12,
    pressed: bool = false,
    dragging: bool = false,
    start_x: i32 = 0,
    start_y: i32 = 0,
    last_x: i32 = 0,
    last_y: i32 = 0,

    pub const Tap = struct { x: i32, y: i32 };
    pub const Drag = struct { dx: i32, dy: i32 };

    pub fn press(self: *Gesture, x: i32, y: i32) void {
        self.pressed = true;
        self.dragging = false;
        self.start_x = x;
        self.start_y = y;
        self.last_x = x;
        self.last_y = y;
    }

    /// Movement while pressed; returns the delta once the gesture is a drag.
    pub fn move(self: *Gesture, x: i32, y: i32) ?Drag {
        if (!self.pressed) return null;
        if (!self.dragging) {
            const dx = @abs(x - self.start_x);
            const dy = @abs(y - self.start_y);
            if (@max(dx, dy) <= self.threshold) return null;
            self.dragging = true;
            // The whole travel so far counts, so the content never jumps.
            self.last_x = self.start_x;
            self.last_y = self.start_y;
        }
        const result = Drag{ .dx = x - self.last_x, .dy = y - self.last_y };
        self.last_x = x;
        self.last_y = y;
        if (result.dx == 0 and result.dy == 0) return null;
        return result;
    }

    /// Release; a tap reports where the press started.
    pub fn release(self: *Gesture) ?Tap {
        if (!self.pressed) return null;
        self.pressed = false;
        const was_drag = self.dragging;
        self.dragging = false;
        if (was_drag) return null;
        return .{ .x = self.start_x, .y = self.start_y };
    }

    pub fn cancel(self: *Gesture) void {
        self.pressed = false;
        self.dragging = false;
    }
};

/// Tap threshold for a screen: about 1% of the shorter side, at least 8 px
/// (12 px at 720p, 16 px at 1080p), so a finger's wobble stays a tap.
pub fn tapThreshold(width: u32, height: u32) u32 {
    return @max(8, @min(width, height) * 3 / 200);
}

/// Converts drag pixels into list rows: content follows the finger, so
/// moving the finger up by one row pitch scrolls one row further (+1).
pub const DragScroll = struct {
    pixels: i32 = 0,

    pub fn feed(self: *DragScroll, dy: i32, row_pitch: u32) i32 {
        const pitch: i32 = @intCast(@max(1, row_pitch));
        self.pixels -|= dy;
        const rows = @divTrunc(self.pixels, pitch);
        self.pixels -= rows * pitch;
        return rows;
    }

    pub fn reset(self: *DragScroll) void {
        self.pixels = 0;
    }
};

pub const Direction = enum { up, down, left, right };

/// Analog stick to a direction: radial deadzone with hysteresis (a larger
/// threshold to engage than to stay engaged) and a dominant-axis choice.
pub const Stick = struct {
    /// Fractions of full deflection, in 1/1000.
    engage: u32 = 500,
    release: u32 = 350,
    current: ?Direction = null,

    /// x, y are centred values in -range..range (y positive = down).
    pub fn update(self: *Stick, x: i32, y: i32, range: i32) ?Direction {
        if (range <= 0) return null;
        const fx: i64 = @divTrunc(@as(i64, x) * 1000, range);
        const fy: i64 = @divTrunc(@as(i64, y) * 1000, range);
        const magnitude2 = fx * fx + fy * fy;
        const limit: i64 = if (self.current == null) self.engage else self.release;
        if (magnitude2 < limit * limit) {
            self.current = null;
            return null;
        }
        const next: Direction = if (@abs(fx) > @abs(fy))
            (if (fx < 0) .left else .right)
        else
            (if (fy < 0) .up else .down);
        self.current = next;
        return next;
    }
};

/// Centres a raw evdev/XInput axis value (minimum..maximum) to
/// -range..range around the midpoint.
pub fn centreAxis(value: i32, minimum: i32, maximum: i32, range: i32) i32 {
    if (maximum <= minimum) return 0;
    const mid = @divTrunc(@as(i64, minimum) + maximum, 2);
    const half = @divTrunc(@as(i64, maximum) - minimum, 2);
    if (half == 0) return 0;
    const scaled = @divTrunc((@as(i64, value) - mid) * range, half);
    return @intCast(std.math.clamp(scaled, -@as(i64, range), @as(i64, range)));
}

/// Hold-to-repeat for a direction (D-pad or stick): fires at press, then
/// after `delay_ms`, then every `interval_ms` while held.
pub const Repeat = struct {
    delay_ms: u64 = 400,
    interval_ms: u64 = 90,
    held: ?Direction = null,
    next_ms: u64 = 0,

    /// Sets the held direction (null = released). Returns a direction to
    /// act on now: a new press, or a due repeat of the held one.
    pub fn set(self: *Repeat, direction: ?Direction, now_ms: u64) ?Direction {
        if (direction == null) {
            self.held = null;
            return null;
        }
        if (self.held != direction) {
            self.held = direction;
            self.next_ms = now_ms + self.delay_ms;
            return direction;
        }
        return self.tick(now_ms);
    }

    pub fn tick(self: *Repeat, now_ms: u64) ?Direction {
        const held = self.held orelse return null;
        if (now_ms < self.next_ms) return null;
        self.next_ms = @max(now_ms, self.next_ms) + self.interval_ms;
        if (self.next_ms <= now_ms) self.next_ms = now_ms + self.interval_ms;
        return held;
    }

    /// Milliseconds until the next repeat is due (for poll timeouts).
    pub fn wait(self: *const Repeat, now_ms: u64) ?u64 {
        if (self.held == null) return null;
        return self.next_ms -| now_ms;
    }
};

/// Scroll position for a list view: moves the first visible row by
/// `delta` rows, clamped so the view stays filled.
pub fn scrollFirst(first: usize, delta: i32, count: usize, visible: usize) usize {
    if (count <= visible) return 0;
    const max_first = count - visible;
    const next: i64 = @as(i64, @intCast(first)) + delta;
    return @intCast(std.math.clamp(next, 0, @as(i64, @intCast(max_first))));
}

/// Keeps a selection inside the visible window after the view scrolled,
/// preferring the nearest selectable row (null `selectable` = all rows).
pub fn clampSelection(selected: usize, first: usize, visible: usize, count: usize, selectable: ?[]const bool) usize {
    if (count == 0) return 0;
    const last = @min(count, first + visible) - 1;
    const target = std.math.clamp(selected, first, last);
    if (isSelectable(selectable, target)) return target;
    var distance: usize = 1;
    while (distance <= visible) : (distance += 1) {
        if (target >= first + distance and isSelectable(selectable, target - distance)) return target - distance;
        if (target + distance <= last and isSelectable(selectable, target + distance)) return target + distance;
    }
    return selected;
}

fn isSelectable(selectable: ?[]const bool, index: usize) bool {
    const items = selectable orelse return true;
    return index < items.len and items[index];
}

/// Maps absolute device coordinates to the framebuffer, honouring the
/// device range and the panel rotation.
pub fn mapAbsolute(value: [2]u64, range: [4]u64, rotation: u16, width: u32, height: u32) [2]u32 {
    const nx = normalize(value[0], range[0], range[1]);
    const ny = normalize(value[1], range[2], range[3]);
    const full: u32 = 1 << 16;
    const rotated: [2]u32 = switch (rotation) {
        90 => .{ ny, full - nx },
        180 => .{ full - nx, full - ny },
        270 => .{ full - ny, nx },
        else => .{ nx, ny },
    };
    return .{ scaleUnit(rotated[0], width), scaleUnit(rotated[1], height) };
}

fn normalize(value: u64, minimum: u64, maximum: u64) u32 {
    if (maximum <= minimum) return 0;
    const clamped = @min(@max(value, minimum), maximum) - minimum;
    return @intCast((@as(u128, clamped) << 16) / (maximum - minimum));
}

fn scaleUnit(unit: u32, extent: u32) u32 {
    if (extent <= 1) return 0;
    return @intCast((@as(u64, @min(unit, 1 << 16)) * (extent - 1)) >> 16);
}

/// A panel mounted in portrait (range taller than wide by 20%+) on a
/// landscape framebuffer is rotated 90 degrees; everything else is not.
pub fn autoRotation(range_w: u64, range_h: u64, width: u32, height: u32) u16 {
    if (range_w == 0 or range_h == 0) return 0;
    const portrait_panel = range_h * 5 > range_w * 6;
    const landscape_screen = @as(u64, width) * 5 > @as(u64, height) * 6;
    return if (portrait_panel and landscape_screen) 90 else 0;
}

/// The rotation of one absolute device, recomputed whenever its advertised
/// range changes. A driver may install its protocol with a placeholder
/// range (TouchI2cDxe publishes 0..0xFFFF on both axes until the panel is
/// live, then e.g. 0..1920 x 0..1080), so the rotation chosen when the
/// handle first appeared must not be kept for the real range.
pub const AbsoluteMapping = struct {
    /// min_x, max_x, min_y, max_y as last seen.
    range: [4]u64 = .{ 0, 0, 0, 0 },
    rotation: u16 = 0,
    known: bool = false,

    /// Returns true when the range (or the forced rotation) changed and the
    /// rotation was recomputed.
    pub fn update(self: *AbsoluteMapping, range: [4]u64, forced_rotation: ?u16, width: u32, height: u32) bool {
        const rotation = forced_rotation orelse autoRotation(range[1] -| range[0], range[3] -| range[2], width, height);
        if (self.known and std.mem.eql(u64, &self.range, &range) and self.rotation == rotation) return false;
        self.range = range;
        self.rotation = rotation;
        self.known = true;
        return true;
    }

    /// Screen coordinates for a device report under the current mapping.
    pub fn map(self: AbsoluteMapping, value: [2]u64, width: u32, height: u32) [2]u32 {
        return mapAbsolute(value, self.range, self.rotation, width, height);
    }
};

test "wheel accumulator learns the notch unit and keeps high-resolution remainders" {
    var wheel = WheelAccumulator{};
    try std.testing.expectEqual(@as(i32, 1), wheel.feed(120));
    try std.testing.expectEqual(@as(i32, -2), wheel.feed(-240));
    // A finer device report re-learns a smaller unit.
    try std.testing.expectEqual(@as(i32, 1), wheel.feed(1));
    try std.testing.expectEqual(@as(i32, 3), wheel.feed(3));

    var hires = WheelAccumulator.fixed(120);
    try std.testing.expectEqual(@as(i32, 0), hires.feed(30));
    try std.testing.expectEqual(@as(i32, 0), hires.feed(30));
    try std.testing.expectEqual(@as(i32, 0), hires.feed(30));
    try std.testing.expectEqual(@as(i32, 1), hires.feed(30));
    try std.testing.expectEqual(@as(i32, 0), hires.feed(90));
    // Reversing drops the partial notch instead of cancelling it.
    try std.testing.expectEqual(@as(i32, 0), hires.feed(-60));
    try std.testing.expectEqual(@as(i32, -1), hires.feed(-60));
    // Resolution-scaled firmware reports (ConSplitter-style 8192/notch).
    var scaled = WheelAccumulator{};
    try std.testing.expectEqual(@as(i32, -1), scaled.feed(-8192));
    try std.testing.expectEqual(@as(i32, 2), scaled.feed(16384));
}

test "wheel sign per source: away from the user is always a positive (up) notch" {
    // Linux REL_WHEEL +1, HID +1, WM_MOUSEWHEEL +120, EDK2 USB mouse Z +1.
    try std.testing.expectEqual(@as(i32, 1), orientWheel(.positive_up, 1));
    try std.testing.expectEqual(@as(i32, 120), orientWheel(.positive_up, 120));
    // IntelliMouse PS/2 Z -1 (nibble 0xF) and AMI Aptio SimplePointer Z -1.
    try std.testing.expectEqual(@as(i32, 1), orientWheel(.negative_up, -1));
    try std.testing.expectEqual(@as(i32, -1), orientWheel(.negative_up, 1));
    try std.testing.expectEqual(WheelSource.negative_up, uefiSimplePointerWheel("American Megatrends"));
    try std.testing.expectEqual(WheelSource.negative_up, uefiSimplePointerWheel("AMI"));
    try std.testing.expectEqual(WheelSource.positive_up, uefiSimplePointerWheel("EDK II"));
    try std.testing.expectEqual(WheelSource.positive_up, uefiSimplePointerWheel("INSYDE Corp."));
    var wheel = WheelAccumulator{};
    try std.testing.expectEqual(@as(i32, 1), wheel.feed(orientWheel(.negative_up, -1)));
}

test "tap versus drag uses a movement threshold" {
    var gesture = Gesture{ .threshold = 10 };
    gesture.press(100, 100);
    try std.testing.expect(gesture.move(105, 108) == null);
    const tap = gesture.release().?;
    try std.testing.expectEqual(@as(i32, 100), tap.x);
    try std.testing.expectEqual(@as(i32, 100), tap.y);

    gesture.press(100, 100);
    try std.testing.expect(gesture.move(100, 108) == null);
    const drag = gesture.move(100, 80).?;
    try std.testing.expectEqual(@as(i32, -20), drag.dy);
    const more = gesture.move(100, 70).?;
    try std.testing.expectEqual(@as(i32, -10), more.dy);
    // Coming back near the start never turns a drag into a tap.
    _ = gesture.move(100, 101);
    try std.testing.expect(gesture.release() == null);
    try std.testing.expect(gesture.release() == null);
    try std.testing.expectEqual(@as(u32, 16), tapThreshold(1920, 1080));
    try std.testing.expectEqual(@as(u32, 8), tapThreshold(640, 480));
}

test "drag scroll converts finger travel to rows with content following the finger" {
    var scroll = DragScroll{};
    try std.testing.expectEqual(@as(i32, 0), scroll.feed(-40, 90));
    try std.testing.expectEqual(@as(i32, 1), scroll.feed(-60, 90));
    try std.testing.expectEqual(@as(i32, -1), scroll.feed(100, 90));
    try std.testing.expectEqual(@as(usize, 3), scrollFirst(1, 5, 10, 7));
    try std.testing.expectEqual(@as(usize, 0), scrollFirst(1, -5, 10, 7));
    try std.testing.expectEqual(@as(usize, 0), scrollFirst(4, 2, 5, 7));
}

test "selection follows a scrolled view to the nearest selectable row" {
    try std.testing.expectEqual(@as(usize, 3), clampSelection(0, 3, 4, 10, null));
    try std.testing.expectEqual(@as(usize, 6), clampSelection(9, 3, 4, 10, null));
    const selectable = [_]bool{ true, true, true, false, true, true, true, true };
    try std.testing.expectEqual(@as(usize, 4), clampSelection(0, 3, 3, selectable.len, &selectable));
    try std.testing.expectEqual(@as(usize, 5), clampSelection(5, 3, 3, selectable.len, &selectable));
}

test "stick deadzone with hysteresis and dominant axis" {
    var stick = Stick{};
    try std.testing.expect(stick.update(4000, 0, 32767) == null);
    try std.testing.expectEqual(Direction.right, stick.update(20000, 3000, 32767).?);
    // Between release and engage thresholds the direction is kept.
    try std.testing.expectEqual(Direction.right, stick.update(13000, 0, 32767).?);
    try std.testing.expect(stick.update(9000, 0, 32767) == null);
    try std.testing.expect(stick.update(13000, 0, 32767) == null);
    try std.testing.expectEqual(Direction.up, stick.update(3000, -30000, 32767).?);
    try std.testing.expectEqual(@as(i32, 0), centreAxis(128, 0, 256, 1000));
    try std.testing.expectEqual(@as(i32, -1000), centreAxis(0, 0, 256, 1000));
    try std.testing.expectEqual(@as(i32, 1000), centreAxis(300, 0, 256, 1000));
}

test "hold to repeat fires at press, after the delay, then at the interval" {
    var repeat = Repeat{ .delay_ms = 400, .interval_ms = 100 };
    try std.testing.expectEqual(Direction.down, repeat.set(.down, 1000).?);
    try std.testing.expect(repeat.set(.down, 1200) == null);
    try std.testing.expectEqual(@as(?u64, 200), repeat.wait(1200));
    try std.testing.expectEqual(Direction.down, repeat.set(.down, 1400).?);
    try std.testing.expect(repeat.tick(1450) == null);
    try std.testing.expectEqual(Direction.down, repeat.tick(1500).?);
    try std.testing.expect(repeat.set(null, 1510) == null);
    try std.testing.expect(repeat.tick(2000) == null);
    try std.testing.expectEqual(Direction.up, repeat.set(.up, 2000).?);
}

test "absolute mapping is recomputed when a placeholder range becomes the panel range" {
    var mapping = AbsoluteMapping{};
    // TouchI2cDxe before bring-up: square placeholder, no rotation.
    try std.testing.expect(mapping.update(.{ 0, 0xFFFF, 0, 0xFFFF }, null, 1920, 1080));
    try std.testing.expectEqual(@as(u16, 0), mapping.rotation);
    // Same range again: nothing to do.
    try std.testing.expect(!mapping.update(.{ 0, 0xFFFF, 0, 0xFFFF }, null, 1920, 1080));
    // The panel comes up landscape 1920x1080 (ROG Ally): the new range is
    // used for scaling, the rotation stays 0.
    try std.testing.expect(mapping.update(.{ 0, 1920, 0, 1080 }, null, 1920, 1080));
    try std.testing.expectEqual(@as(u16, 0), mapping.rotation);
    try std.testing.expectEqual([2]u32{ 959, 539 }, mapping.map(.{ 960, 540 }, 1920, 1080));
    try std.testing.expectEqual([2]u32{ 1919, 1079 }, mapping.map(.{ 1920, 1080 }, 1920, 1080));
    // A portrait panel (Steam Deck 800x1280 matrix) on a landscape screen
    // turns 90 degrees once its real range is published.
    var deck = AbsoluteMapping{};
    _ = deck.update(.{ 0, 0xFFFF, 0, 0xFFFF }, null, 1280, 800);
    try std.testing.expectEqual(@as(u16, 0), deck.rotation);
    try std.testing.expect(deck.update(.{ 0, 800, 0, 1280 }, null, 1280, 800));
    try std.testing.expectEqual(@as(u16, 90), deck.rotation);
    try std.testing.expectEqual([2]u32{ 0, 799 }, deck.map(.{ 0, 0 }, 1280, 800));
    // touch_rotation= in usos-settings.ini always wins.
    var forced = AbsoluteMapping{};
    _ = forced.update(.{ 0, 800, 0, 1280 }, 270, 1280, 800);
    try std.testing.expectEqual(@as(u16, 270), forced.rotation);
    // A screen mode change alone re-evaluates the automatic rotation.
    try std.testing.expect(deck.update(.{ 0, 800, 0, 1280 }, null, 800, 1280));
    try std.testing.expectEqual(@as(u16, 0), deck.rotation);
}

test "a touch tap and a drag on the new absolute handle" {
    // What pointer.zig feeds the gesture for TouchI2cDxe reports: press at
    // the touched point, lift-off at the same (last) point = tap.
    var mapping = AbsoluteMapping{};
    _ = mapping.update(.{ 0, 1920, 0, 1080 }, null, 1920, 1080);
    var gesture = Gesture{ .threshold = tapThreshold(1920, 1080) };
    const down = mapping.map(.{ 400, 300 }, 1920, 1080);
    gesture.press(@intCast(down[0]), @intCast(down[1]));
    const jitter = mapping.map(.{ 405, 306 }, 1920, 1080);
    try std.testing.expect(gesture.move(@intCast(jitter[0]), @intCast(jitter[1])) == null);
    const tap = gesture.release().?;
    try std.testing.expectEqual(@as(i32, @intCast(down[0])), tap.x);
    // Finger dragged upwards by 200 panel units: a drag, scrolled by rows.
    gesture.press(@intCast(down[0]), @intCast(down[1]));
    const up = mapping.map(.{ 400, 100 }, 1920, 1080);
    const drag = gesture.move(@intCast(up[0]), @intCast(up[1])).?;
    try std.testing.expect(drag.dy < -150);
    var scroll = DragScroll{};
    try std.testing.expectEqual(@as(i32, 2), scroll.feed(drag.dy, 90));
    try std.testing.expect(gesture.release() == null);
}
