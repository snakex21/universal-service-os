//! Boot UI toolkit shared by the UEFI menu, the Legacy BIOS Core and the
//! micro-Linux framebuffer UI. It mirrors the Windows installer's visual
//! language (installer/internal/ui): a header bar with the product name,
//! build and language, rounded cards and rows with icons and badges, a
//! progress card with a step list and a footer with key hints.
//!
//! All lengths are authored in logical pixels for ~1280x720 and scaled by
//! Ui.px(); text goes through text.Fonts; strings through lang_file.Table.
const std = @import("std");
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const Scale = @import("scale.zig").Scale;
const text = @import("text.zig");
const font = @import("font.zig");
const paint = @import("paint.zig");
const icons = @import("icons.zig");
const lang_file = @import("../i18n/lang_file.zig");
const rgba_image = @import("rgba_image.zig");

pub const Fonts = text.Fonts;
pub const Style = text.Style;
pub const Key = lang_file.Key;
pub const Icon = icons.Kind;

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }

    pub fn right(self: Rect) u32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u32 {
        return self.y + self.h;
    }

    pub fn inset(self: Rect, dx: u32, dy: u32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w -| (2 * dx), .h = self.h -| (2 * dy) };
    }
};

pub const Tone = enum { neutral, accent, success, warning, danger };

pub const Badge = struct {
    text: []const u8,
    tone: Tone = .neutral,
    /// A small dimmed dot instead of a labelled pill (low-key status such
    /// as "tested in a VM"; the details pane carries the words). `text`
    /// and `tone` are ignored.
    dot: bool = false,
};

pub const HeaderInfo = struct {
    /// "UEFI" or "BIOS".
    firmware: []const u8 = "",
    /// Build identifier (usos.build_info.id); shown shortened.
    build: []const u8 = "",
    /// Product version (usos.build_info.version, e.g. "1.0.0"); shown after
    /// the product name. Empty in development builds.
    version: []const u8 = "",
    /// Native language name shown in the language pill.
    language: []const u8 = "English",
    /// Pre-formatted clock, e.g. "Wed 23.09.2026 14:32" (may be empty).
    clock: []const u8 = "",
};

pub const Hint = struct {
    key: []const u8,
    label: []const u8,
};

/// Controller buttons a footer hint key can name. A hint key made only of
/// these names, separated by "/", is drawn as button glyphs ("A", "B",
/// "LB/RB", "Start", "DPad"); anything else is a keyboard key cap.
pub const PadButton = enum {
    a,
    b,
    x,
    y,
    lb,
    rb,
    lt,
    rt,
    ls,
    rs,
    start,
    view,
    dpad,

    const Name = struct { text: []const u8, button: PadButton };
    const names = [_]Name{
        .{ .text = "A", .button = .a },         .{ .text = "B", .button = .b },
        .{ .text = "X", .button = .x },         .{ .text = "Y", .button = .y },
        .{ .text = "LB", .button = .lb },       .{ .text = "RB", .button = .rb },
        .{ .text = "LT", .button = .lt },       .{ .text = "RT", .button = .rt },
        .{ .text = "LS", .button = .ls },       .{ .text = "RS", .button = .rs },
        .{ .text = "Start", .button = .start }, .{ .text = "Menu", .button = .start },
        .{ .text = "View", .button = .view },   .{ .text = "DPad", .button = .dpad },
    };

    pub fn parse(name: []const u8) ?PadButton {
        for (names) |entry| {
            if (std.mem.eql(u8, entry.text, name)) return entry.button;
        }
        return null;
    }

    pub fn label(self: PadButton) []const u8 {
        return switch (self) {
            .a => "A",
            .b => "B",
            .x => "X",
            .y => "Y",
            .lb => "LB",
            .rb => "RB",
            .lt => "LT",
            .rt => "RT",
            .ls => "LS",
            .rs => "RS",
            .start => "Start",
            .view => "View",
            .dpad => "DPad",
        };
    }

    /// Xbox face button colours from the installer palette: A green
    /// (Success), B red (Danger), X blue (the theme's pad_x: the installer
    /// palette has no blue status colour), Y yellow (Warning).
    pub fn faceColor(self: PadButton, theme: Theme) Color {
        return switch (self) {
            .a => theme.success,
            .b => theme.danger,
            .x => theme.pad_x,
            .y => theme.warning,
            else => theme.panel_alt,
        };
    }
};

pub const PadButtons = struct {
    items: [4]PadButton = undefined,
    len: usize = 0,

    pub fn slice(self: *const PadButtons) []const PadButton {
        return self.items[0..self.len];
    }
};

/// Splits a hint key into controller buttons; null when any part is not a
/// pad button (then the key is drawn as a keyboard key cap).
pub fn padButtons(key: []const u8) ?PadButtons {
    if (key.len == 0) return null;
    var result = PadButtons{};
    var parts = std.mem.splitScalar(u8, key, '/');
    while (parts.next()) |part| {
        if (result.len == result.items.len) return null;
        result.items[result.len] = PadButton.parse(part) orelse return null;
        result.len += 1;
    }
    return result;
}

pub const RowIcon = union(enum) {
    none,
    vector: Icon,
    /// 32x32 RGBA (UEFI decoded PNG).
    image: *const rgba_image.RgbaImage,
    /// 32x32 RGBA bytes (BIOS RLE icons).
    rgba: []const u8,
    /// Short label drawn in a tile, e.g. "ISO".
    label: []const u8,
};

pub const RowState = enum { normal, hover, selected };

pub const Row = struct {
    title: []const u8,
    detail: []const u8 = "",
    icon: RowIcon = .none,
    badge: ?Badge = null,
    enabled: bool = true,
};

