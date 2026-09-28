//! Rows of the Legacy BIOS image list (graphics_menu.zig). Kept apart so the
//! host tests can check them: a row title must point into the caller's
//! ImageList, never into a copy of the item on this function's stack. That
//! copy (`const image = items[index]`) made every row show the last image's
//! name, garbled after 16 characters once the frame was reused (Socket 939
//! report, 2026-09-28; also visible in QEMU with two ISOs in one folder).
const catalog = @import("catalog");
const Row = @import("graphics").ui.Row;

pub fn fill(rows: []Row, images_list: *const catalog.ImageList) usize {
    const count = @min(images_list.len, rows.len);
    for (images_list.items[0..count], rows[0..count]) |*image, *row| {
        row.* = .{ .title = image.name.slice(), .icon = .{ .label = kindLabel(image.kind) } };
    }
    return count;
}

pub fn kindLabel(kind: catalog.ImageKind) []const u8 {
    return switch (kind) {
        .iso => "ISO",
        .wim => "WIM",
        .img => "IMG",
        .vhd => "VHD",
        .vhdx => "VHDX",
        .efi => "EFI",
    };
}

fn setName(item: *catalog.ImageItem, name: []const u8) void {
    item.* = .{ .name = .{}, .kind = .iso };
    @memcpy(item.name.bytes[0..name.len], name);
    item.name.len = name.len;
}

/// Overwrites a large stack area, like showList does after the rows are
/// built, so a title left pointing at a dead frame would read garbage.
noinline fn clobberStack() void {
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    std.mem.doNotOptimizeAway(&junk);
}

const std = @import("std");

test "BIOS image rows keep every long ISO name (titles point into the list)" {
    const names = [_][]const u8{
        "ubuntu-24.04.5-live-server-amd64.iso",
        "ubuntu-24.04.5.1-desktop-amd64.iso",
        "linuxmint-22.3-xfce-64bit.iso",
        "pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso",
    };
    var list = catalog.ImageList{};
    for (names, 0..) |name, index| setName(&list.items[index], name);
    list.len = names.len;

    var rows: [64]Row = undefined;
    const count = fill(&rows, &list);
    clobberStack();
    try std.testing.expectEqual(names.len, count);
    for (names, 0..) |name, index| {
        try std.testing.expectEqual(@as([*]const u8, &list.items[index].name.bytes), rows[index].title.ptr);
        try std.testing.expectEqualStrings(name, rows[index].title);
        try std.testing.expectEqualStrings("ISO", rows[index].icon.label);
    }
}

test "BIOS image rows stop at the row capacity" {
    var list = catalog.ImageList{};
    for (0..3) |index| setName(&list.items[index], "a.iso");
    list.len = 3;
    var rows: [2]Row = undefined;
    try std.testing.expectEqual(@as(usize, 2), fill(&rows, &list));
}
