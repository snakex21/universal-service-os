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
const options = @import("options.zig");

pub const file_name = "MSBATCH.INF";

/// Rendered files the UEFI menu leaves for the BIOS Core, one per catalog
/// system (\EFI\USOS\answer\<name>; the Core's release tags).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = "windows-98-se", .file = "98SE.INF" },
    .{ .system_id = "windows-98", .file = "98.INF" },
    .{ .system_id = "windows-me", .file = "ME.INF" },
    .{ .system_id = "windows-95", .file = "95.INF" },
    .{ .system_id = "windows-millennium", .file = "MIL.INF" },
    .{ .system_id = "windows-nashville", .file = "NASH.INF" },
    .{ .system_id = "windows-memphis", .file = "MEMPHIS.INF" },
    .{ .system_id = "windows-chicago", .file = "CHICAGO.INF" },
};

pub const Release = enum { windows_95, windows_98, windows_me };

pub fn releaseFor(system_id: []const u8) ?Release {
    const routed = @import("../../catalog/os_profiles.zig").routeId(system_id);
    const map = [_]struct { id: []const u8, release: Release }{
        .{ .id = "windows-95", .release = .windows_95 },
        .{ .id = "windows-98", .release = .windows_98 },
        .{ .id = "windows-98-se", .release = .windows_98 },
        .{ .id = "windows-me", .release = .windows_me },
    };
    for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.id, system_id) or std.ascii.eqlIgnoreCase(entry.id, routed)) return entry.release;
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

/// The 9x time zone key for a run without an answer profile: the default
/// zone of the menu language (`ui_code`, e.g. "pl"), as a new profile gets
/// it. Without it the Date/Time page stops Setup's hardware phase.
pub fn timeZoneForUi(ui_code: []const u8) ?[]const u8 {
    const zone = tables.timeZone(tables.timeZoneForLanguage(tables.languageForUi(ui_code))) orelse return null;
    return timeZoneName(zone);
}

/// The Windows 95 time zone key for a Windows 98 key: OSR2.1's TIMEZONE.INF
/// (52 keys) names some zones differently (same TZI) and lacks others (null:
/// Setup asks). tools/w9x_csmwrap_prepare.sh w9x_release_time_zone mirrors it.
pub fn timeZoneName95(name98: []const u8) ?[]const u8 {
    const renamed = [_][2][]const u8{
        .{ "Central European", "Warsaw" }, .{ "Central Europe", "Prague Bratislava" },
        .{ "China", "Beijing" },           .{ "SE Asia", "Bangkok" },
        .{ "Arab", "Saudi Arabia" },
    };
    for (renamed) |pair| {
        if (std.mem.eql(u8, pair[0], name98)) return pair[1];
    }
    for (windows95_zones) |known| {
        if (std.mem.eql(u8, known, name98)) return known;
    }
    return null;
}

/// The Windows 98 keys that Windows 95 OSR2.1 has under the same name.
const windows95_zones = [_][]const u8{
    "GMT",            "Romance",      "W. Europe",   "E. Europe",      "E. South America", "Atlantic",
    "Eastern",        "Central",      "Mountain",    "Pacific",        "Alaskan",          "Hawaiian",
    "Samoa",          "New Zealand",  "AUS Eastern", "Cen. Australia", "Tokyo",            "Taipei",
    "India",          "Arabian",      "Iran",        "Israel",         "Newfoundland",     "Azores",
    "Mid-Atlantic",   "Greenwich",    "SA Eastern",  "SA Western",     "US Eastern",       "SA Pacific",
    "Canada Central", "Mexico",       "US Mountain", "Dateline",       "Fiji",             "Central Pacific",
    "Tasmania",       "West Pacific", "AUS Central", "Central Asia",   "West Asia",        "Afghanistan",
    "Egypt",          "South Africa", "Russian",     "E. Australia",
};

