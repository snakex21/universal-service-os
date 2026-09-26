//! Which answer format and which schema details a catalog system gets.
const std = @import("std");

pub const Arch = enum {
    x86,
    amd64,
    arm64,

    pub fn fromText(text: []const u8) ?Arch {
        inline for (@typeInfo(Arch).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(text, f.name)) return @enumFromInt(f.value);
        }
        if (std.ascii.eqlIgnoreCase(text, "x64") or std.ascii.eqlIgnoreCase(text, "x86_64")) return .amd64;
        if (std.ascii.eqlIgnoreCase(text, "i386") or std.ascii.eqlIgnoreCase(text, "ia32")) return .x86;
        if (std.ascii.eqlIgnoreCase(text, "aarch64")) return .arm64;
        return null;
    }
};

pub const Family = enum {
    windows_2000,
    windows_xp,
    windows_2003,
    vista,
    windows_7,
    windows_8,
    windows_8_1,
    windows_10,
    windows_11,
    server_2008,
    server_2008_r2,
    server_2012,
    server_2012_r2,
    server_2016,
    server_2019,
    server_2022,
    server_2025,

    pub fn nt5(self: Family) bool {
        return switch (self) {
            .windows_2000, .windows_xp, .windows_2003 => true,
            else => false,
        };
    }

    pub fn server(self: Family) bool {
        return switch (self) {
            .windows_2003, .server_2008, .server_2008_r2, .server_2012, .server_2012_r2, .server_2016, .server_2019, .server_2022, .server_2025 => true,
            else => false,
        };
    }

    /// The client release whose Setup/OOBE schema this one follows.
    pub fn client(self: Family) Family {
        return switch (self) {
            .server_2008 => .vista,
            .server_2008_r2 => .windows_7,
            .server_2012 => .windows_8,
            .server_2012_r2 => .windows_8_1,
            .server_2016, .server_2019, .server_2022 => .windows_10,
            .server_2025 => .windows_11,
            else => self,
        };
    }

    /// Vista or 7 schema (older time zone names, NetworkLocation, no
    /// online-account screens).
    pub fn legacyNt6(self: Family) bool {
        const c = self.client();
        return c == .vista or c == .windows_7;
    }

    /// Windows 8 and later (HideOnlineAccountScreens).
    pub fn atLeast8(self: Family) bool {
        return !self.nt5() and !self.legacyNt6();
    }
};

const Entry = struct { id: []const u8, family: Family };

const entries = [_]Entry{
    .{ .id = "windows-2000", .family = .windows_2000 },
    .{ .id = "windows-xp", .family = .windows_xp },
    .{ .id = "windows-server-2003", .family = .windows_2003 },
    .{ .id = "windows-vista", .family = .vista },
    .{ .id = "windows-7", .family = .windows_7 },
    .{ .id = "windows-8", .family = .windows_8 },
    .{ .id = "windows-8-1", .family = .windows_8_1 },
    .{ .id = "windows-10", .family = .windows_10 },
    .{ .id = "windows-11", .family = .windows_11 },
    .{ .id = "windows-server-2008", .family = .server_2008 },
    .{ .id = "windows-server-2008-r2", .family = .server_2008_r2 },
    .{ .id = "windows-server-2012", .family = .server_2012 },
    .{ .id = "windows-server-2012-r2", .family = .server_2012_r2 },
    .{ .id = "windows-server-2016", .family = .server_2016 },
    .{ .id = "windows-server-2019", .family = .server_2019 },
    .{ .id = "windows-server-2022", .family = .server_2022 },
    .{ .id = "windows-server-2025", .family = .server_2025 },
};

/// The answer family of a catalog system id; null: no generated answer.
pub fn familyFor(system_id: []const u8) ?Family {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, system_id)) return entry.family;
    }
    return null;
}

pub fn systemId(family: Family) []const u8 {
    for (entries) |entry| {
        if (entry.family == family) return entry.id;
    }
    unreachable;
}

test "families of the catalog systems" {
    try std.testing.expectEqual(Family.windows_xp, familyFor("windows-xp").?);
    try std.testing.expect(familyFor("windows-xp").?.nt5());
    try std.testing.expect(familyFor("windows-98-se") == null);
    try std.testing.expectEqual(Family.windows_7, familyFor("windows-server-2008-r2").?.client());
    try std.testing.expect(familyFor("windows-server-2008").?.legacyNt6());
    try std.testing.expect(familyFor("windows-10").?.atLeast8());
    try std.testing.expect(familyFor("windows-server-2022").?.server());
    try std.testing.expectEqual(Arch.amd64, Arch.fromText("x64").?);
    for (entries) |entry| try std.testing.expectEqualStrings(entry.id, systemId(entry.family));
}