pub const Ui = struct {
    surface: Surface,
    theme: Theme,
    fonts: Fonts,
    strings: *const lang_file.Table,

    pub fn init(surface: Surface, theme: Theme, pack: ?*const font.Pack, strings: *const lang_file.Table) Ui {
        const has_tier1 = if (pack) |value| value.hasTier(1) else true;
        const scale = Scale.forScreen(surface.framebuffer.width, surface.framebuffer.height, has_tier1);
        return .{ .surface = surface, .theme = theme, .fonts = Fonts.init(pack, scale), .strings = strings };
    }

    pub fn px(self: *const Ui, value: u32) u32 {
        return self.fonts.scale.px(value);
    }

    pub fn line(self: *const Ui, value: u32) u32 {
        return self.fonts.scale.line(value);
    }

    pub fn t(self: *const Ui, key: Key) []const u8 {
        return self.strings.get(key);
    }

    pub fn format(self: *const Ui, buffer: []u8, key: Key, args: []const []const u8) []const u8 {
        return self.strings.format(buffer, key, args);
    }

    /// Translates text that arrives as English (catalog labels, scripts).
    pub fn tr(self: *const Ui, buffer: []u8, english: []const u8) []const u8 {
        return self.strings.translate(buffer, english);
    }

    pub fn width(self: *const Ui) u32 {
        return self.surface.framebuffer.width;
    }

    pub fn height(self: *const Ui) u32 {
        return self.surface.framebuffer.height;
    }

    // ---------------------------------------------------------------- layout

    pub fn headerHeight(self: *const Ui) u32 {
        return self.px(64);
    }

    pub fn footerHeight(self: *const Ui) u32 {
        return self.px(44);
    }

    pub fn contentRect(self: *const Ui) Rect {
        const margin = self.px(32);
        const max = self.px(1180);
        const w = @min(self.width() -| (2 * margin), max);
        const x = (self.width() -| w) / 2;
        const top = self.headerHeight() + self.px(22);
        const bottom = self.height() -| self.footerHeight() -| self.px(16);
        return .{ .x = x, .y = top, .w = w, .h = bottom -| top };
    }

    /// Area below the page title and subtitle.
    pub fn bodyRect(self: *const Ui, has_subtitle: bool) Rect {
        const content = self.contentRect();
        const used = self.fonts.lineHeight(.heading) + (if (has_subtitle) self.px(4) + self.fonts.lineHeight(.body) else 0) + self.px(16);
        return .{ .x = content.x, .y = content.y + used, .w = content.w, .h = content.h -| used };
    }

    // ---------------------------------------------------------------- chrome

    pub fn clear(self: *const Ui) void {
        self.surface.fill(self.theme.background);
    }

    pub fn header(self: *const Ui, info: HeaderInfo) void {
        const h = self.headerHeight();
        const theme = self.theme;
        self.surface.fillRect(0, 0, self.width(), h, theme.header);
        self.surface.fillRect(0, h -| self.line(1), self.width(), self.line(1), theme.border);

        const margin = self.px(24);
        const logo = self.px(36);
        const logo_y = (h -| logo) / 2;
        drawLogo(self, margin, logo_y, logo);

        const title_x = margin + logo + self.px(14);
        const title_y = self.fonts.centeredTop(.strong, h / 2);
        var x = title_x + self.fonts.draw(self.surface, title_x, title_y, .strong, "Universal Service OS", theme.text, theme.header);
        if (info.version.len > 0) {
            x += self.px(6);
            x += self.fonts.draw(self.surface, x, title_y, .strong, info.version, theme.text, theme.header);
        }
        // Subtitle and build are dropped (build first) when they would run
        // into the clock area on narrow screens (640x480, 800x600).
        const limit = self.headerClockRight(info) -| self.headerClockWidth() -| self.px(12);
        const subtitle = self.t(.header_subtitle);
        x += self.px(10);
        if (x + self.fonts.width(.body, subtitle) <= limit) {
            x += self.fonts.draw(self.surface, x, self.fonts.centeredTop(.body, h / 2), .body, subtitle, theme.muted, theme.header);
            if (info.build.len > 0) {
                x += self.px(12);
                var buffer: [64]u8 = undefined;
                const build = self.format(&buffer, .header_build, &.{shortBuild(info.build)});
                if (x + self.fonts.width(.small, build) <= limit) {
                    _ = self.fonts.draw(self.surface, x, self.fonts.centeredTop(.small, h / 2), .small, build, theme.faint, theme.header);
                }
            }
        }

        var right = self.width() -| margin;
        right = self.languagePill(right, h, info.language);
        if (info.firmware.len > 0) {
            right -|= self.px(10);
            right = self.badgeRight(right, h / 2, .{ .text = info.firmware, .tone = .accent }, theme.header);
        }
        self.headerClockAt(right -| self.px(16), info.clock);
    }

    /// Right edge x of the header clock area for partial clock refreshes.
    pub fn headerClockRight(self: *const Ui, info: HeaderInfo) u32 {
        var right = self.width() -| self.px(24);
        right -|= self.languagePillWidth(info.language);
        if (info.firmware.len > 0) right -|= self.px(10) + self.badgeWidth(info.firmware);
        return right -| self.px(16);
    }

    /// Redraws only the clock (the header background must be solid there).
    fn headerClockWidth(self: *const Ui) u32 {
        return self.fonts.width(.body, "Www 00.00.0000 00:00") + self.px(8);
    }

    pub fn headerClockAt(self: *const Ui, right: u32, clock: []const u8) void {
        const h = self.headerHeight();
        const sample_width = self.headerClockWidth();
        const area_x = right -| sample_width;
        const area_h = self.fonts.lineHeight(.body);
        const y = self.fonts.centeredTop(.body, h / 2);
        self.surface.fillRect(area_x, y, sample_width, area_h, self.theme.header);
        if (clock.len > 0) _ = self.fonts.drawRight(self.surface, right, y, .body, clock, self.theme.muted, self.theme.header);
    }

    fn languagePillWidth(self: *const Ui, language: []const u8) u32 {
        return self.px(14 + 18 + 8 + 14) + self.fonts.width(.body, language);
    }

    fn languagePill(self: *const Ui, right: u32, header_h: u32, language: []const u8) u32 {
        const w = self.languagePillWidth(language);
        const h = self.px(34);
        const x = right -| w;
        const y = (header_h -| h) / 2;
        paint.card(self.surface, x, y, w, h, self.px(8), self.line(1), self.theme.border_strong, self.theme.header, self.theme.header);
        const icon = self.px(18);
        icons.draw(self.surface, .globe, x + self.px(14), y + (h -| icon) / 2, icon, self.theme.accent, null);
        _ = self.fonts.draw(self.surface, x + self.px(14 + 18 + 8), self.fonts.centeredTop(.body, y + h / 2), .body, language, self.theme.text, self.theme.header);
        return x;
    }

    pub fn pageTitle(self: *const Ui, title: []const u8, subtitle: []const u8) void {
        const content = self.contentRect();
        _ = self.fonts.drawFit(self.surface, content.x, content.y, content.w, .heading, title, self.theme.text, self.theme.background);
        if (subtitle.len > 0) {
            const y = content.y + self.fonts.lineHeight(.heading) + self.px(4);
            _ = self.fonts.drawFit(self.surface, content.x, y, content.w, .body, subtitle, self.theme.muted, self.theme.background);
        }
    }

    pub fn footer(self: *const Ui, hints: []const Hint, note: []const u8) void {
        const h = self.footerHeight();
        const y = self.height() -| h;
        const theme = self.theme;
        self.surface.fillRect(0, y, self.width(), h, theme.header);
        self.surface.fillRect(0, y, self.width(), self.line(1), theme.border);
        const margin = self.px(24);
        var x = margin;
        const note_width = if (note.len > 0) self.fonts.width(.small, note) + self.px(16) else 0;
        const limit = self.width() -| margin -| note_width;
        for (hints) |hint| {
            const needed = self.keycapWidth(hint.key) + self.px(8) + self.fonts.width(.small, hint.label);
            if (x + needed > limit) break;
            x = self.keycap(x, y + h / 2, hint.key, theme.header);
            x += self.px(8);
            x += self.fonts.draw(self.surface, x, self.fonts.centeredTop(.small, y + h / 2), .small, hint.label, theme.muted, theme.header);
            x += self.px(22);
        }
        if (note.len > 0) _ = self.fonts.drawRight(self.surface, self.width() -| margin, self.fonts.centeredTop(.small, y + h / 2), .small, note, theme.faint, theme.header);
    }

    /// Index of the footer hint at (x, y), for tapping or clicking a hint.
    /// The whole footer height counts, so the target is at least 44 logical
    /// pixels tall (66 px at 1080p), and the gap after each hint belongs to
    /// it. Mirrors the layout of `footer`.
    pub fn footerHit(self: *const Ui, hints: []const Hint, note: []const u8, x: u32, y: u32) ?usize {
        const h = self.footerHeight();
        const top = self.height() -| h;
        if (y < top or y >= self.height()) return null;
        const margin = self.px(24);
        var left = margin;
        const note_width = if (note.len > 0) self.fonts.width(.small, note) + self.px(16) else 0;
        const limit = self.width() -| margin -| note_width;
        for (hints, 0..) |hint, index| {
            const needed = self.keycapWidth(hint.key) + self.px(8) + self.fonts.width(.small, hint.label);
            if (left + needed > limit) break;
            const start = left -| self.px(11);
            left += needed + self.px(22);
            if (x >= start and x < left -| self.px(11)) return index;
        }
        return null;
    }

    /// Width of a footer hint symbol: a key cap, or controller button
    /// glyphs when every "/"-separated part of `key` names a pad button.
    fn keycapWidth(self: *const Ui, key: []const u8) u32 {
        if (padButtons(key)) |buttons| {
            var total: u32 = 0;
            for (buttons.slice(), 0..) |pad_button, index| {
                if (index > 0) total += self.px(4);
                total += self.padButtonWidth(pad_button);
            }
            return total;
        }
        return @max(self.px(24), self.fonts.width(.small, key) + self.px(14));
    }

    fn keycap(self: *const Ui, x: u32, center_y: u32, key: []const u8, background: Color) u32 {
        if (padButtons(key)) |buttons| {
            var right = x;
            for (buttons.slice(), 0..) |pad_button, index| {
                if (index > 0) right += self.px(4);
                right = self.padButton(right, center_y, pad_button, background);
            }
            return right;
        }
        const w = self.keycapWidth(key);
        const h = self.px(24);
        const y = center_y -| (h / 2);
        paint.card(self.surface, x, y, w, h, self.px(5), self.line(1), self.theme.border_strong, self.theme.panel_alt, background);
        // A slightly darker bottom lip gives the key some depth.
        self.surface.fillRect(x + self.px(4), y + h -| self.line(2), w -| self.px(8), self.line(1), self.theme.border);
        self.fonts.drawCentered(self.surface, x + w / 2, self.fonts.centeredTop(.small, y + h / 2), .small, key, self.theme.text, self.theme.panel_alt);
        return x + w;
    }

    fn padButtonWidth(self: *const Ui, kind: PadButton) u32 {
        return switch (kind) {
            .a, .b, .x, .y, .dpad => self.px(24),
            .start, .view => self.px(32),
            else => self.fonts.width(.small, kind.label()) + self.px(16),
        };
    }

    /// Draws one controller button the way the Windows installer does
    /// (installer/internal/ui/pad_hints_windows.go): A/B/X/Y as round face
    /// buttons in the Xbox colours with a dark letter; bumpers, triggers and
    /// sticks as pills; Start (three bars) and View (two windows) as pills
    /// with a symbol; the D-pad as a cross. All edges are anti-aliased and
    /// every length goes through px(). Returns the right edge.
    fn padButton(self: *const Ui, x: u32, center_y: u32, kind: PadButton, background: Color) u32 {
        const theme = self.theme;
        const w = self.padButtonWidth(kind);
        const surface = self.surface;
        switch (kind) {
            .a, .b, .x, .y => {
                const fill = kind.faceColor(theme);
                const radius = @divTrunc(paint.s(w), 2);
                paint.circle(surface, paint.s(x) + radius, paint.s(center_y), radius, fill, background);
                self.fonts.drawCentered(surface, x + w / 2, self.fonts.centeredTop(.strong, center_y), .strong, kind.label(), theme.on_pad, fill);
            },
            .dpad => {
                const cx = paint.s(x) + @divTrunc(paint.s(w), 2);
                const cy = paint.s(center_y);
                const arm = @divTrunc(paint.s(w), 2) - paint.s(self.px(1));
                const half = paint.s(self.px(4));
                const inset = paint.s(self.line(1));
                const outer = [_]paint.Box{
                    .{ .x0 = cx - arm, .y0 = cy - half, .x1 = cx + arm, .y1 = cy + half },
                    .{ .x0 = cx - half, .y0 = cy - arm, .x1 = cx + half, .y1 = cy + arm },
                };
                const inner = [_]paint.Box{
                    .{ .x0 = cx - arm + inset, .y0 = cy - half + inset, .x1 = cx + arm - inset, .y1 = cy + half - inset },
                    .{ .x0 = cx - half + inset, .y0 = cy - arm + inset, .x1 = cx + half - inset, .y1 = cy + arm - inset },
                };
                const x0: i32 = @intCast(x);
                const y0: i32 = @as(i32, @intCast(center_y)) - @as(i32, @intCast(w / 2)) - 1;
                const x1 = x0 + @as(i32, @intCast(w)) + 1;
                const y1 = y0 + @as(i32, @intCast(w)) + 3;
                paint.fillShape(surface, x0, y0, x1, y1, paint.Union(paint.Box){ .items = &outer }, theme.muted, background);
                paint.fillShape(surface, x0, y0, x1, y1, paint.Union(paint.Box){ .items = &inner }, theme.panel_alt, theme.muted);
            },
            else => {
                const h = self.px(22);
                const y = center_y -| (h / 2);
                paint.card(surface, x, y, w, h, h / 2, self.line(1), theme.border_strong, theme.panel_alt, background);
                switch (kind) {
                    .start => {
                        // Three short bars: the Menu/Start symbol.
                        const len = paint.s(self.px(10));
                        const thick = @max(paint.s(self.line(2)), paint.sub + @divTrunc(paint.sub, 2));
                        const cx = paint.s(x) + @divTrunc(paint.s(w), 2);
                        const gap = paint.s(self.px(4));
                        var bar: i32 = -1;
                        while (bar <= 1) : (bar += 1) {
                            const cy = paint.s(center_y) + bar * gap;
                            paint.capsule(surface, .{ .x0 = cx - @divTrunc(len, 2), .y0 = cy, .x1 = cx + @divTrunc(len, 2), .y1 = cy, .r = @divTrunc(thick, 2) }, theme.text, theme.panel_alt);
                        }
                    },
                    .view => {
                        // Two overlapping windows: the View/Back symbol.
                        const bw = self.px(9);
                        const bh = self.px(7);
                        const offset = self.px(3);
                        const left = x + (w -| (bw + offset)) / 2;
                        const top = center_y -| ((bh + offset) / 2);
                        const t1 = self.line(1);
                        paint.card(surface, left + offset, top, bw, bh, self.px(1), t1, theme.text, theme.panel_alt, theme.panel_alt);
                        paint.card(surface, left, top + offset, bw, bh, self.px(1), t1, theme.text, theme.panel_alt, theme.panel_alt);
                    },
                    else => self.fonts.drawCentered(surface, x + w / 2, self.fonts.centeredTop(.small, center_y), .small, kind.label(), theme.text, theme.panel_alt),
                }
            },
        }
        return x + w;
    }

    // ---------------------------------------------------------------- badges

    pub fn badgeWidth(self: *const Ui, label: []const u8) u32 {
        return self.fonts.width(.small, label) + self.px(20);
    }

    /// Draws a pill badge ending at `right`, vertically centred on center_y.
    /// Returns its left x.
    pub fn badgeRight(self: *const Ui, right: u32, center_y: u32, badge: Badge, background: Color) u32 {
        const w = self.badgeWidth(badge.text);
        const h = self.px(24);
        const x = right -| w;
        const y = center_y -| (h / 2);
        const colors = self.toneColors(badge.tone);
        paint.roundRect(self.surface, x, y, w, h, h / 2, colors.fill, background);
        self.fonts.drawCentered(self.surface, x + w / 2, self.fonts.centeredTop(.small, center_y), .small, badge.text, colors.text, colors.fill);
        return x;
    }

    pub fn toneColors(self: *const Ui, tone: Tone) struct { fill: Color, text: Color } {
        const theme = self.theme;
        return switch (tone) {
            .neutral => .{ .fill = theme.panel_alt, .text = theme.muted },
            .accent => .{ .fill = theme.accent_soft, .text = theme.accent },
            .success => .{ .fill = theme.success_soft, .text = theme.success },
            .warning => .{ .fill = theme.warning_soft, .text = theme.warning },
            .danger => .{ .fill = theme.danger_soft, .text = theme.danger },
        };
    }

    // ---------------------------------------------------------------- home cards

    pub fn homeCardRect(self: *const Ui, index: usize, count: usize) Rect {
        const body = self.bodyRect(true);
        const columns: u32 = if (body.w >= self.px(640) and count > 1) 2 else 1;
        const rows: u32 = @intCast((count + columns - 1) / columns);
        const gap = self.px(16);
        const card_w = (body.w -| (gap * (columns - 1))) / columns;
        const wanted_h = self.px(100);
        const fit_h = (body.h -| (gap * (rows -| 1))) / @max(rows, 1);
        const card_h = @min(wanted_h, fit_h);
        const column: u32 = @intCast(index % columns);
        const row_index: u32 = @intCast(index / columns);
        return .{ .x = body.x + column * (card_w + gap), .y = body.y + row_index * (card_h + gap), .w = card_w, .h = card_h };
    }

    pub fn homeCard(self: *const Ui, rect: Rect, icon: Icon, title: []const u8, description: []const u8, state: RowState) void {
        const theme = self.theme;
        const fill = switch (state) {
            .selected => theme.accent_soft,
            .hover => theme.panel_alt,
            .normal => theme.panel,
        };
        const border = switch (state) {
            .selected => theme.accent,
            .hover => theme.border_strong,
            .normal => theme.border,
        };
        const thickness = if (state == .selected) self.line(2) else self.line(1);
        // Clear the previous state's outer ring first (selection is thicker).
        self.surface.fillRect(rect.x, rect.y, rect.w, rect.h, theme.background);
        paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(10), thickness, border, fill, theme.background);

        const pad = self.px(20);
        const tile = @min(self.px(52), rect.h -| (2 * self.px(16)));
        const tile_x = rect.x + pad;
        const tile_y = rect.y + (rect.h -| tile) / 2;
        const tile_fill = if (state == .selected) theme.accent else theme.accent_soft;
        paint.roundRect(self.surface, tile_x, tile_y, tile, tile, self.px(10), tile_fill, fill);
        const glyph = tile * 3 / 5;
        icons.drawKind(self.surface, icon, tile_x + (tile - glyph) / 2, tile_y + (tile - glyph) / 2, glyph, if (state == .selected) theme.on_accent else theme.accent, null);

        const chevron = self.px(18);
        const text_x = tile_x + tile + self.px(18);
        const text_right = rect.right() -| pad -| chevron -| self.px(12);
        const text_w = text_right -| text_x;
        const title_h = self.fonts.lineHeight(.strong);
        var lines: [2][]const u8 = undefined;
        const line_count = self.fonts.wrap(.body, description, text_w, &lines, null);
        const block_h = title_h + self.px(4) + @as(u32, @intCast(line_count)) * self.fonts.lineHeight(.body);
        var y = rect.y + (rect.h -| block_h) / 2;
        _ = self.fonts.drawFit(self.surface, text_x, y, text_w, .strong, title, theme.text, fill);
        y += title_h + self.px(4);
        for (lines[0..line_count]) |value| {
            _ = self.fonts.drawFit(self.surface, text_x, y, text_w, .body, value, theme.muted, fill);
            y += self.fonts.lineHeight(.body);
        }
        icons.draw(self.surface, .chevron_right, rect.right() -| pad -| chevron, rect.y + (rect.h -| chevron) / 2, chevron, if (state == .selected) theme.accent else theme.faint, null);
    }

    // ---------------------------------------------------------------- lists

    pub const List = struct {
        panel: Rect,
        first_y: u32,
        row_x: u32,
        row_w: u32,
        row_h: u32,
        row_step: u32,
        visible: usize,

        pub fn rowRect(self: List, visible_index: usize) Rect {
            return .{ .x = self.row_x, .y = self.first_y + @as(u32, @intCast(visible_index)) * self.row_step, .w = self.row_w, .h = self.row_h };
        }

        pub fn hit(self: List, x: u32, y: u32, count: usize) ?usize {
            var index: usize = 0;
            while (index < @min(count, self.visible)) : (index += 1) {
                if (self.rowRect(index).contains(x, y)) return index;
            }
            return null;
        }
    };

    /// Row height for two-line rows (title + detail) or single-line rows.
    pub fn rowHeight(self: *const Ui, two_line: bool) u32 {
        return if (two_line) self.px(58) else self.px(46);
    }

    pub fn listLayout(self: *const Ui, area: Rect, row_h: u32) List {
        const pad = self.px(8);
        const gap = self.px(4);
        const step = row_h + gap;
        const usable = area.h -| (2 * pad);
        const visible: usize = @max(@as(usize, 1), (usable + gap) / step);
        return .{
            .panel = area,
            .first_y = area.y + pad,
            .row_x = area.x + pad,
            .row_w = area.w -| (2 * pad) -| self.px(10),
            .row_h = row_h,
            .row_step = step,
            .visible = visible,
        };
    }

    /// Panel height that fits `count` rows exactly (capped by `max_h`).
    pub fn listHeight(self: *const Ui, count: usize, row_h: u32, max_h: u32) u32 {
        const pad = self.px(8);
        const gap = self.px(4);
        const wanted = 2 * pad + @as(u32, @intCast(count)) * (row_h + gap) -| gap;
        return @min(wanted, max_h);
    }

    pub fn listPanel(self: *const Ui, layout: List) void {
        const p = layout.panel;
        paint.card(self.surface, p.x, p.y, p.w, p.h, self.px(10), self.line(1), self.theme.border, self.theme.panel, self.theme.background);
    }

    pub fn clearRow(self: *const Ui, layout: List, visible_index: usize) void {
        const r = layout.rowRect(visible_index);
        self.surface.fillRect(r.x, r.y, r.w, r.h, self.theme.panel);
    }

    pub fn scrollbar(self: *const Ui, layout: List, first: usize, count: usize) void {
        const p = layout.panel;
        const track_x = p.right() -| self.px(12);
        const track_y = layout.first_y;
        const track_h = @as(u32, @intCast(layout.visible)) * layout.row_step -| self.px(4);
        const bar_w = self.px(4);
        self.surface.fillRect(track_x, track_y, bar_w, track_h, self.theme.panel);
        if (count <= layout.visible or track_h == 0) return;
        const thumb_h = @max(self.px(24), @as(u32, @intCast((track_h * @as(u32, @intCast(layout.visible))) / @as(u32, @intCast(count)))));
        const range = track_h -| thumb_h;
        const max_first = count - layout.visible;
        const offset: u32 = (range * @as(u32, @intCast(@min(first, max_first)))) / @as(u32, @intCast(max_first));
        paint.roundRect(self.surface, track_x, track_y + offset, bar_w, thumb_h, bar_w / 2, self.theme.border_strong, self.theme.panel);
    }

    pub fn row(self: *const Ui, rect: Rect, item: Row, state: RowState) void {
        const theme = self.theme;
        self.surface.fillRect(rect.x, rect.y, rect.w, rect.h, theme.panel);
        // Disabled rows the list lets you select (blocked systems) take the
        // same selection and hover fill as normal rows; their text, icon and
        // badge stay greyed.
        const fill = switch (state) {
            .selected => theme.accent_soft,
            .hover => theme.panel_alt,
            .normal => theme.panel,
        };
        if (state == .selected) {
            paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(8), self.line(2), if (item.enabled) theme.accent else theme.border_strong, fill, theme.panel);
        } else if (state == .hover) {
            paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(8), self.line(1), theme.border_strong, fill, theme.panel);
        }

        const pad = self.px(14);
        var x = rect.x + pad;
        const icon_size = if (item.detail.len > 0) self.px(34) else self.px(28);
        const center_y = rect.y + rect.h / 2;
        switch (item.icon) {
            .none => {},
            .vector => |kind| {
                const tile = icon_size;
                paint.roundRect(self.surface, x, center_y -| tile / 2, tile, tile, self.px(8), if (item.enabled) theme.accent_soft else theme.disabled, fill);
                const glyph = tile * 3 / 5;
                icons.drawKind(self.surface, kind, x + (tile - glyph) / 2, center_y -| tile / 2 + (tile - glyph) / 2, glyph, if (item.enabled) theme.accent else theme.disabled_text, null);
                x += tile + self.px(14);
            },
            .image => |image| {
                drawRgba(self.surface, &image.pixels, x, center_y -| icon_size / 2, icon_size, fill, item.enabled);
                x += icon_size + self.px(14);
            },
            .rgba => |bytes| {
                if (bytes.len >= 32 * 32 * 4) drawRgba(self.surface, bytes[0 .. 32 * 32 * 4], x, center_y -| icon_size / 2, icon_size, fill, item.enabled);
                x += icon_size + self.px(14);
            },
            .label => |label| {
                const w = @max(icon_size + self.px(8), self.fonts.width(.small, label) + self.px(12));
                const h = self.px(24);
                paint.roundRect(self.surface, x, center_y -| h / 2, w, h, self.px(6), if (item.enabled) theme.accent_soft else theme.disabled, fill);
                self.fonts.drawCentered(self.surface, x + w / 2, self.fonts.centeredTop(.small, center_y), .small, label, if (item.enabled) theme.accent else theme.disabled_text, if (item.enabled) theme.accent_soft else theme.disabled);
                x += w + self.px(14);
            },
        }

        var right = rect.right() -| pad;
        if (state == .selected and item.enabled) {
            const chevron = self.px(16);
            icons.draw(self.surface, .chevron_right, right -| chevron, center_y -| chevron / 2, chevron, theme.accent, null);
            right -|= chevron + self.px(10);
        }
        if (item.badge) |badge| {
            if (badge.dot) {
                const d = self.px(6);
                paint.roundRect(self.surface, right -| d, center_y -| d / 2, d, d, d / 2, if (item.enabled) theme.muted else theme.disabled_text, fill);
                right -|= d + self.px(12);
            } else if (self.badgeWidth(badge.text) + self.px(120) < right -| x) {
                right = self.badgeRight(right, center_y, badge, fill) -| self.px(12);
            }
        }
        const text_w = right -| x;
        const title_color = if (!item.enabled) theme.disabled_text else theme.text;
        if (item.detail.len > 0) {
            const block = self.fonts.lineHeight(.strong) + self.fonts.lineHeight(.small);
            const top = center_y -| block / 2;
            _ = self.fonts.drawFit(self.surface, x, top, text_w, .strong, item.title, title_color, fill);
            _ = self.fonts.drawFit(self.surface, x, top + self.fonts.lineHeight(.strong), text_w, .small, item.detail, if (item.enabled) theme.muted else theme.disabled_text, fill);
        } else {
            _ = self.fonts.drawFit(self.surface, x, self.fonts.centeredTop(.strong, center_y), text_w, .strong, item.title, title_color, fill);
        }
    }

    // ---------------------------------------------------------------- panels

    /// A card with an optional icon, a title and wrapped lines. Returns the
    /// y below the last line.
    pub fn infoPanel(self: *const Ui, rect: Rect, icon: ?Icon, tone: Tone, title: []const u8, lines: []const []const u8, badge: ?Badge) u32 {
        const theme = self.theme;
        paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(10), self.line(1), theme.border, theme.panel, theme.background);
        const pad = self.px(20);
        var x = rect.x + pad;
        const colors = self.toneColors(tone);
        if (icon) |kind| {
            const size = self.px(24);
            icons.drawKind(self.surface, kind, x, rect.y + pad, size, if (tone == .neutral) theme.accent else colors.text, null);
            x += size + self.px(14);
        }
        const w = rect.right() -| pad -| x;
        var y = rect.y + pad;
        if (title.len > 0) {
            var title_w = w;
            if (badge) |value| {
                if (!value.dot) {
                    _ = self.badgeRight(rect.right() -| pad, y + self.fonts.lineHeight(.strong) / 2, value, theme.panel);
                    title_w -|= self.badgeWidth(value.text) + self.px(12);
                }
            }
            _ = self.fonts.drawFit(self.surface, x, y, title_w, .strong, title, if (tone == .neutral) theme.text else colors.text, theme.panel);
            y += self.fonts.lineHeight(.strong) + self.px(8);
        }
        for (lines) |value| {
            if (value.len == 0) continue;
            var wrapped: [4][]const u8 = undefined;
            const count = self.fonts.wrap(.body, value, w, &wrapped, null);
            for (wrapped[0..count]) |part| {
                if (y + self.fonts.lineHeight(.body) > rect.bottom() -| self.px(12)) return y;
                _ = self.fonts.drawFit(self.surface, x, y, w, .body, part, theme.muted, theme.panel);
                y += self.fonts.lineHeight(.body);
            }
            y += self.px(4);
        }
        return y;
    }

    /// Height an infoPanel needs for the given content and width.
    pub fn infoPanelHeight(self: *const Ui, w: u32, has_icon: bool, title: []const u8, lines: []const []const u8) u32 {
        const pad = self.px(20);
        const text_w = w -| (2 * pad) -| (if (has_icon) self.px(24 + 14) else 0);
        var h = 2 * pad;
        if (title.len > 0) h += self.fonts.lineHeight(.strong) + self.px(8);
        for (lines) |value| {
            if (value.len == 0) continue;
            var wrapped: [4][]const u8 = undefined;
            const count = self.fonts.wrap(.body, value, text_w, &wrapped, null);
            h += @as(u32, @intCast(count)) * self.fonts.lineHeight(.body) + self.px(4);
        }
        return h;
    }

    /// A tinted banner with a left accent bar and an icon (installer style).
    pub fn banner(self: *const Ui, rect: Rect, tone: Tone, icon: Icon, message: []const u8) void {
        const colors = self.toneColors(tone);
        paint.roundRect(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(8), colors.fill, self.theme.background);
        self.surface.fillRect(rect.x, rect.y + self.px(6), self.line(4), rect.h -| self.px(12), colors.text);
        const size = self.px(20);
        const icon_x = rect.x + self.px(20);
        icons.drawKind(self.surface, icon, icon_x, rect.y + (rect.h -| size) / 2, size, colors.text, null);
        const x = icon_x + size + self.px(14);
        _ = self.fonts.drawFit(self.surface, x, self.fonts.centeredTop(.body, rect.y + rect.h / 2), rect.right() -| x -| self.px(16), .body, message, self.theme.text, colors.fill);
    }

    /// A selectable offer strip (home screen): shield icon, message and an
    /// action label on the right, in the warning tone; selection and hover
    /// draw the same ring as the home cards.
    pub fn offerBanner(self: *const Ui, rect: Rect, message: []const u8, action: []const u8, state: RowState) void {
        const theme = self.theme;
        const colors = self.toneColors(.warning);
        const border = switch (state) {
            .selected => theme.accent,
            .hover => theme.border_strong,
            .normal => colors.text,
        };
        const thickness = if (state == .selected) self.line(2) else self.line(1);
        self.surface.fillRect(rect.x, rect.y, rect.w, rect.h, theme.background);
        paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(10), thickness, border, colors.fill, theme.background);
        const size = self.px(24);
        const icon_x = rect.x + self.px(18);
        icons.drawKind(self.surface, .shield, icon_x, rect.y + (rect.h -| size) / 2, size, colors.text, null);
        const action_w = if (action.len > 0) self.fonts.width(.strong, action) + self.px(28) else 0;
        const right = rect.right() -| self.px(16);
        if (action.len > 0) {
            const pill_h = self.px(32);
            const pill_x = right -| action_w;
            const pill_y = rect.y + (rect.h -| pill_h) / 2;
            paint.roundRect(self.surface, pill_x, pill_y, action_w, pill_h, pill_h / 2, colors.text, colors.fill);
            self.fonts.drawCentered(self.surface, pill_x + action_w / 2, self.fonts.centeredTop(.strong, pill_y + pill_h / 2), .strong, action, theme.background, colors.text);
        }
        const x = icon_x + size + self.px(14);
        const text_right = right -| action_w -| self.px(12);
        _ = self.fonts.drawFit(self.surface, x, self.fonts.centeredTop(.body, rect.y + rect.h / 2), text_right -| x, .body, message, theme.text, colors.fill);
    }

    /// Label/value rows. Returns the y below the last row.
    pub fn keyValues(self: *const Ui, rect: Rect, labels: []const []const u8, values: []const []const u8) u32 {
        const theme = self.theme;
        paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(10), self.line(1), theme.border, theme.panel, theme.background);
        const pad = self.px(20);
        var label_w: u32 = 0;
        for (labels) |label| label_w = @max(label_w, self.fonts.width(.body, label));
        label_w = @min(label_w + self.px(24), rect.w / 3);
        var y = rect.y + pad;
        const value_x = rect.x + pad + label_w;
        const value_w = rect.right() -| pad -| value_x;
        for (labels, values) |label, value| {
            if (y + self.fonts.lineHeight(.body) > rect.bottom() -| self.px(8)) break;
            _ = self.fonts.drawFit(self.surface, rect.x + pad, y, label_w -| self.px(12), .body, label, theme.muted, theme.panel);
            var wrapped: [3][]const u8 = undefined;
            const count = self.fonts.wrap(.body, value, value_w, &wrapped, null);
            for (wrapped[0..count]) |part| {
                _ = self.fonts.drawFit(self.surface, value_x, y, value_w, .body, part, theme.text, theme.panel);
                y += self.fonts.lineHeight(.body);
            }
            y += self.px(8);
        }
        return y;
    }

    pub fn keyValuesHeight(self: *const Ui, w: u32, labels: []const []const u8, values: []const []const u8) u32 {
        const pad = self.px(20);
        var label_w: u32 = 0;
        for (labels) |label| label_w = @max(label_w, self.fonts.width(.body, label));
        label_w = @min(label_w + self.px(24), w / 3);
        const value_w = w -| (2 * pad) -| label_w;
        var h = 2 * pad;
        for (values) |value| {
            var wrapped: [3][]const u8 = undefined;
            const count = self.fonts.wrap(.body, value, value_w, &wrapped, null);
            h += @as(u32, @intCast(@max(count, 1))) * self.fonts.lineHeight(.body) + self.px(8);
        }
        return h;
    }

    /// Size of a `button` with the given key cap ("" for none) and label.
    pub fn buttonSize(self: *const Ui, key: []const u8, label: []const u8) struct { w: u32, h: u32 } {
        const cap = if (key.len > 0) @max(self.px(26), self.fonts.width(.small, key) + self.px(12)) + self.px(12) else 0;
        return .{ .w = self.px(16) + cap + self.fonts.width(.strong, label) + self.px(20), .h = self.px(44) };
    }

    /// Primary (accent) or secondary button with a leading key cap label.
    pub fn button(self: *const Ui, rect: Rect, key: []const u8, label: []const u8, primary: bool, state: RowState, enabled: bool) void {
        const theme = self.theme;
        const fill = if (!enabled) theme.disabled else if (primary) (if (state == .hover) theme.accent_pressed else theme.accent) else if (state == .hover) theme.panel_alt else theme.panel;
        const fg = if (!enabled) theme.disabled_text else if (primary) theme.on_accent else theme.text;
        const border = if (primary and enabled) fill else theme.border_strong;
        self.surface.fillRect(rect.x, rect.y, rect.w, rect.h, theme.background);
        paint.card(self.surface, rect.x, rect.y, rect.w, rect.h, self.px(8), self.line(1), border, fill, theme.background);
        var x = rect.x + self.px(16);
        if (key.len > 0) {
            const cap_w = @max(self.px(26), self.fonts.width(.small, key) + self.px(12));
            const cap_h = self.px(22);
            const cap_y = rect.y + (rect.h -| cap_h) / 2;
            paint.card(self.surface, x, cap_y, cap_w, cap_h, self.px(5), self.line(1), fg, fill, fill);
            self.fonts.drawCentered(self.surface, x + cap_w / 2, self.fonts.centeredTop(.small, rect.y + rect.h / 2), .small, key, fg, fill);
            x += cap_w + self.px(12);
        }
        _ = self.fonts.drawFit(self.surface, x, self.fonts.centeredTop(.strong, rect.y + rect.h / 2), rect.right() -| x -| self.px(16), .strong, label, fg, fill);
    }

    /// Horizontal progress bar with a rounded track.
    pub fn progressBar(self: *const Ui, rect: Rect, percent: u8, tone: Tone, background: Color) void {
        const theme = self.theme;
        paint.roundRect(self.surface, rect.x, rect.y, rect.w, rect.h, rect.h / 2, theme.field, background);
        const filled: u32 = (rect.w * @as(u32, @min(percent, 100))) / 100;
        if (filled >= rect.h) {
            const color = switch (tone) {
                .success => theme.success,
                .danger => theme.danger,
                .warning => theme.warning,
                else => theme.accent,
            };
            paint.roundRect(self.surface, rect.x, rect.y, filled, rect.h, rect.h / 2, color, theme.field);
        }
    }
};

