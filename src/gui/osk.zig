//! On-screen keyboard of the shared form component (src/gui/form.zig) for
//! pads and touch screens; a physical keyboard types into the same field.
//!
//! Two pages (letters with digits, symbols) of 11 columns, and a bottom row
//! with Shift, the page switch, Space, Backspace and Done. Keys the field
//! does not accept are drawn disabled and cannot be pressed. Pad: D-pad
//! moves, A presses, X = Backspace, Y = Shift, LB/RB = page, B = Done.
//! Pure state and drawing: the UEFI loop is src/platform/uefi/manual_form.zig.
const std = @import("std");
const ui_mod = @import("ui.zig");
const paint = @import("paint.zig");
const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const columns = 11;
pub const char_rows = 4;
pub const rows = char_rows + 1;

pub const Page = enum { letters, symbols };

const letters = [char_rows]*const [columns]u8{ "1234567890-", "qwertyuiop_", "asdfghjkl.@", "zxcvbnm,!?#" };
const symbols = [char_rows]*const [columns]u8{ "!@#$%^&*()=", "~`+[]{};:'\"", "<>/\\|,.?-_ ", "0123456789+" };

pub const Special = enum { shift, page, space, backspace, done };

const special_spans = [_]struct { key: Special, span: u8 }{
    .{ .key = .shift, .span = 2 },
    .{ .key = .page, .span = 2 },
    .{ .key = .space, .span = 3 },
    .{ .key = .backspace, .span = 2 },
    .{ .key = .done, .span = 2 },
};

pub const Key = union(enum) {
    char: u8,
    special: Special,
};

/// Characters a field accepts (ASCII 0x20..0x7e).
pub const Allowed = std.StaticBitSet(128);

pub fn allowAll() Allowed {
    var set = Allowed.initEmpty();
    for (0x20..0x7f) |c| set.set(c);
    return set;
}

pub const State = struct {
    page: Page = .letters,
    shift: bool = false,
    row: u8 = 1,
    col: u8 = 0,

    /// The key under the selection (shift applied to letters).
    pub fn key(self: State) Key {
        return keyAt(self, self.row, self.col);
    }

    pub fn move(self: *State, dx: i8, dy: i8) void {
        if (dy != 0) {
            const next: i16 = @as(i16, self.row) + dy;
            self.row = @intCast(@mod(next, rows));
            return;
        }
        if (self.row < char_rows) {
            const next: i16 = @as(i16, self.col) + dx;
            self.col = @intCast(@mod(next, columns));
            return;
        }
        // Bottom row: step over whole special keys.
        var index = specialIndex(self.col);
        const count: i16 = special_spans.len;
        index = @intCast(@mod(@as(i16, @intCast(index)) + dx, count));
        self.col = specialStart(index);
    }

    pub fn togglePage(self: *State) void {
        self.page = if (self.page == .letters) .symbols else .letters;
    }
};

fn specialIndex(col: u8) usize {
    var start: u8 = 0;
    for (special_spans, 0..) |entry, index| {
        if (col < start + entry.span) return index;
        start += entry.span;
    }
    return special_spans.len - 1;
}

fn specialStart(index: usize) u8 {
    var start: u8 = 0;
    for (special_spans[0..index]) |entry| start += entry.span;
    return start;
}

pub fn keyAt(state: State, row: u8, col: u8) Key {
    if (row >= char_rows) return .{ .special = special_spans[specialIndex(col)].key };
    const table = if (state.page == .letters) letters else symbols;
    var c = table[row][col];
    if (state.shift and std.ascii.isLower(c)) c = std.ascii.toUpper(c);
    return .{ .char = c };
}

pub fn enabled(k: Key, allowed: *const Allowed) bool {
    return switch (k) {
        .char => |c| c < 128 and allowed.isSet(c),
        .special => |s| s != .space or allowed.isSet(' '),
    };
}

pub const Labels = struct {
    shift: []const u8 = "Shift",
    symbols: []const u8 = "?123",
    letters: []const u8 = "ABC",
    space: []const u8 = "Space",
    backspace: []const u8 = "\u{2190}",
    done: []const u8 = "Done",
};

