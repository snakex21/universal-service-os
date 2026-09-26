//! Tools -> Theme: "Create or edit a theme" (the theme editor,
//! theme_editor.zig), the built-in menu themes and the user themes (ESP
//! \EFI\USOS\themes, DATA\Themes). Enter applies the theme at once and writes `theme=<name>`
//! to usos-settings.ini through settings_store (a merge: every other key
//! and line stays). A user theme is validated before anything is saved;
//! one that cannot be used shows why and changes nothing. The Legacy
//! BIOS menu reads the same key (built-in themes only).
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const settings_store = @import("settings_store.zig");
const theme_loader = @import("theme_loader.zig");

const Row = usos.gui.ui.Row;
const presets = usos.gui.theme_presets;

const builtin_count = presets.all.len;
/// Row 0 opens the theme editor.
const first_builtin = 1;
const max_rows = first_builtin + builtin_count + theme_loader.max_user_themes;

/// The chosen theme's name ("default" when none is set).
fn currentName() []const u8 {
    const value = presets.settingValue(settings_store.current());
    return if (value.len == 0) presets.all[0].name else value;
}

fn builtinTitle(index: usize) []const u8 {
    return switch (index) {
        0 => view.t(.themes_name_default),
        1 => view.t(.themes_name_dark),
        2 => view.t(.themes_name_light),
        3 => view.t(.themes_name_high_contrast),
        4 => view.t(.themes_name_retro),
        else => presets.all[index].name,
    };
}

comptime {
    // builtinTitle names every preset.
    std.debug.assert(builtin_count == 5);
}

/// The Tools list row for this page.
pub fn toolsRow() Row {
    const name = currentName();
    const title = if (presets.index(name)) |index| builtinTitle(index) else name;
    return .{ .title = view.t(.themes_title), .detail = view.t(.themes_desc), .icon = .{ .vector = .gear }, .badge = .{ .text = title, .tone = .neutral } };
}

var user_names: [theme_loader.max_user_themes]theme_loader.Name = undefined;
var details: [theme_loader.max_user_themes][96]u8 = undefined;
var invalid_text: [160]u8 = undefined;

pub fn page(root: *std.os.uefi.protocol.File) void {
    var user_count = theme_loader.listUser(&user_names);
    var selected: usize = 0;
    var first_open = true;
    while (true) {
        const current = currentName();
        var rows: [max_rows]Row = undefined;
        const current_badge = usos.gui.ui.Badge{ .text = view.t(.themes_current), .tone = .success };
        rows[0] = .{ .title = view.t(.theme_edit_open), .detail = view.t(.theme_edit_open_detail), .icon = .{ .vector = .gear } };
        for (presets.all, 0..) |preset, index| {
            const is_current = std.ascii.eqlIgnoreCase(preset.name, current);
            if (is_current and first_open) selected = first_builtin + index;
            rows[first_builtin + index] = .{ .title = builtinTitle(index), .detail = view.t(.themes_builtin), .icon = .{ .vector = .gear }, .badge = if (is_current) current_badge else null };
        }
        for (user_names[0..user_count], 0..) |*name, index| {
            const is_current = std.ascii.eqlIgnoreCase(name.slice(), current);
            if (is_current and first_open) selected = first_builtin + builtin_count + index;
            const where = if (theme_loader.sourceOf(name.slice()) == .esp) "EFI\\USOS\\themes" else "DATA\\Themes";
            const detail = std.fmt.bufPrint(&details[index], "{s} · {s}\\{s}", .{ view.t(.themes_user), where, name.slice() }) catch name.slice();
            rows[first_builtin + builtin_count + index] = .{ .title = name.slice(), .detail = detail, .icon = .{ .vector = .drive }, .badge = if (is_current) current_badge else null };
        }
        first_open = false;
        const total = first_builtin + builtin_count + user_count;
        var list: view.ListScreen = undefined;
        list.open(view.t(.themes_title), view.t(.themes_hint), rows[0..total], selected, true, null);
        const action: ?usize = loop: while (true) {
            switch (navigation.handle(input.readBlocking(), &selected, total, &list)) {
                .activate => break :loop selected,
                .back => break :loop null,
                .changed => list.updateSelection(selected, null),
                .pointer_moved => view.updatePointer(),
                .ignored => {},
            }
        };
        const row = action orelse return;
        if (row == 0) {
            @import("theme_editor.zig").edit(root, currentName());
            user_count = theme_loader.listUser(&user_names);
            continue;
        }
        const index = row - first_builtin;
        if (index < builtin_count) {
            choose(root, presets.all[index].name, null);
        } else {
            const name = user_names[index - builtin_count].slice();
            const outcome = theme_loader.readUser(name);
            if (outcome.problem) |problem| {
                showInvalid(name, problem);
                continue;
            }
            choose(root, name, outcome.theme);
        }
    }
}

/// Saves `theme=<name>` and applies it (`theme` for a validated user
/// theme; built-in ones go through theme_loader so the default keeps
/// \UI\theme.css).
fn choose(root: *std.os.uefi.protocol.File, name: []const u8, theme: ?usos.gui.Theme) void {
    settings_store.set(presets.setting_key, name) catch |err| {
        const lines = [_][]const u8{@errorName(err)};
        view.notice(view.t(.themes_title), .warning, .warning, "", &lines);
        view.waitForDismiss();
        return;
    };
    view.setTheme(theme orelse theme_loader.forName(root, name));
}

fn showInvalid(name: []const u8, problem: []const u8) void {
    var args = [_][]const u8{problem};
    const lines = [_][]const u8{view.format(&invalid_text, .themes_invalid, &args)};
    view.notice(view.t(.themes_title), .warning, .warning, name, &lines);
    view.waitForDismiss();
}
