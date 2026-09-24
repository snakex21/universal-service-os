//! UEFI driver manifests for the USOS menu (docs/drivers.md): the rules
//! shared by the built-in drivers (TouchI2cDxe) and the user drivers in
//! DATA\Drivers\UEFI\<Name>\ (driver.ini next to one .efi).
//!
//!     [driver]
//!     name=Friendly name
//!     type=input|storage|filesystem|other
//!     load=auto|off
//!     [match]            ; optional; every key present must match
//!     smbios_manufacturer=ASUSTeK   ; prefix, case-insensitive
//!     smbios_product=ROG Ally
//!     smbios_baseboard=RC71L
//!     pci=1022:15E0      ; a PCI function with this vendor:device exists
//!     acpi_hid=PNP0C50   ; the ID appears in the DSDT/SSDTs (_HID/_CID)
//!     [match]            ; several [match] sections: any one may match (OR)
//!
//! No [match] section: the driver is meant for every machine. Unknown keys
//! and malformed lines are counted (reported in drivers.txt) and ignored,
//! so a typo never stops the menu. Everything here is pure (unit tested);
//! src/platform/uefi/uefi_drivers.zig supplies SMBIOS, PCI and ACPI.
const std = @import("std");
const SystemInfo = @import("../gui/handheld.zig").SystemInfo;
const secure_boot_policy = @import("secure_boot_policy.zig");

pub const max_matches = 8;

pub const Type = enum {
    input,
    storage,
    filesystem,
    other,

    pub fn parse(text: []const u8) ?Type {
        inline for (@typeInfo(Type).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(text, field.name)) return @field(Type, field.name);
        }
        return null;
    }
};

pub const Load = enum { auto, off };

pub const PciId = struct {
    vendor: u16,
    device: u16,

    pub fn parse(text: []const u8) ?PciId {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const vendor_text = std.mem.trim(u8, text[0..colon], " \t");
        const device_text = std.mem.trim(u8, text[colon + 1 ..], " \t");
        if (vendor_text.len == 0 or vendor_text.len > 4 or device_text.len == 0 or device_text.len > 4) return null;
        return .{
            .vendor = std.fmt.parseInt(u16, vendor_text, 16) catch return null,
            .device = std.fmt.parseInt(u16, device_text, 16) catch return null,
        };
    }
};

/// One [match] section: every key that is set must match.
pub const Match = struct {
    manufacturer: ?[]const u8 = null,
    product: ?[]const u8 = null,
    baseboard: ?[]const u8 = null,
    pci: ?PciId = null,
    acpi_hid: ?[]const u8 = null,

    pub fn usesSmbios(self: Match) bool {
        return self.manufacturer != null or self.product != null or self.baseboard != null;
    }
};

pub const Manifest = struct {
    /// Slices point into the text passed to parse() (or the default name).
    name: []const u8,
    type: Type = .other,
    load: Load = .auto,
    matches: [max_matches]Match = undefined,
    match_count: usize = 0,
    /// Lines that were not understood (unknown key/section, bad value,
    /// too many [match] sections). Reported, never fatal.
    ignored_lines: usize = 0,

    pub fn matchList(self: *const Manifest) []const Match {
        return self.matches[0..self.match_count];
    }
};

