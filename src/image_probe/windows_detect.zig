const optical_fs = @import("optical_fs.zig");
const DetectedSystem = @import("../catalog/detected_system.zig").DetectedSystem;

pub const Result = struct {
    system: DetectedSystem = .unknown,
    filesystem: ?optical_fs.Kind = null,
    install_image_size: ?u64 = null,
};

const modern_install_images = [_][]const u8{
    "sources/install.wim",
    "sources/install.esd",
    "sources/install.swm",
};

pub fn inspect(reader: anytype) !Result {
    if (try optical_fs.findPath(reader, "sources/boot.wim")) |boot_wim| {
        if (!boot_wim.is_directory) {
            for (modern_install_images) |path| {
                if (try optical_fs.findPath(reader, path)) |install_image| {
                    if (!install_image.is_directory) {
                        return .{
                            .system = .windows_modern,
                            .filesystem = install_image.filesystem,
                            .install_image_size = install_image.size,
                        };
                    }
                }
            }
        }
    }

    if (try optical_fs.findPath(reader, "i386/txtsetup.sif")) |txtsetup| {
        if (!txtsetup.is_directory) {
            if (try optical_fs.findPath(reader, "i386/setupldr.bin")) |setupldr| {
                if (!setupldr.is_directory) {
                    return .{
                        .system = .windows_legacy,
                        .filesystem = setupldr.filesystem,
                    };
                }
            }
        }
    }

    return .{};
}

test "modern Windows detection accepts WIM ESD and split SWM payloads" {
    const std = @import("std");
    try std.testing.expectEqualStrings("sources/install.wim", modern_install_images[0]);
    try std.testing.expectEqualStrings("sources/install.esd", modern_install_images[1]);
    try std.testing.expectEqualStrings("sources/install.swm", modern_install_images[2]);
}
