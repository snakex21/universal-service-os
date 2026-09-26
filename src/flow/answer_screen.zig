//! Rows of the UEFI answer-file screen, the answer-profile manager
//! (src/platform/uefi/manual_unattended.zig), and what each choice hands on
//! to the start of the installation.
//!
//! Order (the agreed mockup, docs/answer-profiles.md):
//!   1. "No answer file (manual installation)": always; on XP it also
//!      ignores DATA's usos-xp.ini (usos.xp_settings=off)
//!   2. XP: "usos-xp.ini: <user>, <computer>" while that file is active
//!      (selected by default; X imports it into a USOS profile)
//!   3. the USOS answer profiles on the ESP (A use, X edit, Y delete)
//!   4. the answer files of the system's Unattended folder (use only)
//!   5. "+ Add a new profile"
//! Profiles (3, 5) appear only where the start can hand a rendered answer
//! on (profileCapable). Without profiles, settings file and files the
//! screen is skipped, as before.
const std = @import("std");
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const Firmware = @import("../core/firmware.zig").Firmware;
const os_profiles = @import("../catalog/os_profiles.zig");
const preparation_capability = @import("preparation_capability.zig");
const answer_target = @import("answer/target.zig");

pub const max_files: usize = 8;
pub const max_profiles: usize = 8;
pub const max_rows: usize = max_files + max_profiles + 3;

pub const Row = enum {
    /// Any system: no answer file (XP: usos-xp.ini ignored as well).
    no_answer,
    /// XP: no answer file and usos-xp.ini ignored (interactive Setup).
    xp_manual,
    /// XP: the active usos-xp.ini (hands-off Setup).
    xp_settings,
    /// A USOS answer profile from the ESP.
    profile,
    /// An answer file from the Unattended folder.
    file,
    /// "+ Add a new profile".
    add,

    /// X (edit) acts on this row.
    pub fn editable(self: Row) bool {
        return self == .profile or self == .xp_settings;
    }

    pub fn deletable(self: Row) bool {
        return self == .profile;
    }
};

pub const Choice = struct {
    /// Answer file name from the Unattended folder; null: none.
    path: ?[]const u8 = null,
    /// XP: do not use usos-xp.ini (manual installation).
    ignore_settings: bool = false,
    /// Index of the chosen USOS answer profile (the manager's list).
    profile: ?usize = null,
};

pub const Layout = struct {
    rows: [max_rows]Row = undefined,
    len: usize = 0,
    /// Row selected when the screen opens.
    default: usize = 0,
    /// Index of the first .profile and .file rows.
    first_profile: usize = 0,
    first_file: usize = 0,

    fn add(self: *Layout, row: Row) void {
        self.rows[self.len] = row;
        self.len += 1;
    }

    pub fn slice(self: *const Layout) []const Row {
        return self.rows[0..self.len];
    }

    /// What activating row `index` means; `files` are the listed file names.
    /// `.add` has no choice (the manager opens the editor).
    pub fn choice(self: *const Layout, index: usize, files: []const []const u8) Choice {
        if (index >= self.len) return .{};
        return switch (self.rows[index]) {
            .no_answer, .xp_settings, .add => .{},
            .xp_manual => .{ .ignore_settings = true },
            .profile => .{ .profile = index - self.first_profile },
            .file => .{ .path = files[index - self.first_file] },
        };
    }
};

pub const Input = struct {
    /// The system has a USOS settings file (XP: usos-xp.ini).
    settings_file: bool = false,
    settings_active: bool = false,
    /// USOS profiles can be used for this selection (profileCapable).
    profiles_allowed: bool = false,
    profiles: usize = 0,
    files: usize = 0,
};

/// Whether the screen is shown at all.
pub fn shown(in: Input) bool {
    return in.settings_file or in.profiles_allowed or in.files > 0;
}

pub fn layout(in: Input) Layout {
    var result = Layout{};
    if (in.settings_file) {
        result.add(.xp_manual);
        if (in.settings_active) {
            result.default = result.len;
            result.add(.xp_settings);
        }
    } else {
        result.add(.no_answer);
    }
    result.first_profile = result.len;
    if (in.profiles_allowed) {
        for (0..@min(in.profiles, max_profiles)) |_| result.add(.profile);
    }
    result.first_file = result.len;
    for (0..@min(in.files, max_files)) |_| result.add(.file);
    if (in.profiles_allowed and in.profiles < max_profiles) result.add(.add);
    return result;
}

