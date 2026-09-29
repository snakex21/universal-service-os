//! The shared form component of the UEFI menu (answer-profile editor,
//! theme editor): text fields with the on-screen keyboard (pad, touch) and
//! the physical keyboard, list pickers, toggles and action buttons.
//!
//! Drawing: src/gui/form.zig and src/gui/osk.zig through view.FormScreen.
//! Input:
//!   form      D-pad/arrows select, A/Enter edits / toggles / opens a picker
//!             / presses a button, Left/Right step a choice or flip a toggle,
//!             B/Esc leaves (the owner decides what that means), X/F2 and
//!             Y/Del go to the owner (edit, delete)
//!   keyboard  typed characters go straight into the field; D-pad moves on
//!             the keys, A presses, X/Backspace deletes, Y shifts, LB/RB
//!             switch letters/symbols, B/Esc/Enter or Done closes
//!   pointer   tap a row to act on it, a key to press it, outside the
//!             keyboard to close it; the wheel scrolls
//! Serial trace [UI_FORM] for the QEMU click-through tests (secrets are
//! never traced).
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

const gui = usos.gui;
const answer_profile = usos.flow.answer.profile;
const osk = gui.osk;
const Hint = gui.ui.Hint;

pub const TextValue = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    max: usize = 64,

    pub fn slice(self: *const TextValue) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *TextValue, value: []const u8) void {
        const n = @min(value.len, @min(self.max, self.bytes.len));
        @memcpy(self.bytes[0..n], value[0..n]);
        self.len = n;
    }

    fn push(self: *TextValue, c: u8) bool {
        if (self.len >= @min(self.max, self.bytes.len)) return false;
        self.bytes[self.len] = c;
        self.len += 1;
        return true;
    }

    fn pop(self: *TextValue) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        return true;
    }
};

pub const Field = struct {
    kind: gui.form.Kind,
    label: []const u8,
    enabled: bool = true,
    // text
    text: ?*TextValue = null,
    secret: bool = false,
    allowed: ?*const osk.Allowed = null,
    /// Typed letters become capitals (product keys, colours).
    uppercase: bool = false,
    /// A product key: letters and digits only, in capitals, the dashes put
    /// in on their own (answer.profile.keyTyped); never traced.
    product_key: bool = false,
    placeholder: []const u8 = "",
    // choice
    options: []const []const u8 = &.{},
    index: ?*usize = null,
    /// A choice whose last option ("Type manually...") is typed on the
    /// keyboard into `text`: picking it (or X/F2 on the row) opens the
    /// keyboard, Y/Del goes back to the first option, and the row shows the
    /// typed value.
    manual: bool = false,
    // toggle
    flag: ?*bool = null,
    // stepper (0..255, Left/Right by `step`)
    number: ?*u8 = null,
    step: u8 = 8,
    // action
    primary: bool = false,
    /// Returned by run() when the button is pressed.
    id: u8 = 0,
    swatch: ?gui.Color = null,
};

/// What the owner may say about the fields after each change.
pub const Hooks = struct {
    context: *anyopaque,
    /// Help panel (and invalid marks) for the selected field.
    help: ?*const fn (context: *anyopaque, index: usize) gui.menu_screens.Help = null,
    invalid: ?*const fn (context: *anyopaque, index: usize) bool = null,
    /// A value changed (live preview, recompute).
    changed: ?*const fn (context: *anyopaque, index: usize) void = null,
    /// Side panel drawing (theme preview); needs `side_w`.
    side: ?*const fn (u: *const gui.ui.Ui, rect: gui.ui.Rect) void = null,
    side_w: u32 = 0,
    /// Extra footer hints for X / Y (null: not offered).
    x_label: ?[]const u8 = null,
    y_label: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    /// An action button was pressed.
    action: u8,
    back,
    /// X / Y on the field at this index.
    x_on: usize,
    y_on: usize,
};

const max_fields = 40;

var items: [max_fields]gui.form.Item = undefined;
var value_text: [max_fields][80]u8 = undefined;
var hints: [5]Hint = undefined;
var screen: view.FormScreen = undefined;
var form_fields: []Field = &.{};
var form_hooks: ?Hooks = null;
var editing: ?usize = null;
var keyboard_state: osk.State = .{};
var edit_display: [80]u8 = undefined;
const all_allowed = osk.allowAll();

fn t(key: view.Key) []const u8 {
    return view.t(key);
}

