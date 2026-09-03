pub const max_len: usize = 127;

pub const FixedText = struct {
    bytes: [max_len]u8 = [_]u8{0} ** max_len,
    len: usize = 0,

    pub fn setAsciiFromUtf16(self: *FixedText, text: []const u16) bool {
        if (text.len > max_len) return false;
        for (text, 0..) |unit, index| {
            if (unit > 0x7f) return false;
            self.bytes[index] = @intCast(unit);
        }
        self.len = text.len;
        return true;
    }

    pub fn slice(self: *const FixedText) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "fixed text stores ASCII UTF-16 without allocation" {
    const std = @import("std");
    var text = FixedText{};
    const source = [_]u16{ 't', 'e', 's', 't', '.', 'i', 's', 'o' };
    try std.testing.expect(text.setAsciiFromUtf16(&source));
    try std.testing.expectEqualStrings("test.iso", text.slice());
}
