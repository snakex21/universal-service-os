//! Windows INF driver packages from DATA\Drivers\<Windows version>\ (docs/
//! drivers.md): what USOS checks before it hands a user package to Windows
//! Setup. Windows itself still does the hardware and signature matching;
//! these checks only keep packages out that cannot work on the target and
//! explain why in the log:
//!   - architecture: the [Manufacturer] decorations (NTamd64 / NTx86;
//!     undecorated or "NT" without an architecture = x86 only, as 64-bit
//!     Windows requires decorated models sections);
//!   - signature: 64-bit Vista/7/8/10/11 load only signed drivers, so an INF
//!     without its catalog (CatalogFile[.NTamd64] present next to it) is
//!     skipped for x64 targets (never bypassed); on x86 it is only flagged;
//!   - completeness: every [SourceDisksFiles] entry for the target must be
//!     in the package folder (its own tree);
//!   - form: a text file with a [Version] section and a Signature.
//! Malformed input never fails: it yields a verdict and the next package
//! is checked. Pure code; used by src/platform/uefi/windows_driver_files.zig
//! (Windows 7 RAM archive) and the micro-Linux stager (Windows 10/11 WORK).
const std = @import("std");

pub const Arch = enum {
    x86,
    amd64,

    pub fn label(self: Arch) []const u8 {
        return switch (self) {
            .x86 => "x86",
            .amd64 => "amd64",
        };
    }
};

pub const ArchSet = struct {
    x86: bool = false,
    amd64: bool = false,
    /// ia64, arm, arm64: never used by USOS targets.
    other: bool = false,

    pub fn has(self: ArchSet, arch: Arch) bool {
        return switch (arch) {
            .x86 => self.x86,
            .amd64 => self.amd64,
        };
    }
};

pub const max_files = 256;

pub const FileArch = enum { any, x86, amd64, other };

pub const SourceFile = struct { name: []const u8, arch: FileArch };

pub const Info = struct {
    has_version: bool = false,
    signature: []const u8 = "",
    class: []const u8 = "",
    provider: []const u8 = "",
    driver_ver: []const u8 = "",
    catalog_any: ?[]const u8 = null,
    catalog_nt: ?[]const u8 = null,
    catalog_x86: ?[]const u8 = null,
    catalog_amd64: ?[]const u8 = null,
    arches: ArchSet = .{},
    manufacturer_entries: usize = 0,
    files: [max_files]SourceFile = undefined,
    file_count: usize = 0,
    files_truncated: bool = false,

    pub fn sourceFiles(self: *const Info) []const SourceFile {
        return self.files[0..self.file_count];
    }

    /// The catalog Windows looks for on `arch` (most specific first).
    pub fn catalogFor(self: *const Info, arch: Arch) ?[]const u8 {
        const specific = switch (arch) {
            .x86 => self.catalog_x86,
            .amd64 => self.catalog_amd64,
        };
        return specific orelse self.catalog_nt orelse self.catalog_any;
    }
};

/// INF text as bytes USOS can parse: UTF-16LE (with or without BOM) is
/// narrowed to ASCII ('?' for anything else), a UTF-8 BOM is dropped.
pub fn decodeText(bytes: []const u8, out: []u8) []const u8 {
    var utf16 = false;
    var start: usize = 0;
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE) {
        utf16 = true;
        start = 2;
    } else if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xEF\xBB\xBF")) {
        start = 3;
    } else if (bytes.len >= 8) {
        // No BOM: ASCII text as UTF-16LE has a zero at every odd offset.
        var zeros: usize = 0;
        var i: usize = 1;
        while (i < @min(bytes.len, 64)) : (i += 2) {
            if (bytes[i] == 0) zeros += 1;
        }
        utf16 = zeros * 2 >= @min(bytes.len, 64) / 2 and zeros >= 3;
    }
    if (!utf16) {
        const n = @min(bytes.len - start, out.len);
        @memcpy(out[0..n], bytes[start .. start + n]);
        return out[0..n];
    }
    var used: usize = 0;
    var i = start;
    while (i + 1 < bytes.len and used < out.len) : (i += 2) {
        out[used] = if (bytes[i + 1] == 0) bytes[i] else '?';
        used += 1;
    }
    return out[0..used];
}

