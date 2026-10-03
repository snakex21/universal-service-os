//! Windows 95/98/Me renderer: MSBATCH.INF for the DOS Setup that the BIOS
//! Core starts (docs/win9x-modern-2026-09-30.md). The base is the USOS
//! default answer (src/platform/bios/win9x/msbatch.inf: typical install,
//! no startup disk, no licence page, no network components, restarts
//! without a prompt, no Welcome screen); the profile adds the owner,
//! organisation, computer name, time zone and, for 98/Me, the product key.
//!
//! The UEFI menu writes the result to \EFI\USOS\answer\MSBATCH.INF before
//! it starts the BIOS mode; the Core copies it into the RAM disk, and
//! clearRendered() removes it at the next UEFI start (it may hold a key).
//! Windows 95 keys have another format (ddddd-OEM-ddddddd-ddddd or
//! ddd-ddddddd) and go to ProductID.
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;
const tables = @import("tables.zig");

pub const file_name = "MSBATCH.INF";

/// Rendered files the UEFI menu leaves for the BIOS Core, one per catalog
/// system (\EFI\USOS\answer\<name>; the Core's release tags).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "windows-98-se", .file = "98SE.INF" },
    .{ .system_id = "windows-98", .file = "98.INF" },
    .{ .system_id = "windows-me", .file = "ME.INF" },
    .{ .system_id = "windows-95", .file = "95.INF" },
};

pub const Release = enum { windows_95, windows_98, windows_me };

pub fn releaseFor(system_id: []const u8) ?Release {
    const map = [_]struct { id: []const u8, release: Release }{
        .{ .id = "windows-95", .release = .windows_95 },
        .{ .id = "windows-98", .release = .windows_98 },
        .{ .id = "windows-98-se", .release = .windows_98 },
        .{ .id = "windows-me", .release = .windows_me },
    };
    for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, system_id)) return entry.release;
    }
    return null;
}

/// The Windows 9x time zone key (HKLM\...\Time Zones\<name>) for a profile
/// zone: the Windows id without " Standard Time" (the older id when there
/// is one), if Windows 98 has that zone; null: Setup asks.
pub fn timeZoneName(zone: *const tables.TimeZone) ?[]const u8 {
    const id = zone.windows_legacy orelse zone.windows;
    const suffix = " Standard Time";
    const name = if (std.mem.endsWith(u8, id, suffix)) id[0 .. id.len - suffix.len] else if (std.mem.eql(u8, id, "UTC")) "Greenwich" else id;
    for (windows98_zones) |known| {
        if (std.mem.eql(u8, known, name)) return known;
    }
    return null;
}

/// The time zone keys of Windows 98 SE (TIMEZONE.INF), zones added later
/// are missing on purpose.
const windows98_zones = [_][]const u8{
    "AUS Central",    "AUS Eastern",  "Afghanistan",     "Alaskan",       "Arab",           "Arabian",
    "Atlantic",       "Azores",       "Canada Central",  "Caucasus",      "Cen. Australia", "Central",
    "Central Asia",   "Central Europe", "Central European", "Central Pacific", "China",       "Dateline",
    "E. Africa",      "E. Australia", "E. Europe",       "E. South America", "Eastern",     "Egypt",
    "Ekaterinburg",   "FLE",          "Fiji",            "GMT",           "GTB",            "Greenwich",
    "Hawaiian",       "India",        "Iran",            "Israel",        "Korea",          "Mexico",
    "Mid-Atlantic",   "Mountain",     "New Zealand",     "Newfoundland",  "Pacific",        "Pacific SA",
    "Romance",        "Russian",      "SA Eastern",      "SA Pacific",    "SA Western",     "SE Asia",
    "Samoa",          "Singapore",    "South Africa",    "Sri Lanka",     "Taipei",         "Tasmania",
    "Tokyo",          "US Eastern",   "US Mountain",     "Vladivostok",   "W. Australia",   "W. Europe",
    "West Asia",      "West Pacific", "Yakutsk",
};

