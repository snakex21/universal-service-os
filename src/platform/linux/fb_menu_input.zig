//! evdev input for the micro-Linux framebuffer menus: keyboards, mice
//! (REL_WHEEL / REL_WHEEL_HI_RES), absolute tablets, touchscreens
//! (BTN_TOUCH + ABS_X/Y pointer emulation or ABS_MT_* slot 0) and gamepads
//! (xpad, hid-generic, hid-asus: BTN_SOUTH/EAST/..., ABS_HAT0X/Y, ABS_X/Y).
//!
//! Every device is opened from /dev/input/event* and grabbed. Events are
//! handled per SYN_REPORT frame. A press released within a small distance
//! is a click/tap; moving further while pressed is a drag (lists scroll with
//! the finger). Gamepad directions repeat while held.
//!
//! Footer hints follow the last input (gamepad_active): a gamepad, or a
//! handheld controller exposed as a keyboard (by EVIOCGID USB VID/PID, see
//! src/gui/handheld.zig), means A/B; a keyboard means Enter/Esc. On a
//! handheld (/sys/class/dmi/id) the hints start as A/B, a touch tap keeps
//! them, and the i8042 keyboard (the EC, which may carry built-in buttons)
//! only switches to Enter/Esc for keys a pad cannot produce.
const std = @import("std");
const linux = std.os.linux;
const usos = @import("usos");
const input_map = usos.gui.input_map;
const handheld = usos.gui.handheld;

pub const Event = extern struct { seconds: i64, micros: i64, kind: u16, code: u16, value: i32 };
const AbsInfo = extern struct { value: i32 = 0, minimum: i32 = 0, maximum: i32 = 0, fuzz: i32 = 0, flat: i32 = 0, resolution: i32 = 0 };
/// scroll_up/down come from keys (PgUp/PgDn); wheel_up/down from a mouse
/// wheel, which the menu routes by pointer position (list or details).
pub const Action = enum { none, previous, next, accept, back, scroll_up, scroll_down, wheel_up, wheel_down, page_up, page_down, pointer, click, drag };

const EV_SYN = 0;
const EV_KEY = 1;
const EV_REL = 2;
const EV_ABS = 3;
const SYN_REPORT = 0;
const SYN_DROPPED = 3;
const REL_X = 0;
const REL_Y = 1;
const REL_WHEEL = 8;
const REL_WHEEL_HI_RES = 11;
const ABS_X = 0;
const ABS_Y = 1;
const ABS_HAT0X = 0x10;
const ABS_HAT0Y = 0x11;
const ABS_MT_SLOT = 0x2f;
const ABS_MT_POSITION_X = 0x35;
const ABS_MT_POSITION_Y = 0x36;
const ABS_MT_TRACKING_ID = 0x39;
const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_SOUTH = 0x130;
const BTN_EAST = 0x131;
const BTN_NORTH = 0x133;
const BTN_WEST = 0x134;
const BTN_TL = 0x136;
const BTN_TR = 0x137;
const BTN_SELECT = 0x13a;
const BTN_START = 0x13b;
const BTN_MODE = 0x13c;
const BTN_TOUCH = 0x14a;
const BTN_DPAD_UP = 0x220;
const BTN_DPAD_DOWN = 0x221;
const BTN_DPAD_LEFT = 0x222;
const BTN_DPAD_RIGHT = 0x223;

const EVIOCGRAB: u32 = 0x40044590;
const EVIOCGID: u32 = 0x80084502; // struct input_id: bustype, vendor, product, version
const BUS_USB = 0x03;
const BUS_I8042 = 0x11;
const EVIOCGBIT_KEY: u32 = 0x80604521; // EVIOCGBIT(EV_KEY, 96)
const EVIOCGBIT_ABS: u32 = 0x80084523; // EVIOCGBIT(EV_ABS, 8)
const EVIOCGBIT_REL: u32 = 0x80024522; // EVIOCGBIT(EV_REL, 2)

