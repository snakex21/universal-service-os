//! "Other systems" (Custom OS, docs/custom-os-2026-10-11.md): operating
//! systems that are neither Windows, Linux nor DOS. Every entry is UEFI-menu
//! only and goes through micro-Linux step 620 with the image-to-disk recipe
//! (tools/image_disk_target.sh, profile custom-image-uefi): the official
//! hybrid image is written to the confirmed target disk, BIOS-only images get
//! the CSMWrap ESP, and the disk then starts by itself. FreeDOS (the DOS
//! category) takes the same route from UEFI.
const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{.automatic};

pub const entries = [_]SystemEntry{
    other("haiku", "Haiku", "Haiku"),
    other("freebsd", "FreeBSD", "FreeBSD"),
    other("reactos", "ReactOS", "ReactOS"),
    other("kolibrios", "KolibriOS", "KolibriOS"),
    // Bring your own image: any hybrid ISO / disk image (UEFI loader or MBR).
    other("other-os", "Other system (own image)", "Other"),
};

fn other(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .other,
        .family = .other,
        .image_directory = "\\Systems\\Other\\" ++ folder ++ "\\Images",
        .boot_methods = &methods,
    };
}
