const std = @import("std");
const storage = @import("storage");
const console = @import("console.zig");
const graphics_menu = @import("graphics_menu.zig");
const vbe = @import("vbe_probe.zig");
const windows_wimboot = @import("windows_wimboot.zig");

const fat = storage.fat32;
const Reader = storage.random_reader.Reader;

const p_efi = std.unicode.utf8ToUtf16LeStringLiteral("EFI");
const p_usos = std.unicode.utf8ToUtf16LeStringLiteral("USOS");
const p_windows_bios = std.unicode.utf8ToUtf16LeStringLiteral("windows-bios");
const p_manifest = std.unicode.utf8ToUtf16LeStringLiteral("native-cache.ini");
const manifest_path = [_][]const u16{ p_efi, p_usos, p_windows_bios, p_manifest };

pub const Error = fat.Error || windows_wimboot.Error || error{
    NativeCacheMissing,
    NativeCacheTooLarge,
    NativeCacheInvalid,
    NativeCacheMismatch,
};

/// Transitional native gate: boot a cache that was prepared outside the BIOS
/// Core, but enter wimboot directly from the still firmware-initialized Core.
/// This deliberately avoids micro-Linux and kexec.  The cache manifest binds
/// the archive to the exact menu selection so a stale boot.cpio is fail-closed.
pub fn run(
    fs: fat.FileSystem,
    reader: Reader,
    bulk: Reader,
    drive: u8,
    graphics: ?vbe.Session,
    system_id: []const u8,
    image_name: []const u8,
) !noreturn {
    try validateManifest(fs, reader, system_id, image_name);
    console.line("[WINDOWS_NATIVE] CACHE IDENTITY PASS");
    if (graphics) |session| graphics_menu.preparationStart(&session);
    try windows_wimboot.prepare(fs, reader, bulk, drive, graphics);
    console.line("[WINDOWS_NATIVE] CORE -> WIMBOOT DIRECT");
    windows_wimboot.start();
}

fn validateManifest(fs: fat.FileSystem, reader: Reader, system_id: []const u8, image_name: []const u8) Error!void {
    const info = fat.fileInfo(fs, reader, &manifest_path) catch |err| switch (err) {
        error.NotFound => return error.NativeCacheMissing,
        else => return err,
    };
    if (info.size == 0 or info.size > 1024) return error.NativeCacheTooLarge;
    var storage_buf: [1024]u8 = undefined;
    const len: usize = @intCast(info.size);
    if (try fat.readFileRange(fs, reader, &manifest_path, 0, storage_buf[0..len]) != len) return error.NativeCacheInvalid;
    const text = storage_buf[0..len];
    var version_ok = false;
    var system_ok = false;
    var image_ok = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.eql(u8, line, "version=1")) {
            version_ok = true;
        } else if (std.mem.startsWith(u8, line, "system_id=")) {
            system_ok = std.mem.eql(u8, line[10..], system_id);
        } else if (std.mem.startsWith(u8, line, "image_name=")) {
            image_ok = std.mem.eql(u8, line[11..], image_name);
        }
    }
    if (!version_ok) return error.NativeCacheInvalid;
    if (!system_ok or !image_ok) return error.NativeCacheMismatch;
}

test "native cache manifest is exact-selection bound" {
    const text = "version=1\r\nsystem_id=windows-vista\r\nimage_name=vista.iso\r\n";
    var version_ok = false;
    var system_ok = false;
    var image_ok = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.eql(u8, line, "version=1")) version_ok = true;
        if (std.mem.startsWith(u8, line, "system_id=")) system_ok = std.mem.eql(u8, line[10..], "windows-vista");
        if (std.mem.startsWith(u8, line, "image_name=")) image_ok = std.mem.eql(u8, line[11..], "vista.iso");
    }
    try std.testing.expect(version_ok and system_ok and image_ok);
}
