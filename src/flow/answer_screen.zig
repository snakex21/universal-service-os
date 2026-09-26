//! Rows of the UEFI answer-file screen (src/platform/uefi/manual_unattended.zig)
//! and what each choice hands on to the start of the installation.
//!
//! A system without a USOS settings file: "No answer file", then the answer
//! files of its Unattended folder; the screen is skipped when there are none.
//! XP (settings file usos-xp.ini): always "No answer file (manual
//! installation)", which ignores usos-xp.ini (usos.xp_settings=off), then the
//! "usos-xp.ini: <user>, <computer>" row while the file is active (selected
//! by default), then the .sif files.
const std = @import("std");

pub const max_files: usize = 8;
pub const max_rows: usize = max_files + 2;

pub const Row = enum {
    /// Any system: no answer file.
    no_answer,
    /// XP: no answer file and usos-xp.ini ignored (interactive Setup).
    xp_manual,
    /// XP: the active usos-xp.ini (hands-off Setup).
    xp_settings,
    /// An answer file from the Unattended folder.
    file,
};

pub const Choice = struct {
    /// Answer file name from the Unattended folder; null: none.
    path: ?[]const u8 = null,
    /// XP: do not use usos-xp.ini (manual installation).
    ignore_settings: bool = false,
};

pub const Layout = struct {
    rows: [max_rows]Row = undefined,
    len: usize = 0,
    /// Row selected when the screen opens.
    default: usize = 0,
    /// Index of the first .file row.
    first_file: usize = 0,

    fn add(self: *Layout, row: Row) void {
        self.rows[self.len] = row;
        self.len += 1;
    }

    pub fn slice(self: *const Layout) []const Row {
        return self.rows[0..self.len];
    }

    /// What activating row `index` means; `files` are the listed file names.
    pub fn choice(self: *const Layout, index: usize, files: []const []const u8) Choice {
        if (index >= self.len) return .{};
        return switch (self.rows[index]) {
            .no_answer, .xp_settings => .{},
            .xp_manual => .{ .ignore_settings = true },
            .file => .{ .path = files[index - self.first_file] },
        };
    }
};

/// Whether the screen is shown at all.
pub fn shown(settings_file: bool, files: usize) bool {
    return settings_file or files > 0;
}

pub fn layout(settings_file: bool, settings_active: bool, files: usize) Layout {
    var result = Layout{};
    if (settings_file) {
        result.add(.xp_manual);
        if (settings_active) {
            result.default = result.len;
            result.add(.xp_settings);
        }
    } else {
        result.add(.no_answer);
    }
    result.first_file = result.len;
    for (0..@min(files, max_files)) |_| result.add(.file);
    return result;
}

/// ` usos.legacy_unattended_hex=` for a .sif chosen on the answer screen: the
/// staging merges it into the automatic answer (tools/xp_user_settings.sh).
pub fn xpAnswerOption(buffer: []u8, answer: ?[]const u8) ![]const u8 {
    const name = answer orelse return "";
    if (name.len == 0 or name.len > 120 or std.mem.indexOfAny(u8, name, "\\/\r\n\"") != null) return error.InvalidXpAnswerName;
    if (name.len < 4 or !std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".sif")) return error.InvalidXpAnswerName;
    const prefix = " usos.legacy_unattended_hex=";
    if (buffer.len < prefix.len + name.len * 2) return error.InvalidXpAnswerName;
    @memcpy(buffer[0..prefix.len], prefix);
    for (name, 0..) |c, i| {
        buffer[prefix.len + i * 2] = "0123456789abcdef"[c >> 4];
        buffer[prefix.len + i * 2 + 1] = "0123456789abcdef"[c & 15];
    }
    return buffer[0 .. prefix.len + name.len * 2];
}

/// ` usos.xp_settings=off` for the manual installation row: the staging
/// (tools/legacy_xp_staging.sh) then leaves usos-xp.ini alone.
pub fn xpSettingsOption(choice: Choice) []const u8 {
    return if (choice.ignore_settings) " usos.xp_settings=off" else "";
}

