const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi, .chainload };

pub const entries = [_]SystemEntry{
    windows("windows-11", "Windows 11", "Windows 11"),
    windows("windows-10", "Windows 10", "Windows 10"),
    windows("windows-8-1", "Windows 8.1", "Windows 8.1"),
    windows("windows-8", "Windows 8", "Windows 8"),
    windows("windows-7", "Windows 7", "Windows 7"),
    windows("windows-vista", "Windows Vista", "Windows Vista"),
};

fn windows(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .windows,
        .family = .windows,
        .image_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Images",
        .unattended_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Unattended",
        .boot_methods = &methods,
    };
}
