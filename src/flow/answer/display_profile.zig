//! Optional display request transport. Missing settings preserve old staging.
const std = @import("std");
const Profile = @import("profile.zig").Profile;

pub fn supportsSystem(id: []const u8) bool {
    for ([_][]const u8{ "windows-2000", "windows-2000-server", "windows-95", "windows-98", "windows-98-se", "windows-me", "windows-nt-4", "windows-nt-4-server", "windows-nt-4-tse", "windows-nt-3-5", "windows-nt-3-5-server", "windows-nt-3-51", "windows-nt-3-51-server" }) |known|
        if (std.mem.eql(u8, known, id)) return true;
    return false;
}

pub fn requested(p: *const Profile) bool {
    return p.display_explicit or p.display != .auto or p.display_bpp != .auto;
}

pub fn comment(p: *const Profile, w: *std.Io.Writer) !void {
    if (requested(p)) try w.print(";USOS-DISPLAY={s}x{s}\r\n", .{ @tagName(p.display), @tagName(p.display_bpp) });
}

test "legacy display support excludes XP, NT3.1 and later Windows" {
    for ([_][]const u8{ "windows-2000", "windows-nt-4", "windows-nt-3-51", "windows-98-se" }) |id| try std.testing.expect(supportsSystem(id));
    for ([_][]const u8{ "windows-xp", "windows-server-2003", "windows-nt-3-1", "windows-vista", "citrix-winframe-1-8" }) |id| try std.testing.expect(!supportsSystem(id));
    var p = Profile{};
    try std.testing.expect(!requested(&p));
    p.display_explicit = true;
    try std.testing.expect(requested(&p));
}
