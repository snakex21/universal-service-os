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
const std = @import("std");

pub const Arch = enum {
    unknown,
    x64,
    x86,
    arm64,
    /// Dual-architecture media (x64 and x86 loaders side by side).
    multi,

    pub fn label(self: Arch) []const u8 {
        return switch (self) {
            .unknown => "",
            .x64 => "x64",
            .x86 => "x86",
            .arm64 => "ARM64",
            .multi => "x64/x86",
        };
    }

    /// WIM <ARCH> values (PROCESSOR_ARCHITECTURE_*).
    pub fn fromWim(code: u32) Arch {
        return switch (code) {
            0 => .x86,
            9 => .x64,
            12 => .arm64,
            else => .unknown,
        };
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
pub const boot_wim = "sources/boot.wim";
pub const setup_exe = "sources/setup.exe";
pub const bios_bootmgr = "bootmgr";

pub const Presence = struct {
    efi_x64: bool = false,
    efi_ia32: bool = false,
    efi_aa64: bool = false,
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
};

pub const Firmware = enum { uefi_x64, uefi_ia32, bios };

pub fn block(info: Info, firmware: Firmware) ?Block {
    if (info.unreadable) return null;
    switch (firmware) {
        .uefi_x64 => {
            if (info.arch == .arm64) return .arm64_media;
            if (info.arch == .x86) return .needs_32bit_uefi_or_bios;
            // Windows boot media with a readable layout but no x64 loader
            // (and not identified as x86 above) cannot start here either.
            if (info.content != .not_windows and info.content != .unknown and !info.uefi_x64 and info.arch == .x64) return .no_uefi_loader;
            return null;
        },
        .uefi_ia32 => return if (info.arch == .x86 or info.arch == .multi) null else if (info.arch == .unknown) null else .no_uefi_loader,
        .bios => return if (info.arch == .arm64) .arm64_media else null,
    }
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
