//! The UEFI theme editor (Tools -> Theme -> Create or edit a theme;
//! docs/menu-themes.md, ROADMAP N7): base theme -> element -> colour, with
//! a live preview of the edited theme beside the form and the readability
//! rules of src/gui/theme_contrast.zig checked on every change. Saved as
//! \EFI\USOS\themes\<name>.ini (the theme.ini format, `base=` plus the
//! colours that differ from the base) and chosen with theme=<name> in
//! usos-settings.ini; the Legacy BIOS Core reads the same file.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const form = @import("manual_form.zig");
const view = @import("manual_view.zig");
const settings_store = @import("settings_store.zig");
const theme_loader = @import("theme_loader.zig");
const serial = @import("serial.zig");

const gui = usos.gui;
const Theme = gui.Theme;
const Color = gui.Color;
const presets = gui.theme_presets;
const contrast = gui.theme_contrast;

const fields = std.meta.fields(Theme);
const color_fields: usize = blk: {
    var n: usize = 0;
    for (fields) |f| {
        if (f.type == Color) n += 1;
    }
    break :blk n;
};

const Row = enum(u8) { name, base, element, colour, red, green, blue, reset, save, cancel };
const reset_id: u8 = 1;
const save_id: u8 = 2;
const cancel_id: u8 = 3;

var name_text = form.TextValue{ .max = presets.max_name_len };
var colour_text = form.TextValue{ .max = 7 };
var base_index: usize = 0;
var element_index: usize = 0;
var red: u8 = 0;
var green: u8 = 0;
var blue: u8 = 0;
var working: Theme = .{};

var base_options: [presets.all.len][]const u8 = undefined;
var element_options: [color_fields][]const u8 = undefined;
var editor_fields: [@typeInfo(Row).@"enum".fields.len]form.Field = undefined;

const name_chars = form.charset("-_", true);

fn t(key: view.Key) []const u8 {
    return view.t(key);
}

fn elementLabel(comptime name: []const u8) []const u8 {
    return t(@field(view.Key, "theme_edit_element_" ++ name));
}

fn baseTitle(index: usize) []const u8 {
    return switch (index) {
        0 => t(.themes_name_default),
        1 => t(.themes_name_dark),
        2 => t(.themes_name_light),
        3 => t(.themes_name_high_contrast),
        4 => t(.themes_name_retro),
        else => presets.all[index].name,
    };
}

fn getColour(index: usize) Color {
    var n: usize = 0;
    inline for (fields) |f| {
        if (f.type == Color) {
            if (n == index) return @field(working, f.name);
            n += 1;
        }
    }
    unreachable;
}

fn setColour(index: usize, colour: Color) void {
    var n: usize = 0;
    inline for (fields) |f| {
        if (f.type == Color) {
            if (n == index) @field(working, f.name) = colour;
            n += 1;
        }
    }
}

fn fieldName(index: usize) []const u8 {
    var n: usize = 0;
    inline for (fields) |f| {
        if (f.type == Color) {
            if (n == index) return f.name;
            n += 1;
        }
    }
    unreachable;
}

fn labelForField(name: []const u8) []const u8 {
    inline for (fields) |f| {
        if (f.type == Color and std.mem.eql(u8, f.name, name)) return elementLabel(f.name);
    }
    return name;
}

fn syncFromElement() void {
    const c = getColour(element_index);
    red = c.r;
    green = c.g;
    blue = c.b;
    syncText();
}

fn syncText() void {
    var buffer: [7]u8 = undefined;
    colour_text.set(std.fmt.bufPrint(&buffer, "#{X:0>2}{X:0>2}{X:0>2}", .{ red, green, blue }) catch "#000000");
}

fn setSwatches() void {
    const c = getColour(element_index);
    editor_fields[@intFromEnum(Row.element)].swatch = c;
    editor_fields[@intFromEnum(Row.colour)].swatch = c;
}

var dummy_context: u8 = 0;

fn hookChanged(_: *anyopaque, index: usize) void {
    switch (@as(Row, @enumFromInt(index))) {
        .base => {
            working = presets.all[base_index].theme;
            syncFromElement();
        },
        .element => syncFromElement(),
        .colour => if (Color.fromHex(colour_text.slice())) |c| {
            setColour(element_index, c);
            red = c.r;
            green = c.g;
            blue = c.b;
        },
        .red, .green, .blue => {
            setColour(element_index, .{ .r = red, .g = green, .b = blue });
            syncText();
        },
        else => {},
    }
    setSwatches();
    traceContrast();
}