/// Parses driver.ini text. Missing file = parse("", folder_name).
pub fn parse(text: []const u8, default_name: []const u8) Manifest {
    var result = Manifest{ .name = default_name };
    const Section = enum { none, driver, match, unknown };
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, stripBom(text), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r\x00");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse {
                result.ignored_lines += 1;
                section = .unknown;
                continue;
            };
            const name = std.mem.trim(u8, line[1..close], " \t");
            if (std.ascii.eqlIgnoreCase(name, "driver")) {
                section = .driver;
            } else if (std.ascii.eqlIgnoreCase(name, "match")) {
                if (result.match_count == max_matches) {
                    result.ignored_lines += 1;
                    section = .unknown;
                    continue;
                }
                result.matches[result.match_count] = .{};
                result.match_count += 1;
                section = .match;
            } else {
                result.ignored_lines += 1;
                section = .unknown;
            }
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            result.ignored_lines += 1;
            continue;
        };
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = unquote(std.mem.trim(u8, line[equals + 1 ..], " \t"));
        switch (section) {
            .driver => {
                if (std.ascii.eqlIgnoreCase(key, "name")) {
                    if (value.len != 0) result.name = value else result.ignored_lines += 1;
                } else if (std.ascii.eqlIgnoreCase(key, "type")) {
                    if (Type.parse(value)) |kind| result.type = kind else result.ignored_lines += 1;
                } else if (std.ascii.eqlIgnoreCase(key, "load")) {
                    if (parseLoad(value)) |load| result.load = load else result.ignored_lines += 1;
                } else result.ignored_lines += 1;
            },
            .match => {
                const match = &result.matches[result.match_count - 1];
                if (!setMatchKey(match, key, value)) result.ignored_lines += 1;
            },
            .none, .unknown => result.ignored_lines += 1,
        }
    }
    return result;
}

fn setMatchKey(match: *Match, key: []const u8, value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(key, "smbios_manufacturer")) {
        match.manufacturer = value;
    } else if (std.ascii.eqlIgnoreCase(key, "smbios_product")) {
        match.product = value;
    } else if (std.ascii.eqlIgnoreCase(key, "smbios_baseboard")) {
        match.baseboard = value;
    } else if (std.ascii.eqlIgnoreCase(key, "pci")) {
        match.pci = PciId.parse(value) orelse return false;
    } else if (std.ascii.eqlIgnoreCase(key, "acpi_hid")) {
        if (value.len > 16) return false;
        for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        match.acpi_hid = value;
    } else return false;
    return true;
}

pub fn parseLoad(value: []const u8) ?Load {
    if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "on") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no")) return .off;
    return null;
}

fn stripBom(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
}

fn stripComment(line: []const u8) []const u8 {
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quotes = !in_quotes;
        if (!in_quotes and (c == ';' or c == '#')) return line[0..i];
    }
    return line;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

// ------------------------------------------------------------ matching

/// What the machine offers to the matcher. `hasPci`/`hasAcpiId` are
/// callbacks so the UEFI side can scan lazily (only when a manifest asks).
pub const Environment = struct {
    smbios: ?SystemInfo,
    context: ?*anyopaque = null,
    hasPci: *const fn (?*anyopaque, PciId) bool = noPci,
    hasAcpiId: *const fn (?*anyopaque, []const u8) bool = noAcpi,

    fn noPci(_: ?*anyopaque, _: PciId) bool {
        return false;
    }
    fn noAcpi(_: ?*anyopaque, _: []const u8) bool {
        return false;
    }
};

pub const MatchResult = union(enum) {
    /// No [match] section: loads on every machine.
    everywhere,
    /// Section index (0-based) that matched.
    matched: usize,
    not_matched,
};

pub fn prefixIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    const text = std.mem.trim(u8, haystack, " \t\r\n\x00");
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

pub fn sectionMatches(match: Match, env: Environment) bool {
    if (match.usesSmbios()) {
        const info = env.smbios orelse return false;
        if (match.manufacturer) |want| if (!prefixIgnoreCase(info.manufacturer, want)) return false;
        if (match.product) |want| if (!prefixIgnoreCase(info.product, want)) return false;
        if (match.baseboard) |want| if (!prefixIgnoreCase(info.board_product, want)) return false;
    }
    if (match.pci) |id| if (!env.hasPci(env.context, id)) return false;
    if (match.acpi_hid) |id| if (!env.hasAcpiId(env.context, id)) return false;
    return true;
}

pub fn evaluate(manifest: *const Manifest, env: Environment) MatchResult {
    if (manifest.match_count == 0) return .everywhere;
    for (manifest.matchList(), 0..) |match, index| {
        if (sectionMatches(match, env)) return .{ .matched = index };
    }
    return .not_matched;
}

