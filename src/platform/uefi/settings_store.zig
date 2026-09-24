//! The one in-memory copy of \EFI\USOS\usos-settings.ini for the whole
//! menu. Pages that change a setting (Secure Boot reminder, Tools ->
//! Drivers toggles, the driver hang guard) all go through set(), so no
//! page can write back a stale copy and drop another page's key. Unknown
//! keys and lines are kept (mok_list.withSetting); the installer merges
//! only [ui] language= (installer/internal/i18n MergeSettingsINI).
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const file_read = @import("file_read.zig");

pub const path = "\\EFI\\USOS\\usos-settings.ini";

var buffer: [4096]u8 = undefined;
var len: usize = 0;
var out: [4096]u8 = undefined;
var root_dir: ?*uefi.protocol.File = null;

/// Reads usos-settings.ini (empty when missing or larger than 4 KiB).
pub fn load(root: *uefi.protocol.File) []const u8 {
    root_dir = root;
    len = if (file_read.into(root, path, &buffer)) |text| text.len else 0;
    return current();
}

pub fn current() []const u8 {
    return buffer[0..len];
}

/// Sets `key=value` (replacing an existing key, case-insensitive) and
/// rewrites the file. The in-memory copy changes only when the write
/// succeeded.
pub fn set(key: []const u8, value: []const u8) !void {
    const root = root_dir orelse return error.NoSettingsVolume;
    const content = usos.flow.mok_list.withSetting(current(), key, value, &out) orelse return error.SettingsTooLarge;
    try replaceFile(root, path, content);
    @memcpy(buffer[0..content.len], content);
    len = content.len;
}

/// Replaces a file on the ESP (UEFI has no truncate: delete, create, write,
/// flush).
pub fn replaceFile(root: *uefi.protocol.File, file_path: []const u8, content: []const u8) !void {
    var name: [128]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], file_path);
    name[units] = 0;
    const z: [*:0]const u16 = @ptrCast(&name);
    if (root.open(z, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = try root.open(z, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < content.len) {
        const n = try file.write(content[written..]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
}