fn problemPair(buffer: []u8, problem: []const u8) []const u8 {
    for (contrast.rules) |rule| {
        if (std.mem.eql(u8, rule.name, problem)) return view.format(buffer, .theme_edit_pair, &.{ labelForField(rule.fore), labelForField(rule.back) });
    }
    return problem;
}

fn nameProblem() bool {
    const name = name_text.slice();
    return name.len == 0 or !presets.nameUsable(name) or presets.index(name) != null;
}

fn hookInvalid(_: *anyopaque, index: usize) bool {
    return switch (@as(Row, @enumFromInt(index))) {
        .name => name_text.len > 0 and nameProblem(),
        .colour => Color.fromHex(colour_text.slice()) == null,
        .save => contrast.firstProblem(working) != null,
        else => false,
    };
}

var status_text: [200]u8 = undefined;
var pair_text: [160]u8 = undefined;

fn contrastLine() struct { text: []const u8, ok: bool } {
    if (contrast.firstProblem(working)) |problem| {
        return .{ .text = view.format(&status_text, .theme_edit_contrast_bad, &.{problemPair(&pair_text, problem)}), .ok = false };
    }
    return .{ .text = t(.theme_edit_contrast_ok), .ok = true };
}

fn traceContrast() void {
    serial.writeAscii("[THEME_EDIT] contrast ");
    serial.writeAscii(if (contrast.firstProblem(working)) |problem| problem else "ok");
    serial.writeAscii("\n");
}

fn drawSide(u: *const gui.ui.Ui, rect: gui.ui.Rect) void {
    const line = contrastLine();
    gui.theme_preview.draw(u, rect, working, .{
        .title = t(.theme_edit_preview_title),
        .row = t(.theme_edit_preview_row),
        .text = t(.theme_edit_preview_text),
        .button = t(.theme_edit_preview_button),
        .disabled = t(.theme_edit_preview_disabled),
        .contrast = line.text,
        .ok = line.ok,
    });
}

/// The file text: base= and every colour that differs from the base.
pub fn fileText(theme: Theme, base: usize, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; USOS user theme, written by the UEFI theme editor (docs/menu-themes.md)\r\n");
    try w.print("base={s}\r\n", .{presets.all[base].name});
    const reference = presets.all[base].theme;
    inline for (fields) |f| {
        if (f.type == Color) {
            const c = @field(theme, f.name);
            const r = @field(reference, f.name);
            if (c.r != r.r or c.g != r.g or c.b != r.b) try w.print("{s}=#{x:0>2}{x:0>2}{x:0>2}\r\n", .{ f.name, c.r, c.g, c.b });
        }
    }
    return w.buffered();
}

fn baseOf(text: []const u8) usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..eq], " \t"), "base")) {
            return presets.index(std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse 0;
        }
    }
    return 0;
}

fn ensureDirectory(root: *uefi.protocol.File, path: []const u8) !void {
    var name: [64]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], path);
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    const dir = try root.open(z, .read_write_create, .{ .directory = true });
    dir.close() catch {};
}

fn save(root: *uefi.protocol.File) !void {
    var bytes: [gui.theme_file.max_bytes]u8 = undefined;
    const text = try fileText(working, base_index, &bytes);
    // What the menu (and the BIOS) will read back must be this theme.
    const outcome = gui.theme_file.resolve(text);
    if (outcome.problem != null or !std.meta.eql(outcome.theme, working)) return error.ThemeDoesNotRoundTrip;
    try ensureDirectory(root, theme_loader.esp_directory);
    var path: [80]u8 = undefined;
    try settings_store.replaceFile(root, try std.fmt.bufPrint(&path, "{s}\\{s}.ini", .{ theme_loader.esp_directory, name_text.slice() }), text);
    try settings_store.set(presets.setting_key, name_text.slice());
    view.setTheme(working);
    serial.writeAscii("[THEME_EDIT] saved ");
    serial.writeAscii(name_text.slice());
    serial.writeAscii("\n");
}