pub const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8 };

/// "Śr 23.09.2026 14:32" with the weekday from boot.day.N.
pub fn clockText(ui: *const Ui, buffer: []u8, now: DateTime) []const u8 {
    if (now.year == 0 or now.month < 1 or now.month > 12 or now.day < 1 or now.day > 31) return "";
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: u32 = now.year;
    if (now.month < 3) y -= 1;
    const weekday = (y + y / 4 - y / 100 + y / 400 + offsets[now.month - 1] + now.day) % 7;
    const days = [_]Key{ .day_0, .day_1, .day_2, .day_3, .day_4, .day_5, .day_6 };
    return std.fmt.bufPrint(buffer, "{s} {d:0>2}.{d:0>2}.{d:0>4} {d:0>2}:{d:0>2}", .{ ui.t(days[weekday]), now.day, now.month, now.year, now.hour, now.minute }) catch "";
}

fn shortBuild(build: []const u8) []const u8 {
    // "B260923-124620-62F8A603" -> "B260923-124620"
    var dashes: usize = 0;
    for (build, 0..) |byte, index| {
        if (byte != '-') continue;
        dashes += 1;
        if (dashes == 2) return build[0..index];
    }
    return build;
}

/// The USOS logo tile: a cyan rounded square with a dark "U" stroke.
pub fn drawLogo(ui: *const Ui, x: u32, y: u32, size: u32) void {
    drawLogoOn(ui, x, y, size, ui.theme.header);
}

