const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    dos("freedos", "FreeDOS", "FreeDOS"),
    dos("ms-dos", "MS-DOS", "MS-DOS"),
    dos("pc-dos", "PC DOS", "PC DOS"),
    dos("dr-dos", "DR-DOS", "DR-DOS"),
    dos("opendos", "OpenDOS", "OpenDOS"),
    dos("other-dos", "Other DOS", "Other DOS"),
};

fn dos(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .dos,
        .family = .dos,
        .image_directory = "\\Systems\\DOS\\" ++ folder ++ "\\Images",
        .firmware = .bios,
        .boot_methods = &methods,
    };
}
