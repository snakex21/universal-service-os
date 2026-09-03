const ImageItem = @import("image_item.zig").ImageItem;

pub const max_items: usize = 32;

pub const ImageList = struct {
    items: [max_items]ImageItem = undefined,
    len: usize = 0,

    pub fn append(self: *ImageList, item: ImageItem) bool {
        if (self.len >= max_items) return false;
        self.items[self.len] = item;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const ImageList) []const ImageItem {
        return self.items[0..self.len];
    }
};

test "image list uses fixed storage" {
    const std = @import("std");
    var list = ImageList{};
    var item: ImageItem = undefined;
    item.kind = .iso;
    item.name = .{};
    try std.testing.expect(list.append(item));
    try std.testing.expectEqual(@as(usize, 1), list.slice().len);
}
