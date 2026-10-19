//! Text-mode/DOS source identity. The caller supplies a setup executable's
//! validated file version; no conclusion is drawn from the ISO filename.
const std = @import("std");
const media = @import("windows_media.zig");
const release = @import("windows_release.zig");

pub const Source = struct {
    txtsetup: []const u8 = "",
    prodspec: []const u8 = "",
    setupp: []const u8 = "",
    setup_version: ?release.Version = null,
    setup_arch: media.Arch = .unknown,
    flp_wim: bool = false,
    posready_wim: bool = false,
    media_center: bool = false,
    tablet_pc: bool = false,
};

pub const Info = struct {
    version: ?release.Version = null,
    arch: media.Arch = .unknown,
    product_type: ?u8 = null,
    channel: enum { unknown, retail, oem, volume } = .unknown,
    locale: ?u32 = null,
    home: bool = false,
    media_center: bool = false,
    tablet_pc: bool = false,
    /// The Setup's SIF describes its WinPE, not the OS in Setup/WIM.
    pe_installer: bool = false,
    system_id: ?[]const u8 = null,
};

pub fn iniValue(text: []const u8, wanted_section: []const u8, wanted_key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var active = false;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOfScalar(u8, line, ';')) |at| line = std.mem.trim(u8, line[0..at], " \t");
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            active = std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[1 .. line.len - 1], " \t"), wanted_section);
            continue;
        }
        if (!active) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..eq], " \t"), wanted_key)) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
    }
    return null;
}

fn number(text: []const u8, key: []const u8) ?u32 {
    return std.fmt.parseInt(u32, iniValue(text, "SetupData", key) orelse return null, 10) catch null;
}

pub fn inspect(source: Source) Info {
    var info = Info{ .arch = source.setup_arch, .version = source.setup_version, .media_center = source.media_center, .tablet_pc = source.tablet_pc };
    if (iniValue(source.txtsetup, "SetupData", "Architecture")) |arch| {
        if (std.ascii.eqlIgnoreCase(arch, "i386")) info.arch = .x86;
        if (std.ascii.eqlIgnoreCase(arch, "amd64")) info.arch = .x64;
        if (std.ascii.eqlIgnoreCase(arch, "ia64")) info.arch = .ia64;
    }
    if (number(source.txtsetup, "ProductType")) |product| if (product <= 3) {
        info.product_type = @intCast(product);
    };
    if (iniValue(source.txtsetup, "nls", "DefaultLayout")) |layout|
        info.locale = std.fmt.parseInt(u32, layout, 16) catch null;
    if (info.version == null) {
        if (number(source.txtsetup, "MajorVersion")) |major| if (number(source.txtsetup, "MinorVersion")) |minor| {
            if (major <= 65535 and minor <= 65535) info.version = .{ .major = @intCast(major), .minor = @intCast(minor), .build = number(source.txtsetup, "BuildNumber") orelse 0, .lineage = .nt };
        };
    }
    const product = iniValue(source.prodspec, "Product Specification", "Product") orelse iniValue(source.txtsetup, "Strings", "ProductName") orelse "";
    info.home = std.ascii.indexOfIgnoreCase(product, "Home") != null;
    if (iniValue(source.setupp, "Pid", "Pid")) |pid| {
        if (std.ascii.endsWithIgnoreCase(pid, "OEM")) info.channel = .oem else if (std.mem.endsWith(u8, pid, "270")) info.channel = .volume else if (std.mem.endsWith(u8, pid, "000")) info.channel = .retail;
    }
    // WinPE sources must win over the PE's Server 2003 ProductType/version.
    if (source.flp_wim or source.posready_wim) {
        info.pe_installer = true;
        info.system_id = if (source.flp_wim) "windows-flp" else "windows-embedded-posready-2009";
        return info;
    }
    if (std.ascii.indexOfIgnoreCase(product, "WinFrame") != null or std.ascii.indexOfIgnoreCase(product, "Citrix") != null) {
        info.system_id = "citrix-winframe-1-8";
        return info;
    }
    if (std.ascii.indexOfIgnoreCase(product, "Cairo") != null) {
        info.system_id = "windows-cairo";
        return info;
    }
    if (info.version) |v| {
        if (release.betaId(v)) |id| info.system_id = id else if (v.major == 5 and v.minor == 1) info.system_id = if (source.media_center and !source.tablet_pc) "windows-xp-mce" else if (source.tablet_pc and !source.media_center) "windows-xp-tablet" else "windows-xp" else if (v.major == 5 and v.minor == 0) info.system_id = if ((info.product_type orelse 0) == 0) "windows-2000" else "windows-2000-server";
    }
    return info;
}

