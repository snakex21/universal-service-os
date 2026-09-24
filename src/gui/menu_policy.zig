pub const Activation = enum {
    open,
    firmware_mismatch,
    secure_boot_off_required,
    no_image,
    backend_unavailable,

    /// Launching is refused; the row itself stays selectable so the user
    /// can read why.
    pub fn blocked(self: Activation) bool {
        return self != .open;
    }
};

pub const Access = struct {
    firmware_compatible: bool,
    has_images: bool,
    backend_available: bool = true,
    /// UEFI with Secure Boot enforcing and a system that needs it off
    /// (see flow/secure_boot_policy.zig).
    secure_boot_blocked: bool = false,

    /// Every row stays keyboard/pad/pointer navigable, whatever its state:
    /// a disabled row must be reachable so its badge and explanation can be
    /// read, and a list must scroll to its last row. Only activation is
    /// refused (see `activation`).
    pub fn navigable(self: Access) bool {
        _ = self;
        return true;
    }

    pub fn activation(self: Access) Activation {
        if (!self.firmware_compatible) return .firmware_mismatch;
        if (self.secure_boot_blocked) return .secure_boot_off_required;
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

test "firmware mismatch is navigable but activation is blocked" {
    const std = @import("std");
    const access = Access{ .firmware_compatible = false, .has_images = true };
    try std.testing.expect(access.navigable());
    try std.testing.expectEqual(Activation.firmware_mismatch, access.activation());
    try std.testing.expect(access.activation().blocked());
}

test "secure boot block is navigable but activation is blocked" {
    const std = @import("std");
    const access = Access{ .firmware_compatible = true, .has_images = true, .secure_boot_blocked = true };
    try std.testing.expect(access.navigable());
    try std.testing.expectEqual(Activation.secure_boot_off_required, access.activation());
    try std.testing.expect(access.activation().blocked());
    // The firmware mode is the first thing to fix, so it is reported first.
    const both = Access{ .firmware_compatible = false, .has_images = false, .secure_boot_blocked = true };
    try std.testing.expectEqual(Activation.firmware_mismatch, both.activation());
    try std.testing.expect(!(Access{ .firmware_compatible = true, .has_images = true }).activation().blocked());
}

test "display path removes only the root separator" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Systems\\Windows\\Windows 11\\Images", displayImagePath("\\Systems\\Windows\\Windows 11\\Images"));
    try std.testing.expectEqualStrings("Systems/Windows/Windows 11/Images", displayImagePath("/Systems/Windows/Windows 11/Images"));
}