/// The time zone keys of Windows 98 SE (TIMEZONE.INF), zones added later
/// are missing on purpose.
const windows98_zones = [_][]const u8{
    "AUS Central",  "AUS Eastern",    "Afghanistan",      "Alaskan",          "Arab",           "Arabian",
    "Atlantic",     "Azores",         "Canada Central",   "Caucasus",         "Cen. Australia", "Central",
    "Central Asia", "Central Europe", "Central European", "Central Pacific",  "China",          "Dateline",
    "E. Africa",    "E. Australia",   "E. Europe",        "E. South America", "Eastern",        "Egypt",
    "Ekaterinburg", "FLE",            "Fiji",             "GMT",              "GTB",            "Greenwich",
    "Hawaiian",     "India",          "Iran",             "Israel",           "Korea",          "Mexico",
    "Mid-Atlantic", "Mountain",       "New Zealand",      "Newfoundland",     "Pacific",        "Pacific SA",
    "Romance",      "Russian",        "SA Eastern",       "SA Pacific",       "SA Western",     "SE Asia",
    "Samoa",        "Singapore",      "South Africa",     "Sri Lanka",        "Taipei",         "Tasmania",
    "Tokyo",        "US Eastern",     "US Mountain",      "Vladivostok",      "W. Australia",   "W. Europe",
    "West Asia",    "West Pacific",   "Yakutsk",
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
        if (timeZoneName(zone)) |name98| {
            const name = if (release == .windows_95) timeZoneName95(name98) else name98;
            if (name) |n| try w.print("TimeZone=\"{s}\"\r\n", .{n});
        }
    }
    // An empty field makes Setup show the user page (it needs a key press).
    const org = if (p.org.slice().len > 0) p.org.slice() else "USOS";
    try w.print("\r\n[NameAndOrg]\r\nName=\"{s}\"\r\nOrg=\"{s}\"\r\nDisplay=0\r\n", .{ p.user.slice(), org });
    const computer = if (p.computer.slice().len > 0) p.computer.slice() else "USOS-9X";
    const workgroup = if (p.workgroup.len > 0) p.workgroup.slice() else "WORKGROUP";
    try w.print("\r\n[Network]\r\nComputerName=\"{s}\"\r\nWorkgroup=\"{s}\"\r\nDescription=\"{s}\"\r\nDisplay=0\r\n", .{ computer, workgroup, p.user.slice() });
    try w.writeAll("Clients=\r\nProtocols=\r\nServices=\r\n");
    // Typed options (options.zig): their own AddReg section, only when set.
    var values: [options.count]u8 = undefined;
    var it = options.iterate(p, &values, .{ .os = switch (release) {
        .windows_95 => .win95,
        .windows_98 => .win98,
        .windows_me => .win_me,
    } });
    const any_option = it.next() != null;
    try w.writeAll(if (any_option) "\n[Install]\nAddReg=USOS.RunOnce,USOS.CsmReg,USOS.Profile\n" else "\n[Install]\nAddReg=USOS.RunOnce,USOS.CsmReg\n");
    try w.writeAll("UpdateInis=USOS.Memory\nUpdateIniFields=USOS.Csm\n");
    if (any_option) {
        // Setup's INF AddReg: HKCU at Setup time is the one default user.
        // A DWORD is written as 4 binary bytes (flag 1), as the 9x shell
        // and policy readers take it.
        try w.writeAll("\n[USOS.Profile]\n");
        it = options.iterate(p, &values, it.t);
        while (it.next()) |rule| switch (rule.action) {
            .reg => |r| {
                const root: []const u8 = switch (r.root) {
                    .hklm => "HKLM",
                    .user => "HKCU",
                    .default => continue,
                };
                try w.print("{s},\"{s}\",{s},", .{ root, r.key, r.name });
                switch (r.data) {
                    .dword => |v| try w.print("1,{x:0>2},{x:0>2},{x:0>2},{x:0>2}\n", .{ v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24 }),
                    .binary => |hex| try w.print("1,{s}\n", .{hex}),
                    else => {
                        var number: [16]u8 = undefined;
                        try w.print(",\"{s}\"\n", .{options.dataText(r.data, p, &number)});
                    },
                }
            },
            else => {},
        };
    }
    try w.writeAll(
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
        \\; Last section: under CSMWrap INSTALL.BAT appends the Me USB input lines
        \\; (Me) or the USOS.CsmReg section (98, 98 SE); missing, it is skipped.
        \\[USOS.Csm]
        \\
    );
    if (p.beta_clock.len > 0) {
        if (!@import("beta_clock.zig").validSetting(p.beta_clock.slice())) return error.InvalidBetaClock;
        try w.print(";USOS-BETA-CLOCK={s}\r\n", .{p.beta_clock.slice()});
    }
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