fn stripComment(line: []const u8) []const u8 {
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quotes = !in_quotes;
        if (!in_quotes and c == ';') return line[0..i];
    }
    return line;
}

fn unquote(value: []const u8) []const u8 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

fn sectionIs(section: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(section, name);
}

fn decorationArch(decoration: []const u8) ?FileArch {
    const d = std.mem.trim(u8, decoration, " \t");
    if (d.len < 2 or !std.ascii.eqlIgnoreCase(d[0..2], "nt")) return null;
    const rest = d[2..];
    if (rest.len == 0 or rest[0] == '.') return .x86;
    const arch_end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const arch = rest[0..arch_end];
    if (std.ascii.eqlIgnoreCase(arch, "amd64")) return .amd64;
    if (std.ascii.eqlIgnoreCase(arch, "x86")) return .x86;
    return .other;
}

/// Parses INF text (already decoded). Slices point into `text`.
pub fn parse(text: []const u8) Info {
    var info = Info{};
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r\x00\x1a");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = std.mem.trim(u8, line[1..close], " \t");
            if (sectionIs(section, "Version")) info.has_version = true;
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=');
        const key = std.mem.trim(u8, if (equals) |e| line[0..e] else line, " \t");
        const value = if (equals) |e| std.mem.trim(u8, line[e + 1 ..], " \t") else "";
        if (sectionIs(section, "Version")) {
            if (std.ascii.eqlIgnoreCase(key, "Signature")) info.signature = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "Class")) info.class = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "Provider")) info.provider = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "DriverVer")) info.driver_ver = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "CatalogFile")) info.catalog_any = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "CatalogFile.NT")) info.catalog_nt = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "CatalogFile.NTx86")) info.catalog_x86 = unquote(value);
            if (std.ascii.eqlIgnoreCase(key, "CatalogFile.NTamd64")) info.catalog_amd64 = unquote(value);
        } else if (sectionIs(section, "Manufacturer")) {
            info.manufacturer_entries += 1;
            // name = models[, decoration, ...]; no decoration = x86 only.
            var parts = std.mem.splitScalar(u8, value, ',');
            _ = parts.next();
            var decorated = false;
            while (parts.next()) |part| {
                const arch = decorationArch(part) orelse continue;
                decorated = true;
                switch (arch) {
                    .x86 => info.arches.x86 = true,
                    .amd64 => info.arches.amd64 = true,
                    .other => info.arches.other = true,
                    .any => {},
                }
            }
            if (!decorated) info.arches.x86 = true;
        } else if (std.ascii.startsWithIgnoreCase(section, "SourceDisksFiles")) {
            const suffix = section["SourceDisksFiles".len..];
            const arch: FileArch = if (suffix.len == 0) .any else if (std.ascii.eqlIgnoreCase(suffix, ".x86")) .x86 else if (std.ascii.eqlIgnoreCase(suffix, ".amd64")) .amd64 else .other;
            const name = unquote(key);
            if (name.len == 0) continue;
            if (info.file_count == max_files) {
                info.files_truncated = true;
                continue;
            }
            info.files[info.file_count] = .{ .name = name, .arch = arch };
            info.file_count += 1;
        }
    }
    return info;
}

pub const Verdict = enum {
    use,
    /// Usable on x86, but no catalog: Windows may ask or refuse.
    use_unsigned,
    not_an_inf,
    no_models,
    wrong_arch,
    unsigned_x64,
    missing_file,

    pub fn accepted(self: Verdict) bool {
        return self == .use or self == .use_unsigned;
    }

    pub fn text(self: Verdict) []const u8 {
        return switch (self) {
            .use => "use",
            .use_unsigned => "use (unsigned: no catalog; 32-bit Windows may warn)",
            .not_an_inf => "skip: not a driver INF ([Version] Signature missing)",
            .no_models => "skip: no [Manufacturer] entries (not a device driver package)",
            .wrong_arch => "skip: no models for the target architecture",
            .unsigned_x64 => "skip: unsigned (no catalog) - 64-bit Windows loads only signed drivers",
            .missing_file => "skip: a file listed in [SourceDisksFiles] is missing",
        };
    }
};

