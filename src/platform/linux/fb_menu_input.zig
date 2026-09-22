const std = @import("std");
const linux = std.os.linux;

pub const Event = extern struct { seconds: i64, micros: i64, kind: u16, code: u16, value: i32 };
const AbsInfo = extern struct { value: i32, minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32 };
pub const Action = enum { none, previous, next, accept, back, scroll_up, scroll_down, pointer, click };

pub fn key(code: u16, value: i32) Action {
    // Commit only on a new press, never a held key carried across screens.
    if (value != 1) return .none;
    return switch (code) {
        103, 105 => .previous,
        108, 106, 15 => .next,
        28, 96 => .accept,
        1 => .back,
        104 => .scroll_up,
        109 => .scroll_down,
        272 => .click,
        else => .none,
    };
}

pub const Input = struct {
    fds: [64]linux.pollfd = [_]linux.pollfd{.{ .fd = -1, .events = 1, .revents = 0 }} ** 64,
    x: i32, y: i32, width: i32, height: i32,
    pointer_visible: bool = false,

    pub fn scan(self: *Input) void {
        for (&self.fds, 0..) |*slot, index| {
            if (slot.fd >= 0) continue;
            var path: [64]u8 = undefined;
            const name = std.fmt.bufPrintZ(&path, "/dev/input/event{d}", .{index}) catch continue;
            const result = linux.open(name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
            if (linux.errno(result) != .SUCCESS) continue;
            slot.fd = @intCast(result);
            // Route the device to this screen instead of the console keyboard.
            _ = linux.ioctl(slot.fd, 0x40044590, 1); // EVIOCGRAB
        }
    }

    pub fn close(self: *Input) void {
        for (&self.fds) |*slot| {
            if (slot.fd >= 0) {
                _ = linux.ioctl(slot.fd, 0x40044590, 0);
                _ = linux.close(slot.fd);
                slot.fd = -1;
            }
        }
    }

    pub fn next(self: *Input) Action {
        const result = linux.poll(&self.fds, self.fds.len, 250);
        if (linux.errno(result) != .SUCCESS or result == 0) {
            self.scan();
            return .none;
        }
        for (&self.fds) |*slot| {
            if (slot.fd < 0 or slot.revents == 0) continue;
            var event: Event = undefined;
            const n = linux.read(slot.fd, @ptrCast(&event), @sizeOf(Event));
            if (linux.errno(n) == .AGAIN) continue;
            if (linux.errno(n) != .SUCCESS or n != @sizeOf(Event)) {
                _ = linux.close(slot.fd);
                slot.fd = -1;
                continue;
            }
            if (event.kind == 1) return key(event.code, event.value);
            if (event.kind == 2) {
                if (event.code == 8) return if (event.value > 0) .scroll_up else if (event.value < 0) .scroll_down else .none;
                if (event.code == 0) self.x = @intCast(@min(self.width - 1, @max(0, @as(i64, self.x) + event.value)));
                if (event.code == 1) self.y = @intCast(@min(self.height - 1, @max(0, @as(i64, self.y) + event.value)));
                if (event.code <= 1) { self.pointer_visible = true; return .pointer; }
            }
            if (event.kind == 3 and event.code <= 1) {
                var abs: AbsInfo = undefined;
                const r = linux.ioctl(slot.fd, 0x80184540 + @as(u32, event.code), @intFromPtr(&abs));
                if (linux.errno(r) == .SUCCESS and abs.maximum > abs.minimum) {
                    const extent = if (event.code == 0) self.width else self.height;
                    const position = scaleAxis(event.value, abs.minimum, abs.maximum, extent);
                    if (event.code == 0) self.x = position else self.y = position;
                    self.pointer_visible = true;
                    return .pointer;
                }
            }
        }
        return .none;
    }
};

pub fn scaleAxis(value: i32, minimum: i32, maximum: i32, extent: i32) i32 {
    const numerator = (@as(i64, value) - minimum) * (extent - 1);
    return @intCast(@max(0, @min(extent - 1, @divTrunc(numerator, @as(i64, maximum) - minimum))));
}

test "input accepts arrows and mouse but never held enter" {
    try std.testing.expectEqual(Action.next, key(108, 1));
    try std.testing.expectEqual(Action.previous, key(103, 1));
    try std.testing.expectEqual(Action.accept, key(28, 1));
    try std.testing.expectEqual(Action.none, key(28, 2));
    try std.testing.expectEqual(Action.none, key(28, 0));
    try std.testing.expectEqual(Action.click, key(272, 1));
    try std.testing.expectEqual(Action.back, key(1, 1));
    try std.testing.expectEqual(@as(i32, 639), scaleAxis(32767, 0, 32767, 640));
    try std.testing.expectEqual(@as(i32, 0), scaleAxis(-1, 0, 32767, 640));
}
