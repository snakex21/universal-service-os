//! Windows 95/98/Me from the UEFI menu (profile w9x-uefi-csmwrap,
//! experimental; docs/win9x-modern-2026-09-30.md section 4c): the menu writes
//! EFI\USOS\win9x\request.ini (system, folder, ISO on DATA, answer source,
//! partition size), stages a profile's MSBATCH.INF (answer_profiles.stageWin9x)
//! and starts the base micro-Linux with usos.legacy_action=w9x-csmwrap.
//! Pipeline step 620 (tools/w9x_csmwrap_prepare.sh) shows the disk picker and
//! the erase confirmation and writes the FAT32 Setup disk with its one-time
//! DOS start and a CSMWrap ESP; after the restart Setup runs from that disk.
const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const directory = "\\EFI\\USOS\\win9x";

/// A locale id and its keyboard layout id (request.ini locale= / keyboard=).
pub const UiInput = struct { lcid: u16, klid: u32 };

pub const Answer = union(enum) {
    none,
    profile,
    /// A file name in the system's DATA Unattended folder.
    file: []const u8,
};

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| if (c < 0x20 or c == '/' or c == '\\' or c == '=' or c == '\r' or c == '\n') return false;
    return true;
}

/// request.ini of tools/w9x_csmwrap_prepare.sh (CRLF, DATA-relative paths).
/// `folder`: the system's name (heading, DATA Unattended/Boot folders);
/// `images`: its DATA image folder ("\Systems\...\Images").
/// `time_zone`: the 9x time zone key for the USOS default answer
/// (answer=none); tools/w9x_csmwrap_prepare.sh puts it into its [Setup].
/// `ui_input`: the menu language's locale and keyboard layout (every
/// answer): NT 3.x takes them where the answer names none (English-only
/// CDs; docs/nt3-polish-2026-10-14.md).
pub fn formatRequest(buffer: []u8, system_id: []const u8, folder: []const u8, images: []const u8, name: []const u8, answer: Answer, size_gib: u8, time_zone: ?[]const u8, ui_input: ?UiInput) ![]const u8 {
    if (!safeName(folder) or !safeName(name) or !safeName(system_id)) return error.InvalidImageName;
    var path_buffer: [160]u8 = undefined;
    if (images.len < 2 or images.len > path_buffer.len or images[0] != '\\' or std.mem.indexOf(u8, images, "..") != null) return error.InvalidImageName;
    const path = path_buffer[0 .. images.len - 1];
    for (images[1..], 0..) |c, i| path[i] = if (c == '\\') '/' else c;
    var answer_text: [300]u8 = undefined;
    const answer_value = switch (answer) {
        .none => "none",
        .profile => "profile",
        .file => |file| blk: {
            if (!safeName(file)) return error.InvalidImageName;
            break :blk try std.fmt.bufPrint(&answer_text, "file:{s}", .{file});
        },
    };
    var text = try std.fmt.bufPrint(buffer, "version=1\r\nprofile=w9x-uefi-csmwrap\r\nsystem={s}\r\nfolder={s}\r\niso={s}/{s}\r\nanswer={s}\r\nsize={d}\r\n", .{ system_id, folder, path, name, answer_value, size_gib });
    if (ui_input) |input| {
        const tail = try std.fmt.bufPrint(buffer[text.len..], "locale={X:0>8}\r\nkeyboard={X:0>8}\r\n", .{ input.lcid, input.klid });
        text = buffer[0 .. text.len + tail.len];
    }
    // Only the USOS default answer gets it; profiles and files carry their own.
    const zone = time_zone orelse return text;
    if (answer != .none) return text;
    if (!safeName(zone)) return error.InvalidImageName;
    const tail = try std.fmt.bufPrint(buffer[text.len..], "timezone={s}\r\n", .{zone});
    return buffer[0 .. text.len + tail.len];
}

fn ensureDirectory(root: *uefi.protocol.File, path: [*:0]const u16) !void {
    const dir = try root.open(path, .read_write_create, .{ .directory = true });
    dir.close() catch {};
}