/// ACPI ID search in raw AML (DSDT/SSDT bytes): the ID as an AML string
/// (StringPrefix 0x0D, the ID, NUL) or, for 7-character EISA IDs such as
/// PNP0C50, as the compressed EisaId() DWORD (DWordPrefix 0x0C). Both
/// _HID and _CID use these encodings; the scan does not tell them apart.
pub fn amlContainsId(aml: []const u8, id: []const u8) bool {
    if (id.len == 0 or id.len > 16) return false;
    var upper: [16]u8 = undefined;
    for (id, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const wanted = upper[0..id.len];
    var string_pattern: [18]u8 = undefined;
    string_pattern[0] = 0x0D;
    @memcpy(string_pattern[1 .. 1 + wanted.len], wanted);
    string_pattern[1 + wanted.len] = 0;
    if (std.mem.indexOf(u8, aml, string_pattern[0 .. 2 + wanted.len]) != null) return true;
    if (eisaId(wanted)) |dword| {
        const pattern = [5]u8{ 0x0C, dword[0], dword[1], dword[2], dword[3] };
        if (std.mem.indexOf(u8, aml, &pattern) != null) return true;
    }
    return false;
}

/// The byte encoding of ASL EisaId("AAA####") as stored in AML.
pub fn eisaId(id: []const u8) ?[4]u8 {
    if (id.len != 7) return null;
    var letters: u16 = 0;
    for (id[0..3]) |c| {
        if (c < 'A' or c > 'Z') return null;
        letters = (letters << 5) | @as(u16, c - 0x40);
    }
    const digits = std.fmt.parseInt(u16, id[3..7], 16) catch return null;
    return .{ @intCast(letters >> 8), @intCast(letters & 0xFF), @intCast(digits >> 8), @intCast(digits & 0xFF) };
}

// ------------------------------------------------------------ images

pub const machine_x64: u16 = 0x8664;
pub const machine_ia32: u16 = 0x014c;
pub const machine_aarch64: u16 = 0xaa64;
pub const subsystem_application: u16 = 10;
pub const subsystem_boot_service_driver: u16 = 11;
pub const subsystem_runtime_driver: u16 = 12;

pub const ImageCheck = union(enum) {
    boot_service_driver,
    runtime_driver,
    not_pe,
    /// PE machine type other than the menu's own (x64).
    wrong_machine: u16,
    application,
    other_subsystem: u16,

    pub fn loadable(self: ImageCheck) bool {
        return self == .boot_service_driver or self == .runtime_driver;
    }
};

pub const ImageInfo = struct {
    check: ImageCheck,
    /// An Authenticode certificate table is present (the image is signed by
    /// someone; whether db/MOK trust it is only known after verification).
    signed: bool = false,
};

/// Header checks before anything is loaded: x64 PE32+, EFI boot-service
/// or runtime driver. Applications and other architectures are refused.
pub fn inspectImage(bytes: []const u8, expected_machine: u16) ImageInfo {
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return .{ .check = .not_pe };
    const pe: usize = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (pe > bytes.len or bytes.len - pe < 24 or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return .{ .check = .not_pe };
    const machine = std.mem.readInt(u16, bytes[pe + 4 ..][0..2], .little);
    const optional_size = std.mem.readInt(u16, bytes[pe + 20 ..][0..2], .little);
    const opt = pe + 24;
    if (bytes.len < opt + 70 or optional_size < 70) return .{ .check = .not_pe };
    const magic = std.mem.readInt(u16, bytes[opt..][0..2], .little);
    const subsystem = std.mem.readInt(u16, bytes[opt + 68 ..][0..2], .little);
    // Data directory 4 (certificate table): PE32+ at opt+112, PE32 at opt+96.
    const directories: usize = if (magic == 0x20b) opt + 112 else opt + 96;
    var signed = false;
    const cert = directories + 4 * 8;
    if (optional_size >= cert - opt + 8 and bytes.len >= cert + 8) {
        const size = std.mem.readInt(u32, bytes[cert + 4 ..][0..4], .little);
        signed = size >= 8;
    }
    if (machine != expected_machine) return .{ .check = .{ .wrong_machine = machine }, .signed = signed };
    if (magic != 0x20b) return .{ .check = .not_pe, .signed = signed };
    const check: ImageCheck = switch (subsystem) {
        subsystem_boot_service_driver => .boot_service_driver,
        subsystem_runtime_driver => .runtime_driver,
        subsystem_application => .application,
        else => .{ .other_subsystem = subsystem },
    };
    return .{ .check = check, .signed = signed };
}

pub fn machineName(machine: u16) []const u8 {
    return switch (machine) {
        machine_x64 => "x64",
        machine_ia32 => "ia32",
        machine_aarch64 => "aarch64",
        0x01c4 => "arm",
        0x5064 => "riscv64",
        0x0ebc => "ebc",
        else => "unknown",
    };
}

// ------------------------------------------------------------ decisions

/// usos-settings.ini `driver.<folder>=on|off|blocked`; `blocked` is written
/// by the menu when a driver did not return on an earlier start.
pub const Setting = enum { none, on, off, blocked };

pub fn settingKeyPrefix() []const u8 {
    return "driver.";
}

/// The value of `driver.<folder>` in usos-settings.ini text.
pub fn parseSetting(settings: []const u8, folder: []const u8) Setting {
    var result: Setting = .none;
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        if (key.len != settingKeyPrefix().len + folder.len) continue;
        if (!std.ascii.eqlIgnoreCase(key[0..settingKeyPrefix().len], settingKeyPrefix())) continue;
        if (!std.ascii.eqlIgnoreCase(key[settingKeyPrefix().len..], folder)) continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(value, "blocked")) {
            result = .blocked;
        } else if (parseLoad(value)) |load| {
            result = if (load == .auto) .on else .off;
        }
    }
    return result;
}

