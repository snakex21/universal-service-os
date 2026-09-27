const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    .{
        .id = "windows-xp",
        .name = "Windows XP",
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\Windows XP\\Images",
        .unattended_directory = "\\Systems\\Windows\\Windows XP\\Unattended",
        .firmware = .any,
        .boot_methods = &methods,
    },
    // BIOS staging, and from UEFI the XP UEFI-CSM / CSMWrap preparation
    // (profile w2k-x86-sp4-uefi-csm, experimental).
    .{
        .id = "windows-2000",
        .name = "Windows 2000",
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\Windows 2000\\Images",
        .unattended_directory = "\\Systems\\Windows\\Windows 2000\\Unattended",
        .firmware = .any,
        .boot_methods = &methods,
    },
    legacy("windows-nt-4", "Windows NT 4.0", "Windows NT 4.0", true),
    legacy("windows-me", "Windows Me", "Windows Me", true),
    legacy("windows-98-se", "Windows 98 SE", "Windows 98 SE", true),
    legacy("windows-98", "Windows 98", "Windows 98", true),
    legacy("windows-95", "Windows 95", "Windows 95", true),
    legacy("windows-3-11", "Windows 3.11", "Windows 3.11", false),
    legacy("windows-3-1", "Windows 3.1", "Windows 3.1", false),
};

fn legacy(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime folder: []const u8,
    comptime unattended: bool,
) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Images",
        .unattended_directory = if (unattended) "\\Systems\\Windows\\" ++ folder ++ "\\Unattended" else null,
        .firmware = .bios,
        .boot_methods = &methods,
    };
}
