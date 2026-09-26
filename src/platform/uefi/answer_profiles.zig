//! USOS answer profiles on the ESP (docs/answer-profiles.md): the UEFI
//! menu cannot write DATA, so profiles live in \EFI\USOS\profiles\<stem>.ini
//! (FAT). A product key is written only with remember_key; a key typed
//! without it stays in memory for this boot (the session copy) and is used
//! for starts until the menu restarts.
//!
//! At start the chosen profile is rendered just in time (src/flow/answer):
//! stage() writes \EFI\USOS\answer\usos-plan.ini and the rendered file for
//! the micro-Linux (XP staging, WORK), render() returns the XML for the
//! wimboot RAM disk. clearRendered() removes rendered files left behind
//! (they may carry a key or a password) before any start.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const directory_scan = @import("directory_scan.zig");
const file_read = @import("file_read.zig");
const settings_store = @import("settings_store.zig");
const serial = @import("serial.zig");

const answer = usos.flow.answer;
pub const Profile = answer.Profile;
const plan_file = answer.plan_file;

pub const directory = "\\EFI\\USOS\\profiles";
pub const max = usos.flow.answer_screen.max_profiles;

const Stem = answer.profile.Text(32);

var loaded: [max]Profile = undefined;
var stems: [max]Stem = undefined;
var count: usize = 0;
/// Keys typed this boot without remember_key, by file stem.
var session: [max]Profile = undefined;
var session_stems: [max]Stem = undefined;
var session_count: usize = 0;

pub fn len() usize {
    return count;
}

pub fn get(index: usize) *Profile {
    return &loaded[index];
}

pub fn stem(index: usize) []const u8 {
    return stems[index].slice();
}

fn stemOf(name: []const u8) Stem {
    var buffer: [32]u8 = undefined;
    var result = Stem{};
    result.set(answer.profile.fileStem(name, &buffer)) catch {};
    return result;
}

/// Index of a profile whose file stem equals that of `name`.
pub fn find(name: []const u8) ?usize {
    const wanted = stemOf(name);
    for (stems[0..count], 0..) |*s, i| {
        if (std.ascii.eqlIgnoreCase(s.slice(), wanted.slice())) return i;
    }
    return null;
}

/// Re-reads every profile file (invalid files are skipped and traced).
pub fn reload(root: *uefi.protocol.File) void {
    var names: [max]usos.catalog.FixedText = undefined;
    const found = directory_scan.listFilesWithExtension(root, directory, ".ini", &names);
    count = 0;
    var bytes: [answer.profile.max_file]u8 = undefined;
    var path: [96]u8 = undefined;
    for (names[0..found]) |*name| {
        const file_path = std.fmt.bufPrint(&path, "{s}\\{s}", .{ directory, name.slice() }) catch continue;
        const text = file_read.into(root, file_path, &bytes) orelse continue;
        var profile: Profile = undefined;
        switch (answer.profile.parse(text, &profile)) {
            .ok => {},
            .invalid => |issue| {
                var line: [160]u8 = undefined;
                serial.writeAscii(std.fmt.bufPrint(&line, "[PROFILE] {s} skipped: field={s} problem={s} line={d}\n", .{ name.slice(), if (issue.field) |f| @tagName(f) else "-", @tagName(issue.problem), issue.line }) catch "[PROFILE] skipped\n");
                continue;
            },
        }
        const file_stem = name.slice()[0 .. name.slice().len - 4];
        stems[count] = .{};
        stems[count].set(file_stem) catch continue;
        loaded[count] = profile;
        // Keys typed this boot (not remembered).
        if (!profile.remember_key) {
            for (session_stems[0..session_count], 0..) |*s, i| {
                if (std.ascii.eqlIgnoreCase(s.slice(), file_stem)) {
                    loaded[count].key = session[i].key;
                    loaded[count].system_keys = session[i].system_keys;
                    loaded[count].system_key_count = session[i].system_key_count;
                }
            }
        }
        count += 1;
        if (count == max) break;
    }
    // Stable order: by name.
    sortByName();
}

fn sortByName() void {
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0 and lessThan(j, j - 1)) : (j -= 1) {
            std.mem.swap(Profile, &loaded[j], &loaded[j - 1]);
            std.mem.swap(Stem, &stems[j], &stems[j - 1]);
        }
    }
}

fn lessThan(a: usize, b: usize) bool {
    return std.ascii.lessThanIgnoreCase(loaded[a].name.slice(), loaded[b].name.slice());
}

fn ensureDirectory(root: *uefi.protocol.File, path: []const u8) !void {
    var name: [96]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], path);
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    const dir = try root.open(z, .read_write_create, .{ .directory = true });
    dir.close() catch {};
}

fn deleteFile(root: *uefi.protocol.File, path: []const u8) void {
    var name: [128]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], path) catch return;
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    if (root.open(z, .read_write, .{})) |file| {
        _ = file.delete() catch {};
    } else |_| {}
}

