pub const SystemMediaStatus = struct {
    iso_count: usize = 0,
    wim_count: usize = 0,
    img_count: usize = 0,
    vhd_count: usize = 0,
    vhdx_count: usize = 0,
    efi_count: usize = 0,
    unattended_files: usize = 0,

    pub fn imageCount(self: SystemMediaStatus) usize {
        return self.iso_count + self.wim_count + self.img_count + self.vhd_count + self.vhdx_count + self.efi_count;
    }

    pub fn hasImages(self: SystemMediaStatus) bool {
        return self.imageCount() != 0;
    }
};

test "image count combines every supported source format" {
    const std = @import("std");
    const status = SystemMediaStatus{ .iso_count = 2, .wim_count = 1, .img_count = 3, .vhd_count = 1, .vhdx_count = 1, .efi_count = 1 };
    try std.testing.expectEqual(@as(usize, 9), status.imageCount());
    try std.testing.expect(status.hasImages());
}
