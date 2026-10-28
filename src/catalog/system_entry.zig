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

    pub fn imageFolder(self: SystemEntry) []const u8 {
        const path = self.image_directory;
        const suffix = "\\Images";
        const std = @import("std");
        if (!std.mem.endsWith(u8, path, suffix)) return "";
        const parent = path[0 .. path.len - suffix.len];
        const at = std.mem.lastIndexOfScalar(u8, parent, '\\') orelse return "";
        return parent[at + 1 ..];
    }

    pub fn dataCategory(self: SystemEntry) []const u8 {
        const prefix = "\\Systems\\";
        const std = @import("std");
        if (!std.mem.startsWith(u8, self.image_directory, prefix)) return "";
        const rest = self.image_directory[prefix.len..];
        const at = std.mem.indexOfScalar(u8, rest, '\\') orelse return "";
        return rest[0..at];
    }
};