/// Folder names usable as a settings key (no '=', no line breaks).
pub fn settingKeyUsable(folder: []const u8) bool {
    if (folder.len == 0 or folder.len > 96) return false;
    for (folder) |c| if (c == '=' or c == '\r' or c == '\n' or c == '[' or c == ']' or c == ';') return false;
    return true;
}

pub const Decision = enum {
    load,
    disabled_in_manifest,
    disabled_in_settings,
    blocked_after_hang,
    hardware_not_matched,
    image_refused,

    pub fn text(self: Decision) []const u8 {
        return switch (self) {
            .load => "load",
            .disabled_in_manifest => "skipped (load=off in driver.ini)",
            .disabled_in_settings => "skipped (turned off on Tools -> Drivers)",
            .blocked_after_hang => "skipped (blocked: the menu stopped while it started on an earlier boot)",
            .hardware_not_matched => "skipped (no [match] section matches this computer)",
            .image_refused => "skipped (not an x64 EFI driver)",
        };
    }
};

/// Whether the driver is switched on: the Tools -> Drivers toggle wins
/// over driver.ini load=; `blocked` (hang guard) wins over both until the
/// user switches the driver on again.
pub fn enabled(manifest_load: Load, setting: Setting) bool {
    return switch (setting) {
        .on => true,
        .off, .blocked => false,
        .none => manifest_load == .auto,
    };
}

pub fn decide(manifest: *const Manifest, setting: Setting, image: ImageCheck, match: MatchResult) Decision {
    if (setting == .blocked) return .blocked_after_hang;
    if (setting == .off) return .disabled_in_settings;
    if (setting == .none and manifest.load == .off) return .disabled_in_manifest;
    if (!image.loadable()) return .image_refused;
    if (match == .not_matched) return .hardware_not_matched;
    return .load;
}

/// How a driver is loaded given the Secure Boot state.
pub const SecureBootPath = enum {
    /// Secure Boot off: firmware LoadImage, no signature needed.
    plain,
    /// Secure Boot on: verified through shim (db, dbx, MOK) or firmware.
    verify,
    /// Secure Boot on and the image carries no signature at all: skipped
    /// without trying ("requires Secure Boot off or a signature").
    needs_signature,
};

pub fn secureBootPath(state: secure_boot_policy.State, signed: bool) SecureBootPath {
    if (!state.enforced()) return .plain;
    return if (signed) .verify else .needs_signature;
}

