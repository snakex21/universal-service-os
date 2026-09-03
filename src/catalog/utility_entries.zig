const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{
    .automatic,
    .direct_iso,
    .direct_efi,
    .chainload,
    .memdisk,
    .disk_image,
    .floppy_image,
};

pub const entries = [_]SystemEntry{
    utility("memory-tests", "Memory tests", "Memory Tests"),
    utility("disk-tools", "Disk & storage", "Disk & Storage"),
    utility("recovery-tools", "Recovery", "Recovery"),
    utility("firmware-tools", "Firmware & BIOS", "Firmware & BIOS"),
    utility("network-tools", "Network", "Network"),
    utility("boot-tools", "Boot & partition", "Boot & Partition"),
    utility("hardware-diagnostics", "Hardware diagnostics", "Hardware Diagnostics"),
    utility("other-utilities", "Other utilities", "Other Utilities"),
};

fn utility(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .utilities,
        .family = .utility,
        .image_directory = "\\Utilities\\" ++ folder ++ "\\Images",
        .boot_methods = &methods,
    };
}
