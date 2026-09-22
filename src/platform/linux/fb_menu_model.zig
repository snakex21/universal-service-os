const std = @import("std");
pub const Table = @import("fb_menu_table.zig").Table;

pub const Item = struct { title: []const u8, detail: []const u8 = "" };
pub const State = struct {
    title: []const u8 = "WINDOWS XP",
    subtitle: []const u8 = "",
    items: [64]Item = undefined,
    count: usize = 0,
    info: [120][]const u8 = undefined,
    info_count: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    table: Table = .{},

    pub fn detailCount(self: State) usize {
        return if (self.table.columns > 0) self.table.count else self.info_count;
    }

    pub fn move(self: *State, forward: bool) void {
        self.selected = if (forward) (self.selected + 1) % self.count else (self.selected + self.count - 1) % self.count;
    }
    pub fn scrollInfo(self: *State, forward: bool, visible: usize) void {
        const limit = self.detailCount() -| visible;
        self.scroll = if (forward) @min(limit, self.scroll + 1) else self.scroll -| 1;
    }
};

pub fn parse(input: []const u8) !State {
    var state = State{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const sep = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..sep];
        const value = line[sep + 1 ..];
        if (std.mem.eql(u8, key, "title")) state.title = value else if (std.mem.eql(u8, key, "subtitle")) state.subtitle = value else if (std.mem.eql(u8, key, "selected")) {
            state.selected = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "item")) {
            if (state.count == state.items.len) return error.TooManyItems;
            const split = std.mem.indexOfScalar(u8, value, '|') orelse value.len;
            state.items[state.count] = .{ .title = value[0..split], .detail = if (split < value.len) value[split + 1 ..] else "" };
            state.count += 1;
        } else if (std.mem.eql(u8, key, "table_header")) {
            try state.table.header(value);
        } else if (std.mem.eql(u8, key, "table_row")) {
            try state.table.append(value);
        } else if (std.mem.eql(u8, key, "info")) {
            if (state.info_count == state.info.len) return error.TooMuchInfo;
            state.info[state.info_count] = value;
            state.info_count += 1;
        }
    }
    if (state.count == 0 or state.selected >= state.count) return error.InvalidSelection;
    return state;
}

test "menu preserves device identity text and safe default" {
    var state = try parse("title=Test\nitem=Confirm|Deletes data\nitem=Back\nselected=1\ninfo=S/N: A=B\n");
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    try std.testing.expectEqualStrings("S/N: A=B", state.info[0]);
    state.move(true);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    state.move(false);
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    try std.testing.expectError(error.InvalidSelection, parse("item=one\nselected=1"));
    try std.testing.expectError(error.InvalidSelection, parse("title=empty"));
}

test "overview scroll stays in bounds" {
    var state = try parse("item=one\ninfo=a\ninfo=b\ninfo=c");
    state.scrollInfo(true, 2);
    state.scrollInfo(true, 2);
    try std.testing.expectEqual(@as(usize, 1), state.scroll);
    state.scrollInfo(false, 2);
    state.scrollInfo(false, 2);
    try std.testing.expectEqual(@as(usize, 0), state.scroll);
}