fn refreshItems() void {
    for (form_fields, 0..) |*field, index| {
        const invalid = if (form_hooks) |h| (if (h.invalid) |f| f(h.context, index) else false) else false;
        var item = gui.form.Item{ .kind = field.kind, .label = field.label, .enabled = field.enabled, .invalid = invalid, .primary = field.primary, .swatch = field.swatch, .placeholder = field.placeholder };
        switch (field.kind) {
            .text => {
                const value = field.text.?.slice();
                if (field.secret and value.len > 0) {
                    var n: usize = 0;
                    for (0..@min(value.len, 24)) |_| {
                        const dot = "\u{2022}";
                        @memcpy(value_text[index][n .. n + dot.len], dot);
                        n += dot.len;
                    }
                    item.value = value_text[index][0..n];
                } else item.value = value;
                if (item.placeholder.len == 0) item.placeholder = t(.form_empty);
            },
            .choice => {
                item.value = if (field.index) |i| (if (i.* < field.options.len) field.options[i.*] else "") else "";
                if (onManual(field) and field.text.?.len > 0) item.value = field.text.?.slice();
            },
            .toggle => {
                item.on = field.flag.?.*;
                item.value = if (item.on) t(.form_on) else t(.form_off);
            },
            .stepper => item.value = std.fmt.bufPrint(&value_text[index], "{d}", .{field.number.?.*}) catch "",
            .action, .section => {},
        }
        items[index] = item;
    }
}

/// The field is a manual choice set to its "type manually" option.
fn onManual(field: *const Field) bool {
    return field.kind == .choice and field.manual and field.text != null and field.options.len > 0 and field.index.?.* == field.options.len - 1;
}

fn manualField(index: usize) bool {
    if (index >= form_fields.len) return false;
    const field = &form_fields[index];
    return field.kind == .choice and field.manual and field.text != null and field.enabled;
}

/// Opens the keyboard for a manual choice (its last option).
fn startManual(index: usize) void {
    const field = &form_fields[index];
    field.index.?.* = field.options.len - 1;
    startEditing(index);
}

fn formHints() void {
    var n: usize = 0;
    if (editing != null) {
        hints[n] = .{ .key = input.moveKey("\u{2191}\u{2193}\u{2190}\u{2192}"), .label = t(.form_key_type) };
        n += 1;
        hints[n] = .{ .key = if (input.padActive()) "X" else "\u{2190}", .label = t(.form_key_backspace) };
        n += 1;
        if (input.padActive()) {
            hints[n] = .{ .key = "Y", .label = t(.form_osk_shift) };
            n += 1;
        }
        hints[n] = .{ .key = input.backKey(), .label = t(.form_osk_done) };
        n += 1;
    } else {
        hints[n] = .{ .key = input.moveKey("\u{2191}\u{2193}"), .label = t(.key_select) };
        n += 1;
        hints[n] = .{ .key = input.enterKey(), .label = t(.form_key_change) };
        n += 1;
        const owner_xy = if (form_hooks) |h| h.x_label != null or h.y_label != null else false;
        if (!owner_xy and manualField(screen.spec.selected)) {
            hints[n] = .{ .key = input.xKey(), .label = t(.profile_key_edit) };
            n += 1;
            hints[n] = .{ .key = input.yKey(), .label = t(.profile_key_delete) };
            n += 1;
        }
        if (form_hooks) |h| {
            if (h.x_label) |label| {
                hints[n] = .{ .key = input.xKey(), .label = label };
                n += 1;
            }
            if (h.y_label) |label| {
                hints[n] = .{ .key = input.yKey(), .label = label };
                n += 1;
            }
        }
        hints[n] = .{ .key = input.backKey(), .label = t(.key_back) };
        n += 1;
    }
    screen.spec.hints = hints[0..n];
}

fn rehint() void {
    formHints();
}

fn keyboardSpec(index: usize) osk.Spec {
    const field = &form_fields[index];
    const value = field.text.?.slice();
    const invalid = if (form_hooks) |h| (if (h.invalid) |f| f(h.context, index) else false) else false;
    return .{
        .label = field.label,
        .value = value,
        .placeholder = field.placeholder,
        .state = keyboard_state,
        .allowed = field.allowed orelse &all_allowed,
        .labels = .{ .shift = t(.form_osk_shift), .space = t(.form_osk_space), .done = t(.form_osk_done), .symbols = "?123", .letters = "ABC" },
        .problem = if (invalid) "!" else "",
    };
}

