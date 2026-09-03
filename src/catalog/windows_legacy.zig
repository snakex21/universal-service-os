const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    legacy("windows-xp", "Windows XP", "Windows XP", true),
    legacy("windows-2000", "Windows 2000", "Windows 2000", true),
    legacy("windows-nt-4", "Windows NT 4.0", "Windows NT 4.0", true),
    legacy("windows-me", "Windows Me", "Windows Me", true),
    legacy("windows-98-se", "Windows 98 SE", "Windows 98 SE", true),
    legacy("windows-98", "Windows 98", "Windows 98", true),
    legacy("windows-95", "Windows 95", "Windows 95", true),
    legacy("windows-3-11", "Windows 3.11", "Windows 3.11", false),
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
        .boot_methods = &methods,
    };
}
