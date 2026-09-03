const Architecture = @import("../core/architecture.zig").Architecture;

pub const Firmware = enum {
    bios,
    uefi,
};

pub fn isSupported(firmware: Firmware, arch: Architecture) bool {
    return switch (firmware) {
        .bios => arch == .x86 or arch == .x86_64,
        .uefi => arch.supportsUefi(),
    };
}

test "legacy BIOS is limited to x86 family" {
    const std = @import("std");
    try std.testing.expect(isSupported(.bios, .x86));
    try std.testing.expect(isSupported(.bios, .x86_64));
    try std.testing.expect(!isSupported(.bios, .aarch64));
}

test "UEFI covers all initial CPU targets" {
    const std = @import("std");
    try std.testing.expect(isSupported(.uefi, .x86));
    try std.testing.expect(isSupported(.uefi, .x86_64));
    try std.testing.expect(isSupported(.uefi, .aarch64));
}
