pub const Category = enum {
    windows,
    linux,
    beta,
    dos,
    utilities,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .windows => "Windows",
            .linux => "Linux",
            .beta => "Beta builds",
            .dos => "DOS",
            .utilities => "Utilities",
        };
    }
};

test "category labels stay user readable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Beta builds", Category.beta.label());
}