pub const Geometry = struct {
    panel: Rect,
    edit: Rect,
    keys: Rect,
    key_w: u32,
    key_h: u32,
    gap: u32,

    pub fn keyRect(self: Geometry, row: u8, col: u8, span: u8) Rect {
        return .{
            .x = self.keys.x + @as(u32, col) * (self.key_w + self.gap),
            .y = self.keys.y + @as(u32, row) * (self.key_h + self.gap),
            .w = @as(u32, span) * self.key_w + (@as(u32, span) - 1) * self.gap,
            .h = self.key_h,
        };
    }

    /// The key (row, col) at a point.
    pub fn hit(self: Geometry, x: u32, y: u32) ?[2]u8 {
        if (!self.keys.contains(x, y)) return null;
        const row: u8 = @intCast(@min((y - self.keys.y) / (self.key_h + self.gap), rows - 1));
        const col: u8 = @intCast(@min((x - self.keys.x) / (self.key_w + self.gap), columns - 1));
        return .{ row, col };
    }

    pub fn contains(self: Geometry, x: u32, y: u32) bool {
        return self.panel.contains(x, y);
    }
};

/// Height of the keyboard panel for a content width.
pub fn panelHeight(ui: *const Ui) u32 {
    return ui.px(64) + rows * ui.px(40) + (rows - 1) * ui.px(6) + ui.px(28);
}

pub fn geometry(ui: *const Ui, area: Rect) Geometry {
    const pad = ui.px(14);
    const gap = ui.px(6);
    const edit_h = ui.px(52);
    const keys_w = @min(area.w -| 2 * pad, ui.px(900));
    const key_w = (keys_w -| (columns - 1) * gap) / columns;
    const key_h = ui.px(40);
    const keys_total_w = columns * key_w + (columns - 1) * gap;
    const keys_x = area.x + (area.w -| keys_total_w) / 2;
    const edit = Rect{ .x = keys_x, .y = area.y + pad, .w = keys_total_w, .h = edit_h };
    return .{
        .panel = area,
        .edit = edit,
        .keys = .{ .x = keys_x, .y = edit.bottom() + ui.px(12), .w = keys_total_w, .h = rows * key_h + (rows - 1) * gap },
        .key_w = key_w,
        .key_h = key_h,
        .gap = gap,
    };
}

pub const Spec = struct {
    label: []const u8,
    /// Text to show in the edit box (already masked for secrets).
    value: []const u8,
    /// Shown muted when the value is empty.
    placeholder: []const u8 = "",
    state: State,
    allowed: *const Allowed,
    labels: Labels = .{},
    /// The value is invalid: the edit box border turns red (the form's help
    /// panel says why).
    problem: []const u8 = "",
    hover: ?[2]u8 = null,
};

pub fn draw(ui: *const Ui, area: Rect, spec: Spec) Geometry {
    const g = geometry(ui, area);
    const theme = ui.theme;
    paint.card(ui.surface, area.x, area.y, area.w, area.h, ui.px(12), ui.line(1), theme.border_strong, theme.header, theme.background);
    drawEdit(ui, g, spec);
    var row: u8 = 0;
    while (row < rows) : (row += 1) drawRow(ui, g, spec, row);
    return g;
}

pub fn drawEdit(ui: *const Ui, g: Geometry, spec: Spec) void {
    const theme = ui.theme;
    const label_w = @min(ui.fonts.width(.strong, spec.label) + ui.px(16), g.edit.w / 3);
    ui.surface.fillRect(g.edit.x, g.edit.y, g.edit.w, g.edit.h, theme.header);
    _ = ui.fonts.drawFit(ui.surface, g.edit.x, ui.fonts.centeredTop(.strong, g.edit.y + g.edit.h / 2), label_w -| ui.px(8), .strong, spec.label, theme.muted, theme.header);
    const box = Rect{ .x = g.edit.x + label_w, .y = g.edit.y + ui.px(4), .w = g.edit.w -| label_w, .h = g.edit.h -| ui.px(8) };
    const border = if (spec.problem.len > 0) theme.danger else theme.accent;
    paint.card(ui.surface, box.x, box.y, box.w, box.h, ui.px(8), ui.line(2), border, theme.field, theme.header);
    const text_x = box.x + ui.px(12);
    const text_w = box.w -| ui.px(24) -| ui.px(4);
    const center = box.y + box.h / 2;
    var shown = spec.value;
    // Keep the end (the caret) in view.
    while (shown.len > 0 and ui.fonts.width(.body, shown) > text_w) shown = shown[1..];
    const top = ui.fonts.centeredTop(.body, center);
    var end = text_x;
    if (spec.value.len == 0) {
        _ = ui.fonts.drawFit(ui.surface, text_x + ui.px(6), top, text_w, .body, spec.placeholder, theme.faint, theme.field);
    } else {
        end += ui.fonts.draw(ui.surface, text_x, top, .body, shown, theme.text, theme.field);
    }
    // Caret.
    const caret_h = ui.fonts.lineHeight(.body);
    ui.surface.fillRect(end + ui.px(1), center -| caret_h / 2, @max(ui.line(2), 1), caret_h, theme.accent);
}

