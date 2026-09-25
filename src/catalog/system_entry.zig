const BootMethod = @import("boot_method.zig").BootMethod;
const Category = @import("category.zig").Category;
const FirmwareRequirement = @import("firmware_requirement.zig").FirmwareRequirement;
const SystemFamily = @import("system_family.zig").SystemFamily;

pub const SystemEntry = struct {
    id: []const u8,
    name: []const u8,
    category: Category,
    family: SystemFamily,
    image_directory: []const u8,
    unattended_directory: ?[]const u8 = null,
    firmware: FirmwareRequirement = .any,
    boot_methods: []const BootMethod,
    /// Windows Server: listed in the Server section of the Windows category.
    server: bool = false,
};
