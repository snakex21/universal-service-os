//! What a Windows ISO actually contains, for the image list and the start
//! gates: CPU architecture (from the removable-media EFI loaders, else the
//! boot.wim metadata) and whether it is Setup media or only a WinPE/rescue
//! image. Pure policy (no I/O); the platform adapters look the paths up
//! case-insensitively (UDF/ISO9660 names are compared ignoring case) and
//! fill `Presence`.
//!
//! Rules (same as image_probe/windows_detect.zig):
//!   sources/boot.wim + sources/setup.exe + install.{wim,esd,swm} = Setup media
//!   sources/boot.wim without an install image                    = WinPE / rescue
//!   no sources/boot.wim                                          = not Windows boot media
//!
//! The install image metadata (`parseInstall`, the XML of install.wim/esd)
//! adds what the image installs: client or Windows Server, the Server
//! editions (Standard, Datacenter, ... as Core or Desktop Experience), the
//! Windows version (for the "belongs in folder X" hint) and IA64 images.
const std = @import("std");

pub const Arch = enum {
    unknown,
    x64,
    x86,
    arm64,
    /// Dual-architecture media (x64 and x86 loaders side by side).
    multi,
    /// Itanium (Windows Server 2008 R2 and older for IA64).
    ia64,

    pub fn label(self: Arch) []const u8 {
        return switch (self) {
            .unknown => "",
            .x64 => "x64",
            .x86 => "x86",
            .arm64 => "ARM64",
            .multi => "x64/x86",
            .ia64 => "IA64",
        };
    }

    /// WIM <ARCH> values (PROCESSOR_ARCHITECTURE_*).
    pub fn fromWim(code: u32) Arch {
        return switch (code) {
            0 => .x86,
            6 => .ia64,
            9 => .x64,
            12 => .arm64,
            else => .unknown,
        };
    }
};

/// Windows Server edition families, from <EDITIONID> without the "Server"
/// prefix and the Core/Eval suffixes (ServerStandard, ServerDatacenterCore,
/// ServerStandardEval, ServerDatacenterACor, ServerHyperCore, ...).
pub const ServerEdition = enum(u4) {
    standard,
    datacenter,
    enterprise,
    web,
    essentials,
    foundation,
    storage,
    hyperv,
    other,

    pub fn label(self: ServerEdition) []const u8 {
        return switch (self) {
            .standard => "Standard",
            .datacenter => "Datacenter",
            .enterprise => "Enterprise",
            .web => "Web",
            .essentials => "Essentials",
            .foundation => "Foundation",
            .storage => "Storage",
            .hyperv => "Hyper-V Server",
            .other => "Other",
        };
    }

    pub fn bit(self: ServerEdition) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }
};

/// Summary of the install image (install.wim/esd/swm XML metadata).
pub const Install = struct {
    /// The metadata was read and had at least one image.
    known: bool = false,
    images: u16 = 0,
    /// At least one image is a Windows Server / a client Windows edition.
    server: bool = false,
    client: bool = false,
    /// At least one image is for Itanium (ARCH 6).
    ia64: bool = false,
    /// Server editions present as Server Core / with the Desktop Experience
    /// (ServerEdition.bit masks).
    core: u16 = 0,
    desktop: u16 = 0,
    /// Version of the first image (0 when absent).
    major: u16 = 0,
    minor: u16 = 0,
    build: u32 = 0,

    pub fn serverOnly(self: Install) bool {
        return self.known and self.server and !self.client;
    }

    pub fn clientOnly(self: Install) bool {
        return self.known and self.client and !self.server;
    }
};

pub const Content = enum {
    unknown,
    /// Windows Setup media (boot.wim, setup.exe and an install image).
    setup,
    /// boot.wim without an install image: WinPE, a recovery/rescue disc or a
    /// USOS PE10 donor.
    winpe,
    /// No sources/boot.wim at all.
    not_windows,
};

/// Paths below are the ones the adapters look up (any case).
pub const efi_x64 = "efi/boot/bootx64.efi";
pub const efi_ia32 = "efi/boot/bootia32.efi";
pub const efi_aa64 = "efi/boot/bootaa64.efi";
pub const efi_ia64 = "efi/boot/bootia64.efi";
pub const boot_wim = "sources/boot.wim";
pub const setup_exe = "sources/setup.exe";
pub const bios_bootmgr = "bootmgr";