fn helpFor(index: usize) ?gui.menu_screens.Help {
    const h = form_hooks orelse return null;
    const f = h.help orelse return null;
    return f(h.context, index);
}

fn rebuild(selected: usize) void {
    refreshItems();
    screen.spec.items = items[0..form_fields.len];
    screen.spec.selected = selected;
    screen.spec.help = helpFor(selected);
    screen.spec.keyboard = if (editing) |index| keyboardSpec(index) else null;
    formHints();
}

var trace_number: [4]u8 = undefined;

var trace_key: [16]u8 = undefined;

/// What the serial trace shows of a text value: a password as "(secret)",
/// a product key only as how far it is typed ("(key 12/25)").
fn traceText(field: *const Field, out: *[16]u8) []const u8 {
    const value = field.text.?.slice();
    if (value.len == 0) return "";
    if (field.secret) return "(secret)";
    if (field.product_key) return std.fmt.bufPrint(out, "(key {d}/{d})", .{ answer_profile.keySymbolCount(value), answer_profile.key_symbols }) catch "(key)";
    return value;
}

fn trace(kind: []const u8, index: usize) void {
    const field = &form_fields[index];
    var line: [160]u8 = undefined;
    const value: []const u8 = switch (field.kind) {
        .text => traceText(field, &trace_key),
        .choice => if (onManual(field) and field.text.?.len > 0) field.text.?.slice() else if (field.index) |i| (if (i.* < field.options.len) field.options[i.*] else "") else "",
        .toggle => if (field.flag.?.*) "on" else "off",
        .stepper => std.fmt.bufPrint(&trace_number, "{d}", .{field.number.?.*}) catch "",
        .action, .section => "",
    };
    view.traceForm(kind, std.fmt.bufPrint(&line, "index={d} label={s} value={s}", .{ index, field.label, value }) catch return);
}

fn notifyChanged(index: usize) void {
    if (form_hooks) |h| if (h.changed) |f| f(h.context, index);
    trace("changed", index);
}

/// Section headings are never selected: the next selectable row from
/// `index` in the direction of travel (wrapping), or `index` itself.
fn selectable(fields: []const Field, index: usize, down: bool) usize {
    var i = index;
    for (0..fields.len) |_| {
        if (fields[i].kind != .section) return i;
        i = if (down) (i + 1) % fields.len else (i + fields.len - 1) % fields.len;
    }
    return index;
}

/// The row the wheel lands on: `notches` rows (positive turns the wheel
/// away, towards the top) over the selectable rows, stopping at the ends.
/// Section headings are passed over, so the wheel crosses from one section
/// into the next like the arrows do.
fn wheelTarget(fields: []const Field, current: usize, notches: i32) usize {
    var mask: [max_fields]bool = undefined;
    for (fields, 0..) |field, i| mask[i] = field.kind != .section;
    const target = usos.gui.selectable_list.stepLinearBy(mask[0..fields.len], fields.len, current, notches < 0, @abs(notches));
    return target;
}

