//! Flicker-free presentation for the boot menus without a GPU driver.
//!
//! Screens are drawn into a RAM back buffer and never directly on the
//! visible framebuffer. `Presenter.present` finds what changed since the
//! last present (row-band diff of the back buffer against a copy of what is
//! on screen), merges the changed areas with the old and new pointer
//! rectangles into a few dirty rectangles and hands each one, with the
//! pointer composited in, to a sink that writes it to the screen in one
//! operation (one GOP Blt on UEFI, row copies into the linear framebuffer
//! elsewhere). The pointer is never drawn into the back buffer, so there is
//! no save-under to go stale and no intermediate state (a cleared row, a
//! half-drawn card, a missing pointer) ever reaches the screen.
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const mix = @import("surface.zig").mix;
const cursor = @import("cursor.zig");

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn right(self: Rect) u32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u32 {
        return self.y + self.h;
    }

    /// True when the rectangles overlap or touch (then merging is cheap).
    pub fn near(self: Rect, other: Rect) bool {
        return self.x <= other.right() and other.x <= self.right() and self.y <= other.bottom() and other.y <= self.bottom();
    }

    pub fn unite(self: Rect, other: Rect) Rect {
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        return .{ .x = x, .y = y, .w = @max(self.right(), other.right()) - x, .h = @max(self.bottom(), other.bottom()) - y };
    }

    pub fn clip(self: Rect, width: u32, height: u32) Rect {
        const x = @min(self.x, width);
        const y = @min(self.y, height);
        return .{ .x = x, .y = y, .w = @min(self.right(), width) -| x, .h = @min(self.bottom(), height) -| y };
    }
};

/// One bounding rectangle in the size-limited i386 Legacy BIOS Core.
pub const max_rects: usize = if (@import("builtin").os.tag == .freestanding and @import("builtin").cpu.arch == .x86) 1 else 8;

/// A small set of dirty rectangles; touching or overlapping ones merge.
pub const Dirty = struct {
    rects: [max_rects]Rect = undefined,
    count: usize = 0,

    pub fn add(self: *Dirty, rect_in: Rect) void {
        if (rect_in.w == 0 or rect_in.h == 0) return;
        var rect = rect_in;
        var index: usize = 0;
        while (index < self.count) {
            if (self.rects[index].near(rect)) {
                rect = rect.unite(self.rects[index]);
                self.count -= 1;
                self.rects[index] = self.rects[self.count];
                index = 0;
                continue;
            }
            index += 1;
        }
        if (self.count == max_rects) {
            for (self.rects[1..self.count]) |other| self.rects[0] = self.rects[0].unite(other);
            self.count = 1;
            self.rects[0] = self.rects[0].unite(rect);
            return;
        }
        self.rects[self.count] = rect;
        self.count += 1;
    }
};

const band_rows: u32 = 32;

/// Adds the areas where `back` differs from `front` and copies them into
/// `front`. Both surfaces must have the same size and format.
pub fn diff(back: Surface, front: Surface, dirty: *Dirty) void {
    const width = back.framebuffer.width;
    const height = back.framebuffer.height;
    const b = pixels(back);
    const f = pixels(front);
    const bs: usize = back.framebuffer.pixels_per_scan_line;
    const fs: usize = front.framebuffer.pixels_per_scan_line;
    var band: u32 = 0;
    while (band < height) : (band += band_rows) {
        const end = @min(band + band_rows, height);
        var min_x: u32 = width;
        var max_x: u32 = 0;
        var first: u32 = end;
        var last: u32 = band;
        var y = band;
        while (y < end) : (y += 1) {
            const brow = b[@as(usize, y) * bs ..][0..width];
            const frow = f[@as(usize, y) * fs ..][0..width];
            var x: u32 = 0;
            while (x < width and brow[x] == frow[x]) x += 1;
            if (x == width) continue;
            var x_end: u32 = width;
            while (brow[x_end - 1] == frow[x_end - 1]) x_end -= 1;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x_end);
            first = @min(first, y);
            last = y + 1;
        }
        if (first >= last) continue;
        const rect = Rect{ .x = min_x, .y = first, .w = max_x - min_x, .h = last - first };
        copyRect(back, front, rect);
        dirty.add(rect);
    }
}

pub fn copyRect(from: Surface, to: Surface, rect: Rect) void {
    const src = pixels(from);
    const dst = pixels(to);
    var y = rect.y;
    while (y < rect.bottom()) : (y += 1) {
        const s = src[@as(usize, y) * from.framebuffer.pixels_per_scan_line + rect.x ..][0..rect.w];
        const d = dst[@as(usize, y) * to.framebuffer.pixels_per_scan_line + rect.x ..][0..rect.w];
        @memcpy(d, s);
    }
}

