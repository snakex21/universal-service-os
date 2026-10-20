//! Legacy pack selection. Only the existing 9x and NT4 renderers call it.
const std = @import("std");
pub const Preset = enum { praca, retro, minimal, none };
pub fn validList(text: []const u8) bool {
    if (text.len == 0) return true;
    var it = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (it.next()) |id| {
        if (id.len == 0 or id.len > 47) return false;
        for (id) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
        count += 1;
    }
    return count <= 48;
}
pub fn metadata(p: anytype, w: *std.Io.Writer) !void {
    if (p.addons_preset == .none) return;
    try w.print(";USOS-ADDONS-PRESET={s}\r\n;USOS-ADDONS-OPTIONS={s}\r\n;USOS-ADDONS-EXCLUDE={s}\r\n", .{ @tagName(p.addons_preset), p.addons_options.slice(), p.addons_exclude.slice() });
}
pub const run_line = "HKLM,\"Software\\Microsoft\\Windows\\CurrentVersion\\Run\",USOSAddons,,\"C:\\USOS\\ADDONS\\USOSADD.EXE\"\r\n";
test "addon lists are data tokens, never paths or commands" {
    try std.testing.expect(validList("kernelex,rdp51-pl"));
    try std.testing.expect(!validList("a,,b"));
    try std.testing.expect(!validList("../x"));
    try std.testing.expect(!validList("a&cmd"));
}