/// Runs the form until an action button, Back, or X/Y. `selected` is kept
/// across calls (the owner reopens the form after a confirmation).
pub fn run(title: []const u8, subtitle: []const u8, fields: []Field, hooks: ?Hooks, selected: *usize) Outcome {
    std.debug.assert(fields.len <= max_fields and fields.len > 0);
    form_fields = fields;
    form_hooks = hooks;
    editing = null;
    if (selected.* >= fields.len) selected.* = 0;
    selected.* = selectable(fields, selected.*, true);
    screen = .{ .spec = .{ .title = title, .subtitle = subtitle, .items = &.{}, .side_w = if (hooks) |h| h.side_w else 0 }, .side = if (hooks) |h| h.side else null, .rehint = rehint };
    rebuild(selected.*);
    view.traceFormScreen(title);
    screen.redraw();
    trace("selected", selected.*);
    while (true) {
        const event = input.readBlocking();
        if (editing) |index| {
            if (keyboardEvent(event, index)) |closed| {
                _ = closed;
                editing = null;
                // Nothing typed on "type manually": back to the first option.
                const field = &fields[index];
                if (onManual(field) and field.text.?.len == 0) {
                    field.index.?.* = 0;
                    notifyChanged(index);
                }
                rebuild(selected.*);
                screen.redraw();
            }
            continue;
        }
        switch (event) {
            .x_button => {
                if (hooks != null and hooks.?.x_label != null) return .{ .x_on = selected.* };
                if (manualField(selected.*)) {
                    // Edit: the keyboard on the value shown now.
                    const field = &fields[selected.*];
                    if (!onManual(field)) {
                        const shown = field.options[field.index.?.*];
                        field.text.?.set(if (field.index.?.* == 0) "" else shown);
                    }
                    startManual(selected.*);
                    rebuild(selected.*);
                    screen.redraw();
                }
            },
            .y_button => {
                if (hooks != null and hooks.?.y_label != null) return .{ .y_on = selected.* };
                if (manualField(selected.*)) {
                    // Delete: back to the first option (e.g. "Setup asks").
                    const field = &fields[selected.*];
                    field.index.?.* = 0;
                    field.text.?.set("");
                    notifyChanged(selected.*);
                    rebuild(selected.*);
                    screen.redrawRows();
                }
            },
            .left, .right => {
                const field = &fields[selected.*];
                if (!field.enabled) continue;
                switch (field.kind) {
                    .choice => {
                        const i = field.index.?;
                        if (field.options.len == 0) continue;
                        i.* = if (event == .right) (i.* + 1) % field.options.len else (i.* + field.options.len - 1) % field.options.len;
                        notifyChanged(selected.*);
                        rebuild(selected.*);
                        screen.redrawRows();
                    },
                    .toggle => {
                        field.flag.?.* = event == .right;
                        notifyChanged(selected.*);
                        rebuild(selected.*);
                        screen.redrawRows();
                    },
                    .stepper => {
                        const value = field.number.?;
                        value.* = if (event == .right) value.* +| field.step else value.* -| field.step;
                        notifyChanged(selected.*);
                        rebuild(selected.*);
                        screen.redraw();
                    },
                    else => {},
                }
            },
            .enter => if (activate(selected)) |outcome| return outcome,
            .back => return .back,
            .pointer => |mouse| {
                if (mouse.right_click) return .back;
                if (mouse.scroll != 0) {
                    const before = selected.*;
                    selected.* = wheelTarget(fields, selected.*, mouse.scroll);
                    if (before != selected.*) select(selected.*);
                    continue;
                }
                if (mouse.left_click) {
                    if (screen.hitRow(mouse.x, mouse.y)) |index| {
                        if (!fields[index].enabled or fields[index].kind == .section) continue;
                        selected.* = index;
                        select(index);
                        if (activate(selected)) |outcome| return outcome;
                    }
                    continue;
                }
                if (mouse.moved) view.updatePointer();
            },
            else => {
                // Arrows, Page Up/Down, Home/End.
                const before = selected.*;
                switch (event) {
                    .up => selected.* = if (selected.* == 0) fields.len - 1 else selected.* - 1,
                    .down => selected.* = (selected.* + 1) % fields.len,
                    .home => selected.* = 0,
                    .end => selected.* = fields.len - 1,
                    .page_up => selected.* -|= screen.visibleRows(),
                    .page_down => selected.* = @min(fields.len - 1, selected.* + screen.visibleRows()),
                    .other => |key| {
                        // A printable key on a text row starts editing with it.
                        const field = &fields[selected.*];
                        const printable = key.unicode >= 0x20 and key.unicode < 0x7f;
                        if (printable and manualField(selected.*)) {
                            // Typing on a manual choice types a new value.
                            if (!onManual(field)) field.text.?.set("");
                            startManual(selected.*);
                            _ = typeChar(selected.*, @intCast(key.unicode));
                            rebuild(selected.*);
                            screen.redraw();
                        } else if (field.kind == .text and field.enabled and printable) {
                            startEditing(selected.*);
                            _ = typeChar(selected.*, @intCast(key.unicode));
                            rebuild(selected.*);
                            screen.redraw();
                        }
                    },
                    else => {},
                }
                const down = switch (event) {
                    .up, .end, .page_up => false,
                    else => true,
                };
                selected.* = selectable(fields, selected.*, down);
                if (before != selected.*) select(selected.*);
            },
        }
    }
}

fn select(index: usize) void {
    screen.spec.hover = null;
    rebuild(index);
    screen.redrawRows();
    trace("selected", index);
}

fn startEditing(index: usize) void {
    editing = index;
    keyboard_state = .{};
    trace("edit", index);
}

