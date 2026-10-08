const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi, .chainload };
const windows7_methods = [_]BootMethod{ .automatic, .direct_iso, .wimboot, .vhdboot, .direct_efi };

pub const entries = [_]SystemEntry{
    windows("windows-11", "Windows 11", "Windows 11"),
    windows("windows-10", "Windows 10", "Windows 10"),
    windows("windows-8-1", "Windows 8.1", "Windows 8.1"),
} ++ @import("windows_legacy.zig").uefiOnly(.{
    // Windows Embedded 8.1 Industry (Pro / Enterprise): the Windows 8.1
    // Setup (os_profiles.zig route_as windows-8-1); UEFI only, x64 starts
    // natively from the ISO, x86 media is blocked on 64-bit UEFI.
    uefiWindows("windows-embedded-8-1-industry", "Windows Embedded 8.1 Industry", "Windows Embedded 8.1 Industry"),
}) ++ [_]SystemEntry{
    windows("windows-8", "Windows 8", "Windows 8"),
    windows("windows-7", "Windows 7", "Windows 7"),
    windows("windows-vista", "Windows Vista", "Windows Vista"),
};

fn uefiWindows(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    var result = windows(id, name, folder);
    result.firmware = .uefi;
    return result;
}

fn windows(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .windows,
        .family = .windows,
        .image_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Images",
        .unattended_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Unattended",
        .boot_methods = if (@import("std").mem.eql(u8, id, "windows-7")) &windows7_methods else &methods,
    };
}