test "XP answer option carries only a .sif file name" {
    var buffer: [300]u8 = undefined;
    try std.testing.expectEqualStrings("", try xpAnswerOption(&buffer, null));
    try std.testing.expectEqualStrings(" usos.legacy_unattended_hex=612e534946", try xpAnswerOption(&buffer, "a.SIF"));
    try std.testing.expectError(error.InvalidXpAnswerName, xpAnswerOption(&buffer, "a.xml"));
    try std.testing.expectError(error.InvalidXpAnswerName, xpAnswerOption(&buffer, "dir\\a.sif"));
    try std.testing.expectEqualStrings(" usos.legacy_unattended_hex=6d7920612e736966", try xpAnswerOption(&buffer, "my a.sif"));
}

const Golden = struct {
    name: []const u8,
    settings_file: bool,
    active: bool,
    files: usize,
    shown: bool,
    rows: []const Row,
    default: usize,
    /// Command-line options of each row (XP) as the UEFI menu passes them.
    options: []const []const u8 = &.{},
};

// Golden rows: screen state -> rows, default row, per-row XP options.
const golden = [_]Golden{
    .{ .name = "Windows 10, empty Unattended", .settings_file = false, .active = false, .files = 0, .shown = false, .rows = &.{.no_answer}, .default = 0 },
    .{ .name = "Windows 10, two .xml", .settings_file = false, .active = false, .files = 2, .shown = true, .rows = &.{ .no_answer, .file, .file }, .default = 0 },
    .{ .name = "XP, usos-xp.ini empty, no .sif", .settings_file = true, .active = false, .files = 0, .shown = true, .rows = &.{.xp_manual}, .default = 0, .options = &.{" usos.xp_settings=off"} },
    .{ .name = "XP, usos-xp.ini empty, one .sif", .settings_file = true, .active = false, .files = 1, .shown = true, .rows = &.{ .xp_manual, .file }, .default = 0, .options = &.{ " usos.xp_settings=off", " usos.legacy_unattended_hex=612e736966" } },
    .{ .name = "XP, usos-xp.ini active, no .sif", .settings_file = true, .active = true, .files = 0, .shown = true, .rows = &.{ .xp_manual, .xp_settings }, .default = 1, .options = &.{ " usos.xp_settings=off", "" } },
    .{ .name = "XP, usos-xp.ini active, one .sif (X470 bug 1)", .settings_file = true, .active = true, .files = 1, .shown = true, .rows = &.{ .xp_manual, .xp_settings, .file }, .default = 1, .options = &.{ " usos.xp_settings=off", "", " usos.legacy_unattended_hex=612e736966" } },
    .{ .name = "XP, eight .sif (list limit)", .settings_file = true, .active = true, .files = 12, .shown = true, .rows = &.{ .xp_manual, .xp_settings, .file, .file, .file, .file, .file, .file, .file, .file }, .default = 1 },
};

test "answer screen golden rows" {
    const names = [_][]const u8{"a.sif"} ** max_files;
    for (golden) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.shown, shown(case.settings_file, case.files));
        const l = layout(case.settings_file, case.active, case.files);
        try std.testing.expectEqualSlices(Row, case.rows, l.slice());
        try std.testing.expectEqual(case.default, l.default);
        for (case.options, 0..) |expected, index| {
            const c = l.choice(index, &names);
            var buffer: [300]u8 = undefined;
            var text: [400]u8 = undefined;
            const joined = try std.fmt.bufPrint(&text, "{s}{s}", .{ try xpAnswerOption(&buffer, c.path), xpSettingsOption(c) });
            try std.testing.expectEqualStrings(expected, joined);
        }
    }
}

test "only the manual row ignores usos-xp.ini" {
    const names = [_][]const u8{"a.sif"};
    const l = layout(true, true, 1);
    try std.testing.expect(l.choice(0, &names).ignore_settings);
    try std.testing.expect(!l.choice(1, &names).ignore_settings);
    try std.testing.expect(!l.choice(2, &names).ignore_settings);
    try std.testing.expectEqualStrings("a.sif", l.choice(2, &names).path.?);
}
