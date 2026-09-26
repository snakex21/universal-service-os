//! Shared form screen of the boot toolkit (answer-profile editor, theme
//! editor): one row per field with its label on the left and its value on
//! the right, drawn in the theme's colours.
//!
//!   text     value in a field box (placeholder when empty, bullets for a
//!            secret); edited with the on-screen keyboard (osk.zig) or a
//!            physical keyboard
//!   choice   value between chevrons; Left/Right step, A opens a list picker
//!   toggle   switch pill
//!   action   button row (Save, Cancel, Delete)
//!
//! Pure drawing and hit testing; values are formatted by the caller. The
//! UEFI loop is src/platform/uefi/manual_form.zig.
const std = @import("std");
const ui_mod = @import("ui.zig");
const paint = @import("paint.zig");
const icons = @import("icons.zig");
const Color = @import("color.zig").Color;
const menu_screens = @import("menu_screens.zig");
const osk = @import("osk.zig");
const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;
const RowState = ui_mod.RowState;

pub const Kind = enum { text, choice, toggle, action };

pub const Item = struct {
    kind: Kind,
    label: []const u8,
    /// Display value (text/choice); toggles use `on`.
    value: []const u8 = "",
    placeholder: []const u8 = "",
    on: bool = false,
    enabled: bool = true,
    /// Value fails validation: red border and label.
    invalid: bool = false,
    /// Action rows: accent button.
    primary: bool = false,
    /// Colour square before the value (theme editor).
    swatch: ?Color = null,
};

pub const Spec = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    items: []const Item,
    selected: usize = 0,
    hover: ?usize = null,
    help: ?menu_screens.Help = null,
    hints: []const ui_mod.Hint = &.{},
    note: []const u8 = "",
    /// Width share of the label column in percent.
    label_percent: u32 = 42,
    /// Keyboard open: it takes the bottom of the body.
    keyboard: ?osk.Spec = null,
    /// Area kept free at the right of the rows (theme preview), in logical px.
    side_w: u32 = 0,
};

pub const Geometry = struct {
    list: Ui.List,
    first: usize,
    help: ?Rect,
    keyboard: ?osk.Geometry,
    side: ?Rect,
};

pub fn rowHeight(ui: *const Ui) u32 {
    return ui.px(46);
}

pub fn geometry(ui: *const Ui, spec: Spec, current_first: usize) Geometry {
    const body = ui.bodyRect(spec.subtitle.len > 0);
    var area = body;
    var keyboard: ?osk.Geometry = null;
    if (spec.keyboard != null) {
        const h = @min(osk.panelHeight(ui), body.h * 3 / 4);
        const panel = Rect{ .x = body.x, .y = body.bottom() -| h, .w = body.w, .h = h };
        keyboard = osk.geometry(ui, panel);
        area.h = body.h -| h -| ui.px(12);
    }
    var side: ?Rect = null;
    if (spec.side_w > 0 and body.w >= ui.px(760)) {
        const w = @min(ui.px(spec.side_w), body.w / 2);
        area.w = body.w -| w -| ui.px(16);
        side = .{ .x = area.right() + ui.px(16), .y = body.y, .w = w, .h = area.h };
    }
    var help: ?Rect = null;
    if (spec.help != null and spec.keyboard == null and side == null) {
        const content = spec.help.?;
        if (body.w >= ui.px(860)) {
            const help_w = @min(body.w * 2 / 5, ui.px(420));
            area.w = body.w -| help_w -| ui.px(16);
            help = .{ .x = area.right() + ui.px(16), .y = body.y, .w = help_w, .h = @min(body.h, ui.infoPanelHeight(help_w, true, content.title, content.lines)) };
        } else {
            const help_h = @min(ui.infoPanelHeight(body.w, true, content.title, content.lines), body.h / 3);
            area.h = body.h -| help_h -| ui.px(14);
            help = .{ .x = body.x, .y = area.bottom() + ui.px(14), .w = body.w, .h = help_h };
        }
    }
    area.h = ui.listHeight(spec.items.len, rowHeight(ui), area.h);
    if (help) |*rect| {
        if (rect.x == area.x and rect.y > area.bottom() + ui.px(14)) rect.y = area.bottom() + ui.px(14);
    }
    const list = ui.listLayout(area, rowHeight(ui));
    return .{ .list = list, .first = menu_screens.firstVisible(spec.selected, spec.items.len, list.visible, current_first), .help = help, .keyboard = keyboard, .side = side };
}