// ------------------------------------------------------------ tests

const testing = std.testing;

test "driver.ini parsing: [driver], [match] sections, comments and junk" {
    const text =
        "\xEF\xBB\xBF; sample\r\n" ++
        "[driver]\r\n" ++
        "name = Goodix touch ; trailing comment\r\n" ++
        "type=INPUT\r\n" ++
        "load=off\r\n" ++
        "colour=blue\r\n" ++
        "[match]\r\n" ++
        "smbios_manufacturer=ASUSTeK\r\n" ++
        "smbios_baseboard=RC71L\r\n" ++
        "[match]\n" ++
        "pci=1022:15e0\n" ++
        "acpi_hid=PNP0C50\n" ++
        "pci=zz:1\n" ++
        "garbage line\n" ++
        "[other]\nkey=value\n";
    const m = parse(text, "Folder");
    try testing.expectEqualStrings("Goodix touch", m.name);
    try testing.expectEqual(Type.input, m.type);
    try testing.expectEqual(Load.off, m.load);
    try testing.expectEqual(@as(usize, 2), m.match_count);
    try testing.expectEqualStrings("ASUSTeK", m.matches[0].manufacturer.?);
    try testing.expectEqualStrings("RC71L", m.matches[0].baseboard.?);
    try testing.expect(m.matches[0].pci == null);
    try testing.expectEqual(PciId{ .vendor = 0x1022, .device = 0x15e0 }, m.matches[1].pci.?);
    try testing.expectEqualStrings("PNP0C50", m.matches[1].acpi_hid.?);
    // colour=, bad pci=, "garbage line", [other] and key=value.
    try testing.expectEqual(@as(usize, 5), m.ignored_lines);

    const empty = parse("", "MyDriver");
    try testing.expectEqualStrings("MyDriver", empty.name);
    try testing.expectEqual(Type.other, empty.type);
    try testing.expectEqual(Load.auto, empty.load);
    try testing.expectEqual(@as(usize, 0), empty.match_count);

    // Too many [match] sections: the extra ones are ignored, not fatal.
    const lots = "[match]\npci=1:1\n" ** (max_matches + 2);
    const capped = parse(lots, "x");
    try testing.expectEqual(@as(usize, max_matches), capped.match_count);
    try testing.expect(capped.ignored_lines >= 2);
}

const TestEnv = struct {
    pci: []const PciId = &.{},
    aml: []const u8 = "",

    fn env(self: *const TestEnv, info: ?SystemInfo) Environment {
        return .{ .smbios = info, .context = @ptrCast(@constCast(self)), .hasPci = hasPci, .hasAcpiId = hasAcpi };
    }
    fn hasPci(context: ?*anyopaque, id: PciId) bool {
        const self: *const TestEnv = @ptrCast(@alignCast(context.?));
        for (self.pci) |present| if (present.vendor == id.vendor and present.device == id.device) return true;
        return false;
    }
    fn hasAcpi(context: ?*anyopaque, id: []const u8) bool {
        const self: *const TestEnv = @ptrCast(@alignCast(context.?));
        return amlContainsId(self.aml, id);
    }
};

