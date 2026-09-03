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
};

test "boot method labels stay user readable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("WIMBoot", BootMethod.wimboot.label());
}
