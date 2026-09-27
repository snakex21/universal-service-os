//! Windows Server: its own section of the Windows category, after the
//! client versions. Each entry reuses the routing of the client release it
//! shares a Setup with (os_profiles.zig `route_as`); only the DATA folders
//! (Systems\Windows\Windows Server <version>\Images, \Unattended) differ.
//! Windows Server 2003 (x86) uses the NT5 staging (os_profiles.zig
//! nt5_staging trait, profile w2k3-x86-sp2-uefi-csm from UEFI).
const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi, .chainload };
/// Same as Windows 7: no chainload of the 6.1 Setup from WORK.
const windows7_methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi };
/// NT5 staging (the Windows legacy methods).
const nt5_methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    server("windows-server-2025", "2025", &methods),
    server("windows-server-2022", "2022", &methods),
    server("windows-server-2019", "2019", &methods),
    server("windows-server-2016", "2016", &methods),
    server("windows-server-2012-r2", "2012 R2", &methods),
    server("windows-server-2012", "2012", &methods),
    server("windows-server-2008-r2", "2008 R2", &windows7_methods),
    server("windows-server-2008", "2008", &methods),
    server("windows-server-2003", "2003", &nt5_methods),
};

fn server(comptime id: []const u8, comptime version: []const u8, comptime boot_methods: []const BootMethod) SystemEntry {
    const name = "Windows Server " ++ version;
    return .{
        .id = id,
        .name = name,
        .category = .windows,
        .family = .windows,
        .image_directory = "\\Systems\\Windows\\" ++ name ++ "\\Images",
        .unattended_directory = "\\Systems\\Windows\\" ++ name ++ "\\Unattended",
        .boot_methods = boot_methods,
        .server = true,
    };
}

test "Server entries keep the client folder convention" {
    const std = @import("std");
    try std.testing.expectEqualStrings("\\Systems\\Windows\\Windows Server 2012 R2\\Images", entries[4].image_directory);
    try std.testing.expectEqualStrings("\\Systems\\Windows\\Windows Server 2012 R2\\Unattended", entries[4].unattended_directory.?);
    for (entries) |entry| try std.testing.expect(entry.server);
}
