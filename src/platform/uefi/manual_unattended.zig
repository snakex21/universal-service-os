//! Answer file choice. When the system's Unattended folder has no answer
//! files there is nothing to choose, so the screen is skipped, except for a
//! system with a USOS settings file (XP: usos-xp.ini). XP always offers "No
//! answer file (manual installation)", which ignores usos-xp.ini, then the
//! usos-xp.ini summary (first account, computer name; never the key) while
//! the file is active, then the .sif files. Rows: src/flow/answer_screen.zig.
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const xp_settings = @import("xp_settings.zig");

const answer_screen = usos.flow.answer_screen;
pub const Choice = answer_screen.Choice;

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

/// Row text for a settings summary (also used by the summary screen); an
/// inactive file means a manual installation.
pub fn settingsText(buffer: []u8, summary: *const usos.flow.xp_settings_summary.Summary) []const u8 {
    if (!summary.active) return view.t(.unattended_xp_manual);
    return view.format(buffer, .unattended_xp_settings, &.{ summary.user(), summary.computer() });
}

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) Result {
    const directory = system.unattended_directory orelse return .{};
    const found = discovery.listFilesWithExtension(directory, usos.flow.unattended_policy.extension(system), file_storage[0..]);
    const settings_name = usos.catalog.os_profiles.traits(system.id).settings_file;
    if (!answer_screen.shown(settings_name != null, found)) return .{};
    settings = if (settings_name) |name| xp_settings.read(directory, name) else .{};
    layout = answer_screen.layout(settings_name != null, settings.active, found);

    var names: [answer_screen.max_files][]const u8 = undefined;
    for (0..found) |index| names[index] = file_storage[index].slice();
    var rows: [answer_screen.max_rows]usos.gui.ui.Row = undefined;
    for (layout.slice(), 0..) |kind, index| rows[index] = switch (kind) {
        .no_answer => .{ .title = view.t(.unattended_none), .icon = .{ .vector = .close } },
        .xp_manual => .{ .title = view.t(.unattended_xp_manual), .icon = .{ .vector = .close } },
        .xp_settings => .{ .title = settingsText(&settings_title, &settings), .icon = .{ .label = "INI" } },
        .file => .{ .title = names[index - layout.first_file], .icon = .{ .label = usos.flow.unattended_policy.fileKindLabel(system) } },
    };
    const len = layout.len;

    var selected: usize = layout.default;
    var list: view.ListScreen = undefined;
    list.open(view.t(.unattended_title), view.t(.unattended_subtitle), rows[0..len], selected, false, help(selected));
    traceRows(rows[0..len]);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, &list)) {
            .activate => return .{ .choice = layout.choice(selected, names[0..found]), .available = found, .shown = true },
            .back => return .{ .back = true, .shown = true },
            .changed => list.updateSelection(selected, help(selected)),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

/// Serial trace of the rows (QEMU click-through test and its golden,
/// tools/tests/golden/uefi_answer_screen.tsv). Never shows the key.
fn traceRows(rows: []const usos.gui.ui.Row) void {
    const serial = @import("serial.zig");
    for (rows, layout.slice()) |row, kind| {
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
        .file => if (layout.rows[0] == .xp_manual) view.t(.unattended_xp_file_detail) else view.t(.unattended_file_detail),
    };
    return .{ .title = view.t(.unattended_title), .lines = &help_line };
}
