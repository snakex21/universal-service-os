const optical_fs = @import("optical_fs.zig");
const DetectedSystem = @import("../catalog/detected_system.zig").DetectedSystem;

pub const Result = struct {
    system: DetectedSystem = .unknown,
    filesystem: ?optical_fs.Kind = null,
    install_image_size: ?u64 = null,
};

/// Install images Windows Setup (8 and later) accepts, in preference order;
/// install.swm is the first part of a split image. Shared by the ISO probe and
/// the UEFI WORK handoff check (src/platform/uefi/work_volume.zig).
pub const modern_install_images = [_][]const u8{
    "sources/install.wim",
    "sources/install.esd",
    "sources/install.swm",
};

/// First entry of `modern_install_images` for which `exists(context, path)`
/// is true (host-testable; the caller does the case-insensitive lookup).
pub fn firstInstallImage(context: anytype, comptime exists: fn (@TypeOf(context), []const u8) bool) ?[]const u8 {
    for (modern_install_images) |path| {
        if (exists(context, path)) return path;
    }
    return null;
}

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

test "WORK handoff accepts install.wim, install.esd and install.swm" {
    const std = @import("std");
    const Fake = struct {
        present: []const []const u8,
        fn exists(self: *const @This(), path: []const u8) bool {
            for (self.present) |item| if (std.mem.eql(u8, item, path)) return true;
            return false;
        }
    };
    const esd_only = Fake{ .present = &.{ "sources/setup.exe", "sources/install.esd" } };
    try std.testing.expectEqualStrings("sources/install.esd", firstInstallImage(&esd_only, Fake.exists).?);
    const swm = Fake{ .present = &.{ "sources/install.swm", "sources/install2.swm" } };
    try std.testing.expectEqualStrings("sources/install.swm", firstInstallImage(&swm, Fake.exists).?);
    const both = Fake{ .present = &.{ "sources/install.esd", "sources/install.wim" } };
    try std.testing.expectEqualStrings("sources/install.wim", firstInstallImage(&both, Fake.exists).?);
    const none = Fake{ .present = &.{ "sources/boot.wim", "sources/install.xml" } };
    try std.testing.expect(firstInstallImage(&none, Fake.exists) == null);
}