/// MSBATCH.INF (CRLF) for the release. `key`: the product key to use (the
/// profile's or one typed at start); ignored for Windows 95.
pub fn render(p: *const Profile, release: Release, key: []const u8, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; MSBATCH.INF rendered by USOS from an answer profile (docs/win9x-modern-2026-09-30.md)\r\n");
    try w.writeAll("[Version]\r\nSignature=\"$CHICAGO$\"\r\n\r\n[Setup]\r\n");
    try w.writeAll("Express=1\r\nInstallDir=\"C:\\WINDOWS\"\r\nInstallType=1\r\nEBD=0\r\nShowEula=0\r\nChangeDir=0\r\n");
    try w.writeAll("OptionalComponents=1\r\nNetwork=1\r\nSystem=0\r\nCCP=0\r\nCleanBoot=0\r\nDisplay=0\r\n");
    try w.writeAll("DevicePath=1\r\nNoDirWarn=1\r\nNoPrompt2Boot=1\r\nUninstall=0\r\nVRC=1\r\n");
    // 98/Me: ProductKey (5x5); 95: ProductID (OEM ddddd-OEM-ddddddd-ddddd or
    // retail ddd-ddddddd). A key of the other kind is left out (Setup asks).
    const shape = profile_mod.keyShape(key);
    const key_field: ?[]const u8 = if (shape) |s| switch (s) {
        .five_by_five => if (release != .windows_95) "ProductKey" else null,
        .win95_oem, .win95_retail => if (release == .windows_95) "ProductID" else null,
    } else null;
    if (key_field) |field| {
        try w.print("{s}=\"", .{field});
        for (key) |c| try w.writeByte(std.ascii.toUpper(c));
        try w.writeAll("\"\r\n");
    }
    if (p.timeZone()) |zone| {
        if (timeZoneName(zone)) |name| try w.print("TimeZone=\"{s}\"\r\n", .{name});
    }
    // An empty field makes Setup show the user page (it needs a key press).
    const org = if (p.org.slice().len > 0) p.org.slice() else "USOS";
    try w.print("\r\n[NameAndOrg]\r\nName=\"{s}\"\r\nOrg=\"{s}\"\r\nDisplay=0\r\n", .{ p.user.slice(), org });
    const computer = if (p.computer.slice().len > 0) p.computer.slice() else "USOS-9X";
    try w.print("\r\n[Network]\r\nComputerName=\"{s}\"\r\nWorkgroup=\"WORKGROUP\"\r\nDescription=\"{s}\"\r\nDisplay=0\r\n", .{ computer, p.user.slice() });
    try w.writeAll("Clients=\r\nProtocols=\r\nServices=\r\n");
    try w.writeAll(
        \\
        \\[Install]
        \\AddReg=USOS.RunOnce
        \\UpdateInis=USOS.Memory
        \\UpdateIniFields=USOS.Csm
        \\
        \\[USOS.Memory]
        \\system.ini,386Enh,,"MaxPhysPage=40000"
        \\system.ini,vcache,,"MaxFileCache=262144"
        \\
        \\[USOS.RunOnce]
        \\HKLM,"Software\Microsoft\Windows\CurrentVersion\RunOnce",USOSWelcome,,"%25%\rundll.exe setupx.dll,InstallHinfSection USOS.NoWelcome 4 %10%\msbatch.inf"
        \\
        \\[USOS.NoWelcome]
        \\DelReg=USOS.Welcome.Del
        \\AddReg=USOS.Regwiz
        \\
        \\[USOS.Welcome.Del]
        \\HKLM,"Software\Microsoft\Windows\CurrentVersion\Run",Welcome
        \\
        \\[USOS.Regwiz]
        \\HKLM,"Software\Microsoft\Windows\CurrentVersion\Welcome\Regwiz",,1,01,00,00,00
        \\HKLM,"Software\Microsoft\Windows\CurrentVersion",RegDone,1,01,00,00,00
        \\
        \\; Last section: under CSMWrap INSTALL.BAT appends the Me USB input lines.
        \\[USOS.Csm]
        \\
    );
    // The multiline literal ends lines with LF only: make every line CRLF.
    const text = w.buffered();
    var extra: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n' and (i == 0 or text[i - 1] != '\r')) extra += 1;
    }
    if (text.len + extra > buffer.len) return error.WriteFailed;
    var out = text.len + extra;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        out -= 1;
        buffer[out] = text[i];
        if (text[i] == '\n' and (i == 0 or text[i - 1] != '\r')) {
            out -= 1;
            buffer[out] = '\r';
        }
    }
    return buffer[0 .. text.len + extra];
}

