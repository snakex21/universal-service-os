//! The answer-file screen, the answer-profile manager
//! (docs/answer-profiles.md; rows: src/flow/answer_screen.zig):
//!
//!   No answer file (manual installation)
//!   usos-xp.ini: <user>, <computer>        XP, while DATA's file is active
//!   <USOS profiles from the ESP>          A use, X edit, Y delete (confirmed)
//!   <files from Unattended\>              use only
//!   + Add a new profile
//!
//! X on the usos-xp.ini row imports it into a new ESP profile (DATA is
//! read-only for the menu). The screen is skipped only when nothing can be
//! chosen (no profiles possible, no settings file, no files).
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const xp_settings = @import("xp_settings.zig");
const answer_profiles = @import("answer_profiles.zig");
const profile_editor = @import("profile_editor.zig");
const serial = @import("serial.zig");

const answer_screen = usos.flow.answer_screen;
pub const Choice = answer_screen.Choice;
const Hint = usos.gui.ui.Hint;

pub const Result = struct {
    back: bool = false,
    choice: Choice = .{},
    /// Answer files found in the system's Unattended folder on DATA (read
    /// directly with the NTFS reader; extensions match in any case). Zero
    /// skips the screen; the summary then says where to put one.
    available: usize = 0,
    /// The screen was on display (Back from the summary returns to it).
    shown: bool = false,
};

var file_storage: [answer_screen.max_files]usos.catalog.FixedText = undefined;
var settings_title: [160]u8 = undefined;
var settings: usos.flow.xp_settings_summary.Summary = .{};
var layout: answer_screen.Layout = .{};
var profile_details: [answer_screen.max_profiles][120]u8 = undefined;

/// Row text for a settings summary (also used by the summary screen); an
/// inactive file means a manual installation.
pub fn settingsText(buffer: []u8, summary: *const usos.flow.xp_settings_summary.Summary) []const u8 {
    if (!summary.active) return view.t(.unattended_xp_manual);
    return view.format(buffer, .unattended_xp_settings, &.{ summary.user(), summary.computer() });
}

/// Text of a profile for rows and the summary: "<user>, <computer>".
pub fn profileDetail(buffer: []u8, p: *const answer_profiles.Profile) []const u8 {
    const computer = if (p.computer.len > 0) p.computer.slice() else view.t(.profile_value_auto);
    return view.format(buffer, .profile_row_detail, &.{ p.user.slice(), computer });
}

pub const Context = struct {
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    /// USOS profiles can be handed on for this selection.
    profiles_allowed: bool,
    /// Vista on UEFI: the screen shows only the "not supported yet" note.
    answers_unsupported: bool = false,
    /// The image chosen before this screen (the editor lists its editions).
    image: ?usos.catalog.ImageItem = null,
};

var editor_images: usos.flow.answer.editions.List = .{};
var editor_images_for: usos.catalog.FixedText = .{};
var editor_images_known = false;
var editor_images_system: ?*const usos.catalog.SystemEntry = null;

