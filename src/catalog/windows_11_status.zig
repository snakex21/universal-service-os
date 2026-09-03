pub const Windows11Status = struct {
    iso_count: usize = 0,
    wim_count: usize = 0,
    img_count: usize = 0,
    autounattend: bool = false,
    unattend: bool = false,

    pub fn imageCount(self: Windows11Status) usize {
        return self.iso_count + self.wim_count + self.img_count;
    }

    pub fn ready(self: Windows11Status) bool {
        return self.imageCount() > 0;
    }
};

test "Windows 11 is ready with any supported image type" {
    const std = @import("std");
    try std.testing.expect(!(Windows11Status{}).ready());
    try std.testing.expect((Windows11Status{ .iso_count = 1 }).ready());
    try std.testing.expect((Windows11Status{ .wim_count = 1 }).ready());
    try std.testing.expect((Windows11Status{ .img_count = 1 }).ready());
}
