const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;

pub const unavailable_reason = "No implemented boot backend supports this selection.";

pub fn supportsSystem(system_id: []const u8) bool {
    // Direct EFI and generic ISO chainload are system-agnostic. A concrete
    // image/method pair is still checked by resolve() before it can run.
    return system_id.len > 0;
}

pub fn resolve(system_id: []const u8, image: ImageKind, method: BootMethod) ?BootMethod {
    if (!supportsSystem(system_id)) return null;

    return switch (method) {
        .automatic => switch (image) {
            .iso => if (std.mem.eql(u8, system_id, "windows-11")) .direct_iso else .chainload,
            .wim => .wimboot,
            .vhd, .vhdx => .vhdboot,
            .efi => .direct_efi,
            else => null,
        },
        .direct_iso => if (std.mem.eql(u8, system_id, "windows-11") and image == .iso) .direct_iso else null,
        .wimboot => if (image == .wim) .wimboot else null,
        .vhdboot => if (image == .vhd or image == .vhdx) .vhdboot else null,
        .direct_efi => if (image == .efi) .direct_efi else null,
        .chainload => switch (image) {
            .iso, .efi => .chainload,
            else => null,
        },
        else => null,
    };
}

pub fn supports(system_id: []const u8, image: ImageKind, method: BootMethod) bool {
    return resolve(system_id, image, method) != null;
}

pub fn validate(system_id: []const u8, image: ImageKind, method: BootMethod) !void {
    if (!supportsSystem(system_id)) return error.UnsupportedSystem;
    if (resolve(system_id, image, method) != null) return;

    const image_compatible = switch (method) {
        .automatic => image == .iso or image == .wim or image == .vhd or image == .vhdx or image == .efi,
        .direct_iso => image == .iso,
        .wimboot => image == .iso or image == .wim,
        .vhdboot => image == .vhd or image == .vhdx,
        .direct_efi => image == .efi,
        .chainload => image == .iso or image == .img or image == .efi,
        .memdisk => image == .iso or image == .img,
        .disk_image, .floppy_image => image == .img,
    };
    if (!image_compatible) return error.UnsupportedImage;
    return error.UnsupportedMethod;
}

test "Windows 11 ISO keeps verified ISO preparation as automatic path" {
    try std.testing.expectEqual(BootMethod.direct_iso, resolve("windows-11", .iso, .automatic).?);
    try std.testing.expectEqual(BootMethod.direct_iso, resolve("windows-11", .iso, .direct_iso).?);
}

test "generic ISO images can use real chainload preparation" {
    try std.testing.expectEqual(BootMethod.chainload, resolve("ubuntu", .iso, .automatic).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("ubuntu", .iso, .chainload).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("windows-10", .iso, .chainload).?);
}

test "EFI images can start directly or through explicit chainload" {
    try std.testing.expectEqual(BootMethod.direct_efi, resolve("memory-tests", .efi, .automatic).?);
    try std.testing.expectEqual(BootMethod.direct_efi, resolve("memory-tests", .efi, .direct_efi).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("memory-tests", .efi, .chainload).?);
}

test "standalone WIM and VHD images resolve to their native Windows boot backends" {
    try std.testing.expectEqual(BootMethod.wimboot, resolve("windows-11", .wim, .automatic).?);
    try std.testing.expectEqual(BootMethod.wimboot, resolve("windows-11", .wim, .wimboot).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhd, .automatic).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhd, .vhdboot).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhdx, .vhdboot).?);
}
