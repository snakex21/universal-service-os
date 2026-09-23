//! Loading screen shown while USOS starts and while it hands over to another
//! loader: the USOS logo tile and name centred on the menu background, a
//! 12-dot spinner and one status line ("Loading…", "Starting…").
//!
//! It is drawn straight into the visible framebuffer in pieces so a timer
//! (UEFI) or a load step can advance the spinner without redrawing the rest:
//! `draw` paints the whole screen once, `spinner` repaints only the dots and
//! `status` only the status line. With a firmware logo (ACPI BGRT, drawn by
//! the caller) the layout keeps the logo and puts the spinner and status
//! below it, the way Windows does.
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const surface_mod = @import("surface.zig");
const ui_mod = @import("ui.zig");
const paint = @import("paint.zig");
const Ui = ui_mod.Ui;

pub const product_name = "Universal Service OS";

/// Spinner dots; frame `n` lights dot `n % dot_count` with a fading tail.
pub const dot_count: u32 = 12;

/// sin(k * 30 degrees) * 1024 for k = 0..11 (cos is sin shifted by 3).
const sin_table = [dot_count]i32{ 0, 512, 887, 1024, 887, 512, 0, -512, -887, -1024, -887, -512 };

pub const Layout = struct {
    background: Color,
    /// Logo tile (USOS layout only).
    logo_x: u32 = 0,
    logo_y: u32 = 0,
    logo_size: u32 = 0,
    name_y: u32 = 0,
    /// Spinner centre and radii in paint sub-pixel units.
    spinner_cx: i32,
    spinner_cy: i32,
    ring_radius: i32,
    dot_radius: i32,
    /// Status line box (full width, one body line).
    status_y: u32,
    status_h: u32,

    /// Pixel box that holds every spinner dot (for tests and partial copies).
    pub fn spinnerBox(self: Layout) ui_mod.Rect {
        const reach = self.ring_radius + self.dot_radius;
        const x0 = @divFloor(self.spinner_cx - reach, paint.sub) - 1;
        const y0 = @divFloor(self.spinner_cy - reach, paint.sub) - 1;
        const x1 = @divFloor(self.spinner_cx + reach, paint.sub) + 2;
        const y1 = @divFloor(self.spinner_cy + reach, paint.sub) + 2;
        return .{ .x = @intCast(@max(x0, 0)), .y = @intCast(@max(y0, 0)), .w = @intCast(x1 - @max(x0, 0)), .h = @intCast(y1 - @max(y0, 0)) };
    }
};

fn spinnerRadii(ui: *const Ui) struct { ring: i32, dot: i32 } {
    return .{ .ring = paint.s(ui.px(14)), .dot = @divTrunc(paint.s(ui.px(10)), 4) };
}

/// Centred USOS layout: logo tile, product name, spinner, status line.
pub fn usosLayout(ui: *const Ui) Layout {
    const logo = ui.px(84);
    const name_gap = ui.px(22);
    const name_h = ui.fonts.lineHeight(.heading);
    const spinner_gap = ui.px(34);
    const radii = spinnerRadii(ui);
    const spinner_d: u32 = @intCast(@divTrunc(2 * (radii.ring + radii.dot), paint.sub) + 1);
    const status_gap = ui.px(24);
    const status_h = ui.fonts.lineHeight(.body);
    const block = logo + name_gap + name_h + spinner_gap + spinner_d + status_gap + status_h;
    // Optical centre slightly above the middle of the screen.
    const top = (ui.height() * 46 / 100) -| (block / 2);
    const logo_y = top;
    const name_y = logo_y + logo + name_gap;
    const spinner_top = name_y + name_h + spinner_gap;
    const status_y = spinner_top + spinner_d + status_gap;
    return .{
        .background = ui.theme.background,
        .logo_x = (ui.width() -| logo) / 2,
        .logo_y = logo_y,
        .logo_size = logo,
        .name_y = name_y,
        .spinner_cx = paint.s(ui.width() / 2),
        .spinner_cy = paint.s(spinner_top) + @divTrunc(paint.s(spinner_d), 2),
        .ring_radius = radii.ring,
        .dot_radius = radii.dot,
        .status_y = status_y,
        .status_h = status_h,
    };
}

/// Layout under a firmware logo whose bottom edge is `logo_bottom`: the
/// spinner sits at least 48 px below it (and not above 70% of the height),
/// on the black background the firmware drew the logo on.
pub fn firmwareLogoLayout(ui: *const Ui, logo_bottom: u32) Layout {
    const radii = spinnerRadii(ui);
    const spinner_d: u32 = @intCast(@divTrunc(2 * (radii.ring + radii.dot), paint.sub) + 1);
    const status_h = ui.fonts.lineHeight(.body);
    const status_gap = ui.px(20);
    var spinner_top = @max(logo_bottom + ui.px(48), ui.height() * 70 / 100);
    const needed = spinner_d + status_gap + status_h + ui.px(24);
    if (spinner_top + needed > ui.height()) spinner_top = ui.height() -| needed;
    return .{
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .spinner_cx = paint.s(ui.width() / 2),
        .spinner_cy = paint.s(spinner_top) + @divTrunc(paint.s(spinner_d), 2),
        .ring_radius = radii.ring,
        .dot_radius = radii.dot,
        .status_y = spinner_top + spinner_d + status_gap,
        .status_h = status_h,
    };
}