test "real beta metadata values, synthetic source text, filenames are irrelevant" {
    const sif = "[SetupData]\nMajorVersion=5\nMinorVersion=1\nProductType=0\nArchitecture=i386\n[nls]\nDefaultLayout=00000409\n";
    const w = inspect(.{ .txtsetup = sif, .setupp = "[Pid]\nPid=55034000\n", .setup_version = .{ .major = 5, .minor = 1, .build = 2542 } });
    try std.testing.expectEqualStrings("windows-whistler", w.system_id.?);
    try std.testing.expectEqual(media.Arch.x86, w.arch);
    try std.testing.expectEqual(@as(?u32, 0x409), w.locale);
    try std.testing.expectEqualStrings("windows-neptune", inspect(.{ .setup_version = .{ .major = 5, .minor = 50, .build = 5111 } }).system_id.?);
    const flp = inspect(.{ .txtsetup = "[SetupData]\nMajorVersion=5\nMinorVersion=2\nProductType=1\nArchitecture=i386\n", .flp_wim = true });
    try std.testing.expect(flp.pe_installer);
    try std.testing.expectEqualStrings("windows-flp", flp.system_id.?);
    try std.testing.expect(inspect(.{}).system_id == null);
}

/// A bounded caller-owned setup executable, never a filename-derived version.
/// NT versions store build in FileVersionLS.high; 9x setup resources often
/// use 4.10.0.999 / 4.90.0.2525, with build in the low word instead.
pub fn setupVersion(bytes: []const u8, lineage: release.Version.Lineage) ?release.Version {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return null;
    const offset: usize = std.mem.readInt(u32, bytes[60..64], .little);
    if (offset > bytes.len or bytes.len - offset < 2) return null;
    const pe_header = bytes.len - offset >= 4 and std.mem.eql(u8, bytes[offset .. offset + 4], "PE\x00\x00");
    if (!pe_header and !std.mem.eql(u8, bytes[offset .. offset + 2], "NE")) return null;
    const magic = "\xbd\x04\xef\xfe\x00\x00\x01\x00";
    const at = std.mem.indexOf(u8, bytes, magic) orelse return null;
    if (bytes.len - at < 16) return null;
    const ms = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little);
    const ls = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little);
    return .{ .major = @intCast(ms >> 16), .minor = @truncate(ms), .build = if (lineage == .win9x and ls >> 16 == 0) ls & 0xffff else ls >> 16, .lineage = lineage };
}

test "validated PE and NE resource versions with different build word conventions" {
    var bytes: [128]u8 = @splat(0);
    @memcpy(bytes[0..2], "MZ");
    std.mem.writeInt(u32, bytes[60..64], 64, .little);
    @memcpy(bytes[64..66], "NE");
    @memcpy(bytes[80..88], "\xbd\x04\xef\xfe\x00\x00\x01\x00");
    std.mem.writeInt(u32, bytes[88..92], (4 << 16) | 10, .little);
    std.mem.writeInt(u32, bytes[92..96], 999, .little);
    try std.testing.expectEqual(@as(u32, 999), setupVersion(&bytes, .win9x).?.build);
    bytes[64] = 'X';
    try std.testing.expect(setupVersion(&bytes, .win9x) == null);
}

test "legacy synthetic fixtures preserve SKU, locale, setup lineage and unknown build" {
    const w = inspect(.{ .txtsetup = @embedFile("testdata/variants/whistler.sif"), .setup_version = .{ .major = 5, .minor = 1, .build = 2542, .lineage = .nt } });
    try std.testing.expectEqualStrings("windows-whistler", w.system_id.?);
    const n = inspect(.{ .txtsetup = @embedFile("testdata/variants/neptune.sif"), .setup_version = .{ .major = 5, .minor = 50, .build = 5111, .lineage = .nt } });
    try std.testing.expectEqualStrings("windows-neptune", n.system_id.?);
    const wf = inspect(.{ .txtsetup = @embedFile("testdata/variants/winframe.sif"), .prodspec = "[Product Specification]\nProduct=Citrix WinFrame\n" });
    try std.testing.expectEqualStrings("citrix-winframe-1-8", wf.system_id.?);
    try std.testing.expectEqual(@as(?u8, 1), wf.product_type);
    const no_build = inspect(.{ .txtsetup = @embedFile("testdata/variants/whistler.sif") });
    try std.testing.expectEqualStrings("windows-xp", no_build.system_id.?);
    try std.testing.expectEqual(@as(u32, 0), no_build.version.?.build);
    try std.testing.expect(inspect(.{ .setupp = "[Pid]\nPid=76447OEM\n" }).channel == .oem);
    try std.testing.expect(inspect(.{ .setupp = "[Pid]\nPid=69917270\n" }).channel == .volume);
    try std.testing.expect(inspect(.{ .setupp = "[Pid]\nPid=76447000\n" }).channel == .retail);
    const mce = inspect(.{ .setup_version = .{ .major = 5, .minor = 1, .build = 2600 }, .media_center = true });
    try std.testing.expectEqualStrings("windows-xp-mce", mce.system_id.?);
}
