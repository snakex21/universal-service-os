const Category = @import("category.zig").Category;

pub const all = [_]Category{
    .windows,
    .linux,
    .beta,
    .dos,
    .utilities,
};

test "top-level categories stay intentionally small" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 5), all.len);
}
