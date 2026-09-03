const BootMethod = @import("boot_method.zig").BootMethod;
const ImageKind = @import("image_kind.zig").ImageKind;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const compatibility = @import("boot_compatibility.zig");

pub const BootSelection = struct {
    system: *const SystemEntry,
    image_kind: ImageKind,
    method: BootMethod,
    unattended_path: ?[]const u8 = null,

    pub fn valid(self: BootSelection) bool {
        if (!compatibility.canUse(self.system, self.image_kind, self.method)) return false;
        if (self.unattended_path != null and self.system.unattended_directory == null) return false;
        return true;
    }
};

test "DOS selection rejects unattended files" {
    const std = @import("std");
    const systems = @import("systems.zig");
    const dos = systems.findById("ms-dos").?;
    const selection = BootSelection{
        .system = dos,
        .image_kind = .img,
        .method = .floppy_image,
        .unattended_path = "answer.txt",
    };
    try std.testing.expect(!selection.valid());
}