pub const Presence = struct {
    efi_x64: bool = false,
    efi_ia32: bool = false,
    efi_aa64: bool = false,
    efi_ia64: bool = false,
    bootmgr: bool = false,
    boot_wim: bool = false,
    setup_exe: bool = false,
    install_image: bool = false,
    /// <ARCH> of the boot.wim boot image, when it was read.
    wim_arch: ?u32 = null,
};

pub const Info = struct {
    arch: Arch = .unknown,
    content: Content = .unknown,
    /// A loader for x64 UEFI firmware is on the media.
    uefi_x64: bool = false,
    /// A BIOS boot manager is on the media.
    bios: bool = false,
    /// The ISO could not be read (the name is still listed).
    unreadable: bool = false,
    /// What the install image installs (Setup media only, when read).
    install: Install = .{},
};

pub fn classify(p: Presence) Info {
    var info = Info{ .uefi_x64 = p.efi_x64, .bios = p.bootmgr };
    info.content = if (!p.boot_wim)
        .not_windows
    else if (p.install_image and p.setup_exe)
        .setup
    else
        .winpe;
    const loaders = @as(u8, @intFromBool(p.efi_x64)) + @intFromBool(p.efi_ia32) + @intFromBool(p.efi_aa64);
    info.arch = if (loaders > 1)
        (if (p.efi_x64 and p.efi_ia32 and !p.efi_aa64) .multi else if (p.efi_x64) .x64 else .unknown)
    else if (p.efi_x64)
        .x64
    else if (p.efi_ia32)
        .x86
    else if (p.efi_aa64)
        .arm64
    else if (p.efi_ia64)
        .ia64
    else if (p.wim_arch) |code|
        Arch.fromWim(code)
    else
        .unknown;
    // Media with only a BIOS loader: boot.wim says what runs.
    if (p.wim_arch) |code| {
        const wim = Arch.fromWim(code);
        if (loaders == 0 and wim != .unknown) info.arch = wim;
    }
    return info;
}

/// Why an image cannot be started on this machine, before anything is read
/// further or copied. `null` means no objection.
pub const Block = enum {
    /// 32-bit media on 64-bit UEFI: needs 32-bit UEFI or BIOS/CSM.
    needs_32bit_uefi_or_bios,
    /// ARM64 media on an x86 PC.
    arm64_media,
    /// No loader for this firmware (x64 UEFI) on the media.
    no_uefi_loader,
    /// Itanium (IA64) media: never starts on an x86 PC.
    ia64_media,
};

pub const Firmware = enum { uefi_x64, uefi_ia32, bios };

pub fn block(info: Info, firmware: Firmware) ?Block {
    return blockWith(info, firmware, .media);
}

/// Which UEFI loader starts Setup on x64 UEFI.
pub const UefiLoader = enum {
    /// The media's own efi\boot\bootx64.efi.
    media,
    /// An external PE donor (Windows 7/Vista, Server 2008/2008 R2: the
    /// DATA\Programs\USOS\WinPE boot image, windows7_iso.resolveDonor). The
    /// media's own UEFI loader is irrelevant; the donor and media checks are
    /// windows7_iso.inspectSelected/resolveDonor's.
    pe_donor,
};

pub fn blockWith(info: Info, firmware: Firmware, loader: UefiLoader) ?Block {
    if (info.unreadable) return null;
    if (info.arch == .ia64 or info.install.ia64) return .ia64_media;
    switch (firmware) {
        .uefi_x64 => {
            if (info.arch == .arm64) return .arm64_media;
            if (info.arch == .x86) return .needs_32bit_uefi_or_bios;
            // Windows boot media with a readable layout but no x64 loader
            // (and not identified as x86 above) cannot start here either.
            if (loader == .media and info.content != .not_windows and info.content != .unknown and !info.uefi_x64 and info.arch == .x64) return .no_uefi_loader;
            return null;
        },
        .uefi_ia32 => return if (info.arch == .x86 or info.arch == .multi) null else if (info.arch == .unknown) null else .no_uefi_loader,
        .bios => return if (info.arch == .arm64) .arm64_media else null,
    }
}

