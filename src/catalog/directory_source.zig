const FixedText = @import("../core/fixed_text.zig").FixedText;

pub const max_directory_entries: usize = 64;

pub const Entry = struct {
    name: FixedText = .{},
    directory: bool = false,
    size: u32 = 0,
};

pub const Page = struct {
    count: usize,
    has_more: bool,
};

pub const Source = struct {
    context: *anyopaque,
    list_fn: *const fn (*anyopaque, []const u8, []Entry) anyerror!usize,
    page_fn: ?*const fn (*anyopaque, []const u8, usize, []Entry) anyerror!Page = null,

    pub fn list(self: Source, path: []const u8, output: []Entry) anyerror!usize {
        return self.list_fn(self.context, path, output);
    }

    pub fn listPage(self: Source, path: []const u8, skip: usize, output: []Entry) anyerror!Page {
        if (self.page_fn) |page_fn| return page_fn(self.context, path, skip, output);
        if (skip != 0) return .{ .count = 0, .has_more = false };
        return .{ .count = try self.list_fn(self.context, path, output), .has_more = false };
    }
};