/// A USOS profile can be rendered and handed on for this selection: a
/// Windows with a generated answer, started through the XP UEFI-CSM
/// staging, the native wimboot start (7, 10/11; not Vista, whose own
/// servicing answer refuses one) or a WORK preparation (8/10/11, WIM).
pub fn profileCapable(system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: Firmware) bool {
    if (answer_target.familyFor(system.id) == null) return false;
    if (image != .iso and image != .wim) return false;
    const backend = preparation_capability.resolveForFirmware(system, image, method, firmware) orelse return false;
    return switch (backend) {
        .xp_uefi_staging => true,
        .windows_iso => os_profiles.traits(system.id).native_uefi != .vista,
        .chainload, .wimboot => true,
        else => false,
    };
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

/// ` usos.xp_settings=off` for the manual installation row, ` usos.xp_settings=plan`
/// for a USOS profile (the staging reads EFI/USOS/answer/usos-plan.ini).
pub fn xpSettingsOption(choice: Choice) []const u8 {
    if (choice.profile != null) return " usos.xp_settings=plan";
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
    in: Input,
    shown: bool,
    rows: []const Row,
    default: usize,
    /// Command-line options of each row (XP) as the UEFI menu passes them.
    options: []const []const u8 = &.{},
};

// Golden rows: screen state -> rows, default row, per-row XP options.
const golden = [_]Golden{
    .{ .name = "Windows 98, empty Unattended (no profiles)", .in = .{}, .shown = false, .rows = &.{.no_answer}, .default = 0 },
    .{ .name = "Windows 10, empty Unattended, no profile yet", .in = .{ .profiles_allowed = true }, .shown = true, .rows = &.{ .no_answer, .add }, .default = 0 },
    .{ .name = "Windows 10, two profiles, two .xml", .in = .{ .profiles_allowed = true, .profiles = 2, .files = 2 }, .shown = true, .rows = &.{ .no_answer, .profile, .profile, .file, .file, .add }, .default = 0 },
    .{ .name = "Vista, two .xml (no profiles)", .in = .{ .profiles = 2, .files = 2 }, .shown = true, .rows = &.{ .no_answer, .file, .file }, .default = 0 },
    .{ .name = "XP, usos-xp.ini empty, no .sif", .in = .{ .settings_file = true, .profiles_allowed = true }, .shown = true, .rows = &.{ .xp_manual, .add }, .default = 0, .options = &.{" usos.xp_settings=off"} },
    .{ .name = "XP, usos-xp.ini empty, one .sif", .in = .{ .settings_file = true, .profiles_allowed = true, .files = 1 }, .shown = true, .rows = &.{ .xp_manual, .file, .add }, .default = 0, .options = &.{ " usos.xp_settings=off", " usos.legacy_unattended_hex=612e736966" } },
    .{ .name = "XP, usos-xp.ini active, no .sif", .in = .{ .settings_file = true, .settings_active = true, .profiles_allowed = true }, .shown = true, .rows = &.{ .xp_manual, .xp_settings, .add }, .default = 1, .options = &.{ " usos.xp_settings=off", "" } },
    .{ .name = "XP, usos-xp.ini active, one profile, one .sif", .in = .{ .settings_file = true, .settings_active = true, .profiles_allowed = true, .profiles = 1, .files = 1 }, .shown = true, .rows = &.{ .xp_manual, .xp_settings, .profile, .file, .add }, .default = 1, .options = &.{ " usos.xp_settings=off", "", " usos.xp_settings=plan", " usos.legacy_unattended_hex=612e736966" } },
    .{ .name = "XP, eight .sif (list limit), eight profiles (no Add)", .in = .{ .settings_file = true, .settings_active = true, .profiles_allowed = true, .profiles = 9, .files = 12 }, .shown = true, .rows = &(([_]Row{ .xp_manual, .xp_settings }) ++ [_]Row{.profile} ** 8 ++ [_]Row{.file} ** 8), .default = 1 },
};

test "answer screen golden rows" {
    const names = [_][]const u8{"a.sif"} ** max_files;
    for (golden) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.shown, shown(case.in));
        const l = layout(case.in);
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

test "only the manual row ignores usos-xp.ini; profiles map to their index" {
    const names = [_][]const u8{"a.sif"};
    const l = layout(.{ .settings_file = true, .settings_active = true, .profiles_allowed = true, .profiles = 2, .files = 1 });
    try std.testing.expect(l.choice(0, &names).ignore_settings);
    try std.testing.expect(!l.choice(1, &names).ignore_settings);
    try std.testing.expectEqual(@as(?usize, 0), l.choice(2, &names).profile);
    try std.testing.expectEqual(@as(?usize, 1), l.choice(3, &names).profile);
    try std.testing.expectEqualStrings("a.sif", l.choice(4, &names).path.?);
    try std.testing.expectEqual(Row.add, l.rows[5]);
    try std.testing.expect(l.rows[2].editable() and l.rows[2].deletable());
    try std.testing.expect(l.rows[1].editable() and !l.rows[1].deletable());
    try std.testing.expect(!l.rows[4].editable());
}

test "profiles only where a rendered answer can be handed on" {
    const systems = @import("../catalog/systems.zig");
    const cases = [_]struct { id: []const u8, image: ImageKind, method: BootMethod, capable: bool }{
        .{ .id = "windows-xp", .image = .iso, .method = .automatic, .capable = true },
        .{ .id = "windows-10", .image = .iso, .method = .automatic, .capable = true },
        .{ .id = "windows-11", .image = .iso, .method = .automatic, .capable = true },
        .{ .id = "windows-7", .image = .iso, .method = .automatic, .capable = true },
        .{ .id = "windows-vista", .image = .iso, .method = .automatic, .capable = false },
        .{ .id = "windows-10", .image = .efi, .method = .automatic, .capable = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.id});
        const system = systems.findById(case.id) orelse return error.TestSystemMissing;
        try std.testing.expectEqual(case.capable, profileCapable(system, case.image, case.method, .uefi));
    }
}