fn activate(selected: *usize) ?Outcome {
    const index = selected.*;
    const field = &form_fields[index];
    if (!field.enabled) return null;
    switch (field.kind) {
        .text => {
            startEditing(index);
            rebuild(index);
            screen.redraw();
        },
        .toggle => {
            field.flag.?.* = !field.flag.?.*;
            notifyChanged(index);
            rebuild(index);
            screen.redrawRows();
        },
        // A steps up (wrapping), like Right on a pad without the D-pad.
        .stepper => {
            const value = field.number.?;
            value.* = if (value.* == 255) 0 else value.* +| field.step;
            notifyChanged(index);
            rebuild(index);
            screen.redraw();
        },
        .choice => {
            const picked = pick(field);
            if (picked) |changed| {
                if (changed) notifyChanged(index);
                // "Type manually": the keyboard on the typed value.
                if (onManual(field)) startEditing(index);
            }
            rebuild(index);
            screen.redraw();
        },
        .action => {
            trace("action", index);
            return .{ .action = field.id };
        },
        .section => {},
    }
    return null;
}

var picker_rows: [96]gui.ui.Row = undefined;

/// List picker for a choice (time zone, language): null on Back, else
/// whether the value changed.
fn pick(field: *Field) ?bool {
    const count = @min(field.options.len, picker_rows.len);
    if (count == 0) return null;
    for (field.options[0..count], 0..) |option, i| picker_rows[i] = .{ .title = option };
    var selected: usize = @min(field.index.?.*, count - 1);
    var list: view.ListScreen = undefined;
    list.open(field.label, t(.form_picker_subtitle), picker_rows[0..count], selected, false, null);
    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, count, &list)) {
            .activate => {
                const changed = selected != field.index.?.*;
                field.index.?.* = selected;
                return changed;
            },
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn allowedChar(index: usize, c: u8) bool {
    const field = &form_fields[index];
    const set = field.allowed orelse &all_allowed;
    return c < 128 and set.isSet(c);
}

fn typeChar(index: usize, raw: u8) bool {
    const field = &form_fields[index];
    if (field.product_key) {
        const text = field.text.?;
        const before = text.len;
        text.len = answer_profile.keyTyped(&text.bytes, text.len, raw);
        if (text.len == before) return false;
        notifyChanged(index);
        return true;
    }
    const c = if (field.uppercase) std.ascii.toUpper(raw) else raw;
    if (!allowedChar(index, c)) return false;
    if (!field.text.?.push(c)) return false;
    notifyChanged(index);
    return true;
}

fn backspace(index: usize) void {
    const field = &form_fields[index];
    if (field.product_key) {
        const text = field.text.?;
        const before = text.len;
        text.len = answer_profile.keyBackspace(&text.bytes, text.len);
        if (text.len != before) notifyChanged(index);
        return;
    }
    if (field.text.?.pop()) notifyChanged(index);
}

/// One event while the keyboard is open; non-null when it closes.
fn keyboardEvent(event: input.Event, index: usize) ?bool {
    const from_keyboard = input.lastSource() == .keyboard;
    const raw = input.lastKey();
    switch (event) {
        .other => |key| {
            if (key.unicode >= 0x20 and key.unicode < 0x7f) {
                _ = typeChar(index, @intCast(key.unicode));
                return refreshKeyboard(index);
            }
            return null;
        },
        .enter => {
            if (from_keyboard and raw.unicode == ' ') {
                _ = typeChar(index, ' ');
                return refreshKeyboard(index);
            }
            if (from_keyboard and (raw.unicode == 13 or raw.unicode == 10)) return true;
            return press(index);
        },
        .back => {
            if (from_keyboard and raw.unicode == 8) {
                backspace(index);
                return refreshKeyboard(index);
            }
            return true;
        },
        .x_button => {
            backspace(index);
            return refreshKeyboard(index);
        },
        .y_button => {
            if (from_keyboard) {
                backspace(index);
            } else keyboard_state.shift = !keyboard_state.shift;
            return refreshKeyboard(index);
        },
        .page_up, .page_down => {
            keyboard_state.togglePage();
            return refreshKeyboard(index);
        },
        .up => keyboard_state.move(0, -1),
        .down => keyboard_state.move(0, 1),
        .left => keyboard_state.move(-1, 0),
        .right => keyboard_state.move(1, 0),
        .home, .end => return null,
        .pointer => |mouse| {
            if (mouse.left_click) {
                if (screen.hitKey(mouse.x, mouse.y)) |key| {
                    keyboard_state.row = key[0];
                    keyboard_state.col = key[1];
                    return press(index);
                }
                if (!screen.inKeyboard(mouse.x, mouse.y)) return true;
                return null;
            }
            if (mouse.right_click) return true;
            if (mouse.moved) view.updatePointer();
            return null;
        },
    }
    return refreshKeyboard(index);
}

fn press(index: usize) ?bool {
    const key = keyboard_state.key();
    const field = &form_fields[index];
    if (!osk.enabled(key, field.allowed orelse &all_allowed)) return null;
    switch (key) {
        .char => |c| _ = typeChar(index, c),
        .special => |s| switch (s) {
            .shift => keyboard_state.shift = !keyboard_state.shift,
            .page => keyboard_state.togglePage(),
            .space => _ = typeChar(index, ' '),
            .backspace => backspace(index),
            .done => return true,
        },
    }
    return refreshKeyboard(index);
}

fn refreshKeyboard(index: usize) ?bool {
    rebuild(index);
    screen.redraw();
    return null;
}

// ------------------------------------------------------------ character sets

pub fn charset(comptime chars: []const u8, comptime alnum: bool) osk.Allowed {
    var set = osk.Allowed.initEmpty();
    if (alnum) {
        for ('a'..'z' + 1) |c| set.set(c);
        for ('A'..'Z' + 1) |c| set.set(c);
        for ('0'..'9' + 1) |c| set.set(c);
    }
    for (chars) |c| set.set(c);
    return set;
}

/// Printable ASCII without the characters that break WINNT.SIF or cmd
/// (tools/xp_user_settings.sh), with or without space.
pub fn cleanAscii(space: bool) osk.Allowed {
    var set = osk.allowAll();
    for ("\"%^&|<>") |c| set.unset(c);
    if (!space) set.unset(' ');
    return set;
}

// ------------------------------------------------------------------- tests

fn testFields(comptime kinds: []const gui.form.Kind) [kinds.len]Field {
    var fields: [kinds.len]Field = undefined;
    for (kinds, 0..) |kind, i| fields[i] = .{ .kind = kind, .label = "" };
    return fields;
}

test "wheel crosses section headings in both directions and stops at the ends" {
    // The XP profile editor: general rows, "Use for", the "Appearance and
    // extras" heading, its toggles, Save, Cancel.
    const fields = testFields(&.{ .text, .text, .choice, .section, .toggle, .toggle, .choice, .action, .action });
    // One notch down from "Use for" goes past the heading, not back up.
    try std.testing.expectEqual(@as(usize, 4), wheelTarget(&fields, 2, -1));
    try std.testing.expectEqual(@as(usize, 5), wheelTarget(&fields, 2, -2));
    // One notch up from the first toggle lands on "Use for".
    try std.testing.expectEqual(@as(usize, 2), wheelTarget(&fields, 4, 1));
    // Turning on reaches every row down to Cancel and back to the top.
    var at: usize = 0;
    var seen: usize = 1;
    while (true) : (seen += 1) {
        const next = wheelTarget(&fields, at, -1);
        if (next == at) break;
        try std.testing.expect(fields[next].kind != .section);
        at = next;
    }
    try std.testing.expectEqual(fields.len - 1, at);
    try std.testing.expectEqual(fields.len - 1, seen);
    try std.testing.expectEqual(fields.len - 1, wheelTarget(&fields, at, -3));
    try std.testing.expectEqual(@as(usize, 0), wheelTarget(&fields, at, 20));
}

test "the trace never shows a product key or a password" {
    var key = TextValue{ .max = 29 };
    const secret = "ABCDE-12345-FGHIJ-67890-KLMNO";
    key.set(secret);
    var out: [16]u8 = undefined;
    const key_field = Field{ .kind = .text, .label = "Product key", .text = &key, .product_key = true };
    const shown = traceText(&key_field, &out);
    try std.testing.expectEqualStrings("(key 25/25)", shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "ABCDE") == null);
    key.set("ABCDE-12");
    try std.testing.expectEqualStrings("(key 7/25)", traceText(&key_field, &out));
    var password = TextValue{};
    password.set(secret);
    const password_field = Field{ .kind = .text, .label = "Password", .text = &password, .secret = true };
    try std.testing.expectEqualStrings("(secret)", traceText(&password_field, &out));
    key.set("");
    try std.testing.expectEqualStrings("", traceText(&key_field, &out));
}
