const std = @import("std");
pub const Xml = struct { offset: u64, size: usize };
pub const Setup = struct {
    index: u32,
    major: u32,
    minor: u32,
    // Zero means absent metadata; never sufficient to qualify an external donor.
    build: u32 = 0,
    pub fn isWindows10Donor(self: Setup) bool {
        return self.major == 10 and self.minor == 0 and self.build >= 10240 and self.build < 22000;
    }
    pub fn isModern(self: Setup) bool {
        return self.major > 6 or (self.major == 6 and self.minor >= 2);
    }
    pub fn label(self: Setup) []const u8 {
        return if (self.major >= 10) "Windows 10/11 PE x64" else if (self.isModern()) "Windows 8/8.1 PE x64" else "Windows 7 PE x64 (6.1)";
    }
    pub fn usbLabel(self: Setup) []const u8 {
        return if (self.isModern()) "Native USB 3 stack; Win7 target drivers are separate" else "No native USB 3 stack; load matching driver packages";
    }
};

pub fn bootIndex(header: []const u8) !u32 {
    if (header.len < 124) return error.InvalidWimHeader;
    const count = std.mem.readInt(u32, header[44..48], .little);
    const index = std.mem.readInt(u32, header[120..124], .little);
    if (index == 0 or index > count) return error.WindowsSetupIndexMissing;
    return index;
}

test "declared boot index selects single-index and modified Setup images" {
    var header = [_]u8{0} ** 124;
    std.mem.writeInt(u32, header[44..48], 1, .little);
    std.mem.writeInt(u32, header[120..124], 1, .little);
    try std.testing.expectEqual(@as(u32, 1), try bootIndex(&header));
    std.mem.writeInt(u32, header[120..124], 2, .little);
    try std.testing.expectError(error.WindowsSetupIndexMissing, bootIndex(&header));
    const metadata = "<WIM><IMAGE INDEX=\"1\"><WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR></VERSION></WINDOWS></IMAGE></WIM>";
    var bytes: [metadata.len * 2 + 2]u8 = undefined;
    bytes[0] = 0xff; bytes[1] = 0xfe;
    for (metadata, 0..) |ch, i| { bytes[2 + i * 2] = ch; bytes[3 + i * 2] = 0; }
    const detected = try detectX64Setup(&bytes, 1);
    try std.testing.expect(detected.isModern());
    try std.testing.expectEqual(@as(u32, 1), detected.index);
    try std.testing.expectEqualStrings("Windows 10/11 PE x64", detected.label());
}

pub fn xmlResource(header: []const u8, wim_size: u64) !Xml {
    if (header.len < 124 or !std.mem.eql(u8, header[0..8], "MSWIM\x00\x00\x00")) return error.InvalidWimHeader;
    if (std.mem.readInt(u32, header[44..48], .little) == 0) return error.WindowsSetupIndexMissing;
    const encoded = std.mem.readInt(u64, header[72..80], .little);
    const offset = std.mem.readInt(u64, header[80..88], .little);
    const size = std.mem.readInt(u64, header[88..96], .little);
    const flags = encoded >> 56;
    if ((flags != 0 and flags != 2) or (encoded & 0x00ffffffffffffff) != size or size < 4 or size > 1024 * 1024 or size % 2 != 0 or offset > wim_size or size > wim_size - offset) return error.InvalidWimXml;
    return .{ .offset = offset, .size = @intCast(size) };
}

// XML text in WIM is UTF-16LE; only ASCII metadata tags are needed here.
pub fn hasModernX64Setup(xml: []u8) !bool {
    return (try detectX64Setup(xml, 2)).isModern();
}

pub fn detectX64Setup(xml: []u8, index: u32) !Setup {
    if (xml.len % 2 != 0 or xml.len < 4 or xml[0] != 0xff or xml[1] != 0xfe) return error.InvalidWimXml;
    const length = xml.len / 2 - 1;
    for (0..length) |i| xml[i] = if (xml[3 + 2 * i] == 0) xml[2 + 2 * i] else '?';
    const text = xml[0..length];
    var tag_buffer: [48]u8 = undefined;
    const tag = try std.fmt.bufPrint(&tag_buffer, "<IMAGE INDEX=\"{d}\">", .{index});
    const begin = std.mem.indexOf(u8, text, tag) orelse return error.WindowsSetupIndexMissing;
    const rest = text[begin..];
    const end = std.mem.indexOf(u8, rest, "</IMAGE>") orelse return error.InvalidWimXml;
    const entry = rest[0..end];
    if (std.mem.indexOf(u8, entry[1..], "<IMAGE") != null or
        std.mem.indexOf(u8, rest[end + 8 ..], tag) != null) return error.InvalidWimXml;
    const arch = try number(entry, "ARCH");
    if (arch != 9) return error.WindowsSetupRequiresX64;
    const major = try number(entry, "MAJOR");
    const minor = try number(entry, "MINOR");
    if (major < 6 or (major == 6 and minor == 0)) return error.UnsupportedWindowsSetupVersion;
    const build = if (std.mem.indexOf(u8, entry, "<BUILD>") != null) try number(entry, "BUILD") else 0;
    return .{ .index = index, .major = major, .minor = minor, .build = build };
}
fn number(xml: []const u8, comptime tag: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, xml, "<" ++ tag ++ ">") orelse return error.InvalidWimXml) + tag.len + 2;
    const rest = xml[start..];
    const end = std.mem.indexOf(u8, rest, "</" ++ tag ++ ">") orelse return error.InvalidWimXml;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch return error.InvalidWimXml;
}

