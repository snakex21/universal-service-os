pub const Category = enum {
    windows,
    linux,
    beta,
    dos,
    /// Custom OS (docs/custom-os-2026-10-11.md): Haiku, FreeBSD, ReactOS,
    /// KolibriOS, bring-your-own image. UEFI menu only.
    other,
    utilities,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .windows => "Windows",
            .linux => "Linux",
            .beta => "Beta builds",
            .dos => "DOS",
            .other => "Other systems",
            .utilities => "Utilities",
        };
    }
};

test "category labels stay user readable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Beta builds", Category.beta.label());
}
