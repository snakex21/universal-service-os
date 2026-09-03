const std = @import("std");

pub const ImageKind = enum {
    iso,
    wim,
    img,
    vhd,
    vhdx,
    efi,

    pub fn fromExtension(extension: []const u8) ?ImageKind {
        if (std.ascii.eqlIgnoreCase(extension, ".iso")) return .iso;
        if (std.ascii.eqlIgnoreCase(extension, ".wim")) return .wim;
        if (std.ascii.eqlIgnoreCase(extension, ".img")) return .img;
        if (std.ascii.eqlIgnoreCase(extension, ".vhd")) return .vhd;
        if (std.ascii.eqlIgnoreCase(extension, ".vhdx")) return .vhdx;
        if (std.ascii.eqlIgnoreCase(extension, ".efi")) return .efi;
        return null;
    }

    pub fn fromFilename(filename: []const u8) ?ImageKind {
        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return null;
        return fromExtension(filename[dot..]);
    }
};

test "image kind recognizes supported extensions case insensitively" {
    try std.testing.expectEqual(ImageKind.iso, ImageKind.fromExtension(".ISO").?);
    try std.testing.expectEqual(ImageKind.wim, ImageKind.fromExtension(".wim").?);
    try std.testing.expectEqual(ImageKind.img, ImageKind.fromExtension(".IMG").?);
    try std.testing.expectEqual(ImageKind.vhdx, ImageKind.fromExtension(".VHDX").?);
    try std.testing.expectEqual(ImageKind.efi, ImageKind.fromExtension(".efi").?);
    try std.testing.expectEqual(ImageKind.vhdx, ImageKind.fromFilename("disk.backup.VHDX").?);
    try std.testing.expect(ImageKind.fromExtension(".zip") == null);
}