pub fn screen(ui: *const Ui, header: ui_mod.HeaderInfo, spec: Spec, current_first: usize) Geometry {
    ui.clear();
    ui.header(header);
    ui.pageTitle(spec.title, spec.subtitle);
    const g = geometry(ui, spec, current_first);
    ui.listPanel(g.list);
    drawRows(ui, g, spec);
    if (g.help) |rect| menu_screens.drawHelp(ui, rect, spec.help.?);
    if (g.keyboard) |k| _ = osk.draw(ui, k.panel, spec.keyboard.?);
    ui.footer(spec.hints, spec.note);
    return g;
}

pub fn drawRows(ui: *const Ui, g: Geometry, spec: Spec) void {
    var visible_index: usize = 0;
    while (visible_index < g.list.visible) : (visible_index += 1) {
        const index = g.first + visible_index;
        if (index >= spec.items.len) {
            ui.clearRow(g.list, visible_index);
            continue;
        }
        drawItem(ui, g.list.rowRect(visible_index), spec, index);
    }
    ui.scrollbar(g.list, g.first, spec.items.len);
}

pub fn drawRow(ui: *const Ui, g: Geometry, spec: Spec, index: usize) void {
    if (index < g.first or index >= g.first + g.list.visible or index >= spec.items.len) return;
    drawItem(ui, g.list.rowRect(index - g.first), spec, index);
}

pub fn hit(g: Geometry, count: usize, x: u32, y: u32) ?usize {
    const visible_count = @min(g.list.visible, count -| g.first);
    const visible_index = g.list.hit(x, y, visible_count) orelse return null;
    return g.first + visible_index;
}

fn drawItem(ui: *const Ui, rect: Rect, spec: Spec, index: usize) void {
    const item = spec.items[index];
    const theme = ui.theme;
    const state = menu_screens.stateOf(index, spec.selected, spec.hover);
    ui.surface.fillRect(rect.x, rect.y, rect.w, rect.h, theme.panel);
    const fill = switch (state) {
        .selected => theme.accent_soft,
        .hover => theme.panel_alt,
        .normal => theme.panel,
    };
    if (item.kind == .action) {
        const size = ui.buttonSize("", item.label);
        const w = @min(@max(size.w, rect.w / 3), rect.w);
        const button = Rect{ .x = rect.x + ui.px(6), .y = rect.y + (rect.h -| ui.px(40)) / 2, .w = w, .h = ui.px(40) };
        if (state == .selected) paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(8), ui.line(2), theme.accent, theme.panel, theme.panel);
        ui.surface.fillRect(button.x, button.y, button.w, button.h, theme.panel);
        const fg = if (!item.enabled) theme.disabled_text else if (item.primary) theme.on_accent else theme.text;
        const bg = if (!item.enabled) theme.disabled else if (item.primary) (if (state == .hover) theme.accent_pressed else theme.accent) else if (state != .normal) theme.panel_alt else theme.panel;
        const border = if (item.primary and item.enabled) bg else if (item.invalid) theme.danger else theme.border_strong;
        paint.card(ui.surface, button.x, button.y, button.w, button.h, ui.px(8), ui.line(1), border, bg, theme.panel);
        ui.fonts.drawCentered(ui.surface, button.x + button.w / 2, ui.fonts.centeredTop(.strong, button.y + button.h / 2), .strong, item.label, fg, bg);
        return;
    }
    if (state == .selected) {
        paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(8), ui.line(2), if (item.enabled) theme.accent else theme.border_strong, fill, theme.panel);
    } else if (state == .hover) {
        paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(8), ui.line(1), theme.border_strong, fill, theme.panel);
    }
    const pad = ui.px(14);
    const center = rect.y + rect.h / 2;
    const label_w = rect.w * spec.label_percent / 100;
    const label_color = if (!item.enabled) theme.disabled_text else if (item.invalid) theme.danger else theme.text;
    _ = ui.fonts.drawFit(ui.surface, rect.x + pad, ui.fonts.centeredTop(.strong, center), label_w -| pad -| ui.px(8), .strong, item.label, label_color, fill);
    const value = Rect{ .x = rect.x + label_w, .y = rect.y + ui.px(6), .w = rect.w -| label_w -| pad, .h = rect.h -| ui.px(12) };
    switch (item.kind) {
        .text => {
            const border = if (item.invalid) theme.danger else if (state == .selected) theme.accent else theme.border;
            paint.card(ui.surface, value.x, value.y, value.w, value.h, ui.px(6), ui.line(1), border, theme.field, fill);
            var x = value.x + ui.px(10);
            if (item.swatch) |color| {
                const size = value.h -| ui.px(10);
                paint.card(ui.surface, x, value.y + ui.px(5), size, size, ui.px(4), ui.line(1), theme.border_strong, color, theme.field);
                x += size + ui.px(10);
            }
            const shown = if (item.value.len > 0) item.value else item.placeholder;
            const color = if (item.value.len > 0) (if (item.enabled) theme.text else theme.disabled_text) else theme.faint;
            _ = ui.fonts.drawFit(ui.surface, x, ui.fonts.centeredTop(.body, center), value.right() -| x -| ui.px(10), .body, shown, color, theme.field);
        },
        .choice => {
            const chevron = ui.px(14);
            const color = if (item.enabled) theme.accent else theme.disabled_text;
            icons.draw(ui.surface, .chevron_left, value.x, center -| chevron / 2, chevron, color, null);
            icons.draw(ui.surface, .chevron_right, value.right() -| chevron, center -| chevron / 2, chevron, color, null);
            var x = value.x + chevron + ui.px(10);
            if (item.swatch) |sw| {
                const size = value.h -| ui.px(10);
                paint.card(ui.surface, x, value.y + ui.px(5), size, size, ui.px(4), ui.line(1), theme.border_strong, sw, fill);
                x += size + ui.px(10);
            }
            _ = ui.fonts.drawFit(ui.surface, x, ui.fonts.centeredTop(.body, center), value.right() -| chevron -| ui.px(10) -| x, .body, if (item.value.len > 0) item.value else item.placeholder, if (item.enabled) theme.text else theme.disabled_text, fill);
        },
        .toggle => {
            const h = ui.px(24);
            const w = ui.px(44);
            const x = value.x;
            const y = center -| h / 2;
            const on_fill = if (!item.enabled) theme.disabled else if (item.on) theme.accent else theme.panel_alt;
            paint.card(ui.surface, x, y, w, h, h / 2, ui.line(1), if (item.on) on_fill else theme.border_strong, on_fill, fill);
            const knob = h -| ui.px(6);
            const knob_x = if (item.on) x + w -| knob -| ui.px(3) else x + ui.px(3);
            paint.circle(ui.surface, paint.s(knob_x) + @divTrunc(paint.s(knob), 2), paint.s(center), @divTrunc(paint.s(knob), 2), if (item.on) theme.on_accent else theme.muted, on_fill);
            _ = ui.fonts.drawFit(ui.surface, x + w + ui.px(12), ui.fonts.centeredTop(.body, center), value.right() -| x -| w -| ui.px(12), .body, item.value, if (item.enabled) theme.muted else theme.disabled_text, fill);
        },
        .action => unreachable,
    }
}