/// Keyboard keys. Enter/Esc commit only on a new press (never a held key
/// carried across screens); arrows and paging also follow key repeat.
pub fn key(code: u16, value: i32) Action {
    if (value == 2) return switch (code) {
        103, 105 => .previous,
        108, 106 => .next,
        104 => .scroll_up,
        109 => .scroll_down,
        else => .none,
    };
    if (value != 1) return .none;
    return switch (code) {
        103, 105 => .previous,
        108, 106, 15 => .next,
        28, 96, 57 => .accept,
        1, 14 => .back,
        104 => .scroll_up,
        109 => .scroll_down,
        else => .none,
    };
}

/// Gamepad face and shoulder buttons (press only): A/Start confirm the
/// selected item (menus open on a safe default), B/Back go back, LB/RB page
/// the details panel.
pub fn gamepadButton(code: u16) Action {
    return switch (code) {
        BTN_SOUTH, BTN_START => .accept,
        BTN_EAST, BTN_SELECT => .back,
        BTN_TL => .page_up,
        BTN_TR => .page_down,
        else => .none,
    };
}

fn isGamepadButton(code: u16) bool {
    return (code >= BTN_SOUTH and code <= 0x13e) or (code >= BTN_DPAD_UP and code <= BTN_DPAD_RIGHT);
}

/// Where a device's key presses count for the hint style.
pub fn keyOrigin(bustype: u16, vendor: u16, product: u16, on_handheld: bool) handheld.KeyOrigin {
    if (handheld.padKeyboard(vendor, product) != null and (bustype == BUS_USB or bustype == 0x05)) return .pad;
    if (bustype == BUS_I8042 and on_handheld) return .unattributed;
    return .keyboard;
}

const Device = struct {
    gamepad: bool = false,
    /// EVIOCGID: bus type and USB IDs.
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    touch: bool = false,
    uses_mt: bool = false,
    hires: bool = false,
    abs_x: AbsInfo = .{},
    abs_y: AbsInfo = .{},
    // Gamepad state.
    dpad: [4]bool = .{ false, false, false, false },
    hat_x: i32 = 0,
    hat_y: i32 = 0,
    stick_x: i32 = 0,
    stick_y: i32 = 0,
    stick: input_map.Stick = .{},
    // Pointer frame.
    dx: i32 = 0,
    dy: i32 = 0,
    wheel_raw: i32 = 0,
    wheel: input_map.WheelAccumulator = input_map.WheelAccumulator.fixed(120),
    raw_x: i32 = 0,
    raw_y: i32 = 0,
    abs_changed: bool = false,
    primary: bool = false,
    primary_changed: bool = false,
    slot: i32 = 0,
};

