const Category = @import("category.zig").Category;

/// "Other systems" (Custom OS) is a UEFI-menu category: its systems are
/// written to the target disk by the micro-Linux, which the BIOS Core does not
/// start, so the Core's home screen keeps its five cards (and its size).
pub const all = [_]Category{
    .windows,
    .linux,
    .beta,
    .dos,
} ++ (if (@import("builtin").os.tag == .freestanding) [_]Category{} else [_]Category{.other}) ++ [_]Category{
    .utilities,
};

test "top-level categories stay intentionally small" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 6), all.len);
}