/// UTF-16LE WIM XML (with BOM) to ASCII in place; returns the ASCII text.
/// install.wim XML metadata (UTF-16LE with BOM) as ASCII, in place
/// (non-ASCII characters become '?'), for answer.editions.parse.
pub fn installXmlAscii(xml: []u8) ![]u8 {
    return asciiXml(xml);
}

fn asciiXml(xml: []u8) ![]u8 {
    if (xml.len % 2 != 0 or xml.len < 4 or xml[0] != 0xff or xml[1] != 0xfe) return error.InvalidWimXml;
    const length = xml.len / 2 - 1;
    for (0..length) |i| xml[i] = if (xml[3 + 2 * i] == 0) xml[2 + 2 * i] else '?';
    return xml[0..length];
}

/// Text of the first <tag>...</tag> in `entry` (trimmed), or null.
fn tagText(entry: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const start = (std.mem.indexOf(u8, entry, open) orelse return null) + open.len;
    const stop = std.mem.indexOfPos(u8, entry, start, "</" ++ tag ++ ">") orelse return null;
    return std.mem.trim(u8, entry[start..stop], " \t\r\n");
}

fn tagNumber(entry: []const u8, comptime tag: []const u8) ?u32 {
    return std.fmt.parseInt(u32, tagText(entry, tag) orelse return null, 10) catch null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

/// Server edition family of an <EDITIONID> ("ServerDatacenterCore" ->
/// datacenter), null for a client edition (Professional, Enterprise, ...).
pub fn serverEdition(edition_id: []const u8) ?ServerEdition {
    if (!startsWithIgnoreCase(edition_id, "Server")) return null;
    // The family is a prefix: StandardCore, DatacenterEval, DatacenterACor.
    const name = edition_id["Server".len..];
    // Hyper-V Server: ServerHyperCore / ServerHyper.
    if (startsWithIgnoreCase(name, "Hyper")) return .hyperv;
    const Known = struct { prefix: []const u8, edition: ServerEdition };
    const known = [_]Known{
        .{ .prefix = "Standard", .edition = .standard },
        .{ .prefix = "Datacenter", .edition = .datacenter },
        .{ .prefix = "Enterprise", .edition = .enterprise },
        .{ .prefix = "Web", .edition = .web },
        .{ .prefix = "Solution", .edition = .essentials },
        .{ .prefix = "Essentials", .edition = .essentials },
        .{ .prefix = "Foundation", .edition = .foundation },
        .{ .prefix = "Storage", .edition = .storage },
    };
    for (known) |item| if (startsWithIgnoreCase(name, item.prefix)) return item.edition;
    return .other;
}

/// Server Core rather than the Desktop Experience: <INSTALLATIONTYPE>
/// "Server Core" (2012 and later) or a Core <EDITIONID> (2008/2008 R2).
fn serverCore(edition_id: []const u8, installation_type: ?[]const u8) bool {
    if (installation_type) |kind| {
        if (std.ascii.eqlIgnoreCase(kind, "Server Core")) return true;
        if (std.ascii.eqlIgnoreCase(kind, "Server")) return false;
    }
    return endsWithIgnoreCase(edition_id, "Core") or endsWithIgnoreCase(edition_id, "ACor") or startsWithIgnoreCase(edition_id, "ServerHyper");
}

/// Reads what an install image installs from its XML metadata (UTF-16LE
/// with BOM, converted to ASCII in place). Every <IMAGE> counts; one
/// Server image makes it Server media.
pub fn parseInstall(xml: []u8) !Install {
    var rest = try asciiXml(xml);
    var info = Install{};
    while (std.mem.indexOf(u8, rest, "<IMAGE")) |start| {
        rest = rest[start..];
        const end = std.mem.indexOf(u8, rest, "</IMAGE>") orelse return error.InvalidWimXml;
        const entry = rest[0..end];
        rest = rest[end + "</IMAGE>".len ..];
        if (info.images == 0) {
            info.major = @intCast(@min(tagNumber(entry, "MAJOR") orelse 0, std.math.maxInt(u16)));
            info.minor = @intCast(@min(tagNumber(entry, "MINOR") orelse 0, std.math.maxInt(u16)));
            info.build = tagNumber(entry, "BUILD") orelse 0;
        }
        info.images +|= 1;
        if (tagNumber(entry, "ARCH") == 6) info.ia64 = true;
        const edition_id = tagText(entry, "EDITIONID") orelse "";
        const installation_type = tagText(entry, "INSTALLATIONTYPE");
        const server_type = if (installation_type) |kind| startsWithIgnoreCase(kind, "Server") else false;
        // INSTALLATIONTYPE Client wins: Windows 10 Enterprise multi-session
        // is EDITIONID ServerRdsh on a client Setup.
        const client_type = if (installation_type) |kind| startsWithIgnoreCase(kind, "Client") else false;
        if (client_type) {
            info.client = true;
        } else if (serverEdition(edition_id)) |edition| {
            info.server = true;
            if (serverCore(edition_id, installation_type)) info.core |= edition.bit() else info.desktop |= edition.bit();
        } else if (server_type) {
            info.server = true;
            if (serverCore(edition_id, installation_type)) info.core |= ServerEdition.other.bit() else info.desktop |= ServerEdition.other.bit();
        } else {
            info.client = true;
        }
    }
    if (info.images == 0) return error.InvalidWimXml;
    info.known = true;
    return info;
}

/// "Standard (Core), Standard (Desktop Experience), Datacenter (Core)":
/// the Server editions of `install`, with localized Core / Desktop labels.
pub fn formatEditions(install: Install, buffer: []u8, core_label: []const u8, desktop_label: []const u8) []const u8 {
    var used: usize = 0;
    for (std.enums.values(ServerEdition)) |edition| {
        for ([_]bool{ true, false }) |core| {
            const mask = if (core) install.core else install.desktop;
            if (mask & edition.bit() == 0) continue;
            const part = std.fmt.bufPrint(buffer[used..], "{s}{s} ({s})", .{ if (used == 0) "" else ", ", edition.label(), if (core) core_label else desktop_label }) catch return buffer[0..used];
            used += part.len;
        }
    }
    return buffer[0..used];
}

/// The DATA system folder ("Windows Server 2022", "Windows 10") this
/// install image belongs in, from the version of its first image; null when
/// the version does not name one catalog folder.
pub fn suggestedFolder(install: Install) ?[]const u8 {
    if (!install.known or (install.server and install.client)) return null;
    const server = install.server;
    return switch (install.major) {
        6 => switch (install.minor) {
            0 => if (server) "Windows Server 2008" else "Windows Vista",
            1 => if (server) "Windows Server 2008 R2" else "Windows 7",
            2 => if (server) "Windows Server 2012" else "Windows 8",
            3 => if (server) "Windows Server 2012 R2" else "Windows 8.1",
            else => null,
        },
        10 => if (install.minor != 0 or install.build == 0)
            null
        else if (!server)
            (if (install.build >= 22000) "Windows 11" else "Windows 10")
        else if (install.build >= 26100)
            "Windows Server 2025"
        else if (install.build >= 20348)
            "Windows Server 2022"
        else if (install.build >= 17763)
            "Windows Server 2019"
        else if (install.build >= 14393)
            "Windows Server 2016"
        else
            null,
        else => null,
    };
}

pub const FolderHint = enum {
    none,
    /// Windows Server media in a client Windows folder.
    server_in_client_folder,
    /// Client Windows media in a Windows Server folder.
    client_in_server_folder,
};

/// Media and folder kinds disagree (a hint only; the image stays usable).
pub fn folderHint(install: Install, server_folder: bool) FolderHint {
    if (server_folder and install.clientOnly()) return .client_in_server_folder;
    if (!server_folder and install.serverOnly()) return .server_in_client_folder;
    return .none;
}

/// Reads <ARCH> of image `index` from boot.wim XML metadata (UTF-16LE with
/// BOM, as stored in the WIM). The buffer is converted to ASCII in place.
pub fn wimArch(xml: []u8, index: u32) !u32 {
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
    const open = "<ARCH>";
    const start = (std.mem.indexOf(u8, entry, open) orelse return error.InvalidWimXml) + open.len;
    const stop = std.mem.indexOfPos(u8, entry, start, "</ARCH>") orelse return error.InvalidWimXml;
    return std.fmt.parseInt(u32, entry[start..stop], 10) catch error.InvalidWimXml;
}

test "Setup media, WinPE and non-Windows ISOs are told apart" {
    const setup = classify(.{ .efi_x64 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(Content.setup, setup.content);
    try std.testing.expectEqual(Arch.x64, setup.arch);
    try std.testing.expect(setup.uefi_x64 and setup.bios);

    // The USOS PE10 donor: boot.wim and setup.exe, but no install image.
    const donor = classify(.{ .efi_x64 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true });
    try std.testing.expectEqual(Content.winpe, donor.content);
    const rescue = classify(.{ .efi_x64 = true, .boot_wim = true });
    try std.testing.expectEqual(Content.winpe, rescue.content);
    // An install image without Setup is not Setup media.
    try std.testing.expectEqual(Content.winpe, classify(.{ .boot_wim = true, .install_image = true }).content);

    try std.testing.expectEqual(Content.not_windows, classify(.{ .efi_x64 = true }).content);
}

test "architecture comes from the EFI loaders, else from boot.wim" {
    // The pl-pl Windows 10 22H2 x86 ISO: only efi/boot/bootia32.efi.
    const x86 = classify(.{ .efi_ia32 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(Arch.x86, x86.arch);
    try std.testing.expect(!x86.uefi_x64);
    try std.testing.expectEqual(Arch.arm64, classify(.{ .efi_aa64 = true, .boot_wim = true }).arch);
    try std.testing.expectEqual(Arch.multi, classify(.{ .efi_x64 = true, .efi_ia32 = true }).arch);
    // BIOS-only media: the boot.wim metadata decides.
    try std.testing.expectEqual(Arch.x86, classify(.{ .bootmgr = true, .boot_wim = true, .wim_arch = 0 }).arch);
    try std.testing.expectEqual(Arch.x64, classify(.{ .bootmgr = true, .boot_wim = true, .wim_arch = 9 }).arch);
    try std.testing.expectEqual(Arch.unknown, classify(.{ .boot_wim = true }).arch);
    try std.testing.expectEqualStrings("x86", Arch.x86.label());
    try std.testing.expectEqualStrings("ARM64", Arch.arm64.label());
}

test "32-bit media is blocked on x64 UEFI but allowed through BIOS/CSM" {
    const x86 = classify(.{ .efi_ia32 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(Block.needs_32bit_uefi_or_bios, block(x86, .uefi_x64).?);
    try std.testing.expect(block(x86, .bios) == null);
    try std.testing.expect(block(x86, .uefi_ia32) == null);

    const x64 = classify(.{ .efi_x64 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expect(block(x64, .uefi_x64) == null);
    try std.testing.expect(block(x64, .bios) == null);

    const arm = classify(.{ .efi_aa64 = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(Block.arm64_media, block(arm, .uefi_x64).?);
    try std.testing.expectEqual(Block.arm64_media, block(arm, .bios).?);

    // x64 BIOS-only Windows media (no EFI loader) cannot start on UEFI.
    const bios_only = classify(.{ .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true, .wim_arch = 9 });
    try std.testing.expectEqual(Block.no_uefi_loader, block(bios_only, .uefi_x64).?);

    // An external PE donor starts it instead: only the loader gate goes.
    try std.testing.expect(blockWith(bios_only, .uefi_x64, .pe_donor) == null);
    try std.testing.expectEqual(Block.needs_32bit_uefi_or_bios, blockWith(x86, .uefi_x64, .pe_donor).?);
    try std.testing.expectEqual(Block.arm64_media, blockWith(arm, .uefi_x64, .pe_donor).?);
    try std.testing.expectEqual(Block.no_uefi_loader, blockWith(bios_only, .uefi_ia32, .pe_donor).?);

    // Unknown or unreadable media is never blocked here.
    try std.testing.expect(block(.{ .unreadable = true, .arch = .x86 }, .uefi_x64) == null);
    try std.testing.expect(block(classify(.{}), .uefi_x64) == null);
}

test "boot.wim ARCH is read from the declared image" {
    const metadata = "<WIM><IMAGE INDEX=\"1\"><WINDOWS><ARCH>0</ARCH></WINDOWS></IMAGE><IMAGE INDEX=\"2\"><WINDOWS><ARCH>9</ARCH></WINDOWS></IMAGE></WIM>";
    var bytes: [metadata.len * 2 + 2]u8 = undefined;
    inline for (.{ 1, 2 }) |index| {
        bytes[0] = 0xff;
        bytes[1] = 0xfe;
        for (metadata, 0..) |ch, i| {
            bytes[2 + i * 2] = ch;
            bytes[3 + i * 2] = 0;
        }
        try std.testing.expectEqual(@as(u32, if (index == 1) 0 else 9), try wimArch(&bytes, index));
    }
    var bad = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(error.InvalidWimXml, wimArch(&bad, 1));
}

/// Fixture XML (UTF-8 text in testdata) as the WIM stores it: UTF-16LE + BOM.
fn fixtureInstall(comptime name: []const u8) !Install {
    const text = @embedFile("testdata/" ++ name);
    const gpa = std.testing.allocator;
    const units = try std.unicode.utf8ToUtf16LeAlloc(gpa, text);
    defer gpa.free(units);
    const bytes = try gpa.alloc(u8, 2 + units.len * 2);
    defer gpa.free(bytes);
    bytes[0] = 0xff;
    bytes[1] = 0xfe;
    for (units, 0..) |unit, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], unit, .little);
    return parseInstall(bytes);
}

test "Server 2022 install.wim: Standard and Datacenter, Core and Desktop Experience" {
    const install = try fixtureInstall("install-server-2022.xml");
    try std.testing.expect(install.known and install.server and !install.client and !install.ia64);
    try std.testing.expectEqual(@as(u16, 4), install.images);
    const both = ServerEdition.standard.bit() | ServerEdition.datacenter.bit();
    try std.testing.expectEqual(both, install.core);
    try std.testing.expectEqual(both, install.desktop);
    try std.testing.expectEqual(@as(u32, 20348), install.build);
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Standard (Core), Standard (Desktop Experience), Datacenter (Core), Datacenter (Desktop Experience)",
        formatEditions(install, &buffer, "Core", "Desktop Experience"),
    );
    // Localized labels (pl: "z pulpitem") come from the caller.
    try std.testing.expectEqualStrings("Standard (Core), Standard (z pulpitem), Datacenter (Core), Datacenter (z pulpitem)", formatEditions(install, &buffer, "Core", "z pulpitem"));
    try std.testing.expectEqualStrings("Windows Server 2022", suggestedFolder(install).?);
    try std.testing.expectEqual(FolderHint.server_in_client_folder, folderHint(install, false));
    try std.testing.expectEqual(FolderHint.none, folderHint(install, true));
}

test "Server 2008 R2: Core comes from the EDITIONID suffix too" {
    const install = try fixtureInstall("install-server-2008-r2.xml");
    try std.testing.expect(install.serverOnly());
    const all = ServerEdition.standard.bit() | ServerEdition.enterprise.bit() | ServerEdition.datacenter.bit() | ServerEdition.web.bit();
    try std.testing.expectEqual(all, install.core);
    try std.testing.expectEqual(all, install.desktop);
    try std.testing.expectEqualStrings("Windows Server 2008 R2", suggestedFolder(install).?);
    var buffer: [48]u8 = undefined;
    // A short buffer keeps whole entries only.
    try std.testing.expectEqualStrings("Standard (Core), Standard (Desktop Experience)", formatEditions(install, &buffer, "Core", "Desktop Experience"));
}

test "IA64 Server 2008 R2 media is blocked on every firmware" {
    const install = try fixtureInstall("install-server-2008-r2-ia64.xml");
    try std.testing.expect(install.ia64 and install.server);
    try std.testing.expectEqual(ServerEdition.enterprise.bit(), install.desktop);
    // Itanium media: only efi/boot/bootia64.efi, boot.wim ARCH 6.
    var info = classify(.{ .efi_ia64 = true, .boot_wim = true, .setup_exe = true, .install_image = true, .wim_arch = 6 });
    try std.testing.expectEqual(Arch.ia64, info.arch);
    try std.testing.expectEqualStrings("IA64", info.arch.label());
    for (std.enums.values(Firmware)) |firmware| try std.testing.expectEqual(Block.ia64_media, block(info, firmware).?);
    // The install image alone decides too.
    info = classify(.{ .efi_x64 = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    info.install = install;
    try std.testing.expectEqual(Block.ia64_media, block(info, .uefi_x64).?);
}

test "eval and Hyper-V Server editions; x86 Server 2008 follows the Vista gate" {
    const install = try fixtureInstall("install-server-2019-eval-hyperv.xml");
    try std.testing.expectEqual(ServerEdition.datacenter.bit() | ServerEdition.hyperv.bit(), install.core);
    try std.testing.expectEqual(ServerEdition.datacenter.bit(), install.desktop);
    try std.testing.expectEqualStrings("Windows Server 2019", suggestedFolder(install).?);
    var buffer: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Datacenter (Core), Datacenter (Desktop Experience), Hyper-V Server (Core)", formatEditions(install, &buffer, "Core", "Desktop Experience"));
    // 32-bit Server 2008: BIOS and 32-bit UEFI only, like Vista x86.
    const x86 = classify(.{ .efi_ia32 = true, .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(Block.needs_32bit_uefi_or_bios, block(x86, .uefi_x64).?);
    try std.testing.expect(block(x86, .uefi_ia32) == null and block(x86, .bios) == null);
}

test "client media: no Server editions, hint in a Server folder" {
    const install = try fixtureInstall("install-windows-10-client.xml");
    // ServerRdsh (Enterprise multi-session) is a client edition.
    try std.testing.expect(install.clientOnly());
    try std.testing.expectEqual(@as(u16, 0), install.core | install.desktop);
    try std.testing.expectEqualStrings("Windows 10", suggestedFolder(install).?);
    try std.testing.expectEqual(FolderHint.client_in_server_folder, folderHint(install, true));
    try std.testing.expectEqual(FolderHint.none, folderHint(install, false));
    try std.testing.expectEqual(FolderHint.none, folderHint(.{}, true));
}

test "edition ids and version folders" {
    try std.testing.expectEqual(ServerEdition.standard, serverEdition("ServerStandardCore").?);
    try std.testing.expectEqual(ServerEdition.datacenter, serverEdition("ServerDatacenterACor").?);
    try std.testing.expectEqual(ServerEdition.essentials, serverEdition("ServerSolution").?);
    try std.testing.expectEqual(ServerEdition.foundation, serverEdition("ServerFoundation").?);
    try std.testing.expectEqual(ServerEdition.storage, serverEdition("ServerStorageStandard").?);
    try std.testing.expectEqual(ServerEdition.other, serverEdition("ServerAzureStackHCICor").?);
    try std.testing.expect(serverEdition("Professional") == null);
    try std.testing.expect(serverEdition("Enterprise") == null);
    const Case = struct { server: bool, major: u16, minor: u16, build: u32, folder: ?[]const u8 };
    const cases = [_]Case{
        .{ .server = true, .major = 6, .minor = 0, .build = 6002, .folder = "Windows Server 2008" },
        .{ .server = true, .major = 6, .minor = 2, .build = 9200, .folder = "Windows Server 2012" },
        .{ .server = true, .major = 6, .minor = 3, .build = 9600, .folder = "Windows Server 2012 R2" },
        .{ .server = true, .major = 10, .minor = 0, .build = 14393, .folder = "Windows Server 2016" },
        .{ .server = true, .major = 10, .minor = 0, .build = 26100, .folder = "Windows Server 2025" },
        .{ .server = true, .major = 10, .minor = 0, .build = 10240, .folder = null },
        .{ .server = false, .major = 10, .minor = 0, .build = 22631, .folder = "Windows 11" },
        .{ .server = false, .major = 6, .minor = 1, .build = 7601, .folder = "Windows 7" },
        .{ .server = false, .major = 5, .minor = 1, .build = 2600, .folder = null },
    };
    for (cases) |c| {
        const install = Install{ .known = true, .images = 1, .server = c.server, .client = !c.server, .major = c.major, .minor = c.minor, .build = c.build };
        const folder = suggestedFolder(install);
        if (c.folder) |expected| try std.testing.expectEqualStrings(expected, folder.?) else try std.testing.expect(folder == null);
    }
    var empty = [_]u8{ 0xff, 0xfe, '<', 0, 'W', 0, '>', 0 };
    try std.testing.expectError(error.InvalidWimXml, parseInstall(&empty));
}
