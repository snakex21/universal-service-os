const BootMethod = @import("boot_method.zig").BootMethod;
const ImageKind = @import("image_kind.zig").ImageKind;
const SystemEntry = @import("system_entry.zig").SystemEntry;

pub fn methodSupportsImage(method: BootMethod, image: ImageKind) bool {
    return switch (method) {
        .automatic => true,
        .direct_iso => image == .iso,
        .wimboot => image == .iso or image == .wim,
        .vhdboot => image == .vhd or image == .vhdx,
        .direct_efi => image == .efi,
        .chainload => image == .iso or image == .img or image == .efi,
        .memdisk => image == .iso or image == .img,
        .disk_image, .floppy_image => image == .img,
    };
}

pub fn systemAllowsMethod(system: *const SystemEntry, method: BootMethod) bool {
    for (system.boot_methods) |allowed| {
        if (allowed == method) return true;
    }
    return false;
}

pub fn canUse(system: *const SystemEntry, image: ImageKind, method: BootMethod) bool {
    return systemAllowsMethod(system, method) and methodSupportsImage(method, image);
}

test "ISO can use WIMBoot but WIM cannot use direct ISO" {
    const std = @import("std");
    try std.testing.expect(methodSupportsImage(.wimboot, .iso));
    try std.testing.expect(methodSupportsImage(.wimboot, .wim));
    try std.testing.expect(!methodSupportsImage(.direct_iso, .wim));
}