/// The logo tile on `background` (its rounded corners blend into it).
pub fn drawLogoOn(ui: *const Ui, x: u32, y: u32, size: u32, background: Color) void {
    const theme = ui.theme;
    paint.roundRect(ui.surface, x, y, size, size, size / 4, theme.accent, background);
    const stroke = @max(@divTrunc(paint.s(size), 11), paint.sub);
    const left = paint.s(x) + @divTrunc(paint.s(size) * 31, 100);
    const right = paint.s(x) + @divTrunc(paint.s(size) * 69, 100);
    const top = paint.s(y) + @divTrunc(paint.s(size) * 25, 100);
    const bottom = paint.s(y) + @divTrunc(paint.s(size) * 56, 100);
    const radius = @divTrunc(right - left, 2);
    const shape = LogoU{
        .stems = .{ .items = &.{
            .{ .x0 = left, .y0 = top, .x1 = left, .y1 = bottom, .r = stroke },
            .{ .x0 = right, .y0 = top, .x1 = right, .y1 = bottom, .r = stroke },
        } },
        .bowl = .{
            .cx = left + radius,
            .cy = bottom,
            .r_outer = radius + stroke,
            .r_inner = radius - stroke,
            .gap = .{ .min_dx = -paint.s(size), .max_dx = paint.s(size), .max_dy = 0 },
        },
    };
    paint.fillShape(ui.surface, @intCast(x), @intCast(y), @intCast(x + size), @intCast(y + size), shape, theme.on_accent, theme.accent);
}

