//! UI scale chosen from the framebuffer size. Layout is authored for about
//! 1280x720 logical pixels; 1080p uses the natively rasterized 1.5x font
//! tier, 1440p draws the 1x tier doubled and 4K the 1.5x tier doubled.
pub const legacy_bios = @import("builtin").os.tag == .freestanding and @import("builtin").cpu.arch == .x86;

pub const Scale = struct {
    /// Font tier: 0 = 1x glyphs, 1 = 1.5x glyphs.
    tier: u1 = 0,
    /// Integer multiplier applied on top of the tier (1..3).
    mult: u8 = 1,

    pub const one = Scale{};

    pub fn forScreen(width: u32, height: u32, has_tier1: bool) Scale {
        // The Legacy BIOS Core ships only the 1x glyph tier and its VBE modes
        // stay at or below 1280x1024.
        if (legacy_bios) return .{};
        var result: Scale = if (height >= 2000 and width >= 3000)
            .{ .tier = 1, .mult = 2 }
        else if (height >= 1400 and width >= 2200)
            .{ .tier = 0, .mult = 2 }
        else if (height >= 1000 and width >= 1600)
            .{ .tier = 1, .mult = 1 }
        else
            .{};
        if (!has_tier1 and result.tier == 1) result.tier = 0;
        return result;
    }

    /// Scale factor times two (2 = 1x, 3 = 1.5x, 4 = 2x, 6 = 3x).
    pub fn twice(self: Scale) u32 {
        return (@as(u32, self.tier) + 2) * self.mult;
    }

    /// Converts a length in logical (1x) pixels to device pixels.
    pub fn px(self: Scale, value: u32) u32 {
        return (value * self.twice() + 1) / 2;
    }

    /// Like px but never returns less than one device pixel for value > 0.
    pub fn line(self: Scale, value: u32) u32 {
        if (value == 0) return 0;
        return @max(@as(u32, 1), (value * self.twice()) / 2);
    }
};

test "scale follows common framebuffer sizes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 2), Scale.forScreen(1024, 768, true).twice());
    try std.testing.expectEqual(@as(u32, 2), Scale.forScreen(1280, 1024, true).twice());
    try std.testing.expectEqual(@as(u32, 3), Scale.forScreen(1920, 1080, true).twice());
    try std.testing.expectEqual(@as(u32, 4), Scale.forScreen(2560, 1440, true).twice());
    try std.testing.expectEqual(@as(u32, 6), Scale.forScreen(3840, 2160, true).twice());
    try std.testing.expectEqual(@as(u32, 4), Scale.forScreen(3840, 2160, false).twice());
    try std.testing.expectEqual(@as(u32, 15), Scale.forScreen(1920, 1080, true).px(10));
}
