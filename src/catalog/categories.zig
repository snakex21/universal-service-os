const std = @import("std");
const Category = @import("category.zig").Category;
const systems = @import("systems.zig");

/// "Other systems" (Custom OS) and macOS are UEFI-menu categories: their
/// systems start from the UEFI menu (micro-Linux image-to-disk, OpenCore),
/// which the BIOS Core does not run, so the Core's home screen keeps its five
/// cards (and its size). On UEFI the home shows 7 categories + Power = 8
/// cards, an even 2-column grid.
pub const all = [_]Category{
    .windows,
    .linux,
    .beta,
    .dos,
} ++ (if (@import("builtin").os.tag == .freestanding) [_]Category{} else [_]Category{ .macos, .other }) ++ [_]Category{
    .utilities,
};

/// Built-in icon id (media/UI/Icons/Systems/<id>.png, packed into
/// EFI/USOS/bios-ui.bin) drawn on the macOS tile; the vector `.disc` icon is
/// the fallback when the pack lacks it. Swap that one PNG to change the tile.
pub const macos_icon_id = "macos";

/// The macOS add-on (DLC, docs/ROADMAP.md L10) is installed when the build
/// carries macOS catalog entries: the add-on registers its systems (e.g.
/// macos-opencore) with category .macos. Without them the tile is shown
/// disabled with "Requires the macOS add-on".
pub fn macosAddonInstalled() bool {
    return systems.countInCategory(.macos) > 0;
}

/// False for a category tile that is shown but cannot be opened.
pub fn available(category: Category) bool {
    return switch (category) {
        .macos => macosAddonInstalled(),
        else => true,
    };
}

test "top-level categories stay intentionally small" {
    // Host/UEFI: 7 categories + Power = 8 home cards (4 rows of 2).
    try std.testing.expectEqual(@as(usize, 7), all.len);
    try std.testing.expectEqual(@as(usize, 0), (all.len + 1) % 2);
}

test "macOS has its own tile between DOS and Other systems" {
    const index = std.mem.indexOfScalar(Category, &all, .macos).?;
    try std.testing.expectEqual(Category.dos, all[index - 1]);
    try std.testing.expectEqual(Category.other, all[index + 1]);
    try std.testing.expectEqualStrings("macOS", Category.macos.label());
}

test "macOS tile is disabled until the add-on registers entries" {
    // The main build has no macOS catalog entries (the add-on is separate).
    try std.testing.expect(!macosAddonInstalled());
    try std.testing.expect(!available(.macos));
    try std.testing.expect(available(.windows) and available(.other) and available(.utilities));
    var index: usize = 0;
    while (systems.byCategoryIndex(.other, index)) |entry| : (index += 1) {
        try std.testing.expect(!std.mem.startsWith(u8, entry.id, "macos"));
    }
}