const LogoU = struct {
    stems: paint.Union(paint.Capsule),
    bowl: paint.Ring,

    pub fn inside(self: LogoU, px: i32, py: i32) bool {
        return self.stems.inside(px, py) or self.bowl.inside(px, py);
    }
};

/// Bilinear-scaled 32x32 RGBA icon blended over `background`.
pub fn drawRgba(surface: Surface, pixels: []const u8, x: u32, y: u32, size: u32, background: Color, enabled: bool) void {
    if (size == 0 or pixels.len < 32 * 32 * 4) return;
    var oy: u32 = 0;
    while (oy < size) : (oy += 1) {
        const v = ((2 * oy + 1) * 32 * 256) / (2 * size);
        const sy: i32 = @as(i32, @intCast(v)) - 128;
        const y0 = @divFloor(sy, 256);
        const fy: u32 = @intCast(sy - y0 * 256);
        var ox: u32 = 0;
        while (ox < size) : (ox += 1) {
            const u = ((2 * ox + 1) * 32 * 256) / (2 * size);
            const sx: i32 = @as(i32, @intCast(u)) - 128;
            const x0 = @divFloor(sx, 256);
            const fx: u32 = @intCast(sx - x0 * 256);
            var channels: [4]u32 = .{ 0, 0, 0, 0 };
            const weights = [4]u32{ (256 - fx) * (256 - fy), fx * (256 - fy), (256 - fx) * fy, fx * fy };
            const offsets = [4][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
            for (offsets, weights) |offset, weight| {
                const px = std.math.clamp(x0 + offset[0], 0, 31);
                const py = std.math.clamp(y0 + offset[1], 0, 31);
                const index: usize = @intCast((py * 32 + px) * 4);
                const alpha: u32 = pixels[index + 3];
                // Premultiply so transparent neighbours do not darken edges.
                channels[0] += pixels[index] * alpha * weight / 255;
                channels[1] += pixels[index + 1] * alpha * weight / 255;
                channels[2] += pixels[index + 2] * alpha * weight / 255;
                channels[3] += alpha * weight;
            }
            const alpha_total = channels[3] >> 16;
            if (alpha_total == 0) continue;
            const rgb = Color{
                .r = @intCast(@min(255, channels[0] / @max(channels[3] / 255, 1))),
                .g = @intCast(@min(255, channels[1] / @max(channels[3] / 255, 1))),
                .b = @intCast(@min(255, channels[2] / @max(channels[3] / 255, 1))),
            };
            var alpha: u32 = @min(alpha_total, 255);
            if (!enabled) alpha = alpha * 2 / 5;
            surface.blendPixel(x + ox, y + oy, rgb, @intCast(alpha), background);
        }
    }
}

test "toolkit renders a full home, list and panels at 1024x768 and 1920x1080" {
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const table = lang_file.Table.english_only;
    const sizes = [_][2]u32{ .{ 1024, 768 }, .{ 1920, 1080 }, .{ 800, 600 } };
    for (sizes) |size| {
        const pixels = try std.testing.allocator.alloc(u32, size[0] * size[1]);
        defer std.testing.allocator.free(pixels);
        const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, size[0], size[1], .bgrx8).?;
        const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
        ui.clear();
        ui.header(.{ .firmware = "UEFI", .build = "B260923-124620-62F8A603", .language = "Polski", .clock = "Wed 23.09.2026 14:32" });
        ui.pageTitle("What do you want to start?", "Choose what you want to boot or service");
        for (0..6) |index| {
            const rect = ui.homeCardRect(index, 6);
            try std.testing.expect(rect.right() <= size[0] and rect.bottom() < size[1] - ui.footerHeight());
            ui.homeCard(rect, .windows, "Windows", "Install and repair Microsoft Windows", if (index == 0) .selected else .normal);
        }
        const footer_hints = [_]Hint{ .{ .key = "Enter", .label = "Open" }, .{ .key = "Esc", .label = "Power" } };
        ui.footer(&footer_hints, "B260923");
        // Footer hints are touch targets: the full footer height, both hints.
        const footer_mid = size[1] - ui.footerHeight() / 2;
        try std.testing.expectEqual(@as(?usize, 0), ui.footerHit(&footer_hints, "B260923", ui.px(30), footer_mid));
        try std.testing.expectEqual(@as(?usize, 0), ui.footerHit(&footer_hints, "B260923", ui.px(30), size[1] - 1));
        const second_x = ui.px(24) + ui.keycapWidth("Enter") + ui.px(8) + ui.fonts.width(.small, "Open") + ui.px(22) + ui.px(4);
        try std.testing.expectEqual(@as(?usize, 1), ui.footerHit(&footer_hints, "B260923", second_x, footer_mid));
        try std.testing.expect(ui.footerHit(&footer_hints, "B260923", size[0] - 2, footer_mid) == null);
        try std.testing.expect(ui.footerHit(&footer_hints, "B260923", ui.px(30), size[1] - ui.footerHeight() - 2) == null);
        try std.testing.expect(ui.footerHeight() >= 44);
        const body = ui.bodyRect(true);
        const layout = ui.listLayout(body, ui.rowHeight(true));
        try std.testing.expect(layout.visible >= 5);
        ui.listPanel(layout);
        ui.row(layout.rowRect(0), .{ .title = "Windows 11", .detail = "Images: 2", .icon = .{ .vector = .windows }, .badge = .{ .text = "Ready", .tone = .success } }, .selected);
        ui.row(layout.rowRect(1), .{ .title = "Windows 95", .detail = "No image", .icon = .{ .label = "ISO" }, .enabled = false }, .hover);
        ui.scrollbar(layout, 3, 30);
        _ = ui.infoPanel(.{ .x = body.x, .y = body.y, .w = body.w / 2, .h = ui.px(200) }, .info, .neutral, "Automatic - recommended", &.{ "USOS chooses the best implemented boot method for the selected image.", "" }, .{ .text = "Ready", .tone = .success });
        ui.banner(.{ .x = body.x, .y = body.y, .w = body.w, .h = ui.px(44) }, .warning, .warning, "Do not disconnect the drive or turn off the computer.");
        ui.progressBar(.{ .x = body.x, .y = body.y, .w = body.w, .h = ui.px(8) }, 44, .accent, (Theme{}).panel);
        ui.button(.{ .x = body.x, .y = body.y, .w = ui.px(300), .h = ui.px(44) }, "Enter", "Load the Windows ISO", true, .normal, true);
        try std.testing.expect(pixels[0] != pixels[pixels.len / 2]);
    }
}