test "matching: SMBIOS prefixes, PCI, ACPI and OR over sections" {
    const ally = SystemInfo{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "ROG Ally RC71L_RC71L", .board_product = "RC71L" };
    const desktop = SystemInfo{ .manufacturer = "To Be Filled By O.E.M.", .product = "To Be Filled By O.E.M.", .board_product = "B550 Taichi" };
    const empty_env = TestEnv{};

    const smbios = parse("[match]\nsmbios_manufacturer=asustek\nsmbios_product=ROG ally\nsmbios_baseboard=rc71\n", "d");
    try testing.expectEqual(MatchResult{ .matched = 0 }, evaluate(&smbios, empty_env.env(ally)));
    try testing.expectEqual(MatchResult.not_matched, evaluate(&smbios, empty_env.env(desktop)));
    // SMBIOS keys never match without an SMBIOS table.
    try testing.expectEqual(MatchResult.not_matched, evaluate(&smbios, empty_env.env(null)));
    // All keys of one section must match (AND).
    const both = parse("[match]\nsmbios_baseboard=RC71L\npci=8086:1234\n", "d");
    try testing.expectEqual(MatchResult.not_matched, evaluate(&both, empty_env.env(ally)));
    const with_pci = TestEnv{ .pci = &.{ .{ .vendor = 0x8086, .device = 0x1234 }, .{ .vendor = 0x1022, .device = 0x15e0 } } };
    try testing.expectEqual(MatchResult{ .matched = 0 }, evaluate(&both, with_pci.env(ally)));
    // Several sections: OR, first match reported.
    const any = parse("[match]\nsmbios_baseboard=RC72LA\n[match]\npci=1022:15E0\n[match]\nsmbios_baseboard=RC71L\n", "d");
    try testing.expectEqual(MatchResult{ .matched = 1 }, evaluate(&any, with_pci.env(ally)));
    try testing.expectEqual(MatchResult{ .matched = 2 }, evaluate(&any, empty_env.env(ally)));
    try testing.expectEqual(MatchResult.not_matched, evaluate(&any, empty_env.env(desktop)));
    // No [match]: everywhere, even without SMBIOS.
    const none = parse("[driver]\nname=x\n", "d");
    try testing.expectEqual(MatchResult.everywhere, evaluate(&none, empty_env.env(null)));
    // ACPI HID in AML: string and EisaId encodings.
    const aml_string = TestEnv{ .aml = "\x08_HID\x0DNVTK0603\x00\x08_CID\x0C\x41\xD0\x0C\x50" };
    const hid = parse("[match]\nacpi_hid=NVTK0603\n", "d");
    try testing.expectEqual(MatchResult{ .matched = 0 }, evaluate(&hid, aml_string.env(null)));
    const cid = parse("[match]\nacpi_hid=pnp0c50\n", "d");
    try testing.expectEqual(MatchResult{ .matched = 0 }, evaluate(&cid, aml_string.env(null)));
    const other = parse("[match]\nacpi_hid=PNP0C51\n", "d");
    try testing.expectEqual(MatchResult.not_matched, evaluate(&other, aml_string.env(null)));
    // A longer string that merely starts with the ID is not a match.
    try testing.expect(!amlContainsId("\x0DNVTK06031\x00", "NVTK0603"));
}

test "EisaId encoding matches the ASL compiler" {
    // EisaId("PNP0C0A") = 0x0A0CD041 -> bytes 41 D0 0C 0A.
    try testing.expectEqual([4]u8{ 0x41, 0xD0, 0x0C, 0x0A }, eisaId("PNP0C0A").?);
    try testing.expectEqual([4]u8{ 0x41, 0xD0, 0x0C, 0x50 }, eisaId("PNP0C50").?);
    try testing.expect(eisaId("NVTK0603") == null);
    try testing.expect(eisaId("pnp0c50") == null);
}