// Conservative applicability gate: never add SP1 packages to mixed/RTM media.
pub fn allWindows7Sp1X64(xml: []u8) bool {
    return (inspectWin7Install(xml) catch return false).sp1;
}

pub const Win7Mode = enum {
    original,
    hybrid,
    unsupported,

    pub fn label(self: Win7Mode) []const u8 {
        return switch (self) {
            .original => "Win7 x64 / native PE7 -> external PE10",
            .hybrid => "Win7 x64 hybrid / own modern PE and Setup",
            .unsupported => "Unsupported installation target",
        };
    }
};

pub const InstallInfo = struct { count: u32, sp1: bool };

// Consumes UTF-16LE metadata once. Identity (6.1 x64) is independent of SP1.
// Version metadata identifies a layout, not the authenticity of an original ISO.
pub fn inspectWin7Install(xml: []u8) !InstallInfo {
    return inspectInstall(xml, false);
}

pub fn inspectVistaSp2Install(xml: []u8) !InstallInfo {
    return inspectInstall(xml, true);
}

test "Vista donor route accepts only all-SP2-x64 install images" {
    const cases = [_]struct { arch: u32, minor: u32, build: u32, ok: bool }{
        .{ .arch = 9, .minor = 0, .build = 6002, .ok = true },
        .{ .arch = 0, .minor = 0, .build = 6002, .ok = false },
        .{ .arch = 9, .minor = 0, .build = 6001, .ok = false },
        .{ .arch = 9, .minor = 0, .build = 6003, .ok = false },
        .{ .arch = 9, .minor = 1, .build = 7601, .ok = false },
    };
    for (cases) |c| {
        var ascii: [700]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>0</MINOR><BUILD>6002</BUILD></IMAGE><IMAGE INDEX=\"2\"><ARCH>{d}</ARCH><MAJOR>6</MAJOR><MINOR>{d}</MINOR><BUILD>{d}</BUILD></IMAGE></WIM>", .{ c.arch, c.minor, c.build });
        var bytes: [1402]u8 = undefined;
        bytes[0] = 0xff; bytes[1] = 0xfe;
        for (text, 0..) |ch, i| { bytes[2 + i * 2] = ch; bytes[3 + i * 2] = 0; }
        const ok = if (inspectVistaSp2Install(bytes[0 .. 2 + text.len * 2])) |info| info.count == 2 else |_| false;
        try std.testing.expectEqual(c.ok, ok);
    }
}

fn inspectInstall(xml: []u8, vista: bool) !InstallInfo {
    if (xml.len < 4 or xml.len % 2 != 0 or xml[0] != 0xff or xml[1] != 0xfe) return error.InvalidWimXml;
    const length = xml.len / 2 - 1;
    for (0..length) |i| xml[i] = if (xml[3 + i * 2] == 0) xml[2 + i * 2] else '?';
    var rest = xml[0..length];
    var info = InstallInfo{ .count = 0, .sp1 = true };
    while (std.mem.indexOf(u8, rest, "<IMAGE")) |start| {
        rest = rest[start..];
        // WIM image indices are contiguous and one-based. Do not silently skip
        // an IMAGE with malformed attributes, duplicate index or missing index.
        const prefix = "<IMAGE INDEX=\"";
        if (!std.mem.startsWith(u8, rest, prefix)) return error.InvalidWimXml;
        const index_end = std.mem.indexOfScalarPos(u8, rest, prefix.len, '"') orelse return error.InvalidWimXml;
        const index = std.fmt.parseInt(u32, rest[prefix.len..index_end], 10) catch return error.InvalidWimXml;
        if (index != info.count + 1 or !std.mem.startsWith(u8, rest[index_end..], "\">")) return error.InvalidWimXml;
        const end = std.mem.indexOf(u8, rest, "</IMAGE>") orelse return error.InvalidWimXml;
        const entry = rest[0..end];
        // A nested/unclosed IMAGE must not hide an unsupported edition.
        if (std.mem.indexOf(u8, entry[1..], "<IMAGE") != null) return error.InvalidWimXml;
        if (try number(entry, "ARCH") != 9 or try number(entry, "MAJOR") != 6 or
            try number(entry, "MINOR") != @as(u32, if (vista) 0 else 1))
            return if (vista) error.VistaRequiresSp2X64 else error.UnsupportedWindows7InstallTarget;
        const build = if (std.mem.indexOf(u8, entry, "<BUILD>") != null) try number(entry, "BUILD") else 0;
        if (vista and build != 6002) return error.VistaRequiresSp2X64;
        info.sp1 = info.sp1 and build == 7601;
        info.count += 1;
        rest = rest[end + 8 ..];
    }
    if (info.count == 0) return error.UnsupportedWindows7InstallTarget;
    return info;
}

