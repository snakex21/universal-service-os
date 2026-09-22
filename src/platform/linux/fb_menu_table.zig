//! Bounded display-only tables, shared by framebuffer menus.
const std = @import("std");
pub const max_columns = 7;
pub const max_rows = 120;
pub const Cells = [max_columns][]const u8;
pub const Tone = enum { normal, warning, failure };
pub const Row = struct { cells: Cells = @splat(""), tone: Tone = .normal };
pub const Table = struct {
    headers: Cells = @splat(""),
    columns: usize = 0,
    rows: [max_rows]Row = undefined,
    count: usize = 0,

    pub fn header(self: *Table, value: []const u8) !void {
        if (self.columns != 0) return error.DuplicateTableHeader;
        self.columns = try split(value, &self.headers);
    }

    pub fn append(self: *Table, value: []const u8) !void {
        if (self.columns == 0) return error.MissingTableHeader;
        if (self.count == self.rows.len) return error.TooManyTableRows;
        const sep = std.mem.indexOfScalar(u8, value, '|') orelse return error.InvalidTableRow;
        var row = Row{ .tone = std.meta.stringToEnum(Tone, value[0..sep]) orelse return error.InvalidTableTone };
        if (try split(value[sep + 1 ..], &row.cells) != self.columns) return error.InvalidTableRow;
        self.rows[self.count] = row;
        self.count += 1;
    }

    // ATA has compact numeric columns and room for the raw manufacturer data.
    // Other reports use a metric/value table with equal-width columns.
    pub fn weight(self: Table, column: usize) u32 {
        return if (self.columns == 7) ([_]u32{ 6, 25, 8, 8, 8, 30, 15 })[column] else 100 / @as(u32, @intCast(self.columns));
    }
};

fn split(value: []const u8, cells: *Cells) !usize {
    var fields = std.mem.splitScalar(u8, value, '|');
    var count: usize = 0;
    while (fields.next()) |field| {
        if (count == cells.len) return error.TooManyTableColumns;
        cells[count] = field;
        count += 1;
    }
    return count;
}

test "tables preserve raw values and reject inconsistent rows" {
    var table = Table{};
    try std.testing.expectError(error.MissingTableHeader, table.append("normal|one"));
    try table.header("Metric|Value");
    try table.append("warning|Media errors|1,234 [reported]");
    try std.testing.expectEqual(Tone.warning, table.rows[0].tone);
    try std.testing.expectEqualStrings("1,234 [reported]", table.rows[0].cells[1]);
    try std.testing.expectError(error.InvalidTableRow, table.append("normal|missing"));
    try std.testing.expectError(error.InvalidTableTone, table.append("unknown|a|b"));
    try std.testing.expectError(error.DuplicateTableHeader, table.header("Other"));
    for (1..max_rows) |_| try table.append("normal|a|b");
    try std.testing.expectError(error.TooManyTableRows, table.append("normal|a|b"));
}
