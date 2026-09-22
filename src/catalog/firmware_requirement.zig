const std = @import("std");
const Firmware = @import("../core/firmware.zig").Firmware;

pub const FirmwareRequirement = enum {
    any,
    bios,
    uefi,

    pub fn accepts(self: FirmwareRequirement, runtime: Firmware) bool {
        return switch (self) {
            .any => true,
            .bios => runtime == .bios,
            .uefi => runtime == .uefi,
        };
    }

    pub fn label(self: FirmwareRequirement) []const u8 {
        return switch (self) {
            .any => "ANY",
            .bios => "BIOS",
            .uefi => "UEFI",
        };
    }

    pub fn mismatchReason(self: FirmwareRequirement, runtime: Firmware) []const u8 {
        if (self.accepts(runtime)) return "";
        return switch (self) {
            .any => "",
            .bios => "[requires BIOS; running UEFI]",
            .uefi => "[requires UEFI; running BIOS]",
        };
    }
};

test "any accepts both runtimes while explicit requirements are strict" {
    try std.testing.expect(FirmwareRequirement.any.accepts(Firmware.uefi));
    try std.testing.expect(FirmwareRequirement.any.accepts(Firmware.bios));
    try std.testing.expect(FirmwareRequirement.uefi.accepts(Firmware.uefi));
    try std.testing.expect(!FirmwareRequirement.uefi.accepts(Firmware.bios));
    try std.testing.expect(FirmwareRequirement.bios.accepts(Firmware.bios));
    try std.testing.expect(!FirmwareRequirement.bios.accepts(Firmware.uefi));
}

test "firmware mismatch reason names required and running modes" {
    try std.testing.expectEqualStrings("[requires BIOS; running UEFI]", FirmwareRequirement.bios.mismatchReason(.uefi));
    try std.testing.expectEqualStrings("[requires UEFI; running BIOS]", FirmwareRequirement.uefi.mismatchReason(.bios));
    try std.testing.expectEqualStrings("", FirmwareRequirement.any.mismatchReason(.uefi));
}