/// Opens the editor on `current` (the chosen theme's name; a user theme
/// is loaded for editing, a built-in one is the base of a new theme).
pub fn edit(root: *uefi.protocol.File, current: []const u8) void {
    name_text.len = 0;
    base_index = 0;
    working = .{};
    if (presets.index(current)) |index| {
        base_index = index;
        working = presets.all[index].theme;
    } else if (theme_loader.readUserText(current)) |text| {
        const outcome = gui.theme_file.resolve(text);
        base_index = baseOf(text);
        working = if (outcome.problem == null) outcome.theme else presets.all[base_index].theme;
        // The shipped examples (usos-*) are rewritten by updates: a copy
        // under the user's own name is saved instead.
        if (!std.ascii.startsWithIgnoreCase(current, "usos-")) name_text.set(current);
    }
    for (presets.all, 0..) |_, i| base_options[i] = baseTitle(i);
    comptime var n: usize = 0;
    inline for (fields) |f| {
        if (f.type == Color) {
            element_options[n] = elementLabel(f.name);
            n += 1;
        }
    }
    element_index = 0;
    syncFromElement();
    editor_fields = .{
        .{ .kind = .text, .label = t(.theme_edit_field_name), .text = &name_text, .allowed = &name_chars },
        .{ .kind = .choice, .label = t(.theme_edit_field_base), .options = &base_options, .index = &base_index },
        .{ .kind = .choice, .label = t(.theme_edit_field_element), .options = &element_options, .index = &element_index },
        .{ .kind = .text, .label = t(.theme_edit_field_color), .text = &colour_text, .allowed = &hex_allowed, .uppercase = true },
        .{ .kind = .stepper, .label = t(.theme_edit_field_red), .number = &red },
        .{ .kind = .stepper, .label = t(.theme_edit_field_green), .number = &green },
        .{ .kind = .stepper, .label = t(.theme_edit_field_blue), .number = &blue },
        .{ .kind = .action, .label = t(.theme_edit_reset), .id = reset_id },
        .{ .kind = .action, .label = t(.theme_edit_save), .primary = true, .id = save_id },
        .{ .kind = .action, .label = t(.theme_edit_cancel), .id = cancel_id },
    };
    setSwatches();
    traceContrast();
    const hooks = form.Hooks{ .context = @ptrCast(&dummy_context), .changed = hookChanged, .invalid = hookInvalid, .side = drawSide, .side_w = 440 };
    var selected: usize = if (name_text.len == 0) 0 else 2;
    while (true) {
        switch (form.run(t(.theme_edit_title), t(.theme_edit_subtitle), &editor_fields, hooks, &selected)) {
            .back => return,
            .x_on, .y_on => {},
            .action => |id| switch (id) {
                reset_id => {
                    // The base's own value of this element.
                    resetElement();
                    syncFromElement();
                    setSwatches();
                },
                save_id => {
                    if (nameProblem()) {
                        selected = @intFromEnum(Row.name);
                        continue;
                    }
                    if (contrast.firstProblem(working)) |problem| {
                        var args = [_][]const u8{problemPair(&pair_text, problem)};
                        const lines = [_][]const u8{view.format(&status_text, .theme_edit_blocked, &args)};
                        view.notice(t(.theme_edit_title), .warning, .warning, name_text.slice(), &lines);
                        view.waitForDismiss();
                        continue;
                    }
                    save(root) catch |err| {
                        const lines = [_][]const u8{ t(.theme_edit_save_failed), @errorName(err) };
                        view.notice(t(.theme_edit_title), .warning, .warning, name_text.slice(), &lines);
                        view.waitForDismiss();
                        continue;
                    };
                    var saved_text: [120]u8 = undefined;
                    const lines = [_][]const u8{view.format(&saved_text, .theme_edit_saved, &.{name_text.slice()})};
                    view.notice(t(.theme_edit_title), .check_circle, .success, name_text.slice(), &lines);
                    view.waitForDismiss();
                    return;
                },
                else => return,
            },
        }
    }
}

const hex_allowed = form.charset("#0123456789ABCDEFabcdef", false);

fn resetElement() void {
    const reference = presets.all[base_index].theme;
    var n: usize = 0;
    inline for (fields) |f| {
        if (f.type == Color) {
            if (n == element_index) @field(working, f.name) = @field(reference, f.name);
            n += 1;
        }
    }
}

test "theme file text round-trips through theme_file.resolve" {
    var theme = presets.all[1].theme;
    theme.accent = .{ .r = 0xff, .g = 0x9e, .b = 0x40 };
    var buffer: [4096]u8 = undefined;
    const text = try fileText(theme, 1, &buffer);
    const outcome = gui.theme_file.resolve(text);
    try std.testing.expect(outcome.problem == null);
    try std.testing.expect(std.meta.eql(theme, outcome.theme));
}
