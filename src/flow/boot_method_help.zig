const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const capability = @import("preparation_capability.zig");

pub const Help = struct {
    title: []const u8,
    line1: []const u8,
    line2: []const u8,
};

pub fn describe(system_id: []const u8, image: ImageKind, method: BootMethod) Help {
    if (method == .automatic) {
        if (capability.resolve(system_id, image, method)) |resolved| {
            return switch (resolved) {
                .direct_iso => .{
                    .title = "AUTOMATIC - RECOMMENDED",
                    .line1 = "USOS selects the supported boot path for this image automatically.",
                    .line2 = "For this Windows 11 ISO it currently resolves to the ISO method below.",
                },
                else => genericAutomatic(),
            };
        }
        return genericAutomatic();
    }

    return switch (method) {
        .direct_iso => .{
            .title = "ISO - FORCE ISO PREPARATION",
            .line1 = "Extracts Windows Setup from the ISO to the WORK partition.",
            .line2 = "After preparation USOS restarts once and boots Windows Setup from WORK.",
        },
        .wimboot => .{
            .title = "WIMBOOT",
            .line1 = "Starts a Windows PE/WIM image using a WIM-oriented boot path.",
            .line2 = "Useful when the source is a WIM instead of a complete installation ISO.",
        },
        .vhdboot => .{
            .title = "VHDBOOT",
            .line1 = "Boots a prepared Windows installation stored in a VHD or VHDX image.",
            .line2 = "It is for virtual-disk images, not normal Windows installation ISO files.",
        },
        .direct_efi => .{
            .title = "EFI - DIRECT UEFI START",
            .line1 = "Loads the selected EFI application directly through UEFI LoadImage/StartImage.",
            .line2 = "Use it for standalone .efi boot programs that do not need another loader.",
        },
        .chainload => .{
            .title = "CHAINLOAD",
            .line1 = "Transfers control to another bootloader instead of preparing the image itself.",
            .line2 = "Useful when the selected media already contains its own compatible bootloader.",
        },
        .memdisk => .{
            .title = "MEMDISK",
            .line1 = "Presents a small image as memory-backed boot media for legacy software.",
            .line2 = "Primarily intended for DOS and older utilities, not modern Windows installers.",
        },
        .disk_image => .{
            .title = "DISK IMAGE",
            .line1 = "Treats an IMG file as a complete disk image rather than an optical image.",
            .line2 = "Use it for utilities or systems distributed as raw disk images.",
        },
        .floppy_image => .{
            .title = "FLOPPY IMAGE",
            .line1 = "Treats an IMG file as a legacy floppy image.",
            .line2 = "Intended for DOS-era boot disks and small legacy diagnostic tools.",
        },
        .automatic => unreachable,
    };
}

fn genericAutomatic() Help {
    return .{
        .title = "AUTOMATIC - RECOMMENDED",
        .line1 = "USOS chooses the best implemented boot method for the selected image.",
        .line2 = "Choose an explicit method only when you intentionally want to force that path.",
    };
}

test "Windows 11 ISO automatic help explains the resolved ISO backend" {
    const help = describe("windows-11", .iso, .automatic);
    try std.testing.expect(std.mem.indexOf(u8, help.line2, "ISO method") != null);
}

test "explicit ISO help explains WORK preparation" {
    const help = describe("windows-11", .iso, .direct_iso);
    try std.testing.expect(std.mem.indexOf(u8, help.line1, "WORK partition") != null);
}
