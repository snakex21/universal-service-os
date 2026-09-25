//! Answer file choice. When the system's Unattended folder has no answer
//! files there is nothing to choose, so the screen is skipped, except for a
//! system with a USOS settings file (XP: usos-xp.ini), whose state is always
//! shown in the first row: its summary (first account, computer name; never
//! the key) or "no settings (interactive Setup)".
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const xp_settings = @import("xp_settings.zig");

pub const Result = struct {
    back: bool = false,
    path: ?[]const u8 = null,
    /// Answer files found in the system's Unattended folder on DATA (read
    /// directly with the NTFS reader; extensions match in any case). Zero
    /// skips the screen; the summary then says where to put one.
    available: usize = 0,
};

var file_storage: [8]usos.catalog.FixedText = undefined;
var settings_title: [160]u8 = undefined;
var settings: usos.flow.xp_settings_summary.Summary = .{};
var has_settings_file = false;

/// First-row text for a settings summary (also used by the summary screen).
pub fn settingsText(buffer: []u8, summary: *const usos.flow.xp_settings_summary.Summary) []const u8 {
    if (!summary.active) return view.t(.unattended_xp_none);
    return view.format(buffer, .unattended_xp_settings, &.{ summary.user(), summary.computer() });
}

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) Result {
    const directory = system.unattended_directory orelse return .{};
    const found = discovery.listFilesWithExtension(directory, usos.flow.unattended_policy.extension(system), file_storage[0..]);
    const settings_name = usos.catalog.os_profiles.traits(system.id).settings_file;
    has_settings_file = settings_name != null;
    if (found == 0 and !has_settings_file) return .{};
    const available = found;
    settings = if (settings_name) |name| xp_settings.read(directory, name) else .{};

    var options: [9]?[]const u8 = undefined;
    var rows: [9]usos.gui.ui.Row = undefined;
    options[0] = null;
    rows[0] = if (!has_settings_file)
        .{ .title = view.t(.unattended_none), .icon = .{ .vector = .close } }
    else if (settings.active)
        .{ .title = settingsText(&settings_title, &settings), .icon = .{ .label = "INI" } }
    else
        .{ .title = view.t(.unattended_xp_none), .icon = .{ .vector = .close } };
    for (0..found) |index| {
        options[1 + index] = file_storage[index].slice();
        rows[1 + index] = .{ .title = file_storage[index].slice(), .icon = .{ .label = usos.flow.unattended_policy.fileKindLabel(system) } };
    }
    const len = 1 + found;

    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.t(.unattended_title), view.t(.unattended_subtitle), rows[0..len], selected, false, help(selected));

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, &list)) {
            .activate => return .{ .path = options[selected], .available = available },
            .back => return .{ .back = true },
            .changed => list.updateSelection(selected, help(selected)),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

var help_line: [1][]const u8 = undefined;

fn help(selected: usize) usos.gui.menu_screens.Help {
    help_line[0] = if (selected == 0)
        (if (!has_settings_file) view.t(.unattended_none_detail) else if (settings.active) view.t(.unattended_xp_settings_detail) else view.t(.unattended_xp_none_detail))
    else if (has_settings_file) view.t(.unattended_xp_file_detail) else view.t(.unattended_file_detail);
    return .{ .title = view.t(.unattended_title), .lines = &help_line };
}