test "MSBATCH.INF: typed options in their own AddReg section, only when set" {
    var p = Profile{};
    try p.name.set("Retro");
    try p.user.set("Jan");
    var buffer: [4096]u8 = undefined;
    const plain = try render(&p, .windows_98, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, plain, "USOS.Profile") == null);
    p.show_extensions = true;
    p.no_autorun = true;
    p.opts[@intFromEnum(options.Opt.show_protected)] = 1;
    try p.workgroup.set("RETRO");
    const me = try render(&p, .windows_me, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, me, "\r\nWorkgroup=\"RETRO\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, me, "\r\nAddReg=USOS.RunOnce,USOS.CsmReg,USOS.Profile\r\nUpdateInis=USOS.Memory\r\nUpdateIniFields=USOS.Csm\r\n\r\n[USOS.Profile]\r\n" ++
        "HKCU,\"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\",HideFileExt,1,00,00,00,00\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, me, "\r\nHKCU,\"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\",ShowSuperHidden,1,01,00,00,00\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, me, "\r\nHKCU,\"Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer\",NoDriveTypeAutoRun,1,ff,00,00,00\r\n") != null);
    // [USOS.Csm] stays the last section (INSTALL.BAT appends to it).
    try std.testing.expect(std.mem.endsWith(u8, me, "[USOS.Csm]\r\n"));
    // 95: no Explorer\Advanced values, AutoRun only.
    const ninety_five = try render(&p, .windows_95, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ninety_five, "HideFileExt") == null and std.mem.indexOf(u8, ninety_five, "NoDriveTypeAutoRun") != null);
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

test "Windows 95 time zone keys: renamed, same, or none" {
    try std.testing.expectEqualStrings("Warsaw", timeZoneName95("Central European").?);
    try std.testing.expectEqualStrings("Prague Bratislava", timeZoneName95("Central Europe").?);
    try std.testing.expectEqualStrings("W. Europe", timeZoneName95("W. Europe").?);
    try std.testing.expectEqualStrings("Eastern", timeZoneName95("Eastern").?);
    try std.testing.expect(timeZoneName95("GTB") == null);
    try std.testing.expect(timeZoneName95("Korea") == null);
    // Every 95 key comes from a 98 key the menu can produce.
    for (windows95_zones) |name| {
        var found = false;
        for (windows98_zones) |known| found = found or std.mem.eql(u8, known, name);
        try std.testing.expect(found);
    }
}

test "the menu language gives the default 9x time zone" {
    try std.testing.expectEqualStrings("Central European", timeZoneForUi("pl").?);
    try std.testing.expectEqualStrings("W. Europe", timeZoneForUi("de").?);
    try std.testing.expectEqualStrings("Eastern", timeZoneForUi("en").?);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nAddReg=USOS.RunOnce,USOS.CsmReg\r\n") != null);
    for (text, 0..) |c, i| {
        if (c == '\n') try std.testing.expectEqual(@as(u8, '\r'), text[i - 1]);
    }
    const ninety_five = try render(&p, .windows_95, key, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ninety_five, "ProductKey") == null and std.mem.indexOf(u8, ninety_five, "ProductID") == null);
    const oem = try render(&p, .windows_95, "12345-oem-0012345-12345", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, oem, "\r\nProductID=\"12345-OEM-0012345-12345\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, oem, "\r\nTimeZone=\"Warsaw\"\r\n") != null);
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
