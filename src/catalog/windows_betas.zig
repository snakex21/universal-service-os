const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    beta("windows-whistler", "Windows Whistler", "Windows Whistler"),
    beta("windows-longhorn", "Windows Longhorn", "Windows Longhorn"),
    beta("windows-neptune", "Windows Neptune", "Windows Neptune"),
    beta("windows-chicago", "Windows Chicago", "Windows Chicago"),
    beta("windows-memphis", "Windows Memphis", "Windows Memphis"),
    beta("windows-nashville", "Windows Nashville", "Windows Nashville"),
} ++ @import("windows_legacy.zig").uefiOnly(.{
    beta("windows-millennium", "Windows Millennium Beta", "Windows Millennium"),
    beta("windows-7-beta", "Windows 7 Beta", "Windows 7 Beta"),
    beta("windows-2000-beta", "Windows 2000 Beta", "Windows 2000 Beta"),
    beta("windows-nt-4-beta", "Windows NT 4.0 Beta", "Windows NT 4.0 Beta"),
    beta("windows-nt-3-beta", "Windows NT 3.x Beta", "Windows NT 3.x Beta"),
    beta("windows-cairo", "Windows Cairo", "Windows Cairo"),
});

fn beta(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .beta,
        .family = .windows_beta,
        .firmware = .uefi,
        .image_directory = "\\Systems\\Betas\\" ++ folder ++ "\\Images",
        .unattended_directory = "\\Systems\\Betas\\" ++ folder ++ "\\Unattended",
        .boot_methods = &methods,
    };
}