/// The editions of the chosen ISO for the editor's list picker (read once
/// per image); null: no ISO, NT5, or unreadable (the editor offers text).
fn editorImages(context: Context) ?*const usos.flow.answer.editions.List {
    const image = context.image orelse return null;
    if (image.kind != .iso) return null;
    const family = usos.flow.answer.target.familyFor(context.system.id) orelse return null;
    if (family.nt5()) return null;
    if (!(editor_images_known and editor_images_system == context.system and std.mem.eql(u8, editor_images_for.slice(), image.name.slice()))) {
        editor_images_for = image.name;
        editor_images_known = true;
        editor_images_system = context.system;
        @import("windows_media_probe.zig").readEditions(context.system, image.name.slice(), &editor_images) catch {
            editor_images.len = 0;
        };
    }
    return if (editor_images.len > 0) &editor_images else null;
}

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, context: Context) Result {
    const system = context.system;
    const directory = system.unattended_directory orelse return .{};
    const found = discovery.listFilesWithExtension(directory, usos.flow.unattended_policy.extension(system), file_storage[0..]);
    const settings_name = usos.catalog.os_profiles.traits(system.id).settings_file;
    if (context.profiles_allowed) answer_profiles.reload(context.root);
    const in_first = answer_screen.Input{ .settings_file = settings_name != null, .profiles_allowed = context.profiles_allowed, .profiles = answer_profiles.len(), .files = found, .unsupported = context.answers_unsupported };
    if (!answer_screen.shown(in_first)) return .{};
    settings = if (settings_name) |name| xp_settings.read(directory, name) else .{};

    var selected: ?usize = null;
    while (true) {
        const in = answer_screen.Input{ .settings_file = settings_name != null, .settings_active = settings.active, .profiles_allowed = context.profiles_allowed, .profiles = answer_profiles.len(), .files = found, .unsupported = context.answers_unsupported };
        layout = answer_screen.layout(in);
        var names: [answer_screen.max_files][]const u8 = undefined;
        for (0..found) |index| names[index] = file_storage[index].slice();
        const outcome = screen(context, names[0..found], selected orelse layout.default);
        selected = outcome.index;
        switch (outcome.action) {
            .back => return .{ .back = true, .shown = true },
            .use => {
                if (layout.rows[outcome.index] == .add) {
                    selected = addProfile(context) orelse outcome.index;
                    continue;
                }
                return .{ .choice = layout.choice(outcome.index, names[0..found]), .available = found, .shown = true };
            },
            .edit => {
                const row = layout.rows[outcome.index];
                if (row == .profile) {
                    const index = outcome.index - layout.first_profile;
                    const p = answer_profiles.get(index).*;
                    var stem_copy: [32]u8 = undefined;
                    const s = answer_profiles.stem(index);
                    @memcpy(stem_copy[0..s.len], s);
                    if (profile_editor.edit(context.root, &p, stem_copy[0..s.len], system.id, system.name, editorImages(context))) |name| selected = rowOfProfile(name);
                } else if (row == .xp_settings) {
                    selected = importXp(context, directory, settings_name.?) orelse outcome.index;
                }
            },
            .delete => {
                if (layout.rows[outcome.index] != .profile) continue;
                const index = outcome.index - layout.first_profile;
                if (confirmDelete(answer_profiles.get(index).name.slice())) {
                    answer_profiles.delete(context.root, index);
                    selected = outcome.index -| 1;
                }
            },
        }
    }
}

fn rowOfProfile(name: []const u8) ?usize {
    const index = answer_profiles.find(name) orelse return null;
    // The layout is rebuilt with the new count on the next pass.
    return layout.first_profile + index;
}

fn addProfile(context: Context) ?usize {
    const p = profile_editor.defaults(view.languageCode());
    const name = profile_editor.edit(context.root, &p, null, context.system.id, context.system.name, editorImages(context)) orelse return null;
    return rowOfProfile(name);
}

/// X on usos-xp.ini: its settings in the editor as a new ESP profile.
fn importXp(context: Context, directory: []const u8, name: []const u8) ?usize {
    var p: answer_profiles.Profile = undefined;
    const imported = xp_settings.importProfile(directory, name, &p) orelse return null;
    _ = imported;
    p.name.set("usos-xp") catch {};
    const saved = profile_editor.edit(context.root, &p, null, context.system.id, context.system.name, editorImages(context)) orelse return null;
    return rowOfProfile(saved);
}

var confirm_rows: [2]usos.gui.ui.Row = undefined;
var confirm_title: [120]u8 = undefined;