/// Writes `profile` (replacing the file of `previous_stem` after a rename)
/// and keeps a session copy of keys that are not remembered.
pub fn save(root: *uefi.protocol.File, profile: *const Profile, previous_stem: ?[]const u8) !void {
    if (answer.profile.validate(profile)) |_| return error.InvalidProfile;
    try ensureDirectory(root, directory);
    var bytes: [answer.profile.max_file]u8 = undefined;
    const text = try answer.profile.write(profile, &bytes);
    const new_stem = stemOf(profile.name.slice());
    var path: [96]u8 = undefined;
    try settings_store.replaceFile(root, try std.fmt.bufPrint(&path, "{s}\\{s}.ini", .{ directory, new_stem.slice() }), text);
    if (previous_stem) |old| {
        if (!std.ascii.eqlIgnoreCase(old, new_stem.slice())) deleteFile(root, try std.fmt.bufPrint(&path, "{s}\\{s}.ini", .{ directory, old }));
    }
    rememberSession(profile, new_stem, previous_stem);
    serial.writeAscii("[PROFILE] saved ");
    serial.writeAscii(new_stem.slice());
    serial.writeAscii(if (profile.remember_key and profile.hasAnyKey()) " (key remembered)\n" else "\n");
    reload(root);
}

fn rememberSession(profile: *const Profile, new_stem: Stem, previous_stem: ?[]const u8) void {
    // Drop the old entries of this profile.
    var out: usize = 0;
    for (0..session_count) |i| {
        const s = session_stems[i].slice();
        const same = std.ascii.eqlIgnoreCase(s, new_stem.slice()) or (if (previous_stem) |old| std.ascii.eqlIgnoreCase(s, old) else false);
        if (same) continue;
        session[out] = session[i];
        session_stems[out] = session_stems[i];
        out += 1;
    }
    session_count = out;
    if (profile.remember_key or !profile.hasAnyKey() or session_count == max) return;
    session[session_count] = profile.*;
    session_stems[session_count] = new_stem;
    session_count += 1;
}

pub fn delete(root: *uefi.protocol.File, index: usize) void {
    var path: [96]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path, "{s}\\{s}.ini", .{ directory, stems[index].slice() }) catch return;
    deleteFile(root, file_path);
    serial.writeAscii("[PROFILE] deleted ");
    serial.writeAscii(stems[index].slice());
    serial.writeAscii("\n");
    reload(root);
}

// ------------------------------------------------------------ rendering

var rendered: [answer.autounattend.max_size]u8 = undefined;

/// The media's architecture for the XML components (x64 UEFI starts are
/// amd64; unknown media: amd64).
pub fn archOf(info: ?usos.image_probe.windows_media.Info) answer.Arch {
    const media = info orelse return .amd64;
    return switch (media.arch) {
        .x86 => .x86,
        .arm64 => .arm64,
        else => .amd64,
    };
}

/// The answer rendered in memory (valid until the next render).
pub fn render(profile: *const Profile, system_id: []const u8, arch: answer.Arch) !answer.Rendered {
    return (try answer.render(profile, system_id, arch, null, &rendered)) orelse error.NoGeneratedAnswer;
}

/// Removes rendered answers and the plan left on the ESP by an earlier
/// start (they may hold a key or a password).
pub fn clearRendered(root: *uefi.protocol.File) void {
    var path: [96]u8 = undefined;
    for ([_]plan_file.Format{ .nt5_settings, .autounattend_xml }) |format| {
        deleteFile(root, plan_file.filePathEsp(format, &path) catch continue);
    }
    deleteFile(root, plan_file.plan_path);
}

/// Renders `profile` for the system and writes usos-plan.ini with the
/// rendered file to \EFI\USOS\answer (the XP staging and the WORK
/// preparation read them). `os_profile` is the plan profile id.
pub fn stage(root: *uefi.protocol.File, profile: *const Profile, system_id: []const u8, arch: answer.Arch, os_profile: []const u8) !plan_file.Format {
    const result = try render(profile, system_id, arch);
    clearRendered(root);
    try ensureDirectory(root, "\\EFI\\USOS");
    try ensureDirectory(root, plan_file.directory);
    var path: [96]u8 = undefined;
    try settings_store.replaceFile(root, try plan_file.filePathEsp(result.format, &path), result.bytes);
    var plan_bytes: [512]u8 = undefined;
    const plan = try plan_file.write(.{
        .os_profile = os_profile,
        .system_id = system_id,
        .source = .profile,
        .name = profile.name.slice(),
        .format = result.format,
        .arch = if (result.format == .autounattend_xml) arch else null,
        .key = profile.keyFor(system_id).len > 0,
    }, &plan_bytes);
    try settings_store.replaceFile(root, plan_file.plan_path, plan);
    var line: [160]u8 = undefined;
    serial.writeAscii(std.fmt.bufPrint(&line, "[PROFILE] staged {s} for {s} format={s} bytes={d}\n", .{ profile.name.slice(), system_id, @tagName(result.format), result.bytes.len }) catch "[PROFILE] staged\n");
    return result.format;
}

/// usos-plan.ini for the wimboot RAM disk (same content as on the ESP).
pub fn planText(profile: *const Profile, system_id: []const u8, arch: answer.Arch, os_profile: []const u8, buffer: []u8) ![]const u8 {
    return plan_file.write(.{ .os_profile = os_profile, .system_id = system_id, .source = .profile, .name = profile.name.slice(), .format = .autounattend_xml, .arch = arch, .key = profile.keyFor(system_id).len > 0 }, buffer);
}