pub const Judgement = struct {
    verdict: Verdict,
    /// The target architecture that was accepted (or checked).
    arch: Arch,
    missing: []const u8 = "",
};

/// `hasFile(context, name)`: the package tree contains `name`
/// (case-insensitive file name).
pub fn judge(info: *const Info, targets: []const Arch, context: ?*anyopaque, hasFile: *const fn (?*anyopaque, []const u8) bool) Judgement {
    const first = if (targets.len != 0) targets[0] else Arch.amd64;
    if (!info.has_version or info.signature.len == 0) return .{ .verdict = .not_an_inf, .arch = first };
    if (info.manufacturer_entries == 0) return .{ .verdict = .no_models, .arch = first };
    var best: ?Judgement = null;
    for (targets) |arch| {
        if (!info.arches.has(arch)) continue;
        for (info.sourceFiles()) |file| {
            const applies = switch (file.arch) {
                .any => true,
                .x86 => arch == .x86,
                .amd64 => arch == .amd64,
                .other => false,
            };
            if (applies and !hasFile(context, file.name)) {
                if (best == null) best = .{ .verdict = .missing_file, .arch = arch, .missing = file.name };
                break;
            }
        } else {
            const catalog = info.catalogFor(arch);
            const signed = if (catalog) |name| hasFile(context, name) else false;
            if (signed) return .{ .verdict = .use, .arch = arch };
            if (arch == .x86) return .{ .verdict = .use_unsigned, .arch = arch };
            if (best == null or best.?.verdict == .missing_file) best = .{ .verdict = .unsigned_x64, .arch = arch };
        }
    }
    return best orelse .{ .verdict = .wrong_arch, .arch = first };
}

/// Drivers\<OS>\<Class>\...: Storage and USB are boot-critical (loaded in
/// Windows Setup and injected), everything else is Other (injected only).
pub const Class = enum {
    storage,
    usb,
    other,

    pub fn fromFolder(name: []const u8) Class {
        if (std.ascii.eqlIgnoreCase(name, "Storage")) return .storage;
        if (std.ascii.eqlIgnoreCase(name, "USB")) return .usb;
        return .other;
    }

    pub fn folder(self: Class) []const u8 {
        return switch (self) {
            .storage => "Storage",
            .usb => "USB",
            .other => "Other",
        };
    }
};

/// "Storage", "USB" or "Other" exactly (case-insensitive): the class
/// folders directly under Drivers\<OS>.
pub fn isClassFolder(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Storage") or std.ascii.eqlIgnoreCase(name, "USB") or std.ascii.eqlIgnoreCase(name, "Other");
}

/// The package that owns folder `start`: the folder itself when it holds an
/// .inf, else the nearest ancestor holding one - but ownership never
/// passes through a boundary (Drivers\<OS> and its class folders), so an
/// .inf lying loose in Drivers\<OS> or Drivers\<OS>\Other does not swallow
/// unrelated sub-folders. `Dir` needs `inf_count`, `parent: ?u16` and
/// `boundary: bool`.
pub fn owner(comptime Dir: type, dirs: []const Dir, start: u16) ?u16 {
    var current: u16 = start;
    while (true) {
        const dir = &dirs[current];
        if (dir.inf_count != 0 and (current == start or !dir.boundary)) return current;
        if (dir.boundary) return null;
        current = dir.parent orelse return null;
    }
}

// ------------------------------------------------------------ tests

