const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const systems = @import("../catalog/systems.zig");
const capability = @import("preparation_capability.zig");

pub const Help = struct {
    title: []const u8,
    line1: []const u8,
    line2: []const u8,
};

pub fn describe(system_id: []const u8, image: ImageKind, method: BootMethod) Help {
    const system = systems.findById(system_id) orelse return genericAutomatic();
    return describeEntry(system, image, method);
}

pub fn describeEntry(system: *const SystemEntry, image: ImageKind, method: BootMethod) Help {
    // The direct Win7 WIMBoot implementation is UEFI-only. Keep its extra help
    // outside the size-limited, freestanding 32-bit BIOS Core.
    if (@import("builtin").os.tag != .freestanding and @import("../catalog/os_profiles.zig").traits(system.id).native_uefi == .win7 and image == .iso and (method == .automatic or method == .direct_iso)) return .{
        .title = "Windows ISO - WIMBoot UEFI",
        .line1 = "Detects the installer version and starts it directly from ISO in UEFI.",
        .line2 = "WinPE 7 receives UEFI compatibility and optional Drivers/x64 packages in RAM.",
    };
    if (@import("builtin").os.tag != .freestanding and capability.nativeModernNt(system.id) and image == .iso and (method == .automatic or method == .direct_iso)) return .{
        .title = "Windows ISO - WIMBoot UEFI",
        .line1 = "Starts Windows Setup directly from the ISO on DATA; nothing is copied to WORK.",
        .line2 = "Boot files go to the target disk; the USOS stick's ESP is checked and restored.",
    };
    if (method == .automatic) {
        if (capability.resolveBackend(system, image, method)) |backend| {
            return switch (backend) {
                .windows_iso => .{
                    .title = "Automatic - recommended",
                    .line1 = "USOS selects the supported boot path for this image automatically.",
                    .line2 = "For this Windows ISO it currently resolves to the ISO method below.",
                },
                .xp_staging => .{
                    .title = "Automatic - Windows Setup",
                    .line1 = "Copies installation files to the selected Windows partition.",
                    .line2 = "After preparation, remove the USB drive and start the computer from that disk.",
                },
                else => genericAutomatic(),
            };
        }
        return genericAutomatic();
    }

    if (capability.resolveBackend(system, image, method)) |backend| {
        if (backend == .xp_staging) {
            return .{
                .title = "Windows Setup",
                .line1 = "Copies installation files to the selected Windows partition.",
                .line2 = "After preparation, remove the USB drive and start the computer from that disk.",
            };
        }
    }

    return switch (method) {
        .direct_iso => .{
            .title = "ISO - force ISO preparation",
            .line1 = "Extracts Windows Setup from the ISO to the WORK partition.",
            .line2 = "After preparation USOS restarts once and boots Windows Setup from WORK.",
        },
        .wimboot => .{
            .title = "WIMBoot",
            .line1 = "Starts a Windows PE/WIM image using a WIM-oriented boot path.",
            .line2 = "Useful when the source is a WIM instead of a complete installation ISO.",
        },
        .vhdboot => .{
            .title = "VHDBoot",
            .line1 = "Boots a prepared Windows installation stored in a VHD or VHDX image.",
            .line2 = "It is for virtual-disk images, not normal Windows installation ISO files.",
        },
        .direct_efi => .{
            .title = "EFI - direct UEFI start",
            .line1 = "Loads the selected EFI application directly through UEFI LoadImage/StartImage.",
            .line2 = "Use it for standalone .efi boot programs that do not need another loader.",
        },
        .chainload => .{
            .title = "Chainload",
            .line1 = "Transfers control to another bootloader instead of preparing the image itself.",
            .line2 = "Useful when the selected media already contains its own compatible bootloader.",
        },
        .memdisk => .{
            .title = "Memdisk",
            .line1 = "Presents a small image as memory-backed boot media for legacy software.",
            .line2 = "Primarily intended for DOS and older utilities, not modern Windows installers.",
        },
        .disk_image => .{
            .title = "Disk image",
            .line1 = "Treats an IMG file as a complete disk image rather than an optical image.",
            .line2 = "Use it for utilities or systems distributed as raw disk images.",
        },
        .floppy_image => .{
            .title = "Floppy image",
            .line1 = "Treats an IMG file as a legacy floppy image.",
            .line2 = "Intended for DOS-era boot disks and small legacy diagnostic tools.",
        },
        .automatic => unreachable,
    };
}

fn genericAutomatic() Help {
    return .{
        .title = "Automatic - recommended",
        .line1 = "USOS chooses the best implemented boot method for the selected image.",
        .line2 = "Choose an explicit method only when you intentionally want to force that path.",
    };
}

test "Windows 8.1 ISO automatic help explains the resolved backend" {
    const help = describe("windows-8-1", .iso, .automatic);
    try std.testing.expect(help.line1.len > 0);
}

test "Windows 10/11 ISO help explains the native start without a WORK copy" {
    for ([_][]const u8{ "windows-10", "windows-11" }) |id| {
        for ([_]BootMethod{ .automatic, .direct_iso }) |method| {
            const help = describe(id, .iso, method);
            try std.testing.expect(std.mem.indexOf(u8, help.line1, "nothing is copied to WORK") != null);
        }
    }
}

test "explicit ISO help explains WORK preparation" {
    const help = describe("windows-8-1", .iso, .direct_iso);
    try std.testing.expect(std.mem.indexOf(u8, help.line1, "WORK partition") != null);
}