test "form geometry keeps the selection visible and makes room for the keyboard" {
    const testing = std.testing;
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const lang_file = @import("../i18n/lang_file.zig");
    const font = @import("font.zig");
    const Theme = @import("theme.zig").Theme;
    const width = 1280;
    const height = 720;
    const pixels = try testing.allocator.alloc(u32, width * height);
    defer testing.allocator.free(pixels);
    const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, width, height, .bgrx8).?;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const table = lang_file.Table.english_only;
    const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
    var items: [20]Item = undefined;
    for (&items, 0..) |*item, i| item.* = .{ .kind = if (i % 4 == 0) .toggle else if (i % 4 == 1) .choice else if (i % 4 == 2) .text else .action, .label = "Label", .value = "Value", .on = i % 8 == 0 };
    const allowed = osk.allowAll();
    const plain = screen(&ui, .{}, .{ .title = "Form", .items = &items, .selected = 19 }, 0);
    try testing.expect(plain.first + plain.list.visible > 19);
    const with_keyboard = screen(&ui, .{}, .{ .title = "Form", .items = &items, .selected = 2, .keyboard = .{ .label = "User", .value = "Tester", .state = .{}, .allowed = &allowed } }, 0);
    try testing.expect(with_keyboard.keyboard != null);
    try testing.expect(with_keyboard.list.panel.bottom() <= with_keyboard.keyboard.?.panel.y);
    try testing.expect(with_keyboard.first <= 2 and with_keyboard.first + with_keyboard.list.visible > 2);
    const k = with_keyboard.keyboard.?;
    const q = k.keyRect(1, 0, 1);
    try testing.expectEqual([2]u8{ 1, 0 }, k.hit(q.x + 1, q.y + 1).?);
    try testing.expectEqual(@as(usize, 2), hit(with_keyboard, items.len, with_keyboard.list.rowRect(2 - with_keyboard.first).x + 2, with_keyboard.list.rowRect(2 - with_keyboard.first).y + 2).?);
}
