const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .direct_efi, .disk_image };

pub const entries = [_]SystemEntry{
    linux("ubuntu", "Ubuntu", "Ubuntu"),
    linux("debian", "Debian", "Debian"),
    linux("fedora", "Fedora", "Fedora"),
    linux("linux-mint", "Linux Mint", "Linux Mint"),
    linux("arch-linux", "Arch Linux", "Arch Linux"),
    linux("opensuse", "openSUSE", "openSUSE"),
    linux("manjaro", "Manjaro", "Manjaro"),
    linux("kali-linux", "Kali Linux", "Kali Linux"),
    linux("other-linux", "Other Linux", "Other Linux"),
};

fn linux(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .linux,
        .family = .linux,
        .image_directory = "\\Systems\\Linux\\" ++ folder ++ "\\Images",
        .unattended_directory = "\\Systems\\Linux\\" ++ folder ++ "\\Unattended",
        .boot_methods = &methods,
    };
}
