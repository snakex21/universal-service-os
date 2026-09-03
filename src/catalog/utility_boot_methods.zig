const BootMethod = @import("boot_method.zig").BootMethod;

pub const all = [_]BootMethod{
    .automatic,
    .direct_iso,
    .direct_efi,
    .chainload,
    .memdisk,
    .disk_image,
    .floppy_image,
};

test "utility boot methods include direct EFI and disk images" {
    const std = @import("std");
    var has_efi = false;
    var has_disk = false;
    for (all) |method| {
        if (method == .direct_efi) has_efi = true;
        if (method == .disk_image) has_disk = true;
    }
    try std.testing.expect(has_efi);
    try std.testing.expect(has_disk);
}