pub fn writeRequest(root: *uefi.protocol.File, system_id: []const u8, folder: []const u8, images: []const u8, name: []const u8, answer: Answer, time_zone: ?[]const u8, ui_input: ?UiInput) !void {
    var buffer: [1024]u8 = undefined;
    const text = try formatRequest(&buffer, system_id, folder, images, name, answer, 32, time_zone, ui_input);
    try ensureDirectory(root, wide("\\EFI\\USOS"));
    try ensureDirectory(root, wide(directory));
    try @import("settings_store.zig").replaceFile(root, directory ++ "\\request.ini", text);
    @import("serial.zig").writeAscii("[W9X_CSMWRAP] request written\n");
}

test "Windows 9x request names the DATA ISO, the answer source and the size" {
    var buffer: [1024]u8 = undefined;
    const text = try formatRequest(&buffer, "windows-98-se", "Windows 98 SE", "\\Systems\\Windows\\Windows 98 SE\\Images", "Windows_98_SE_PL_OEM.iso", .none, 32, null, null);
    try std.testing.expectEqualStrings("version=1\r\nprofile=w9x-uefi-csmwrap\r\nsystem=windows-98-se\r\nfolder=Windows 98 SE\r\niso=Systems/Windows/Windows 98 SE/Images/Windows_98_SE_PL_OEM.iso\r\nanswer=none\r\nsize=32\r\n", text);
    try std.testing.expect(std.mem.endsWith(u8, try formatRequest(&buffer, "windows-me", "Windows Me", "\\Systems\\Windows\\Windows Me\\Images", "me.iso", .profile, 8, null, null), "answer=profile\r\nsize=8\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, try formatRequest(&buffer, "windows-95", "Windows 95", "\\Systems\\Windows\\Windows 95\\Images", "95.iso", .{ .file = "home.inf" }, 32, null, null), "answer=file:home.inf\r\n") != null);
    try std.testing.expectError(error.InvalidImageName, formatRequest(&buffer, "windows-95", "Windows 95", "\\Systems\\Windows\\Windows 95\\Images", "../x.iso", .none, 32, null, null));
    try std.testing.expectError(error.InvalidImageName, formatRequest(&buffer, "windows-95", "Windows 95", "\\Systems\\Windows\\Windows 95\\Images", "a/b.iso", .none, 32, null, null));
    try std.testing.expect(std.mem.indexOf(u8, try formatRequest(&buffer, "ms-dos", "MS-DOS", "\\Systems\\DOS\\MS-DOS\\Images", "MS-DOS 6.22.iso", .none, 32, null, null), "iso=Systems/DOS/MS-DOS/Images/MS-DOS 6.22.iso\r\n") != null);
    try std.testing.expectError(error.InvalidImageName, formatRequest(&buffer, "windows-95", "Windows 95", "\\Systems\\Windows\\Windows 95\\Images", "x.iso", .{ .file = "a\r\nsize=2" }, 32, null, null));
    // The USOS default answer gets the menu language's time zone; profiles and files carry their own.
    try std.testing.expect(std.mem.endsWith(u8, try formatRequest(&buffer, "windows-98-se", "Windows 98 SE", "\\Systems\\Windows\\Windows 98 SE\\Images", "a.iso", .none, 32, "Central European", null), "size=32\r\ntimezone=Central European\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, try formatRequest(&buffer, "windows-98-se", "Windows 98 SE", "\\Systems\\Windows\\Windows 98 SE\\Images", "a.iso", .profile, 32, "Central European", null), "answer=profile\r\nsize=32\r\n"));
    // The menu language's locale and keyboard go with every answer (NT 3.x uses them).
    const pl: UiInput = .{ .lcid = 0x0415, .klid = 0x00000415 };
    try std.testing.expect(std.mem.endsWith(u8, try formatRequest(&buffer, "windows-nt-3-51", "Windows NT 3.51", "\\Systems\\Windows\\Windows NT 3.51\\Images", "a.iso", .none, 32, "Central European", pl), "size=32\r\nlocale=00000415\r\nkeyboard=00000415\r\ntimezone=Central European\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, try formatRequest(&buffer, "windows-nt-3-51", "Windows NT 3.51", "\\Systems\\Windows\\Windows NT 3.51\\Images", "a.iso", .profile, 32, "Central European", pl), "answer=profile\r\nsize=32\r\nlocale=00000415\r\nkeyboard=00000415\r\n"));
}