test "releases of the catalog 9x systems" {
    try std.testing.expectEqual(Release.windows_98, releaseFor("windows-98-se").?);
    try std.testing.expectEqual(Release.windows_me, releaseFor("windows-me").?);
    try std.testing.expectEqual(Release.windows_95, releaseFor("windows-95").?);
    try std.testing.expect(releaseFor("windows-xp") == null);
}

test "time zones map to the Windows 98 key names or to none" {
    try std.testing.expectEqualStrings("Central European", timeZoneName(tables.timeZone("Europe/Warsaw").?).?);
    try std.testing.expectEqualStrings("Pacific", timeZoneName(tables.timeZone("America/Los_Angeles").?).?);
    try std.testing.expectEqualStrings("Mexico", timeZoneName(tables.timeZone("America/Mexico_City").?).?);
    try std.testing.expectEqualStrings("Greenwich", timeZoneName(tables.timeZone("Etc/UTC").?).?);
    // Zones Windows 98 does not know: Setup asks.
    try std.testing.expect(timeZoneName(tables.timeZone("Asia/Kathmandu") orelse tables.timeZone("Pacific/Tongatapu").?) == null);
}

test "MSBATCH.INF carries the profile, CRLF, the key only for 98 and Me" {
    var p = Profile{};
    try p.name.set("Retro");
    try p.user.set("Jan Kowalski");
    try p.org.set("USOS Lab");
    p.timezone = @intCast(tables.timeZoneIndex("Europe/Warsaw").?);
    var buffer: [4096]u8 = undefined;
    const key = "abcde-12345-fghij-67890-klmno";
    const text = try render(&p, .windows_98, key, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nProductKey=\"ABCDE-12345-FGHIJ-67890-KLMNO\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nName=\"Jan Kowalski\"\r\nOrg=\"USOS Lab\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nTimeZone=\"Central European\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nComputerName=\"USOS-9X\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nAddReg=USOS.RunOnce\r\n") != null);
    for (text, 0..) |c, i| {
        if (c == '\n') try std.testing.expectEqual(@as(u8, '\r'), text[i - 1]);
    }
    const ninety_five = try render(&p, .windows_95, key, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ninety_five, "ProductKey") == null and std.mem.indexOf(u8, ninety_five, "ProductID") == null);
    const oem = try render(&p, .windows_95, "12345-oem-0012345-12345", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, oem, "\r\nProductID=\"12345-OEM-0012345-12345\"\r\n") != null);
    const retail = try render(&p, .windows_95, "123-4567890", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, retail, "\r\nProductID=\"123-4567890\"\r\n") != null);
    const wrong = try render(&p, .windows_98, "123-4567890", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, wrong, "Product") == null);
    const no_key = try render(&p, .windows_me, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, no_key, "ProductKey") == null);
    p.org = .{};
    const no_org = try render(&p, .windows_me, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, no_org, "\r\nOrg=\"USOS\"\r\n") != null);
    var small: [64]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, render(&p, .windows_98, key, &small));
}

test "the USOS default MSBATCH.INF and the renderer share the base keys" {
    const default = @embedFile("../../platform/bios/win9x/msbatch.inf");
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("USOS");
    var buffer: [4096]u8 = undefined;
    const text = try render(&p, .windows_98, "", &buffer);
    var lines = std.mem.tokenizeAny(u8, default, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == ';' or std.mem.startsWith(u8, line, "Name=") or std.mem.startsWith(u8, line, "Description=")) continue;
        try std.testing.expect(std.mem.indexOf(u8, text, line) != null);
    }
}