fn pixels(surface: Surface) [*]u32 {
    return @ptrFromInt(@as(usize, @intCast(surface.framebuffer.address)));
}

pub const Pointer = struct {
    sprite: *const cursor.Sprite,
    x: u32,
    y: u32,

    pub fn rect(self: Pointer) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.sprite.width, .h = self.sprite.height };
    }
};

/// Writes `back[rect]` with the pointer blended in to `out` (stride rect.w,
/// the back buffer's pixel format).
pub fn compose(back: Surface, rect: Rect, pointer: ?Pointer, out: []u32) void {
    const src = pixels(back);
    const stride: usize = back.framebuffer.pixels_per_scan_line;
    var row: u32 = 0;
    while (row < rect.h) : (row += 1) {
        @memcpy(out[@as(usize, row) * rect.w ..][0..rect.w], src[@as(usize, rect.y + row) * stride + rect.x ..][0..rect.w]);
    }
    const p = pointer orelse return;
    const sprite = p.sprite;
    const x0 = @max(p.x, rect.x);
    const y0 = @max(p.y, rect.y);
    const x1 = @min(p.x + sprite.width, rect.right());
    const y1 = @min(p.y + sprite.height, rect.bottom());
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const index = (y - p.y) * cursor.max_width + (x - p.x);
            const alpha = sprite.alpha[index];
            if (alpha == 0) continue;
            const at = @as(usize, y - rect.y) * rect.w + (x - rect.x);
            out[at] = back.packColor(mix(back.unpackColor(out[at]), sprite.color[index], alpha));
        }
    }
}

/// Destination of composited rectangles: `write(context, rect, pixels)`
/// with `pixels` in the back buffer's format, stride rect.w.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, rect: Rect, pixels: []const u32) void,
};

pub const Presenter = struct {
    back: Surface,
    front: Surface,
    /// At least width * height pixels.
    scratch: []u32,
    pointer: ?Pointer = null,
    shown_pointer: ?Rect = null,
    /// Set after the screen was drawn by someone else (splash, a backend,
    /// an EFI application): the next present sends the whole frame.
    stale: bool = true,

    pub fn invalidate(self: *Presenter) void {
        self.stale = true;
    }

    /// Shows the back buffer's changes and the pointer at its current place.
    pub fn present(self: *Presenter, sink: Sink) void {
        self.presentWith(sink, true);
    }

    /// Only the pointer moved and the back buffer is unchanged since the
    /// last present: repaint just the old and new pointer rectangles, with
    /// no full-screen diff (which costs milliseconds per move at 1080p and
    /// made a 1000 Hz mouse fall behind).
    pub fn presentPointer(self: *Presenter, sink: Sink) void {
        self.presentWith(sink, false);
    }

    fn presentWith(self: *Presenter, sink: Sink, compare: bool) void {
        const width = self.back.framebuffer.width;
        const height = self.back.framebuffer.height;
        var dirty = Dirty{};
        if (self.stale) {
            const all = Rect{ .x = 0, .y = 0, .w = width, .h = height };
            copyRect(self.back, self.front, all);
            dirty.add(all);
            self.stale = false;
        } else if (compare) {
            diff(self.back, self.front, &dirty);
        }
        const now: ?Rect = if (self.pointer) |p| p.rect().clip(width, height) else null;
        const moved = !rectEql(now, self.shown_pointer);
        if (moved) {
            if (self.shown_pointer) |old| dirty.add(old);
            if (now) |new| dirty.add(new);
        }
        self.shown_pointer = now;
        for (dirty.rects[0..dirty.count]) |rect| {
            const out = self.scratch[0 .. @as(usize, rect.w) * rect.h];
            compose(self.back, rect, self.pointer, out);
            sink.write(sink.context, rect, out);
        }
    }
};

fn rectEql(a: ?Rect, b: ?Rect) bool {
    if (a == null or b == null) return a == null and b == null;
    const x = a.?;
    const y = b.?;
    return x.x == y.x and x.y == y.y and x.w == y.w and x.h == y.h;
}

/// Sink that copies rows into a linear framebuffer surface of the same
/// pixel format (Legacy BIOS VBE, Linux fbdev, tests).
pub fn surfaceSink(target: *const Surface) Sink {
    return .{ .context = @ptrCast(@constCast(target)), .write = writeSurface };
}

fn writeSurface(context: *anyopaque, rect: Rect, source: []const u32) void {
    const target: *const Surface = @ptrCast(@alignCast(context));
    const dst: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(target.framebuffer.address)));
    const stride: usize = target.framebuffer.pixels_per_scan_line;
    var row: u32 = 0;
    while (row < rect.h) : (row += 1) {
        const base = @as(usize, rect.y + row) * stride + rect.x;
        const line = source[@as(usize, row) * rect.w ..][0..rect.w];
        for (line, 0..) |value, column| dst[base + column] = value;
    }
}

