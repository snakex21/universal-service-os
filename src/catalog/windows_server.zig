//! Windows Server: its own section of the Windows category, after the
//! client versions. Each entry reuses the routing of the client release it
//! shares a Setup with (os_profiles.zig `route_as`); only the DATA folders
//! (Systems\Windows\Windows Server <version>\Images, \Unattended) differ.
//! Windows Server 2003 and 2000 need the NT5 staging and come later.
const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi, .chainload };
/// Same as Windows 7: no chainload of the 6.1 Setup from WORK.
const windows7_methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi };

pub const entries = [_]SystemEntry{
    server("windows-server-2025", "2025", &methods),
    server("windows-server-2022", "2022", &methods),
    server("windows-server-2019", "2019", &methods),
    server("windows-server-2016", "2016", &methods),
    server("windows-server-2012-r2", "2012 R2", &methods),
    server("windows-server-2012", "2012", &methods),
    server("windows-server-2008-r2", "2008 R2", &windows7_methods),
    server("windows-server-2008", "2008", &methods),
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
