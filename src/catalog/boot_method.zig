const FirmwareRequirement = @import("firmware_requirement.zig").FirmwareRequirement;

pub const BootMethod = enum {
    automatic,
    direct_iso,
    wimboot,
    vhdboot,
    direct_efi,
    chainload,
    memdisk,
    disk_image,
    floppy_image,

    pub fn label(self: BootMethod) []const u8 {
        return switch (self) {
            .automatic => "Automatic",
            .direct_iso => "ISO",
            .wimboot => "WIMBoot",
            .vhdboot => "VHDBoot",
            .direct_efi => "EFI",
            .chainload => "Chainload",
            .memdisk => "Memdisk",
            .disk_image => "Disk image",
            .floppy_image => "Floppy image",
        };
    }

    pub fn firmwareRequirement(self: BootMethod) FirmwareRequirement {
        return switch (self) {
            .direct_efi => .uefi,
            else => .any,
        };
    }

    pub fn persistedValue(self: BootMethod) []const u8 {
        return switch (self) {
            .automatic => "automatic",
            .direct_iso => "iso",
            .wimboot => "wimboot",
            .vhdboot => "vhdboot",
            .direct_efi => "efi",
            .chainload => "chainload",
            .memdisk => "memdisk",
            .disk_image => "disk-image",
            .floppy_image => "floppy-image",
        };
    }

    pub fn fromPersistedValue(value: []const u8) ?BootMethod {
        const std = @import("std");
        inline for (std.meta.fields(BootMethod)) |field| {
            const method: BootMethod = @enumFromInt(field.value);
            if (std.mem.eql(u8, method.persistedValue(), value)) return method;
        }
        return null;
    }
};

test "boot method labels stay user readable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("WIMBoot", BootMethod.wimboot.label());
}

test "Direct EFI is UEFI-only while generic methods stay firmware-neutral" {
    const std = @import("std");
    try std.testing.expectEqual(FirmwareRequirement.uefi, BootMethod.direct_efi.firmwareRequirement());
    try std.testing.expectEqual(FirmwareRequirement.any, BootMethod.chainload.firmwareRequirement());
    try std.testing.expectEqual(FirmwareRequirement.any, BootMethod.automatic.firmwareRequirement());
}

test "boot method persisted values round trip" {
    const std = @import("std");
    inline for (std.meta.fields(BootMethod)) |field| {
        const method: BootMethod = @enumFromInt(field.value);
        try std.testing.expectEqual(method, BootMethod.fromPersistedValue(method.persistedValue()).?);
    }
    try std.testing.expect(BootMethod.fromPersistedValue("unknown") == null);
}