pub const Input = struct {
    fds: [64]linux.pollfd = [_]linux.pollfd{.{ .fd = -1, .events = 1, .revents = 0 }} ** 64,
    devices: [64]Device = [_]Device{.{}} ** 64,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    /// Draw the mouse cursor (relative mice and tablets, not touch or pads).
    pointer_visible: bool = false,
    /// x/y hold a real pointer or touch position.
    has_position: bool = false,
    /// The last input came from a gamepad (show A/B hints).
    gamepad_active: bool = false,
    /// The machine is a known handheld (DMI); read on the first scan.
    on_handheld: bool = false,
    dmi_read: bool = false,
    gesture: input_map.Gesture = .{},
    repeat: input_map.Repeat = .{},
    drag_dy: i32 = 0,
    queue: [16]Action = undefined,
    queued: usize = 0,

    pub fn scan(self: *Input) void {
        if (!self.dmi_read) {
            self.dmi_read = true;
            self.setHandheld(readDmiHandheld() != null);
        }
        if (self.gesture.threshold == 12 and self.width > 0) self.gesture.threshold = input_map.tapThreshold(@intCast(self.width), @intCast(self.height));
        for (&self.fds, 0..) |*slot, index| {
            if (slot.fd >= 0) continue;
            var path: [64]u8 = undefined;
            const name = std.fmt.bufPrintZ(&path, "/dev/input/event{d}", .{index}) catch continue;
            const result = linux.open(name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
            if (linux.errno(result) != .SUCCESS) continue;
            slot.fd = @intCast(result);
            // Route the device to this screen instead of the console keyboard.
            _ = linux.ioctl(slot.fd, EVIOCGRAB, 1);
            self.devices[index] = probe(slot.fd);
        }
    }

    pub fn close(self: *Input) void {
        for (&self.fds) |*slot| {
            if (slot.fd >= 0) {
                _ = linux.ioctl(slot.fd, EVIOCGRAB, 0);
                _ = linux.close(slot.fd);
                slot.fd = -1;
            }
        }
    }

    /// A handheld starts with pad hints.
    pub fn setHandheld(self: *Input, value: bool) void {
        self.on_handheld = value;
        if (value) self.gamepad_active = true;
    }

    /// Pixels dragged since the last .drag action (negative = finger up).
    pub fn takeDrag(self: *Input) i32 {
        const value = self.drag_dy;
        self.drag_dy = 0;
        return value;
    }

    pub fn next(self: *Input) Action {
        if (self.pop()) |action| return action;
        const now = monotonicMs();
        if (self.repeat.tick(now)) |direction| return directionAction(direction);
        const wait: i32 = if (self.repeat.wait(now)) |ms| @intCast(@min(ms + 1, 250)) else 250;
        const result = linux.poll(&self.fds, self.fds.len, wait);
        if (linux.errno(result) != .SUCCESS or result == 0) {
            if (self.repeat.tick(monotonicMs())) |direction| return directionAction(direction);
            self.scan();
            return .none;
        }
        for (&self.fds, 0..) |*slot, index| {
            if (slot.fd < 0 or slot.revents == 0) continue;
            // Drain everything the device has buffered, so a fast (1000 Hz)
            // mouse yields one present for its newest position instead of a
            // backlog of stale positions presented one by one.
            var reads: usize = 0;
            while (reads < 64) : (reads += 1) {
                var events: [64]Event = undefined;
                const n = linux.read(slot.fd, @ptrCast(&events), @sizeOf(@TypeOf(events)));
                if (linux.errno(n) == .AGAIN) break;
                if (linux.errno(n) == .INTR) continue;
                if (linux.errno(n) != .SUCCESS or n < @sizeOf(Event)) {
                    _ = linux.close(slot.fd);
                    slot.fd = -1;
                    break;
                }
                for (events[0 .. n / @sizeOf(Event)]) |event| self.handle(&self.devices[index], event);
                if (n < @sizeOf(@TypeOf(events))) break;
            }
        }
        return self.pop() orelse .none;
    }

    fn push(self: *Input, action: Action) void {
        if (action == .none or self.queued == self.queue.len) return;
        // Pointer moves carry no data (x/y already hold the newest position):
        // one queued .pointer is enough.
        if (action == .pointer) {
            for (self.queue[0..self.queued]) |queued| if (queued == .pointer) return;
        }
        self.queue[self.queued] = action;
        self.queued += 1;
    }

    fn pop(self: *Input) ?Action {
        if (self.queued == 0) return null;
        const action = self.queue[0];
        std.mem.copyForwards(Action, self.queue[0 .. self.queued - 1], self.queue[1..self.queued]);
        self.queued -= 1;
        return action;
    }

    /// Feeds one evdev event (public for tests).
    pub fn handle(self: *Input, device: *Device, event: Event) void {
        switch (event.kind) {
            EV_KEY => self.handleKey(device, event.code, event.value),
            EV_REL => switch (event.code) {
                REL_X => device.dx += event.value,
                REL_Y => device.dy += event.value,
                // Kernels with high-resolution wheels send both; use one.
                REL_WHEEL => if (!device.hires) {
                    device.wheel_raw += event.value * 120;
                },
                REL_WHEEL_HI_RES => {
                    if (!device.hires) {
                        device.hires = true;
                        device.wheel_raw = 0;
                    }
                    device.wheel_raw += event.value;
                },
                else => {},
            },
            EV_ABS => self.handleAbs(device, event.code, event.value),
            EV_SYN => switch (event.code) {
                SYN_REPORT => self.frame(device),
                SYN_DROPPED => {
                    device.dx = 0;
                    device.dy = 0;
                    device.wheel_raw = 0;
                    device.abs_changed = false;
                },
                else => {},
            },
            else => {},
        }
    }

    fn handleKey(self: *Input, device: *Device, code: u16, value: i32) void {
        switch (code) {
            BTN_LEFT, BTN_TOUCH => {
                const down = value != 0;
                if (down != device.primary) {
                    device.primary = down;
                    device.primary_changed = true;
                }
                if (code == BTN_TOUCH) device.touch = true;
                return;
            },
            BTN_RIGHT => {
                if (value == 1) self.push(.back);
                return;
            },
            else => {},
        }
        if (isGamepadButton(code)) {
            device.gamepad = true;
            self.gamepad_active = true;
            self.pointer_visible = false;
            switch (code) {
                BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT => device.dpad[code - BTN_DPAD_UP] = value != 0,
                else => if (value == 1) self.push(gamepadButton(code)),
            }
            return;
        }
        const action = key(code, value);
        // Keys with no menu action (volume, power) leave the style alone.
        if (value == 1 and (action != .none or handheld.evdevKeyboardOnly(code))) {
            const origin = keyOrigin(device.bustype, device.vendor, device.product, self.on_handheld);
            self.gamepad_active = handheld.styleAfterKey(self.gamepad_active, self.on_handheld, origin, handheld.evdevKeyboardOnly(code));
            if (origin == .pad) self.pointer_visible = false;
        }
        if (action != .none) self.push(action);
    }

    fn handleAbs(self: *Input, device: *Device, code: u16, value: i32) void {
        _ = self;
        if (device.gamepad) {
            switch (code) {
                ABS_X => device.stick_x = value,
                ABS_Y => device.stick_y = value,
                ABS_HAT0X => device.hat_x = value,
                ABS_HAT0Y => device.hat_y = value,
                else => {},
            }
            return;
        }
        switch (code) {
            ABS_X => if (!device.uses_mt) {
                device.raw_x = value;
                device.abs_changed = true;
            },
            ABS_Y => if (!device.uses_mt) {
                device.raw_y = value;
                device.abs_changed = true;
            },
            ABS_MT_SLOT => device.slot = value,
            ABS_MT_TRACKING_ID => if (device.uses_mt and device.slot == 0) {
                const down = value >= 0;
                if (down != device.primary) {
                    device.primary = down;
                    device.primary_changed = true;
                }
            },
            ABS_MT_POSITION_X => if (device.uses_mt and device.slot == 0) {
                device.raw_x = value;
                device.abs_changed = true;
            },
            ABS_MT_POSITION_Y => if (device.uses_mt and device.slot == 0) {
                device.raw_y = value;
                device.abs_changed = true;
            },
            else => {},
        }
    }

    fn frame(self: *Input, device: *Device) void {
        if (device.gamepad) {
            self.gamepadFrame(device);
            return;
        }
        var moved = false;
        if (device.dx != 0 or device.dy != 0) {
            self.x = std.math.clamp(self.x + device.dx, 0, @max(0, self.width - 1));
            self.y = std.math.clamp(self.y + device.dy, 0, @max(0, self.height - 1));
            device.dx = 0;
            device.dy = 0;
            self.pointer_visible = true;
            moved = true;
        }
        if (device.abs_changed) {
            device.abs_changed = false;
            const range = [4]u64{ widen(device.abs_x.minimum), widen(device.abs_x.maximum), widen(device.abs_y.minimum), widen(device.abs_y.maximum) };
            const rotation = input_map.autoRotation(range[1] -| range[0], range[3] -| range[2], @intCast(@max(1, self.width)), @intCast(@max(1, self.height)));
            const mapped = input_map.mapAbsolute(.{ widen(device.raw_x), widen(device.raw_y) }, range, rotation, @intCast(@max(1, self.width)), @intCast(@max(1, self.height)));
            self.x = @intCast(mapped[0]);
            self.y = @intCast(mapped[1]);
            // Tablets keep a cursor; a finger on a touchscreen does not.
            self.pointer_visible = !device.touch;
            moved = true;
        }
        if (moved) {
            self.has_position = true;
            // Pointer use means keyboard hints, except a touch on a handheld
            // or a handheld controller's own pointer (stick as a mouse).
            const from_pad = keyOrigin(device.bustype, device.vendor, device.product, self.on_handheld) == .pad;
            self.gamepad_active = handheld.styleAfterPointer(self.gamepad_active, self.on_handheld, true, device.touch, from_pad);
        }
        if (device.primary_changed) {
            device.primary_changed = false;
            if (device.primary) {
                self.gesture.press(self.x, self.y);
            } else if (self.gesture.release()) |tap| {
                self.x = tap.x;
                self.y = tap.y;
                self.has_position = true;
                self.push(.click);
                moved = false;
            }
        } else if (moved and device.primary) {
            if (self.gesture.move(self.x, self.y)) |drag| {
                self.drag_dy += drag.dy;
                self.push(.drag);
            }
        }
        if (moved) self.push(.pointer);
        if (device.wheel_raw != 0) {
            var notches = device.wheel.feed(device.wheel_raw);
            device.wheel_raw = 0;
            notches = std.math.clamp(notches, -5, 5);
            while (notches > 0) : (notches -= 1) self.push(.wheel_up);
            while (notches < 0) : (notches += 1) self.push(.wheel_down);
        }
    }

    fn gamepadFrame(self: *Input, device: *Device) void {
        const now = monotonicMs();
        var direction: ?input_map.Direction = null;
        if (device.dpad[0] or device.hat_y < 0) direction = .up else if (device.dpad[1] or device.hat_y > 0) direction = .down else if (device.dpad[2] or device.hat_x < 0) direction = .left else if (device.dpad[3] or device.hat_x > 0) direction = .right;
        const stick = device.stick.update(
            input_map.centreAxis(device.stick_x, device.abs_x.minimum, device.abs_x.maximum, 1000),
            input_map.centreAxis(device.stick_y, device.abs_y.minimum, device.abs_y.maximum, 1000),
            1000,
        );
        if (direction == null) direction = stick;
        if (direction != null) {
            self.gamepad_active = true;
            self.pointer_visible = false;
        }
        if (self.repeat.set(direction, now)) |fire| self.push(directionAction(fire));
    }
};

fn directionAction(direction: input_map.Direction) Action {
    return switch (direction) {
        .up => .previous,
        .down => .next,
        .left => .page_up,
        .right => .page_down,
    };
}

fn widen(value: i32) u64 {
    // Ranges may start below zero; shift into u64 space consistently.
    return @intCast(@as(i64, value) + (1 << 31));
}

fn testBit(bits: []const u8, bit: usize) bool {
    return bit / 8 < bits.len and (bits[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
}

fn probe(fd: i32) Device {
    var device = Device{};
    var keys: [96]u8 = @splat(0);
    var abs: [8]u8 = @splat(0);
    var rel: [2]u8 = @splat(0);
    _ = linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&keys));
    _ = linux.ioctl(fd, EVIOCGBIT_ABS, @intFromPtr(&abs));
    _ = linux.ioctl(fd, EVIOCGBIT_REL, @intFromPtr(&rel));
    var id: [4]u16 = @splat(0);
    if (linux.errno(linux.ioctl(fd, EVIOCGID, @intFromPtr(&id))) == .SUCCESS) {
        device.bustype = id[0];
        device.vendor = id[1];
        device.product = id[2];
    }
    device.gamepad = testBit(&keys, BTN_SOUTH) or testBit(&keys, BTN_DPAD_UP);
    device.touch = testBit(&keys, BTN_TOUCH) or testBit(&abs, ABS_MT_POSITION_X);
    device.hires = testBit(&rel, REL_WHEEL_HI_RES);
    // Pointer emulation (ABS_X/Y + BTN_TOUCH) is preferred; MT slot 0 only
    // when a touchscreen reports no single-touch axes.
    device.uses_mt = !device.gamepad and !testBit(&abs, ABS_X) and testBit(&abs, ABS_MT_POSITION_X);
    const x_axis: u32 = if (device.uses_mt) ABS_MT_POSITION_X else ABS_X;
    const y_axis: u32 = if (device.uses_mt) ABS_MT_POSITION_Y else ABS_Y;
    _ = linux.ioctl(fd, 0x80184540 + x_axis, @intFromPtr(&device.abs_x));
    _ = linux.ioctl(fd, 0x80184540 + y_axis, @intFromPtr(&device.abs_y));
    if (device.gamepad) {
        device.stick_x = @divTrunc(device.abs_x.minimum + device.abs_x.maximum, 2);
        device.stick_y = @divTrunc(device.abs_y.minimum + device.abs_y.maximum, 2);
    }
    return device;
}

/// The machine from /sys/class/dmi/id (same rules as SMBIOS on UEFI).
fn readDmiHandheld() ?handheld.Handheld {
    if (@import("builtin").os.tag != .linux) return null;
    var buffers: [5][96]u8 = undefined;
    const names = [5][:0]const u8{
        "/sys/class/dmi/id/sys_vendor",
        "/sys/class/dmi/id/product_name",
        "/sys/class/dmi/id/product_version",
        "/sys/class/dmi/id/board_vendor",
        "/sys/class/dmi/id/board_name",
    };
    var values: [5][]const u8 = @splat("");
    for (names, 0..) |name, index| values[index] = readSmall(name, &buffers[index]);
    const found = handheld.fromDmi(.{ .manufacturer = values[0], .product = values[1], .version = values[2], .board_manufacturer = values[3], .board_product = values[4] });
    std.debug.print("[FB_MENU] dmi vendor=\"{s}\" product=\"{s}\" handheld={s}\n", .{ values[0], values[1], if (found) |machine| machine.label() else "no" });
    return found;
}

fn readSmall(path: [:0]const u8, buffer: []u8) []const u8 {
    const result = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(result) != .SUCCESS) return "";
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(n) != .SUCCESS) return "";
    return std.mem.trim(u8, buffer[0..n], " \t\r\n");
}

