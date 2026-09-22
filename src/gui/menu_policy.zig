pub const Activation = enum {
    open,
    firmware_mismatch,
    no_image,
    backend_unavailable,
};

pub const Access = struct {
    firmware_compatible: bool,
    has_images: bool,
    backend_available: bool = true,

    /// A row stays keyboard/pointer navigable as long as it belongs to the
    /// current firmware mode. Missing media is an activation-time condition,
    /// not a reason to make the cursor skip the row.
    pub fn navigable(self: Access) bool {
        return self.firmware_compatible;
    }

    pub fn activation(self: Access) Activation {
        if (!self.firmware_compatible) return .firmware_mismatch;
        if (!self.has_images) return .no_image;
        if (!self.backend_available) return .backend_unavailable;
        return .open;
    }
};

pub fn displayImagePath(path: []const u8) []const u8 {
    if (path.len > 0 and (path[0] == '\\' or path[0] == '/')) return path[1..];
    return path;
}

test "missing image remains navigable but cannot open" {
    const std = @import("std");
    const access = Access{ .firmware_compatible = true, .has_images = false };
    try std.testing.expect(access.navigable());
    try std.testing.expectEqual(Activation.no_image, access.activation());
}

test "firmware mismatch remains non-navigable" {
    const std = @import("std");
    const access = Access{ .firmware_compatible = false, .has_images = true };
    try std.testing.expect(!access.navigable());
    try std.testing.expectEqual(Activation.firmware_mismatch, access.activation());
}

test "display path removes only the root separator" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Systems\\Windows\\Windows 11\\Images", displayImagePath("\\Systems\\Windows\\Windows 11\\Images"));
    try std.testing.expectEqualStrings("Systems/Windows/Windows 11/Images", displayImagePath("/Systems/Windows/Windows 11/Images"));
}