fn drawRow(ui: *const Ui, g: Geometry, spec: Spec, row: u8) void {
    if (row < char_rows) {
        var col: u8 = 0;
        while (col < columns) : (col += 1) drawKey(ui, g, spec, row, col, 1);
        return;
    }
    var start: u8 = 0;
    for (special_spans) |entry| {
        drawKey(ui, g, spec, row, start, entry.span);
        start += entry.span;
    }
}

pub fn drawKey(ui: *const Ui, g: Geometry, spec: Spec, row: u8, col: u8, span: u8) void {
    const theme = ui.theme;
    const k = keyAt(spec.state, row, col);
    const rect = g.keyRect(row, col, span);
    const is_enabled = enabled(k, spec.allowed);
    const selected = spec.state.row == row and (if (row < char_rows) spec.state.col == col else specialIndex(spec.state.col) == specialIndex(col));
    const hovered = if (spec.hover) |h| h[0] == row and (if (row < char_rows) h[1] == col else specialIndex(h[1]) == specialIndex(col)) else false;
    const active_special = switch (k) {
        .special => |s| (s == .shift and spec.state.shift),
        .char => false,
    };
    const fill = if (selected) theme.accent else if (!is_enabled) theme.disabled else if (active_special) theme.accent_soft else if (hovered) theme.panel_alt else theme.panel;
    const fg = if (selected) theme.on_accent else if (!is_enabled) theme.disabled_text else theme.text;
    const border = if (selected) theme.accent else if (hovered) theme.border_strong else theme.border;
    paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(6), ui.line(1), border, fill, theme.header);
    var buffer: [1]u8 = undefined;
    const label: []const u8 = switch (k) {
        .char => |c| blk: {
            buffer[0] = c;
            break :blk if (c == ' ') "" else buffer[0..1];
        },
        .special => |s| switch (s) {
            .shift => spec.labels.shift,
            .page => if (spec.state.page == .letters) spec.labels.symbols else spec.labels.letters,
            .space => spec.labels.space,
            .backspace => spec.labels.backspace,
            .done => spec.labels.done,
        },
    };
    const style: ui_mod.Style = if (label.len == 1) .strong else .small;
    _ = ui.fonts.drawFit(ui.surface, rect.x + (rect.w -| @min(ui.fonts.width(style, label), rect.w -| ui.px(6))) / 2, ui.fonts.centeredTop(style, rect.y + rect.h / 2), rect.w -| ui.px(6), style, label, fg, fill);
}

test "keyboard navigation wraps and steps over the special keys" {
    var s = State{};
    try std.testing.expectEqual(Key{ .char = 'q' }, s.key());
    s.move(-1, 0);
    try std.testing.expectEqual(Key{ .char = '_' }, s.key());
    s.move(0, -1);
    s.move(0, -1);
    try std.testing.expectEqual(@as(u8, 4), s.row);
    try std.testing.expect(s.key() == .special);
    s.col = 0;
    try std.testing.expectEqual(Special.shift, s.key().special);
    s.move(1, 0);
    try std.testing.expectEqual(Special.page, s.key().special);
    s.move(1, 0);
    try std.testing.expectEqual(Special.space, s.key().special);
    s.move(-3, 0);
    try std.testing.expectEqual(Special.done, s.key().special);
    s.shift = true;
    s.row = 1;
    s.col = 0;
    try std.testing.expectEqual(Key{ .char = 'Q' }, s.key());
    s.togglePage();
    try std.testing.expectEqual(Key{ .char = '~' }, s.key());
}

test "keys outside the field's characters are disabled" {
    var set = Allowed.initEmpty();
    for ("ABCabc0123-") |c| set.set(c);
    try std.testing.expect(enabled(.{ .char = 'a' }, &set));
    try std.testing.expect(!enabled(.{ .char = '!' }, &set));
    try std.testing.expect(!enabled(.{ .special = .space }, &set));
    try std.testing.expect(enabled(.{ .special = .done }, &set));
    const all = allowAll();
    try std.testing.expect(enabled(.{ .special = .space }, &all));
}