test "package ownership stops at Drivers\\<OS> and the class folders" {
    const D = struct { inf_count: usize, parent: ?u16, boundary: bool };
    // 0 root (loose .inf), 1 Other (boundary), 2 Other\junk, 3 Other\Pkg (.inf),
    // 4 Other\Pkg\amd64, 5 Other\Pkg\amd64\deep
    const dirs = [_]D{
        .{ .inf_count = 1, .parent = null, .boundary = true },
        .{ .inf_count = 0, .parent = 0, .boundary = true },
        .{ .inf_count = 0, .parent = 1, .boundary = false },
        .{ .inf_count = 2, .parent = 1, .boundary = false },
        .{ .inf_count = 0, .parent = 3, .boundary = false },
        .{ .inf_count = 0, .parent = 4, .boundary = false },
    };
    try testing.expectEqual(@as(?u16, 0), owner(D, &dirs, 0));
    try testing.expectEqual(@as(?u16, null), owner(D, &dirs, 1));
    try testing.expectEqual(@as(?u16, null), owner(D, &dirs, 2));
    try testing.expectEqual(@as(?u16, 3), owner(D, &dirs, 3));
    try testing.expectEqual(@as(?u16, 3), owner(D, &dirs, 5));
    try testing.expect(isClassFolder("usb") and !isClassFolder("USB3"));
}

const testing = std.testing;

const TestTree = struct {
    names: []const []const u8,
    fn has(context: ?*anyopaque, name: []const u8) bool {
        const self: *const TestTree = @ptrCast(@alignCast(context.?));
        for (self.names) |present| if (std.ascii.eqlIgnoreCase(present, name)) return true;
        return false;
    }
};

const x64_storage =
    \\; Intel RST sample
    \\[Version]
    \\Signature="$WINDOWS NT$"
    \\Class=SCSIAdapter
    \\Provider=%INTEL%
    \\CatalogFile.NTamd64=iaStorAC.cat
    \\DriverVer=01/01/2020,17.8.0.1065
    \\
    \\[Manufacturer]
    \\%INTEL% = INTEL, NTamd64.10.0, NTamd64.6.1
    \\
    \\[SourceDisksNames]
    \\1 = %DiskName%,,,
    \\
    \\[SourceDisksFiles]
    \\iaStorAC.sys = 1
    \\[SourceDisksFiles.amd64]
    \\iaStorAfs.sys = 1,,
    \\[SourceDisksFiles.ia64]
    \\ia64only.sys = 1
;

test "INF: x64 storage package is used on amd64 only when complete and signed" {
    const info = parse(x64_storage);
    try testing.expect(info.has_version);
    try testing.expectEqualStrings("$WINDOWS NT$", info.signature);
    try testing.expectEqualStrings("SCSIAdapter", info.class);
    try testing.expect(info.arches.amd64 and !info.arches.x86);
    try testing.expectEqualStrings("iaStorAC.cat", info.catalogFor(.amd64).?);
    try testing.expect(info.catalogFor(.x86) == null);
    try testing.expectEqual(@as(usize, 3), info.file_count);

    var complete = TestTree{ .names = &.{ "IASTORAC.SYS", "iaStorAfs.sys", "iaStorAC.cat", "iaStorAC.inf" } };
    const ok = judge(&info, &.{.amd64}, &complete, TestTree.has);
    try testing.expectEqual(Verdict.use, ok.verdict);
    // x86 target: wrong architecture.
    try testing.expectEqual(Verdict.wrong_arch, judge(&info, &.{.x86}, &complete, TestTree.has).verdict);
    // Missing file (ia64-only entries do not count).
    var missing = TestTree{ .names = &.{ "iaStorAC.sys", "iaStorAC.cat" } };
    const miss = judge(&info, &.{.amd64}, &missing, TestTree.has);
    try testing.expectEqual(Verdict.missing_file, miss.verdict);
    try testing.expectEqualStrings("iaStorAfs.sys", miss.missing);
    // No catalog on x64: skipped, never bypassed.
    var unsigned = TestTree{ .names = &.{ "iaStorAC.sys", "iaStorAfs.sys" } };
    try testing.expectEqual(Verdict.unsigned_x64, judge(&info, &.{.amd64}, &unsigned, TestTree.has).verdict);
}

