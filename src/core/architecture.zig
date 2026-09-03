const builtin = @import("builtin");

pub const Architecture = enum {
    x86,
    x86_64,
    aarch64,
    unsupported,

    pub fn supportsDos(self: Architecture) bool {
        return self == .x86 or self == .x86_64;
    }

    pub fn supportsUefi(self: Architecture) bool {
        return self == .x86 or self == .x86_64 or self == .aarch64;
    }
};

pub fn current() Architecture {
    return switch (builtin.cpu.arch) {
        .x86 => .x86,
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => .unsupported,
    };
}

test "supported x86 architectures expose DOS compatibility" {
    const std = @import("std");
    try std.testing.expect(Architecture.x86.supportsDos());
    try std.testing.expect(Architecture.x86_64.supportsDos());
    try std.testing.expect(!Architecture.aarch64.supportsDos());
}

test "all initial target architectures expose UEFI compatibility" {
    const std = @import("std");
    try std.testing.expect(Architecture.x86.supportsUefi());
    try std.testing.expect(Architecture.x86_64.supportsUefi());
    try std.testing.expect(Architecture.aarch64.supportsUefi());
    try std.testing.expect(!Architecture.unsupported.supportsUefi());
}