pub fn isWin7OriginalBoot(setup: Setup) bool {
    return setup.major == 6 and setup.minor == 1;
}
pub fn isHybridBoot(setup: Setup) bool {
    return setup.isModern();
}
pub fn classifyWin7Boot(boot: Setup) Win7Mode {
    return if (isWin7OriginalBoot(boot)) .original else if (isHybridBoot(boot)) .hybrid else .unsupported;
}
pub fn classifyWin7(boot: Setup, install_xml: []u8) Win7Mode {
    _ = inspectWin7Install(install_xml) catch return .unsupported;
    return classifyWin7Boot(boot);
}

test "NVMe servicing applicability excludes RTM and mixed installation images" {
    for ([_][]const u8{ "7601", "7600" }) |build| {
        var ascii: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>{s}</BUILD></IMAGE></WIM>", .{build});
        var bytes: [1024]u8 = undefined;
        bytes[0] = 0xff; bytes[1] = 0xfe;
        for (text, 0..) |ch, i| { bytes[2 + 2 * i] = ch; bytes[3 + 2 * i] = 0; }
        try std.testing.expectEqual(std.mem.eql(u8, build, "7601"), allWindows7Sp1X64(bytes[0 .. 2 + text.len * 2]));
    }
}

test "Setup metadata scopes native UEFI to modern x64 WinPE, not ESD extension" {
    const template = "<WIM><IMAGE INDEX=\"2\"><WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>6</MAJOR><MINOR>1</MINOR></VERSION></WINDOWS></IMAGE></WIM>";
    var buffer: [2 + template.len * 2]u8 = undefined;
    for ([_]u8{ '1', '2' }) |minor| {
        buffer[0] = 0xff; buffer[1] = 0xfe;
        for (template, 0..) |ch, i| { buffer[2 + i * 2] = ch; buffer[3 + i * 2] = 0; }
        const at = std.mem.indexOf(u8, template, "<MINOR>").? + 7;
        buffer[2 + at * 2] = minor;
        try std.testing.expectEqual(minor == '2', try hasModernX64Setup(&buffer));
    }
    var header = [_]u8{0} ** 124;
    @memcpy(header[0..8], "MSWIM\x00\x00\x00");
    std.mem.writeInt(u32, header[44..48], 2, .little);
    std.mem.writeInt(u64, header[72..80], 0x0200000000000064, .little);
    std.mem.writeInt(u64, header[80..88], 900, .little);
    std.mem.writeInt(u64, header[88..96], 100, .little);
    try std.testing.expectEqual(@as(u64, 900), (try xmlResource(&header, 1000)).offset);
    try std.testing.expectError(error.InvalidWimXml, xmlResource(&header, 999));
    std.mem.writeInt(u64, header[72..80], 0x0600000000000064, .little);
    try std.testing.expectError(error.InvalidWimXml, xmlResource(&header, 1000));
}

