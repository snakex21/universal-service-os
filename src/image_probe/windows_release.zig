//! Release identity from installer version metadata. Filename spelling is not
//! an input. A zero build is unknown, never evidence of a pre-release build.
const std = @import("std");

pub const Version = struct {
    major: u16,
    minor: u16,
    build: u32,
    /// 4.0.950/1111 alone cannot distinguish a 9x release from NT 4 betas.
    lineage: Lineage = .unknown,

    pub const Lineage = enum { unknown, nt, win9x };
};

pub fn betaId(v: Version) ?[]const u8 {
    if (v.build == 0) return null;
    if (v.major == 6 and v.minor == 1 and v.build < 7600) return "windows-7-beta";
    if (v.major == 6 and v.minor == 0 and v.build < 6000) return "windows-longhorn";
    if (v.major == 5 and (v.minor == 50 or (v.minor == 0 and v.build == 5111))) return "windows-neptune";
    if (v.major == 5 and v.minor == 1 and v.build < 2600) return "windows-whistler";
    if (v.major == 5 and v.minor == 0 and v.build < 2195) return "windows-2000-beta";
    if (v.major == 4 and v.minor == 90 and v.build < 3000) return "windows-millennium";
    if (v.major == 4 and v.minor == 10 and v.build == 999) return "windows-nashville";
    if (v.major == 4 and v.minor == 10 and v.build > 999 and v.build < 1998) return "windows-memphis";
    if (v.major == 4 and v.minor == 0 and v.lineage == .win9x and v.build < 950) return "windows-chicago";
    if (v.major == 4 and v.minor == 0 and v.lineage == .nt and v.build < 1381) return "windows-nt-4-beta";
    if (v.major == 3 and ((v.minor == 51 and v.build < 1057) or (v.minor == 50 and v.build < 807) or (v.minor == 10 and v.build < 511))) return "windows-nt-3-beta";
    return null;
}

pub fn betaFolder(id: []const u8) ?[]const u8 {
    const Row = struct { id: []const u8, folder: []const u8 };
    for ([_]Row{
        .{ .id = "windows-7-beta", .folder = "Windows 7 Beta" },
        .{ .id = "windows-longhorn", .folder = "Windows Longhorn" },
        .{ .id = "windows-neptune", .folder = "Windows Neptune" },
        .{ .id = "windows-whistler", .folder = "Windows Whistler" },
        .{ .id = "windows-millennium", .folder = "Windows Millennium" },
        .{ .id = "windows-nashville", .folder = "Windows Nashville" },
        .{ .id = "windows-memphis", .folder = "Windows Memphis" },
        .{ .id = "windows-chicago", .folder = "Windows Chicago" },
        .{ .id = "windows-2000-beta", .folder = "Windows 2000 Beta" },
        .{ .id = "windows-nt-4-beta", .folder = "Windows NT 4.0 Beta" },
        .{ .id = "windows-nt-3-beta", .folder = "Windows NT 3.x Beta" },
    }) |entry| if (std.mem.eql(u8, id, entry.id)) return entry.folder;
    return null;
}

test "beta boundaries do not turn RTM, SP, missing builds or Me RTM into betas" {
    const Row = struct { v: Version, id: ?[]const u8 };
    for ([_]Row{
        .{ .v = .{ .major = 5, .minor = 1, .build = 2542 }, .id = "windows-whistler" },
        .{ .v = .{ .major = 5, .minor = 0, .build = 5111 }, .id = "windows-neptune" },
        .{ .v = .{ .major = 5, .minor = 50, .build = 5111 }, .id = "windows-neptune" },
        .{ .v = .{ .major = 6, .minor = 0, .build = 5048 }, .id = "windows-longhorn" },
        .{ .v = .{ .major = 6, .minor = 1, .build = 7000 }, .id = "windows-7-beta" },
        .{ .v = .{ .major = 4, .minor = 90, .build = 2525 }, .id = "windows-millennium" },
        .{ .v = .{ .major = 4, .minor = 10, .build = 999 }, .id = "windows-nashville" },
        .{ .v = .{ .major = 4, .minor = 10, .build = 1400 }, .id = "windows-memphis" },
        .{ .v = .{ .major = 4, .minor = 0, .build = 347, .lineage = .win9x }, .id = "windows-chicago" },
        .{ .v = .{ .major = 4, .minor = 0, .build = 950, .lineage = .win9x }, .id = null },
        .{ .v = .{ .major = 4, .minor = 0, .build = 1111, .lineage = .win9x }, .id = null },
        .{ .v = .{ .major = 4, .minor = 0, .build = 1175, .lineage = .nt }, .id = "windows-nt-4-beta" },
        .{ .v = .{ .major = 5, .minor = 1, .build = 2600 }, .id = null },
        .{ .v = .{ .major = 5, .minor = 0, .build = 2195 }, .id = null },
        .{ .v = .{ .major = 6, .minor = 0, .build = 6000 }, .id = null },
        .{ .v = .{ .major = 6, .minor = 1, .build = 7600 }, .id = null },
        .{ .v = .{ .major = 6, .minor = 1, .build = 0 }, .id = null },
        .{ .v = .{ .major = 4, .minor = 90, .build = 3000 }, .id = null },
        .{ .v = .{ .major = 4, .minor = 10, .build = 1998 }, .id = null },
    }) |row| {
        const got = betaId(row.v);
        if (row.id) |id| try std.testing.expectEqualStrings(id, got.?) else try std.testing.expect(got == null);
    }
}