fn confirmDelete(name: []const u8) bool {
    confirm_rows = .{
        .{ .title = view.t(.profile_delete_keep), .icon = .{ .vector = .close } },
        .{ .title = view.t(.profile_delete_confirm), .icon = .{ .vector = .warning } },
    };
    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.t(.profile_delete_title), view.format(&confirm_title, .profile_delete_question, &.{name}), &confirm_rows, selected, false, null);
    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, confirm_rows.len, &list)) {
            .activate => return selected == 1,
            .back => return false,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

const Action = enum { use, edit, delete, back };
const Outcome = struct { action: Action, index: usize };

var rows: [answer_screen.max_rows]usos.gui.ui.Row = undefined;
var hint_storage: [5]Hint = undefined;

fn screen(context: Context, names: []const []const u8, initial: usize) Outcome {
    const system = context.system;
    for (layout.slice(), 0..) |kind, index| rows[index] = switch (kind) {
        .no_answer => .{ .title = view.t(.unattended_xp_manual), .detail = view.t(.profile_manual_detail), .icon = .{ .vector = .close } },
        .xp_manual => .{ .title = view.t(.unattended_xp_manual), .detail = view.t(.profile_manual_detail), .icon = .{ .vector = .close } },
        .xp_settings => .{ .title = settingsText(&settings_title, &settings), .detail = view.t(.profile_xp_ini_detail), .icon = .{ .label = "INI" } },
        .profile => blk: {
            const p = answer_profiles.get(index - layout.first_profile);
            break :blk .{ .title = p.name.slice(), .detail = profileDetail(&profile_details[index - layout.first_profile], p), .icon = .{ .label = "USOS" }, .badge = .{ .text = view.t(.profile_badge), .tone = .accent } };
        },
        .file => .{ .title = names[index - layout.first_file], .detail = view.t(.profile_file_detail), .icon = .{ .label = usos.flow.unattended_policy.fileKindLabel(system) } },
        .add => .{ .title = view.t(.profile_add), .detail = view.t(.profile_add_detail), .icon = .{ .vector = .check } },
        .unsupported => .{ .title = view.t(.unattended_vista_uefi), .detail = view.t(.unattended_vista_uefi_detail), .icon = .{ .label = "!" } },
    };
    const len = layout.len;
    var selected: usize = @min(initial, len - 1);
    var list: view.ListScreen = undefined;
    list.openWithHints(view.t(.unattended_title), view.t(.unattended_subtitle), rows[0..len], selected, true, help(selected), hints(selected));
    traceRows(rows[0..len]);
    while (true) {
        const event = input.readBlocking();
        switch (event) {
            .x_button => if (layout.rows[selected].editable()) return .{ .action = .edit, .index = selected },
            .y_button => if (layout.rows[selected].deletable()) return .{ .action = .delete, .index = selected },
            else => {},
        }
        const before = layout.rows[selected];
        switch (navigation.handle(event, &selected, len, &list)) {
            .activate => return .{ .action = .use, .index = selected },
            .back => return .{ .action = .back, .index = selected },
            .changed => {
                // The footer names X/Y only on rows they act on.
                if (before.editable() != layout.rows[selected].editable() or before.deletable() != layout.rows[selected].deletable()) {
                    list.custom_hints = hints(selected);
                    list.redrawFull(selected, help(selected));
                } else list.updateSelection(selected, help(selected));
                serial.writeAscii("[UI_ROW_SELECTED] ");
                serial.writeAscii(@tagName(layout.rows[selected]));
                serial.writeAscii("\n");
            },
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn hints(selected: usize) []const Hint {
    var n: usize = 0;
    hint_storage[n] = .{ .key = input.moveKey("\u{2191}\u{2193}"), .label = view.t(.key_select) };
    n += 1;
    hint_storage[n] = .{ .key = input.enterKey(), .label = view.t(.profile_key_use) };
    n += 1;
    const row = layout.rows[selected];
    if (row.editable()) {
        hint_storage[n] = .{ .key = input.xKey(), .label = if (row == .xp_settings) view.t(.profile_key_import) else view.t(.profile_key_edit) };
        n += 1;
    }
    if (row.deletable()) {
        hint_storage[n] = .{ .key = input.yKey(), .label = view.t(.profile_key_delete) };
        n += 1;
    }
    hint_storage[n] = .{ .key = input.backKey(), .label = view.t(.key_back) };
    n += 1;
    return hint_storage[0..n];
}

/// Serial trace of the rows (QEMU click-through test and its golden,
/// tools/tests/golden/uefi_answer_screen.tsv). Never shows the key.
fn traceRows(list_rows: []const usos.gui.ui.Row) void {
    for (list_rows, layout.slice()) |row, kind| {
        serial.writeAscii("[UI_ROW] ");
        serial.writeAscii(@tagName(kind));
        serial.writeAscii(" | ");
        serial.writeAscii(row.title);
        serial.writeAscii("\n");
    }
}

var help_line: [1][]const u8 = undefined;

fn help(selected: usize) usos.gui.menu_screens.Help {
    help_line[0] = switch (layout.rows[selected]) {
        .no_answer => view.t(.unattended_none_detail),
        .xp_manual => view.t(.unattended_xp_manual_detail),
        .xp_settings => view.t(.unattended_xp_settings_detail),
        .profile => view.t(.profile_row_help),
        .file => if (layout.rows[0] == .xp_manual) view.t(.unattended_xp_file_detail) else view.t(.unattended_file_detail),
        .add => view.t(.profile_add_detail),
        .unsupported => view.t(.unattended_vista_uefi_detail),
    };
    return .{ .title = view.t(.unattended_title), .lines = &help_line };
}