const std = @import("std");

test "dirty rectangles merge when they touch and collapse when full" {
    var dirty = Dirty{};
    dirty.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    dirty.add(.{ .x = 10, .y = 5, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(usize, 1), dirty.count);
    try std.testing.expectEqual(@as(u32, 15), dirty.rects[0].w);
    dirty.add(.{ .x = 100, .y = 100, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(usize, 2), dirty.count);
    for (0..20) |i| dirty.add(.{ .x = @intCast(200 + i * 10), .y = 0, .w = 1, .h = 1 });
    try std.testing.expect(dirty.count <= max_rects);
}

const TestScreen = struct {
    const w = 160;
    const h = 120;
    back: [w * h]u32 = [_]u32{0} ** (w * h),
    front: [w * h]u32 = [_]u32{0} ** (w * h),
    video: [w * h]u32 = [_]u32{0x123456} ** (w * h),
    expected: [w * h]u32 = [_]u32{0} ** (w * h),
    scratch: [w * h]u32 = undefined,

    fn surface(pixels_: *[w * h]u32) Surface {
        return Surface.init(.{ .address = @intFromPtr(pixels_), .size = w * h * 4, .width = w, .height = h, .pixels_per_scan_line = w, .pixel_format = .bgrx8 }).?;
    }

    /// The "UI": a background, a row of buttons and one hovered button.
    fn render(target: Surface, hovered: ?u32) void {
        target.fill(.{ .r = 8, .g = 13, .b = 20 });
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const color: Color = if (hovered != null and hovered.? == i) .{ .r = 20, .g = 91, .b = 122 } else .{ .r = 16, .g = 25, .b = 35 };
            @import("paint.zig").roundRect(target, 8 + i * 38, 40, 34, 30, 6, color, .{ .r = 8, .g = 13, .b = 20 });
        }
    }
};

test "composited dirty-rect presents equal a clean render with the pointer" {
    var screen = TestScreen{};
    var sprite = cursor.Sprite{};
    sprite.build(2);
    const back = TestScreen.surface(&screen.back);
    const video = TestScreen.surface(&screen.video);
    var presenter = Presenter{ .back = back, .front = TestScreen.surface(&screen.front), .scratch = &screen.scratch };
    const sink = surfaceSink(&video);

    TestScreen.render(back, null);
    presenter.present(sink);
    // Pointer moves over the buttons; the hovered button changes on the way.
    const path = [_][3]u32{ .{ 5, 5, 99 }, .{ 20, 45, 0 }, .{ 30, 50, 0 }, .{ 50, 52, 1 }, .{ 60, 60, 1 }, .{ 90, 45, 2 }, .{ 150, 110, 99 }, .{ 100, 55, 2 } };
    for (path, 0..) |step, n| {
        const hovered: ?u32 = if (step[2] == 99) null else step[2];
        // Hover repaint only when the hovered item changes.
        if (n == 0 or path[n - 1][2] != step[2]) TestScreen.render(back, hovered);
        presenter.pointer = .{ .sprite = &sprite, .x = step[0], .y = step[1] };
        presenter.present(sink);

        // Reference: a clean render of the same state with the pointer.
        const reference = TestScreen.surface(&screen.expected);
        TestScreen.render(reference, hovered);
        var full: [TestScreen.w * TestScreen.h]u32 = undefined;
        compose(reference, .{ .x = 0, .y = 0, .w = TestScreen.w, .h = TestScreen.h }, presenter.pointer, &full);
        try std.testing.expectEqualSlices(u32, &full, &screen.video);
    }
    // Pointer-only presents (no diff) give the same picture while the back
    // buffer is unchanged.
    for ([_][2]u32{ .{ 10, 10 }, .{ 70, 80 }, .{ 159, 119 } }) |at| {
        presenter.pointer = .{ .sprite = &sprite, .x = at[0], .y = at[1] };
        presenter.presentPointer(sink);
        const reference = TestScreen.surface(&screen.expected);
        TestScreen.render(reference, 2);
        var full: [TestScreen.w * TestScreen.h]u32 = undefined;
        compose(reference, .{ .x = 0, .y = 0, .w = TestScreen.w, .h = TestScreen.h }, presenter.pointer, &full);
        try std.testing.expectEqualSlices(u32, &full, &screen.video);
    }
    // Hiding the pointer restores the clean frame.
    presenter.pointer = null;
    presenter.present(sink);
    try std.testing.expectEqualSlices(u32, &screen.back, &screen.video);
    // The back buffer never holds the pointer.
    try std.testing.expectEqualSlices(u32, &screen.back, &screen.front);
}
