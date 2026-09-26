//! Live preview of a theme being edited (the UEFI theme editor, docs/
//! menu-themes.md): a small mock of the menu drawn with the edited colours
//! next to the form (which keeps the current menu theme, so the editor
//! stays readable whatever is being tried), and the contrast result.
const std = @import("std");
const ui_mod = @import("ui.zig");
const paint = @import("paint.zig");
const icons = @import("icons.zig");
const Theme = @import("theme.zig").Theme;
const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const Labels = struct {
    title: []const u8 = "Preview",
    row: []const u8 = "Selected row",
    text: []const u8 = "Text and secondary text",
    button: []const u8 = "Button",
    disabled: []const u8 = "Disabled",
    /// Contrast result line; `ok` picks the colour.
    contrast: []const u8 = "",
    ok: bool = true,
};

/// Draws the preview in `rect` (menu theme around it, edited theme inside).
pub fn draw(menu: *const Ui, rect: Rect, edited: Theme, labels: Labels) void {
    const mt = menu.theme;
    menu.surface.fillRect(rect.x, rect.y, rect.w, rect.h, mt.background);
    _ = menu.fonts.drawFit(menu.surface, rect.x, rect.y, rect.w, .strong, labels.title, mt.text, mt.background);
    const top = rect.y + menu.fonts.lineHeight(.strong) + menu.px(8);
    const status_h = menu.px(44);
    const box = Rect{ .x = rect.x, .y = top, .w = rect.w, .h = rect.bottom() -| top -| status_h -| menu.px(10) };
    const u = Ui{ .surface = menu.surface, .theme = edited, .fonts = menu.fonts, .strings = menu.strings };
    const t = edited;
    paint.card(u.surface, box.x, box.y, box.w, box.h, u.px(10), u.line(1), t.border_strong, t.background, mt.background);
    // Header strip.
    const header_h = u.px(34);
    const inner = box.inset(u.line(1), u.line(1));
    u.surface.fillRect(inner.x + u.px(6), inner.y + u.px(6), inner.w -| u.px(12), header_h, t.header);
    u.surface.fillRect(inner.x + u.px(6), inner.y + u.px(6) + header_h, inner.w -| u.px(12), u.line(1), t.border);
    _ = u.fonts.drawFit(u.surface, inner.x + u.px(16), u.fonts.centeredTop(.strong, inner.y + u.px(6) + header_h / 2), inner.w / 2, .strong, "USOS", t.text, t.header);
    var y = inner.y + u.px(6) + header_h + u.px(10);
    const x = inner.x + u.px(10);
    const w = inner.w -| u.px(20);
    // A panel with a normal and a selected row.
    const panel_h = u.px(96);
    paint.card(u.surface, x, y, w, panel_h, u.px(8), u.line(1), t.border, t.panel, t.background);
    const row_h = u.px(38);
    u.row(.{ .x = x + u.px(6), .y = y + u.px(6), .w = w -| u.px(12), .h = row_h }, .{ .title = labels.text, .icon = .{ .vector = .windows } }, .normal);
    u.row(.{ .x = x + u.px(6), .y = y + u.px(8) + row_h, .w = w -| u.px(12), .h = row_h }, .{ .title = labels.row, .icon = .{ .vector = .gear }, .badge = .{ .text = "OK", .tone = .success } }, .selected);
    y += panel_h + u.px(10);
    // Secondary and faint text, disabled.
    _ = u.fonts.drawFit(u.surface, x, y, w, .body, labels.text, t.muted, t.background);
    y += u.fonts.lineHeight(.body) + u.px(2);
    _ = u.fonts.drawFit(u.surface, x, y, w, .small, labels.disabled, t.disabled_text, t.background);
    y += u.fonts.lineHeight(.small) + u.px(10);
    // Buttons and badges.
    const size = u.buttonSize("", labels.button);
    const bw = @min(size.w, w / 2);
    if (y + size.h <= box.bottom() -| u.px(40)) {
        u.button(.{ .x = x, .y = y, .w = bw, .h = size.h }, "", labels.button, true, .normal, true);
        var bx = x + bw + u.px(12);
        inline for (.{ ui_mod.Tone.success, ui_mod.Tone.warning, ui_mod.Tone.danger }) |tone| {
            const label = switch (tone) {
                .success => "A",
                .warning => "Y",
                else => "B",
            };
            const bwidth = u.badgeWidth(label);
            if (bx + bwidth < x + w) _ = u.badgeRight(bx + bwidth, y + size.h / 2, .{ .text = label, .tone = tone }, t.background);
            bx += bwidth + u.px(8);
        }
        y += size.h + u.px(10);
    }
    // Pad faces on the footer colour.
    if (y + u.px(34) <= box.bottom()) {
        u.surface.fillRect(inner.x + u.px(6), y, inner.w -| u.px(12), u.px(34), t.header);
        var px = x + u.px(6);
        const faces = [_]struct { c: @TypeOf(t.success), l: []const u8 }{
            .{ .c = t.success, .l = "A" }, .{ .c = t.danger, .l = "B" }, .{ .c = t.pad_x, .l = "X" }, .{ .c = t.warning, .l = "Y" },
        };
        for (faces) |face| {
            const r = paint.s(u.px(11));
            paint.circle(u.surface, paint.s(px) + r, paint.s(y + u.px(17)), r, face.c, t.header);
            u.fonts.drawCentered(u.surface, px + u.px(11), u.fonts.centeredTop(.strong, y + u.px(17)), .strong, face.l, t.on_pad, face.c);
            px += u.px(30);
        }
    }
    // Contrast result in the menu theme.
    const status = Rect{ .x = rect.x, .y = rect.bottom() -| status_h, .w = rect.w, .h = status_h };
    if (labels.contrast.len > 0) menu.banner(status, if (labels.ok) .success else .danger, if (labels.ok) .check_circle else .warning, labels.contrast);
    _ = icons;
    _ = std;
}
