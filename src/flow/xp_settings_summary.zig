//! What the answer-file screen says about DATA's usos-xp.ini (read by the
//! micro-Linux staging, tools/xp_user_settings.sh): active with the first
//! account and the computer name, or inactive. Only user= and computer= are
//! read; the key and the password are never shown. Full validation stays in
//! the staging, which stops before any target write on a bad value.
const std = @import("std");

pub const max_value: usize = 64;

pub const Summary = struct {
    active: bool = false,
    user_bytes: [max_value]u8 = undefined,
    user_len: usize = 0,
    computer_bytes: [max_value]u8 = undefined,
    computer_len: usize = 0,

    pub fn user(self: *const Summary) []const u8 {
        return self.user_bytes[0..self.user_len];
    }

    pub fn computer(self: *const Summary) []const u8 {
        return self.computer_bytes[0..self.computer_len];
    }
};

/// Same default as tools/xp_user_settings.sh.
pub const default_computer = "USOS-XP";

/// Parses usos-xp.ini the way the staging does: UTF-8 BOM and CRLF allowed,
/// ';'/'#' comments and [sections] skipped, keys case-insensitive, values
/// trimmed and optionally quoted. Inactive while user= is empty.
pub fn parse(text: []const u8) Summary {
    var summary = Summary{};
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    var user: []const u8 = "";
    var computer: []const u8 = "";
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (std.ascii.eqlIgnoreCase(key, "user")) user = value;
        if (std.ascii.eqlIgnoreCase(key, "computer")) computer = value;
    }
    if (user.len == 0) return summary;
    if (computer.len == 0) computer = default_computer;
    summary.active = true;
    summary.user_len = copyPrintable(&summary.user_bytes, user);
    summary.computer_len = copyPrintable(&summary.computer_bytes, computer);
    return summary;
}

/// ASCII only on screen; anything else (the staging refuses it) becomes '?'.
fn copyPrintable(out: *[max_value]u8, value: []const u8) usize {
    const n = @min(value.len, out.len);
    for (value[0..n], 0..) |c, i| out[i] = if (c >= 0x20 and c < 0x7f) c else '?';
    return n;
}

const Case = struct { name: []const u8, text: []const u8, active: bool, user: []const u8 = "", computer: []const u8 = "" };

// Golden rows: input file -> what the answer screen shows.
const golden = [_]Case{
    .{ .name = "installer template (all empty)", .text = "; comment\r\nuser=\r\nuser2=\r\ncomputer=\r\nkey=\r\npassword=\r\n", .active = false },
    .{ .name = "missing user", .text = "computer=PC-1\n", .active = false },
    .{ .name = "active, default computer", .text = "user=Tester\n", .active = true, .user = "Tester", .computer = default_computer },
    .{ .name = "X470 test file", .text = "user=Tester\r\nuser2=Drugi\r\ncomputer=USOS-XP-TEST\r\norg=USOS\r\ntimezone=95\r\npassword=\r\nkey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\n", .active = true, .user = "Tester", .computer = "USOS-XP-TEST" },
    .{ .name = "BOM, case, quotes, section", .text = "\xef\xbb\xbf[usos]\r\n  USER = \"Jan Kowalski\" \r\nComputer=PC-1\r\n", .active = true, .user = "Jan Kowalski", .computer = "PC-1" },
    .{ .name = "comments are not values", .text = "; user=Nobody\n# computer=X\nuser=Ala\n", .active = true, .user = "Ala", .computer = default_computer },
    .{ .name = "non-ASCII shown as ?", .text = "user=Za\xc5\xbc\n", .active = true, .user = "Za??", .computer = default_computer },
};

test "usos-xp.ini summary golden rows" {
    for (golden) |case| {
        const s = parse(case.text);
        std.testing.expectEqual(case.active, s.active) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
        try std.testing.expectEqualStrings(case.user, s.user());
        try std.testing.expectEqualStrings(case.computer, s.computer());
    }
}

test "the key and the password never reach the summary" {
    const s = parse("user=Tester\nkey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\npassword=secret\n");
    try std.testing.expect(std.mem.indexOf(u8, s.user(), "AAAAA") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.computer(), "secret") == null);
}