/// Paints the whole USOS splash (background, logo, name, status). The
/// spinner is not drawn: it appears only when loading takes long enough.
pub fn draw(ui: *const Ui, layout: Layout, status_text: []const u8) void {
    ui.surface.fill(layout.background);
    ui_mod.drawLogoOn(ui, layout.logo_x, layout.logo_y, layout.logo_size, layout.background);
    ui.fonts.drawCentered(ui.surface, ui.width() / 2, layout.name_y, .heading, product_name, ui.theme.text, layout.background);
    if (status_text.len > 0) status(ui, layout, status_text);
}

/// Repaints the status line.
pub fn status(ui: *const Ui, layout: Layout, text: []const u8) void {
    ui.surface.fillRect(0, layout.status_y, ui.width(), layout.status_h, layout.background);
    const max_w = ui.width() -| ui.px(64);
    const w = @min(ui.fonts.width(.body, text), max_w);
    _ = ui.fonts.drawFit(ui.surface, (ui.width() -| w) / 2, layout.status_y, max_w, .body, text, ui.theme.muted, layout.background);
}

/// Brightness (0..255 of the accent over the background) of `dot` in
/// spinner frame `frame`: the head is full, three dots trail behind it and
/// the rest stay faint, so the ring is visible but calm.
pub fn dotLevel(frame: u32, dot: u32) u8 {
    const head = frame % dot_count;
    const behind = (head + dot_count - (dot % dot_count)) % dot_count;
    return switch (behind) {
        0 => 255,
        1 => 190,
        2 => 135,
        3 => 95,
        else => 55,
    };
}

/// Draws spinner frame `frame` (every dot is repainted, nothing else).
pub fn spinner(ui: *const Ui, layout: Layout, frame: u32) void {
    var dot: u32 = 0;
    while (dot < dot_count) : (dot += 1) {
        const sin = sin_table[dot];
        const cos = sin_table[(dot + 3) % dot_count];
        const x = layout.spinner_cx + @divTrunc(layout.ring_radius * sin, 1024);
        const y = layout.spinner_cy - @divTrunc(layout.ring_radius * cos, 1024);
        const color = surface_mod.mix(layout.background, ui.theme.accent, dotLevel(frame, dot));
        paint.circle(ui.surface, x, y, layout.dot_radius, color, layout.background);
    }
}

const std = @import("std");

test "spinner head moves one dot per frame and keeps a fading tail" {
    try std.testing.expectEqual(@as(u8, 255), dotLevel(0, 0));
    try std.testing.expectEqual(@as(u8, 255), dotLevel(5, 5));
    try std.testing.expectEqual(@as(u8, 190), dotLevel(5, 4));
    try std.testing.expectEqual(@as(u8, 55), dotLevel(5, 6));
    try std.testing.expectEqual(@as(u8, 255), dotLevel(12, 0));
    try std.testing.expectEqual(@as(u8, 190), dotLevel(0, 11));
}

test "splash layouts fit common screens and keep the spinner inside its box" {
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const font = @import("font.zig");
    const lang_file = @import("../i18n/lang_file.zig");
    const Theme = @import("theme.zig").Theme;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const table = lang_file.Table.english_only;
    const sizes = [_][2]u32{ .{ 800, 600 }, .{ 1280, 800 }, .{ 1920, 1080 }, .{ 1024, 768 } };
    for (sizes) |size| {
        const pixels = try std.testing.allocator.alloc(u32, size[0] * size[1]);
        defer std.testing.allocator.free(pixels);
        const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, size[0], size[1], .bgrx8).?;
        const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
        const layout = usosLayout(&ui);
        try std.testing.expect(layout.status_y + layout.status_h < size[1]);
        draw(&ui, layout, "Wczytywanie\u{2026}");
        const background = buffer.surface.packColor(ui.theme.background);
        // Nothing outside the logo, name, spinner and status bands changed.
        try std.testing.expectEqual(background, pixels[0]);
        try std.testing.expectEqual(background, pixels[pixels.len - 1]);
        // The spinner only touches its own box.
        const box = layout.spinnerBox();
        var before: [4]u32 = undefined;
        const probes = [_][2]u32{ .{ box.x -| 2, box.y }, .{ box.right() + 1, box.y }, .{ box.x, box.y -| 2 }, .{ box.x, box.bottom() + 1 } };
        for (probes, 0..) |p, i| before[i] = buffer.surface.getRawPixel(p[0], p[1]);
        spinner(&ui, layout, 3);
        for (probes, 0..) |p, i| try std.testing.expectEqual(before[i], buffer.surface.getRawPixel(p[0], p[1]));
        // The head dot (frame 3 = 3 o'clock) is brighter than the dot opposite.
        const r = @divTrunc(layout.ring_radius, paint.sub);
        const cx: u32 = @intCast(@divTrunc(layout.spinner_cx, paint.sub));
        const cy: u32 = @intCast(@divTrunc(layout.spinner_cy, paint.sub));
        const head = buffer.surface.getPixel(cx + @as(u32, @intCast(r)), cy);
        const opposite = buffer.surface.getPixel(cx - @as(u32, @intCast(r)), cy);
        try std.testing.expect(head.g > opposite.g);
        // A new status replaces the old one without touching the spinner.
        const dot_pixel = buffer.surface.getRawPixel(cx + @as(u32, @intCast(r)), cy);
        status(&ui, layout, "Uruchamianie\u{2026}");
        try std.testing.expectEqual(dot_pixel, buffer.surface.getRawPixel(cx + @as(u32, @intCast(r)), cy));

        const bgrt = firmwareLogoLayout(&ui, size[1] / 2);
        try std.testing.expect(bgrt.status_y + bgrt.status_h <= size[1]);
        try std.testing.expect(@divTrunc(bgrt.spinner_cy - bgrt.ring_radius, paint.sub) > @as(i32, @intCast(size[1] / 2)));
    }
}