fn monotonicMs() u64 {
    if (@import("builtin").os.tag != .linux) return 0;
    var now: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &now) != 0) return 0;
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}

pub fn scaleAxis(value: i32, minimum: i32, maximum: i32, extent: i32) i32 {
    const numerator = (@as(i64, value) - minimum) * (extent - 1);
    return @intCast(@max(0, @min(extent - 1, @divTrunc(numerator, @as(i64, maximum) - minimum))));
}

fn testInput() Input {
    return .{ .x = 320, .y = 240, .width = 640, .height = 480, .gesture = .{ .threshold = 10 } };
}

fn feed(input: *Input, device: *Device, kind: u16, code: u16, value: i32) void {
    input.handle(device, .{ .seconds = 0, .micros = 0, .kind = kind, .code = code, .value = value });
}

fn drain(input: *Input, out: []Action) []Action {
    var n: usize = 0;
    while (input.pop()) |action| : (n += 1) out[n] = action;
    return out[0..n];
}

test "input accepts arrows and mouse but never held enter" {
    try std.testing.expectEqual(Action.next, key(108, 1));
    try std.testing.expectEqual(Action.next, key(108, 2));
    try std.testing.expectEqual(Action.previous, key(103, 1));
    try std.testing.expectEqual(Action.accept, key(28, 1));
    try std.testing.expectEqual(Action.none, key(28, 2));
    try std.testing.expectEqual(Action.none, key(28, 0));
    try std.testing.expectEqual(Action.back, key(1, 1));
    try std.testing.expectEqual(@as(i32, 639), scaleAxis(32767, 0, 32767, 640));
    try std.testing.expectEqual(@as(i32, 0), scaleAxis(-1, 0, 32767, 640));
}