fn testImage(machine: u16, magic: u16, subsystem: u16, cert_size: u32) [512]u8 {
    var image = [_]u8{0} ** 512;
    image[0] = 'M';
    image[1] = 'Z';
    std.mem.writeInt(u32, image[0x3c..0x40], 0x80, .little);
    @memcpy(image[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, image[0x84..0x86], machine, .little);
    std.mem.writeInt(u16, image[0x80 + 20 ..][0..2], 240, .little);
    const opt = 0x80 + 24;
    std.mem.writeInt(u16, image[opt..][0..2], magic, .little);
    std.mem.writeInt(u16, image[opt + 68 ..][0..2], subsystem, .little);
    const cert = opt + 112 + 4 * 8;
    std.mem.writeInt(u32, image[cert..][0..4], 0x100, .little);
    std.mem.writeInt(u32, image[cert + 4 ..][0..4], cert_size, .little);
    return image;
}

test "image checks: x64 drivers only, signature presence" {
    const driver = testImage(machine_x64, 0x20b, subsystem_boot_service_driver, 0x500);
    const info = inspectImage(&driver, machine_x64);
    try testing.expectEqual(ImageCheck.boot_service_driver, info.check);
    try testing.expect(info.signed);
    const unsigned = testImage(machine_x64, 0x20b, subsystem_runtime_driver, 0);
    const unsigned_info = inspectImage(&unsigned, machine_x64);
    try testing.expectEqual(ImageCheck.runtime_driver, unsigned_info.check);
    try testing.expect(!unsigned_info.signed);
    const app = testImage(machine_x64, 0x20b, subsystem_application, 0);
    try testing.expectEqual(ImageCheck.application, inspectImage(&app, machine_x64).check);
    try testing.expect(!inspectImage(&app, machine_x64).check.loadable());
    const ia32 = testImage(machine_ia32, 0x10b, subsystem_boot_service_driver, 0);
    try testing.expectEqual(ImageCheck{ .wrong_machine = machine_ia32 }, inspectImage(&ia32, machine_x64).check);
    try testing.expectEqual(ImageCheck.not_pe, inspectImage("MZ not really", machine_x64).check);
    try testing.expectEqual(ImageCheck.not_pe, inspectImage("", machine_x64).check);
    var truncated = driver;
    std.mem.writeInt(u32, truncated[0x3c..0x40], 0x1F0, .little);
    try testing.expectEqual(ImageCheck.not_pe, inspectImage(&truncated, machine_x64).check);
}

test "settings toggle, hang guard and the load decision" {
    const settings = "[ui]\r\nlanguage=pl\r\ndriver.Goodix=off\r\nDRIVER.goodix = on\r\ndriver.Hung=blocked\r\ndriver.Other Thing=0\r\n";
    try testing.expectEqual(Setting.on, parseSetting(settings, "Goodix"));
    try testing.expectEqual(Setting.blocked, parseSetting(settings, "Hung"));
    try testing.expectEqual(Setting.off, parseSetting(settings, "Other Thing"));
    try testing.expectEqual(Setting.none, parseSetting(settings, "Missing"));
    try testing.expectEqual(Setting.none, parseSetting(settings, "Good"));
    try testing.expect(settingKeyUsable("Goodix touch"));
    try testing.expect(!settingKeyUsable("a=b"));

    const auto = parse("", "d");
    const off = parse("[driver]\nload=off\n", "d");
    const driver: ImageCheck = .boot_service_driver;
    try testing.expectEqual(Decision.load, decide(&auto, .none, driver, .everywhere));
    try testing.expectEqual(Decision.disabled_in_manifest, decide(&off, .none, driver, .everywhere));
    // The Tools -> Drivers toggle overrides driver.ini in both directions.
    try testing.expectEqual(Decision.load, decide(&off, .on, driver, .everywhere));
    try testing.expectEqual(Decision.disabled_in_settings, decide(&auto, .off, driver, .everywhere));
    try testing.expectEqual(Decision.blocked_after_hang, decide(&auto, .blocked, driver, .everywhere));
    try testing.expectEqual(Decision.image_refused, decide(&auto, .none, .application, .everywhere));
    try testing.expectEqual(Decision.image_refused, decide(&auto, .none, .{ .wrong_machine = machine_ia32 }, .everywhere));
    try testing.expectEqual(Decision.hardware_not_matched, decide(&auto, .none, driver, .not_matched));
    try testing.expectEqual(Decision.load, decide(&auto, .none, driver, .{ .matched = 0 }));
    try testing.expect(enabled(.off, .on));
    try testing.expect(!enabled(.auto, .blocked));
}

test "Secure Boot gating: signed drivers are verified, unsigned skipped" {
    try testing.expectEqual(SecureBootPath.plain, secureBootPath(.disabled, false));
    try testing.expectEqual(SecureBootPath.plain, secureBootPath(.disabled, true));
    try testing.expectEqual(SecureBootPath.plain, secureBootPath(.setup_mode, false));
    try testing.expectEqual(SecureBootPath.plain, secureBootPath(.unsupported, false));
    try testing.expectEqual(SecureBootPath.verify, secureBootPath(.enforcing, true));
    try testing.expectEqual(SecureBootPath.needs_signature, secureBootPath(.enforcing, false));
}