test "INF: decorations, undecorated x86, both architectures, broken files" {
    const both = parse("[Version]\nSignature=\"$Windows NT$\"\nCatalogFile=d.cat\n[Manufacturer]\n%M%=M,NTx86,NTamd64,NTarm64\n");
    try testing.expect(both.arches.x86 and both.arches.amd64 and both.arches.other);
    var tree = TestTree{ .names = &.{"d.cat"} };
    const dual = judge(&both, &.{ .x86, .amd64 }, &tree, TestTree.has);
    try testing.expectEqual(Verdict.use, dual.verdict);
    try testing.expectEqual(Arch.x86, dual.arch);

    const plain = parse("[version]\r\nsignature=$chicago$\r\n[manufacturer]\r\n%M%=Models\r\n");
    try testing.expect(plain.arches.x86 and !plain.arches.amd64);
    var empty = TestTree{ .names = &.{} };
    try testing.expectEqual(Verdict.use_unsigned, judge(&plain, &.{.x86}, &empty, TestTree.has).verdict);
    try testing.expectEqual(Verdict.wrong_arch, judge(&plain, &.{.amd64}, &empty, TestTree.has).verdict);
    // "NT.6.1" without an architecture: x86 only.
    const nt = parse("[Version]\nSignature=$Windows NT$\n[Manufacturer]\n%M%=M,NT.6.1\n");
    try testing.expect(nt.arches.x86 and !nt.arches.amd64);

    try testing.expectEqual(Verdict.not_an_inf, judge(&parse("hello world\n"), &.{.amd64}, &empty, TestTree.has).verdict);
    try testing.expectEqual(Verdict.not_an_inf, judge(&parse("[Version]\nClass=USB\n"), &.{.amd64}, &empty, TestTree.has).verdict);
    try testing.expectEqual(Verdict.no_models, judge(&parse("[Version]\nSignature=$Windows NT$\n[Strings]\nA=b\n"), &.{.amd64}, &empty, TestTree.has).verdict);
    // Comments and quoted semicolons.
    const quoted = parse("[Version]\nSignature=\"$Windows NT$\" ; comment\nProvider=\"A;B\"\n");
    try testing.expectEqualStrings("A;B", quoted.provider);
}

test "INF text: UTF-16LE with and without BOM, UTF-8 BOM" {
    var out: [128]u8 = undefined;
    const utf16 = [_]u8{ 0xFF, 0xFE, '[', 0, 'V', 0, ']', 0, 0x41, 0x04 };
    try testing.expectEqualStrings("[V]?", decodeText(&utf16, &out));
    const no_bom = [_]u8{ '[', 0, 'V', 0, 'e', 0, 'r', 0, 's', 0, 'i', 0, 'o', 0, 'n', 0, ']', 0 };
    try testing.expectEqualStrings("[Version]", decodeText(&no_bom, &out));
    try testing.expectEqualStrings("[Version]", decodeText("\xEF\xBB\xBF[Version]", &out));
    try testing.expectEqualStrings("plain", decodeText("plain", &out));
    const info = parse(decodeText(&[_]u8{ 0xFF, 0xFE } ++ asUtf16("[Version]\r\nSignature=$Windows NT$\r\n[Manufacturer]\r\n%M%=M,NTamd64\r\n"), &out));
    try testing.expect(info.arches.amd64);
}

fn asUtf16(comptime text: []const u8) [text.len * 2]u8 {
    var out: [text.len * 2]u8 = undefined;
    for (text, 0..) |c, i| {
        out[2 * i] = c;
        out[2 * i + 1] = 0;
    }
    return out;
}

test "driver classes from the folder name" {
    try testing.expectEqual(Class.storage, Class.fromFolder("storage"));
    try testing.expectEqual(Class.usb, Class.fromFolder("USB"));
    try testing.expectEqual(Class.other, Class.fromFolder("Other"));
    try testing.expectEqual(Class.other, Class.fromFolder("Intel RST"));
}