test "wheel: classic notches and high-resolution counts scroll once per notch" {
    var input = testInput();
    var mouse = Device{};
    var out: [16]Action = undefined;
    feed(&input, &mouse, EV_REL, REL_WHEEL, 1);
    feed(&input, &mouse, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{.wheel_up}, drain(&input, &out));
    var hires = Device{};
    for (0..3) |_| {
        feed(&input, &hires, EV_REL, REL_WHEEL_HI_RES, -40);
        feed(&input, &hires, EV_SYN, SYN_REPORT, 0);
    }
    // The classic REL_WHEEL the kernel adds for the same notch is ignored.
    feed(&input, &hires, EV_REL, REL_WHEEL, -1);
    feed(&input, &hires, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{.wheel_down}, drain(&input, &out));
}

test "mouse: a burst of motion frames queues a single pointer update" {
    var input = testInput();
    var mouse = Device{};
    var out: [16]Action = undefined;
    for (0..40) |_| {
        feed(&input, &mouse, EV_REL, REL_X, 3);
        feed(&input, &mouse, EV_REL, REL_Y, 1);
        feed(&input, &mouse, EV_SYN, SYN_REPORT, 0);
    }
    try std.testing.expectEqualSlices(Action, &.{.pointer}, drain(&input, &out));
    try std.testing.expectEqual(@as(i32, 320 + 120), input.x);
    try std.testing.expectEqual(@as(i32, 240 + 40), input.y);
    // A click after the moves is still delivered, after the one pointer.
    feed(&input, &mouse, EV_REL, REL_X, 1);
    feed(&input, &mouse, EV_SYN, SYN_REPORT, 0);
    feed(&input, &mouse, EV_KEY, BTN_LEFT, 1);
    feed(&input, &mouse, EV_SYN, SYN_REPORT, 0);
    feed(&input, &mouse, EV_KEY, BTN_LEFT, 0);
    feed(&input, &mouse, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{ .pointer, .click }, drain(&input, &out));
}

