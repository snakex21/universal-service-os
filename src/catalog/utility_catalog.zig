const media_discovery = @import("media_discovery.zig");
const FixedText = @import("../core/fixed_text.zig").FixedText;

pub const max_items: usize = 32;
pub const max_path_bytes: usize = 260;
const utilities_root = "\\Utilities";
const path_prefix = "\\Utilities\\";
const images_suffix = "\\Images";

/// DATA\Utilities\UEFI Shell holds the user's files for the built-in UEFI
/// Shell (Tools\: flashers, testers, ROMs), not a bootable image, so it is
/// never listed as a utility: the UEFI menu shows its own "UEFI Shell" row
/// and the Legacy BIOS menu, where the Shell cannot run, shows nothing.
pub const uefi_shell_folder = "UEFI Shell";

pub fn isReservedFolder(name: []const u8) bool {
    return @import("std").ascii.eqlIgnoreCase(name, uefi_shell_folder);
}

pub const Entry = struct {
    builtin: enum { none, hardware, freedos } = .none,
    name: FixedText = .{},
    image_path: [max_path_bytes]u8 = [_]u8{0} ** max_path_bytes,
    image_path_len: u16 = 0,

    pub fn imageDirectory(self: *const Entry) []const u8 {
        return self.image_path[0..self.image_path_len];
    }
};

pub const List = struct {
    items: [max_items + 2]Entry = [_]Entry{.{}} ** (max_items + 2),
    len: usize = 0,

    pub fn appendHardware(self: *List) void {
        if (self.len >= self.items.len) return;
        var item = Entry{ .builtin = .hardware };
        const name = "Hardware & SMART";
        @memcpy(item.name.bytes[0..name.len], name);
        item.name.len = name.len;
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn appendFreeDos(self: *List) void {
        for (self.items[0..self.len]) |*item| {
            if (@import("std").ascii.eqlIgnoreCase(item.name.slice(), "FreeDOS")) {
                item.builtin = .freedos;
                return;
            }
        }
        if (self.len >= self.items.len) return;
        var item = Entry{ .builtin = .freedos };
        const name = "FreeDOS";
        @memcpy(item.name.bytes[0..name.len], name);
        item.name.len = name.len;
        self.items[self.len] = item;
        self.len += 1;
    }
};

pub fn discover(discovery: *media_discovery.Discovery, output: *List) void {
    output.* = .{};
    var names: [max_items]FixedText = undefined;
    const count = discovery.listDirectories(utilities_root, &names);
    var index: usize = 0;
    while (index < count and output.len < output.items.len) : (index += 1) {
        const name = names[index].slice();
        if (isReservedFolder(name)) continue;
        const needed = path_prefix.len + name.len + images_suffix.len;
        if (needed > max_path_bytes) continue;
        var item = Entry{ .name = names[index] };
        var offset: usize = 0;
        @memcpy(item.image_path[offset .. offset + path_prefix.len], path_prefix);
        offset += path_prefix.len;
        @memcpy(item.image_path[offset .. offset + name.len], name);
        offset += name.len;
        @memcpy(item.image_path[offset .. offset + images_suffix.len], images_suffix);
        offset += images_suffix.len;
        item.image_path_len = @intCast(offset);
        output.items[output.len] = item;
        output.len += 1;
    }
}

test "utility image path follows the production ESP convention" {
    const std = @import("std");
    var item = Entry{};
    const name = "MemTest86";
    @memcpy(item.name.bytes[0..name.len], name);
    item.name.len = name.len;
    var fake_path: [max_path_bytes]u8 = undefined;
    const needed = path_prefix.len + name.len + images_suffix.len;
    @memcpy(fake_path[0..path_prefix.len], path_prefix);
    @memcpy(fake_path[path_prefix.len .. path_prefix.len + name.len], name);
    @memcpy(fake_path[path_prefix.len + name.len .. needed], images_suffix);
    try std.testing.expectEqualStrings("\\Utilities\\MemTest86\\Images", fake_path[0..needed]);
}

test "built-in hardware entry is independent of media and keeps utility order" {
    const std = @import("std");
    var list = List{};
    list.items[0].name.len = 1; list.items[0].name.bytes[0] = 'M'; list.len = 1;
    list.appendHardware();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(.hardware, list.items[1].builtin);
    try std.testing.expectEqualStrings("M", list.items[0].name.slice());
    try std.testing.expectEqual(.none, list.items[0].builtin);
    try std.testing.expectEqualStrings("", list.items[1].imageDirectory());
}

test "the UEFI Shell tools folder is not a utility entry" {
    const std = @import("std");
    try std.testing.expect(isReservedFolder("UEFI Shell"));
    try std.testing.expect(isReservedFolder("uefi shell"));
    try std.testing.expect(!isReservedFolder("UEFI Shell 2"));
    try std.testing.expect(!isReservedFolder("MemTest86"));
}

test "FreeDOS program folder becomes one built-in entry" {
    const std = @import("std");
    var list = List{};
    list.appendFreeDos();
    list.appendHardware();
    list.appendFreeDos();
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(.freedos, list.items[0].builtin);
    try std.testing.expectEqual(.hardware, list.items[1].builtin);
}
