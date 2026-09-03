const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;

pub const unavailable_reason = "Backend currently supports Windows 11 + ISO only.";

pub fn supportsSystem(system_id: []const u8) bool {
    return std.mem.eql(u8, system_id, "windows-11");
}

pub fn supports(system_id: []const u8, image: ImageKind, method: BootMethod) bool {
    return supportsSystem(system_id) and image == .iso and method == .direct_iso;
}

pub fn validate(system_id: []const u8, image: ImageKind, method: BootMethod) !void {
    if (!supportsSystem(system_id)) return error.UnsupportedSystem;
    if (image != .iso) return error.UnsupportedImage;
    if (method != .direct_iso) return error.UnsupportedMethod;
}

test "preparation backend accepts only Windows 11 ISO through the ISO method" {
    try std.testing.expect(supports("windows-11", .iso, .direct_iso));
    try std.testing.expect(!supports("windows-10", .iso, .direct_iso));
    try std.testing.expect(!supports("windows-11", .wim, .direct_iso));
    try std.testing.expect(!supports("windows-11", .iso, .vhdboot));
}

test "preparation validation rejects unsupported system image and method explicitly" {
    try std.testing.expectError(error.UnsupportedSystem, validate("windows-10", .iso, .direct_iso));
    try std.testing.expectError(error.UnsupportedImage, validate("windows-11", .wim, .direct_iso));
    try std.testing.expectError(error.UnsupportedMethod, validate("windows-11", .iso, .vhdboot));
}