test "touch: tap clicks where the finger went down, a drag scrolls instead" {
    var input = testInput();
    var touch = Device{ .touch = true, .abs_x = .{ .maximum = 4095 }, .abs_y = .{ .maximum = 4095 } };
    var out: [16]Action = undefined;
    feed(&input, &touch, EV_ABS, ABS_X, 2048);
    feed(&input, &touch, EV_ABS, ABS_Y, 2048);
    feed(&input, &touch, EV_KEY, BTN_TOUCH, 1);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    feed(&input, &touch, EV_KEY, BTN_TOUCH, 0);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{ .pointer, .click }, drain(&input, &out));
    try std.testing.expect(!input.pointer_visible);
    try std.testing.expect(input.has_position);

    feed(&input, &touch, EV_KEY, BTN_TOUCH, 1);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    feed(&input, &touch, EV_ABS, ABS_Y, 1500);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    feed(&input, &touch, EV_KEY, BTN_TOUCH, 0);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    const actions = drain(&input, &out);
    try std.testing.expectEqualSlices(Action, &.{ .drag, .pointer }, actions);
    try std.testing.expect(input.takeDrag() < -50);
}

test "gamepad: A accepts, B goes back, D-pad and stick move with repeat" {
    var input = testInput();
    var pad = Device{ .gamepad = true, .abs_x = .{ .minimum = -32768, .maximum = 32767 }, .abs_y = .{ .minimum = -32768, .maximum = 32767 } };
    var out: [16]Action = undefined;
    feed(&input, &pad, EV_KEY, BTN_SOUTH, 1);
    feed(&input, &pad, EV_KEY, BTN_SOUTH, 0);
    feed(&input, &pad, EV_KEY, BTN_EAST, 1);
    feed(&input, &pad, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{ .accept, .back }, drain(&input, &out));
    try std.testing.expect(input.gamepad_active);
    feed(&input, &pad, EV_ABS, ABS_HAT0Y, 1);
    feed(&input, &pad, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{.next}, drain(&input, &out));
    feed(&input, &pad, EV_ABS, ABS_HAT0Y, 0);
    feed(&input, &pad, EV_SYN, SYN_REPORT, 0);
    // A small stick deflection stays inside the deadzone.
    feed(&input, &pad, EV_ABS, ABS_Y, -5000);
    feed(&input, &pad, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqual(@as(usize, 0), drain(&input, &out).len);
    feed(&input, &pad, EV_ABS, ABS_Y, -30000);
    feed(&input, &pad, EV_SYN, SYN_REPORT, 0);
    try std.testing.expectEqualSlices(Action, &.{.previous}, drain(&input, &out));
    try std.testing.expectEqual(Action.page_down, gamepadButton(BTN_TR));
    try std.testing.expectEqual(Action.accept, gamepadButton(BTN_START));
}

test "hint style: last input wins between keyboards and pads" {
    try std.testing.expectEqual(handheld.KeyOrigin.pad, keyOrigin(BUS_USB, 0x0B05, 0x1ABE, false));
    try std.testing.expectEqual(handheld.KeyOrigin.pad, keyOrigin(BUS_USB, 0x28DE, 0x1205, true));
    try std.testing.expectEqual(handheld.KeyOrigin.keyboard, keyOrigin(BUS_USB, 0x046D, 0xC31C, true));
    try std.testing.expectEqual(handheld.KeyOrigin.keyboard, keyOrigin(BUS_I8042, 0x0001, 0x0001, false));
    try std.testing.expectEqual(handheld.KeyOrigin.unattributed, keyOrigin(BUS_I8042, 0x0001, 0x0001, true));

    var input = testInput();
    var out: [16]Action = undefined;
    var ally = Device{ .bustype = BUS_USB, .vendor = 0x0B05, .product = 0x1ABE };
    var keyboard = Device{ .bustype = BUS_USB, .vendor = 0x046D, .product = 0xC31C };
    var pad = Device{ .gamepad = true };
    // The Ally's controller sends Enter as a keyboard: pad hints.
    feed(&input, &ally, EV_KEY, 28, 1);
    try std.testing.expect(input.gamepad_active);
    // A real keyboard: keyboard hints; a gamepad button: pad hints again.
    feed(&input, &keyboard, EV_KEY, 108, 1);
    try std.testing.expect(!input.gamepad_active);
    feed(&input, &pad, EV_KEY, BTN_SOUTH, 1);
    try std.testing.expect(input.gamepad_active);
    // Volume/power keys (no menu action) change nothing.
    feed(&input, &keyboard, EV_KEY, 115, 1);
    try std.testing.expect(input.gamepad_active);
    // Releases and repeats do not switch either.
    feed(&input, &keyboard, EV_KEY, 108, 0);
    try std.testing.expect(input.gamepad_active);
    try std.testing.expectEqualSlices(Action, &.{ .accept, .next, .accept }, drain(&input, &out));
}

test "hint style on a handheld: starts as pad, EC keyboard and touch keep it" {
    var input = testInput();
    input.setHandheld(true);
    try std.testing.expect(input.gamepad_active);
    var ec = Device{ .bustype = BUS_I8042, .vendor = 0x0001, .product = 0x0001 };
    // Arrows/Enter/Esc from the EC keyboard may be built-in buttons.
    feed(&input, &ec, EV_KEY, 103, 1);
    feed(&input, &ec, EV_KEY, 28, 1);
    try std.testing.expect(input.gamepad_active);
    // A touch tap keeps the pad hints.
    var touch = Device{ .touch = true, .abs_x = .{ .minimum = 0, .maximum = 639 }, .abs_y = .{ .minimum = 0, .maximum = 479 } };
    feed(&input, &touch, EV_KEY, BTN_TOUCH, 1);
    feed(&input, &touch, EV_ABS, ABS_X, 100);
    feed(&input, &touch, EV_ABS, ABS_Y, 100);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    feed(&input, &touch, EV_KEY, BTN_TOUCH, 0);
    feed(&input, &touch, EV_SYN, SYN_REPORT, 0);
    try std.testing.expect(input.gamepad_active);
    // A letter only comes from a keyboard.
    feed(&input, &ec, EV_KEY, 30, 1);
    try std.testing.expect(!input.gamepad_active);

    // Not a handheld: a touch means keyboard hints (as before).
    var desktop = testInput();
    desktop.gamepad_active = true;
    feed(&desktop, &touch, EV_KEY, BTN_TOUCH, 1);
    feed(&desktop, &touch, EV_ABS, ABS_X, 200);
    feed(&desktop, &touch, EV_SYN, SYN_REPORT, 0);
    try std.testing.expect(!desktop.gamepad_active);
}
