const std = @import("std");

pub const FileReader = struct {
    io: std.Io,
    file: std.Io.File,
    file_size: u64,

    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) !FileReader {
        var file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        return .{ .io = io, .file = file, .file_size = stat.size };
    }

    pub fn close(self: *FileReader) void {
        self.file.close(self.io);
    }

    pub fn size(self: *const FileReader) u64 {
        return self.file_size;
    }

    pub fn readAt(self: *const FileReader, offset: u64, buffer: []u8) !usize {
        return self.file.readPositionalAll(self.io, buffer, offset);
    }
};

pub const SliceReader = struct {
    bytes: []const u8,

    pub fn size(self: *const SliceReader) u64 {
        return self.bytes.len;
    }

    pub fn readAt(self: *const SliceReader, offset: u64, buffer: []u8) !usize {
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const len = @min(buffer.len, self.bytes.len - start);
        @memcpy(buffer[0..len], self.bytes[start .. start + len]);
        return len;
    }
};

pub fn readExactAt(reader: anytype, offset: u64, buffer: []u8) !void {
    const got = try reader.readAt(offset, buffer);
    if (got != buffer.len) return error.EndOfStream;
}

test "slice reader performs positional reads" {
    const bytes = "0123456789";
    var reader = SliceReader{ .bytes = bytes };
    var out: [4]u8 = undefined;
    try readExactAt(&reader, 3, &out);
    try std.testing.expectEqualStrings("3456", &out);
    try std.testing.expectEqual(@as(u64, 10), reader.size());
}
