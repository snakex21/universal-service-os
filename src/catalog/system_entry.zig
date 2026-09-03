const BootMethod = @import("boot_method.zig").BootMethod;
const Category = @import("category.zig").Category;
const SystemFamily = @import("system_family.zig").SystemFamily;

pub const SystemEntry = struct {
    id: []const u8,
    name: []const u8,
    category: Category,
    family: SystemFamily,
    image_directory: []const u8,
    unattended_directory: ?[]const u8 = null,
    boot_methods: []const BootMethod,
};
