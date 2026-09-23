const std = @import("std");
const usos = @import("usos");
const file_read = @import("file_read.zig");

const max_icons: usize = 96;
const max_id_bytes: usize = 127;
const max_png_bytes: usize = 1024 * 1024;
const builtin_prefix = "\\UI\\Icons\\Systems\\";
const builtin_suffix = ".png";
const images_suffix = "\\Images";
const profile_icon_suffix = "\\icon.png";

const State = enum { empty, ready, missing };

const Entry = struct {
    state: State = .empty,
    id_bytes: [max_id_bytes]u8 = [_]u8{0} ** max_id_bytes,
    id_len: usize = 0,
    image: usos.gui.RgbaImage = .{},

    fn matches(self: *const Entry, id: []const u8) bool {
        return self.id_len == id.len and std.mem.eql(u8, self.id_bytes[0..self.id_len], id);
    }

    fn setId(self: *Entry, id: []const u8) bool {
        if (id.len > self.id_bytes.len) return false;
        @memcpy(self.id_bytes[0..id.len], id);
        self.id_len = id.len;
        return true;
    }
};

var entries: [max_icons]Entry = [_]Entry{.{}} ** max_icons;
var png_buffer: [max_png_bytes]u8 = undefined;
var scratch: usos.gui.png_rgba.Scratch = .{};

pub fn get(root: *std.os.uefi.protocol.File, system: *const usos.catalog.SystemEntry) ?*const usos.gui.RgbaImage {
    for (&entries) |*entry| {
        if (entry.state == .empty or !entry.matches(system.id)) continue;
        return if (entry.state == .ready) &entry.image else null;
    }

    for (&entries) |*entry| {
        if (entry.state != .empty) continue;
        if (!entry.setId(system.id)) {
            entry.state = .missing;
            return null;
        }

        var path_buffer: [260]u8 = undefined;
        if (buildProfileIconPath(system.image_directory, &path_buffer)) |profile_path| {
            if (decodePath(root, profile_path, &entry.image)) {
                entry.state = .ready;
                return &entry.image;
            }
        }

        // Built-in icons come pre-scaled from bios-ui.bin (one small file
        // read per boot); the 1254x1254 PNGs remain the fallback.
        if (builtinPack(root)) |pack| {
            if (pack.icon(system.id, &entry.image.pixels)) {
                entry.state = .ready;
                return &entry.image;
            }
        }

        const builtin_path = buildBuiltinPath(system.id, &path_buffer) orelse {
            entry.state = .missing;
            return null;
        };
        if (!decodePath(root, builtin_path, &entry.image)) {
            entry.state = .missing;
            return null;
        }

        entry.state = .ready;
        return &entry.image;
    }
    return null;
}

const PackState = enum { unread, ready, unavailable };
var pack_state: PackState = .unread;
var icon_pack: usos.gui.ui_pack.Pack = undefined;

/// EFI\USOS\bios-ui.bin, read and validated once (pool memory, kept).
fn builtinPack(root: *std.os.uefi.protocol.File) ?usos.gui.ui_pack.Pack {
    switch (pack_state) {
        .ready => return icon_pack,
        .unavailable => return null,
        .unread => {},
    }
    pack_state = .unavailable;
    const bs = std.os.uefi.system_table.boot_services orelse return null;
    const storage = bs.allocatePool(.loader_data, usos.gui.ui_pack.max_bytes) catch return null;
    const bytes = file_read.into(root, usos.gui.ui_pack.path, storage) orelse {
        bs.freePool(storage.ptr) catch {};
        return null;
    };
    icon_pack = usos.gui.ui_pack.parse(bytes) orelse {
        bs.freePool(storage.ptr) catch {};
        return null;
    };
    pack_state = .ready;
    return icon_pack;
}

fn decodePath(root: *std.os.uefi.protocol.File, icon_path: []const u8, image: *usos.gui.RgbaImage) bool {
    const png = file_read.into(root, icon_path, &png_buffer) orelse return false;
    return usos.gui.png_rgba.decodeIcon(png, image, &scratch);
}

fn buildProfileIconPath(image_directory: []const u8, buffer: *[260]u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, image_directory, images_suffix)) return null;
    const root_len = image_directory.len - images_suffix.len;
    const needed = root_len + profile_icon_suffix.len;
    if (needed > buffer.len) return null;
    @memcpy(buffer[0..root_len], image_directory[0..root_len]);
    @memcpy(buffer[root_len..needed], profile_icon_suffix);
    return buffer[0..needed];
}

fn buildBuiltinPath(id: []const u8, buffer: *[260]u8) ?[]const u8 {
    const needed = builtin_prefix.len + id.len + builtin_suffix.len;
    if (needed > buffer.len) return null;
    var offset: usize = 0;
    @memcpy(buffer[offset .. offset + builtin_prefix.len], builtin_prefix);
    offset += builtin_prefix.len;
    @memcpy(buffer[offset .. offset + id.len], id);
    offset += id.len;
    @memcpy(buffer[offset .. offset + builtin_suffix.len], builtin_suffix);
    offset += builtin_suffix.len;
    return buffer[0..offset];
}

test "icon cache owns its id bytes" {
    var entry = Entry{};
    var id = [_]u8{ 'M', 'e', 'm', 'T', 'e', 's', 't' };
    try std.testing.expect(entry.setId(&id));
    id[0] = 'X';
    try std.testing.expect(entry.matches("MemTest"));
    try std.testing.expect(!entry.matches(&id));
}

test "profile icon lives beside Images directory" {
    var buffer: [260]u8 = undefined;
    const path = buildProfileIconPath("\\Systems\\Windows\\Windows 11\\Images", &buffer).?;
    try std.testing.expectEqualStrings("\\Systems\\Windows\\Windows 11\\icon.png", path);
}

test "utility profile icon uses the same convention" {
    var buffer: [260]u8 = undefined;
    const path = buildProfileIconPath("\\Utilities\\MemTest86\\Images", &buffer).?;
    try std.testing.expectEqualStrings("\\Utilities\\MemTest86\\icon.png", path);
}

test "built in icon remains a fallback by system id" {
    var buffer: [260]u8 = undefined;
    const path = buildBuiltinPath("windows-11", &buffer).?;
    try std.testing.expectEqualStrings("\\UI\\Icons\\Systems\\windows-11.png", path);
}