test "pad hint keys draw as controller glyphs, other keys as key caps" {
    try std.testing.expectEqual(@as(usize, 2), padButtons("LB/RB").?.len);
    try std.testing.expectEqual(PadButton.start, padButtons("Menu").?.slice()[0]);
    try std.testing.expect(padButtons("Enter") == null);
    try std.testing.expect(padButtons("PgUp/PgDn") == null);
    try std.testing.expect(padButtons("A/Esc") == null);
    try std.testing.expect(padButtons("") == null);
    try std.testing.expect(padButtons("D") == null);

    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const table = lang_file.Table.english_only;
    const sizes = [_][2]u32{ .{ 1024, 768 }, .{ 1920, 1080 } };
    for (sizes) |size| {
        const pixels = try std.testing.allocator.alloc(u32, size[0] * size[1]);
        defer std.testing.allocator.free(pixels);
        const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, size[0], size[1], .bgrx8).?;
        const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
        ui.clear();
        const hints = [_]Hint{ .{ .key = "A", .label = "Open" }, .{ .key = "B", .label = "Back" }, .{ .key = "LB/RB", .label = "Scroll" } };
        ui.footer(&hints, "");
        // Face buttons are round (DPI-scaled) and coloured: the centre of A
        // is the Success green, B the Danger red.
        const cy = size[1] - ui.footerHeight() / 2;
        const a_x = ui.px(24) + ui.px(24) / 2;
        const theme = Theme{};
        const a_pixel = buffer.surface.getRawPixel(a_x - ui.px(7), cy);
        try std.testing.expectEqual(@as(u32, theme.success.r), (a_pixel >> 16) & 0xff);
        try std.testing.expectEqual(@as(u32, theme.success.g), (a_pixel >> 8) & 0xff);
        const b_left = ui.px(24) + ui.keycapWidth("A") + ui.px(8) + ui.fonts.width(.small, "Open") + ui.px(22);
        const b_pixel = buffer.surface.getRawPixel(b_left + ui.px(5), cy);
        try std.testing.expectEqual(@as(u32, theme.danger.r), (b_pixel >> 16) & 0xff);
        // The circle's corner stays footer background (round, not square).
        const corner = buffer.surface.getRawPixel(ui.px(24), cy - ui.px(11));
        try std.testing.expectEqual(@as(u32, theme.header.r), (corner >> 16) & 0xff);
        // Hit-testing uses the same widths.
        try std.testing.expectEqual(@as(?usize, 1), ui.footerHit(&hints, "", b_left + ui.px(2), cy));
        try std.testing.expectEqual(@as(?usize, 2), ui.footerHit(&hints, "", b_left + ui.keycapWidth("B") + ui.px(8) + ui.fonts.width(.small, "Back") + ui.px(22) + ui.px(4), cy));
        try std.testing.expect(ui.keycapWidth("LB/RB") > 2 * ui.px(24));
    }
}