test "Win7 x64 RTM and SP1 identity excludes other targets" {
    const boot_cases = [_]struct { major: u32, minor: u32, original: bool, hybrid: bool }{
        .{ .major = 6, .minor = 1, .original = true, .hybrid = false },
        .{ .major = 10, .minor = 0, .original = false, .hybrid = true },
        .{ .major = 6, .minor = 2, .original = false, .hybrid = true },
        .{ .major = 6, .minor = 3, .original = false, .hybrid = true },
    };
    for (boot_cases) |c| {
        var ascii: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "<WIM><IMAGE INDEX=\"1\"><WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>{d}</MAJOR><MINOR>{d}</MINOR></VERSION></WINDOWS></IMAGE></WIM>", .{ c.major, c.minor });
        var bytes: [512]u8 = undefined;
        bytes[0] = 0xff; bytes[1] = 0xfe;
        for (text, 0..) |ch, i| { bytes[2 + 2 * i] = ch; bytes[3 + 2 * i] = 0; }
        const setup = try detectX64Setup(bytes[0 .. 2 + text.len * 2], 1);
        try std.testing.expectEqual(c.original, isWin7OriginalBoot(setup));
        try std.testing.expectEqual(c.hybrid, isHybridBoot(setup));
    }
    const install_cases = [_]struct { arch: u32, major: u32, minor: u32, build: u32, supported: bool }{
        .{ .arch = 9, .major = 6, .minor = 1, .build = 7601, .supported = true },
        .{ .arch = 9, .major = 6, .minor = 1, .build = 7600, .supported = true },
        .{ .arch = 9, .major = 6, .minor = 0, .build = 6003, .supported = false },
        .{ .arch = 9, .major = 6, .minor = 0, .build = 6002, .supported = false },
        .{ .arch = 9, .major = 6, .minor = 0, .build = 6001, .supported = false },
        .{ .arch = 9, .major = 6, .minor = 0, .build = 6000, .supported = false },
        .{ .arch = 0, .major = 6, .minor = 1, .build = 7601, .supported = false },
        .{ .arch = 0, .major = 6, .minor = 0, .build = 6002, .supported = false },
        .{ .arch = 9, .major = 10, .minor = 0, .build = 19045, .supported = false },
    };
    for (install_cases) |c| {
        var ascii: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&ascii, "<WIM><IMAGE INDEX=\"1\"><ARCH>{d}</ARCH><MAJOR>{d}</MAJOR><MINOR>{d}</MINOR><BUILD>{d}</BUILD></IMAGE></WIM>", .{ c.arch, c.major, c.minor, c.build });
        var bytes: [512]u8 = undefined;
        bytes[0] = 0xff; bytes[1] = 0xfe;
        for (text, 0..) |ch, i| { bytes[2 + 2 * i] = ch; bytes[3 + 2 * i] = 0; }
        const supported = if (inspectWin7Install(bytes[0 .. 2 + text.len * 2])) |_| true else |_| false;
        try std.testing.expectEqual(c.supported, supported);
    }
}

test "Win7 runtime classification separates native PE7 from hybrid" {
    const Case = struct { boot_major: u32, boot_minor: u32, install: []const u8, expected: Win7Mode };
    const cases = [_]Case{
        .{ .boot_major = 6, .boot_minor = 1, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE></WIM>", .expected = .original },
        .{ .boot_major = 10, .boot_minor = 0, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE></WIM>", .expected = .hybrid },
        .{ .boot_major = 10, .boot_minor = 0, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7600</BUILD></IMAGE></WIM>", .expected = .hybrid },
        .{ .boot_major = 6, .boot_minor = 1, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7600</BUILD></IMAGE></WIM>", .expected = .original },
        .{ .boot_major = 10, .boot_minor = 0, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE><IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>19045</BUILD></IMAGE></WIM>", .expected = .unsupported },
        .{ .boot_major = 6, .boot_minor = 3, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE></WIM>", .expected = .hybrid },
        .{ .boot_major = 10, .boot_minor = 0, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>0</ARCH><MAJOR>6</MAJOR><MINOR>0</MINOR><BUILD>6002</BUILD></IMAGE></WIM>", .expected = .unsupported },
        .{ .boot_major = 6, .boot_minor = 1, .install = "<WIM><IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>0</MINOR><BUILD>6003</BUILD></IMAGE></WIM>", .expected = .unsupported },
    };
    for (cases) |c| {
        var boot_ascii: [256]u8 = undefined;
        const boot_text = try std.fmt.bufPrint(&boot_ascii, "<WIM><IMAGE INDEX=\"1\"><WINDOWS><ARCH>9</ARCH><VERSION><MAJOR>{d}</MAJOR><MINOR>{d}</MINOR></VERSION></WINDOWS></IMAGE></WIM>", .{ c.boot_major, c.boot_minor });
        var boot_bytes: [512]u8 = undefined;
        boot_bytes[0] = 0xff; boot_bytes[1] = 0xfe;
        for (boot_text, 0..) |ch, i| { boot_bytes[2 + 2 * i] = ch; boot_bytes[3 + 2 * i] = 0; }
        const boot = try detectX64Setup(boot_bytes[0 .. 2 + boot_text.len * 2], 1);
        var install_bytes: [1024]u8 = undefined;
        install_bytes[0] = 0xff; install_bytes[1] = 0xfe;
        for (c.install, 0..) |ch, i| { install_bytes[2 + 2 * i] = ch; install_bytes[3 + 2 * i] = 0; }
        try std.testing.expectEqual(c.expected, classifyWin7(boot, install_bytes[0 .. 2 + c.install.len * 2]));
    }
}
