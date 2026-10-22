//! OS profiles as data (refactor M1, docs/design/refactor-os-pipeline.md 2.3).
//!
//! Two comptime tables replace the `system.id` string comparisons that were
//! spread over preparation_capability, secure_boot_policy, unattended_policy
//! and the UEFI summary:
//!
//!   traits    per catalog system: answer-file format, Secure Boot need,
//!             native UEFI ISO start kind, NT5 staging
//!   profiles  ordered routing rules: (systems, images, methods, firmware)
//!             -> backend; the first matching rule wins, a rule without a
//!             backend refuses the selection
//!
//! The rules reproduce the routing that was hand-written in
//! preparation_capability.zig; src/flow/testdata/routing_golden.tsv pins it.
//! Pipeline steps, plans and answer rendering are later milestones.
const std = @import("std");
const builtin = @import("builtin");
const BootMethod = @import("boot_method.zig").BootMethod;
const ImageKind = @import("image_kind.zig").ImageKind;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const Firmware = @import("../core/firmware.zig").Firmware;
const Backend = @import("../flow/preparation_capability.zig").Backend;
const windows_media = @import("../image_probe/windows_media.zig");

/// The Windows 7 / Vista native wimboot start is UEFI-only code; the
/// freestanding BIOS Core compiles those rules out.
pub const native_windows7_enabled = builtin.os.tag != .freestanding;

pub const AnswerFormat = enum {
    winnt_sif,
    autounattend_xml,
    /// Windows 95/98/Me DOS Setup (docs/win9x-modern-2026-09-30.md).
    msbatch_inf,

    pub fn extension(self: AnswerFormat) []const u8 {
        return switch (self) {
            .winnt_sif => ".sif",
            .autounattend_xml => ".xml",
            .msbatch_inf => ".inf",
        };
    }

    pub fn fileKindLabel(self: AnswerFormat) []const u8 {
        return switch (self) {
            .winnt_sif => "WINNT.SIF",
            .autounattend_xml => "unattend.xml",
            .msbatch_inf => "MSBATCH.INF",
        };
    }
};

/// How the UEFI menu starts this system's Setup ISO straight from DATA.
pub const NativeUefi = enum {
    none,
    /// Windows 10/11: the ISO's own WinPE (modern-support.cpio).
    modern,
    /// Windows 7: hybrid PE7 or the external PE10 donor (win7-support.cpio).
    win7,
    /// Windows Vista: always the external PE10 donor (vista-support.cpio).
    vista,

    pub fn legacyPe(self: NativeUefi) bool {
        return self == .win7 or self == .vista;
    }
};

pub const SystemTraits = struct {
    system_id: []const u8,
    /// This system is routed exactly like `route_as` (a client Windows that
    /// shares its Setup): the traits below are taken from that entry and the
    /// profile rules match its id. Only the DATA folders differ.
    route_as: ?[]const u8 = null,
    /// Setup has no inbox NVMe driver (Windows Server 2012): the summary
    /// hints at DATA\Drivers\<folder>\Storage when the PC has an NVMe disk.
    no_inbox_nvme: bool = false,
    answer: AnswerFormat = .autounattend_xml,
    /// Every UEFI path of this system needs Secure Boot off (CSM, UefiSeven,
    /// boot managers older than Secure Boot).
    secure_boot_off: bool = false,
    native_uefi: NativeUefi = .none,
    /// An ISO of this system is prepared by the NT5 (XP/2000) staging.
    nt5_staging: bool = false,
    /// USOS settings file in the Unattended folder (hands-off Setup without
    /// an answer file; docs/xp-unattended.md). The answer screen shows it.
    settings_file: ?[]const u8 = null,
    /// The installed system boots through the USOS Int10 dispatcher on the
    /// target ESP (win7-wrapper.efi: firmware Int10 -> the original boot
    /// manager, none -> VGA routing + UefiSeven), so it starts with or
    /// without CSM (docs/design/win7-vista-no-csm.md sections 4, 5, 7).
    /// Windows 7 always had it; for Vista it adds the dispatcher assets'
    /// flag to the wimboot plan (usos-int10-dispatcher.flag).
    int10_dispatcher: bool = false,
    /// The built-in menu icon (UI\Icons\Systems\<id>.png) of another entry,
    /// for a system without its own: XP x64 and Server 2003 (NT 5.2) show
    /// the XP icon, as the routed Servers show their client release's.
    icon_as: ?[]const u8 = null,
    /// 32-bit media of this system on 64-bit UEFI without a firmware CSM
    /// take win-x86-uefi-csmwrap (the ISO's own WinPE, or the x86 PE10 donor
    /// on NVMe), although its routing stays non-native: Windows 8 RTM (6.2,
    /// build 9200). Its x64 media keep the WORK copy on UEFI and BIOS (the
    /// native x64 start was never run with PE 4.0; Server 2012, routed as
    /// Windows 8, has no x86 media and is unchanged).
    x86_csmwrap: bool = false,
};

pub const traits_table = [_]SystemTraits{
    .{ .system_id = "windows-xp", .answer = .winnt_sif, .secure_boot_off = true, .nt5_staging = true, .settings_file = "usos-xp.ini" },
    .{ .system_id = "windows-2000", .answer = .winnt_sif, .secure_boot_off = true, .nt5_staging = true, .settings_file = "usos-xp.ini" },
    .{ .system_id = "windows-xp-x64", .answer = .winnt_sif, .secure_boot_off = true, .nt5_staging = true, .settings_file = "usos-xp.ini", .icon_as = "windows-xp" },
    .{ .system_id = "windows-server-2003", .answer = .winnt_sif, .secure_boot_off = true, .nt5_staging = true, .settings_file = "usos-xp.ini", .icon_as = "windows-xp" },
    .{ .system_id = "windows-7", .secure_boot_off = true, .native_uefi = .win7, .int10_dispatcher = true },
    .{ .system_id = "windows-vista", .secure_boot_off = true, .native_uefi = .vista, .int10_dispatcher = true },
    .{ .system_id = "windows-10", .native_uefi = .modern },
    .{ .system_id = "windows-11", .native_uefi = .modern },
    // Windows 8.1 (PE 5.0, build 9600): on UEFI the same native start as
    // 10/11 (the ISO's own WinPE, ESP guard and finalizer); Server 2012 R2
    // and Embedded 8.1 Industry follow it. BIOS keeps the WORK copy
    // (profile win81-bios-chainload); Windows 8 / Server 2012 keep it on both.
    // Windows 8 RTM: only its 32-bit media without CSM take the x86 CSMWrap
    // path (x86_csmwrap; manual_images.x86Csmwrap).
    .{ .system_id = "windows-8-1", .native_uefi = .modern },
    .{ .system_id = "windows-8", .x86_csmwrap = true },
    // Windows Server (src/catalog/windows_server.zig): the client release
    // with the same Setup. 2016-2025: the Windows 10/11 native UEFI start and
    // the Windows 10 BIOS Core start; 2012 R2 / 2012: Windows 8.1 / 8;
    // 2008 R2: Windows 7; 2008: Vista.
    .{ .system_id = "windows-server-2025", .route_as = "windows-10" },
    .{ .system_id = "windows-server-2022", .route_as = "windows-10" },
    .{ .system_id = "windows-server-2019", .route_as = "windows-10" },
    .{ .system_id = "windows-server-2016", .route_as = "windows-10" },
    .{ .system_id = "windows-server-2012-r2", .route_as = "windows-8-1" },
    .{ .system_id = "windows-server-2012", .route_as = "windows-8", .no_inbox_nvme = true },
    .{ .system_id = "windows-server-2008-r2", .route_as = "windows-7" },
    .{ .system_id = "windows-server-2008", .route_as = "windows-vista" },
    // Linux ISO from DATA: SystemRescue ships no Microsoft-signed shim.
    .{ .system_id = "systemrescue", .secure_boot_off = true },
} ++ (if (native_windows7_enabled) [_]SystemTraits{
    // Windows 2000 Server (UEFI only, src/catalog/windows_server.zig): the
    // Windows 2000 NT5 staging with the same driver set; the micro-Linux
    // reads its own DATA folder and adds the Server answers.
    .{ .system_id = "windows-2000-server", .route_as = "windows-2000" },
    // Windows XP Media Center Edition 2005 (UEFI only, windows_legacy.zig):
    // the XP x86 staging (pae.exe, driver bundle, usos-xp.ini) from its own
    // DATA folder; the micro-Linux copies CMPNENTS into the local source.
    .{ .system_id = "windows-xp-mce", .route_as = "windows-xp" },
    // Windows XP Tablet PC Edition 2005 (UEFI only, windows_legacy.zig): the
    // same XP x86 staging from its own DATA folder (CMPNENTS\TABLETPC).
    .{ .system_id = "windows-xp-tablet", .route_as = "windows-xp" },
    // Windows Embedded POSReady 2009 (UEFI only, windows_legacy.zig): its
    // own VM flow (posready-x86-qemu-csmwrap); POSReady Setup reads an XML
    // answer (a DATA Unattended\*.xml is offered), the XP icon.
    .{ .system_id = "windows-embedded-posready-2009", .icon_as = "windows-xp", .answer = .autounattend_xml },
    // Windows Embedded 8.1 Industry (UEFI only, windows_modern.zig): the
    // Windows 8.1 native start from its own DATA folder.
    .{ .system_id = "windows-embedded-8-1-industry", .route_as = "windows-8-1" },
    // Windows Home Server 2011 (UEFI only, windows_server.zig): the Windows 7
    // native start (PE10 donor, Setup from the ISO) from its own DATA folder.
    .{ .system_id = "windows-home-server-2011", .route_as = "windows-7" },
    .{ .system_id = "windows-embedded-standard-7", .route_as = "windows-7" },
    .{ .system_id = "windows-embedded-posready-7", .route_as = "windows-7" },
    .{ .system_id = "windows-flp", .route_as = "windows-embedded-posready-2009" },
    .{ .system_id = "citrix-winframe-1-8", .route_as = "windows-nt-3-51-server" },
    .{ .system_id = "windows-whistler", .route_as = "windows-xp" },
    .{ .system_id = "windows-neptune", .route_as = "windows-2000" },
    .{ .system_id = "windows-longhorn", .route_as = "windows-vista" },
    .{ .system_id = "windows-7-beta", .route_as = "windows-7" },
    .{ .system_id = "windows-millennium", .route_as = "windows-me" },
    .{ .system_id = "windows-nashville", .route_as = "windows-95" },
    .{ .system_id = "windows-chicago", .route_as = "windows-95" },
    .{ .system_id = "windows-memphis", .route_as = "windows-98" },
    .{ .system_id = "windows-2000-beta", .route_as = "windows-2000" },
    .{ .system_id = "windows-nt-4-beta", .route_as = "windows-nt-4" },
    .{ .system_id = "windows-nt-3-beta", .route_as = "windows-nt-3-51" },
    .{ .system_id = "windows-cairo", .route_as = "windows-nt-4" },
} else [_]SystemTraits{});

fn ownTraits(system_id: []const u8) SystemTraits {
    for (traits_table) |entry| {
        if (std.mem.eql(u8, entry.system_id, system_id)) return entry;
    }
    // Windows 95/98/98 SE/Me (no table rows: the Legacy Core has no room).
    const win9x = std.mem.eql(u8, system_id, "windows-98-se") or std.mem.eql(u8, system_id, "windows-98") or
        std.mem.eql(u8, system_id, "windows-me") or std.mem.eql(u8, system_id, "windows-95");
    // Windows NT 4.0 / 3.51 (answer/nt4.zig, nt3.zig WINNT.SIF), no rows for
    // the same reason.
    const nt4 = std.mem.startsWith(u8, system_id, "windows-nt-");
    return .{ .system_id = system_id, .answer = if (win9x) .msbatch_inf else if (nt4) .winnt_sif else .autounattend_xml };
}

pub fn traits(system_id: []const u8) SystemTraits {
    const own = ownTraits(system_id);
    const base_id = own.route_as orelse return own;
    var result = ownTraits(base_id);
    result.system_id = system_id;
    result.route_as = base_id;
    result.no_inbox_nvme = own.no_inbox_nvme;
    return result;
}

/// The id the profile rules see: the `route_as` system, else the id itself.
pub fn routeId(system_id: []const u8) []const u8 {
    return ownTraits(system_id).route_as orelse system_id;
}

/// The built-in icon a system without its own falls back to: `icon_as`,
/// else the `route_as` system (Server entries show their client's icon),
/// else the id itself.
pub fn iconId(system_id: []const u8) []const u8 {
    const own = ownTraits(system_id);
    return own.icon_as orelse own.route_as orelse system_id;
}

test "NT 5.2 entries and the routed Servers fall back to a client icon" {
    try std.testing.expectEqualStrings("windows-xp", iconId("windows-xp-x64"));
    try std.testing.expectEqualStrings("windows-xp", iconId("windows-server-2003"));
    try std.testing.expectEqualStrings("windows-vista", iconId("windows-server-2008"));
    try std.testing.expectEqualStrings("windows-10", iconId("windows-server-2022"));
    try std.testing.expectEqualStrings("windows-xp", iconId("windows-xp"));
    // The icon alias never changes the routing.
    try std.testing.expectEqualStrings("windows-server-2003", routeId("windows-server-2003"));
    try std.testing.expectEqualStrings("windows-xp-x64", routeId("windows-xp-x64"));
    // Windows 2000 Server takes the Windows 2000 routing, traits and icon.
    try std.testing.expectEqualStrings("windows-2000", routeId("windows-2000-server"));
    try std.testing.expectEqualStrings("windows-2000", iconId("windows-2000-server"));
    try std.testing.expect(traits("windows-2000-server").nt5_staging);
    try std.testing.expectEqual(AnswerFormat.winnt_sif, traits("windows-2000-server").answer);
    // XP Media Center Edition takes the XP routing, traits and icon.
    try std.testing.expectEqualStrings("windows-xp", routeId("windows-xp-mce"));
    try std.testing.expectEqualStrings("windows-xp", iconId("windows-xp-mce"));
    try std.testing.expect(traits("windows-xp-mce").nt5_staging);
    try std.testing.expectEqualStrings("usos-xp.ini", traits("windows-xp-mce").settings_file.?);
    // So does XP Tablet PC Edition.
    try std.testing.expectEqualStrings("windows-xp", routeId("windows-xp-tablet"));
    try std.testing.expectEqualStrings("windows-xp", iconId("windows-xp-tablet"));
    try std.testing.expect(traits("windows-xp-tablet").nt5_staging);
    try std.testing.expectEqualStrings("usos-xp.ini", traits("windows-xp-tablet").settings_file.?);
}

/// The start gate of a probed Windows ISO of this system (image list, boot
/// summary, requestPreparation). Windows 7/Vista and Server 2008/2008 R2
/// (route_as) start through the external PE10 donor on UEFI, so the media's
/// own missing bootx64.efi does not block them; the architecture and IA64
/// gates stay, and the donor/media rejections are windows7_iso's.
pub fn mediaBlock(system_id: []const u8, info: windows_media.Info, firmware: windows_media.Firmware) ?windows_media.Block {
    const loader: windows_media.UefiLoader = if (traits(system_id).native_uefi.legacyPe()) .pe_donor else .media;
    return windows_media.blockWith(info, firmware, loader);
}

/// "<folder>" of a Windows system's "\Systems\Windows\<folder>\Images".
pub fn windowsFolder(system: *const SystemEntry) ?[]const u8 {
    const suffix = "\\Images";
    const directory = system.image_directory;
    for ([_][]const u8{ "\\Systems\\Windows\\", "\\Systems\\Betas\\" }) |prefix| {
        if (std.mem.startsWith(u8, directory, prefix) and std.mem.endsWith(u8, directory, suffix) and directory.len > prefix.len + suffix.len)
            return directory[prefix.len .. directory.len - suffix.len];
    }
    return null;
}

pub const Systems = union(enum) {
    any,
    ids: []const []const u8,
    /// NT5 staging systems (XP, XP x64, 2000, Server 2003).
    nt5_staging,
    /// Systems whose ISO starts natively on UEFI with this kind.
    native: NativeUefi,

    fn matches(self: Systems, system: *const SystemEntry) bool {
        return switch (self) {
            .any => true,
            .ids => |ids| for (ids) |id| {
                if (std.mem.eql(u8, id, routeId(system.id))) break true;
            } else false,
            .nt5_staging => traits(system.id).nt5_staging,
            .native => |kind| traits(system.id).native_uefi == kind,
        };
    }
};

/// Which progress page runs the profile's stages, and with which rows.
pub const Progress = enum {
    /// Refused selection: nothing runs.
    none,
    /// The BIOS Core draws its own screens.
    core,
    /// UEFI handoff, then the micro-Linux preparation (WORK, WIM/VHD boot).
    micro_linux,
    /// Native wimboot start from the ISO (Windows 7, Vista, 10, 11).
    direct_iso,
    /// Windows XP from UEFI: UEFI stage 1, then the NT5 staging.
    xp_uefi,
    /// A UEFI application from Images, started directly.
    efi_image,
    /// A Linux ISO from DATA: its kernel started directly with the USOS helper.
    linux_iso,
    // Rows: src/flow/plan.zig stageLabels (kept out of the catalog module,
    // which the BIOS Core also links next to the graphics module).
};

pub const FirmwareMatch = enum {
    /// Also matches a firmware-less selection (e2e validation, help text).
    any,
    bios,
    uefi,
};

pub const Profile = struct {
    id: []const u8,
    systems: Systems = .any,
    /// Empty: any image kind.
    images: []const ImageKind = &.{},
    /// Empty: any boot method.
    methods: []const BootMethod = &.{},
    firmware: FirmwareMatch = .any,
    /// Null: the selection is refused (no later rule is tried).
    backend: ?Backend,
    /// Rule exists only outside the freestanding BIOS Core.
    host_only: bool = false,
    progress: Progress,

    pub fn matches(self: *const Profile, system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: ?Firmware) bool {
        if (self.host_only and !native_windows7_enabled) return false;
        switch (self.firmware) {
            .any => {},
            .bios => if (firmware != .bios) return false,
            .uefi => if (firmware != .uefi) return false,
        }
        if (self.images.len != 0 and std.mem.indexOfScalar(ImageKind, self.images, image) == null) return false;
        if (self.methods.len != 0 and std.mem.indexOfScalar(BootMethod, self.methods, method) == null) return false;
        return self.systems.matches(system);
    }
};

const iso = &[_]ImageKind{.iso};
/// Every catalog Linux system (src/catalog/linux_systems.zig).
const linux_ids = &[_][]const u8{ "ubuntu", "debian", "fedora", "linux-mint", "arch-linux", "opensuse", "manjaro", "kali-linux", "systemrescue", "gparted-live", "clonezilla", "other-linux" };
const auto_iso = &[_]BootMethod{ .automatic, .direct_iso };
const auto_iso_memdisk = &[_]BootMethod{ .automatic, .direct_iso, .memdisk };

/// UEFI-only rules. The freestanding BIOS Core never runs with UEFI firmware,
/// so it leaves them out of its image (Core size budget); the order of
/// `profiles` is unchanged on every other target.
/// The DOS-family CSMWrap preparation from UEFI (micro-Linux step 620).
const dos_family_ids = &[_][]const u8{ "windows-98-se", "windows-98", "windows-me", "windows-95", "ms-dos", "windows-3-1", "windows-3-11" } ++ windows_early_ids;
/// Windows for Workgroups 3.11 and Windows 1.0x-3.0: UEFI only (the BIOS
/// Core does not carry them; src/catalog/windows_legacy.zig).
pub const windows_early_ids = &[_][]const u8{ "windows-wfw-3-11", "windows-3-0", "windows-2-11-386", "windows-2-11-286", "windows-2-03", "windows-1-04", "windows-1-01" };

const nt4_ids = &[_][]const u8{ "windows-nt-4", "windows-nt-4-server", "windows-nt-4-tse" };
const posready_ids = &[_][]const u8{"windows-embedded-posready-2009"};
/// Custom OS (src/catalog/other_systems.zig) and FreeDOS from UEFI: the image
/// written to the target disk (docs/custom-os-2026-10-11.md).
pub const custom_image_ids = &[_][]const u8{ "haiku", "freebsd", "reactos", "kolibrios", "openbsd", "netbsd", "9front", "redox", "other-os", "freedos" };
const nt3_ids = &[_][]const u8{ "windows-nt-3-51", "windows-nt-3-51-server", "windows-nt-3-5", "windows-nt-3-5-server", "windows-nt-3-1", "windows-nt-3-1-server" };

const uefi_profiles = [_]Profile{
    // ---- UEFI only
    // Linux ISO from DATA (docs/design/linux-iso-boot.md): kernel + initrd from
    // the ISO, /usos/init maps the ISO file as a block device. Replaces the WORK
    // chainload for Linux ISOs, which never booted live media.
    .{ .id = "linux-iso-uefi", .systems = .{ .ids = linux_ids }, .images = iso, .methods = auto_iso, .firmware = .uefi, .backend = .linux_iso, .progress = .linux_iso },
    .{ .id = "xp-x86-sp3-uefi-csm", .systems = .{ .ids = &.{"windows-xp"} }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .xp_uefi_staging, .progress = .xp_uefi },
    .{ .id = "xp-uefi-other", .systems = .{ .ids = &.{"windows-xp"} }, .firmware = .uefi, .backend = null, .progress = .none },
    // Windows 2000 from UEFI: the same micro-Linux preparation and package
    // (EFI/USOS-XP), 2000 answer and no XP driver bundle (NT 5.1 only);
    // experimental. docs/windows-2000-uefi-2026-09-27.md.
    .{ .id = "w2k-x86-sp4-uefi-csm", .systems = .{ .ids = &.{"windows-2000"} }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .xp_uefi_staging, .progress = .xp_uefi },
    .{ .id = "w2k-uefi-other", .systems = .{ .ids = &.{"windows-2000"} }, .firmware = .uefi, .backend = null, .progress = .none },
    // Server 2003 x86 and XP x64 (NT 5.2) from UEFI: the same preparation with
    // GenAHCI on the system StorPort; experimental. docs/nt52-2003-xp64-2026-09-27.md.
    .{ .id = "w2k3-x86-sp2-uefi-csm", .systems = .{ .ids = &.{"windows-server-2003"} }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .xp_uefi_staging, .progress = .xp_uefi },
    .{ .id = "w2k3-uefi-other", .systems = .{ .ids = &.{"windows-server-2003"} }, .firmware = .uefi, .backend = null, .progress = .none },
    .{ .id = "xp-x64-sp2-uefi-csm", .systems = .{ .ids = &.{"windows-xp-x64"} }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .xp_uefi_staging, .progress = .xp_uefi },
    .{ .id = "xp-x64-uefi-other", .systems = .{ .ids = &.{"windows-xp-x64"} }, .firmware = .uefi, .backend = null, .progress = .none },
    // Windows 95/98/Me from UEFI: micro-Linux step 620 writes a FAT32 Setup
    // disk with a one-time DOS start and a CSMWrap ESP; Setup then runs from
    // that disk in BIOS mode (docs/win9x-modern-2026-09-30.md 4c).
    .{ .id = "w9x-uefi-csmwrap", .systems = .{ .ids = dos_family_ids }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .win9x_uefi, .progress = .direct_iso },
    .{ .id = "w9x-uefi-other", .systems = .{ .ids = dos_family_ids }, .firmware = .uefi, .backend = null, .progress = .none },
    // Windows NT 4.0 Workstation / Server from UEFI: the same step 620; the
    // whole install runs in QEMU on the target disk (-cpu pentium3, the RTM
    // text-mode kernel cannot start on Zen), then SP6a starts through CSMWrap
    // (docs/nt4-2026-10-07.md).
    .{ .id = "nt4-x86-qemu-csmwrap", .systems = .{ .ids = nt4_ids }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .win9x_uefi, .progress = .direct_iso },
    .{ .id = "nt4-uefi-other", .systems = .{ .ids = nt4_ids }, .firmware = .uefi, .backend = null, .progress = .none },
    // Windows NT 3.51 Workstation / Server from UEFI: the NT 4.0 VM flow
    // (nt4_csmwrap_target.sh with NT_MAJOR=3: E820 filter MBR, \USOS\NT3 with
    // USOSNT3.EXE as !DetachedProgram); no service pack (docs/nt351-2026-10-08.md).
    .{ .id = "nt3-x86-qemu-csmwrap", .systems = .{ .ids = nt3_ids }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .win9x_uefi, .progress = .direct_iso },
    .{ .id = "nt3-uefi-other", .systems = .{ .ids = nt3_ids }, .firmware = .uefi, .backend = null, .progress = .none },
    // Windows Embedded POSReady 2009 from UEFI: the same step 620; Windows PE
    // + POSReady Setup run in QEMU on the target disk (posready_csmwrap_target.sh,
    // posready_qemu_install.sh), then the system starts through CSMWrap
    // (docs/posready-2009-2026-10-10.md).
    .{ .id = "posready-x86-qemu-csmwrap", .systems = .{ .ids = posready_ids }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .win9x_uefi, .progress = .direct_iso },
    .{ .id = "posready-uefi-other", .systems = .{ .ids = posready_ids }, .firmware = .uefi, .backend = null, .progress = .none },
    // Custom OS from UEFI: the same step 620; tools/image_disk_target.sh writes
    // the official hybrid image (ISO or disk image) to the confirmed disk and
    // adds the CSMWrap ESP when the image has no UEFI loader.
    .{ .id = "custom-image-uefi", .systems = .{ .ids = custom_image_ids }, .images = &.{ .iso, .img }, .methods = &.{.automatic}, .firmware = .uefi, .backend = .win9x_uefi, .progress = .direct_iso },
    .{ .id = "custom-image-uefi-other", .systems = .{ .ids = custom_image_ids }, .firmware = .uefi, .backend = null, .progress = .none },
};

/// Ordered: firmware-specific rules first, then the firmware-independent
/// ones (the former resolveBackend). First match wins.
pub const profiles = (if (native_windows7_enabled) uefi_profiles else [_]Profile{}) ++ [_]Profile{
    // ---- BIOS only
    .{ .id = "linux-live-bios", .systems = .{ .ids = &.{"other-linux"} }, .images = iso, .methods = auto_iso, .firmware = .bios, .backend = .linux_live_iso, .progress = .core },
    // Linux ISO from DATA in the BIOS Core (other-linux keeps the SliTaz row;
    // its backend falls back to this path for non-SliTaz ISOs).
    .{ .id = "linux-iso-bios", .systems = .{ .ids = linux_ids }, .images = iso, .methods = auto_iso, .firmware = .bios, .backend = .linux_iso, .progress = .core },
    .{ .id = "dos-fat16-bios", .systems = .{ .ids = &.{ "ms-dos", "windows-3-1", "windows-3-11" } }, .images = iso, .methods = auto_iso_memdisk, .firmware = .bios, .backend = .dos_bios_iso, .progress = .core },
    // Windows 95/98/Me: the ISO's own DOS boot floppy + DOS Setup from a RAM
    // disk (docs/win9x-modern-2026-09-30.md); also under CSMWrap.
    .{ .id = "win9x-dos-bios", .systems = .{ .ids = &.{ "windows-98-se", "windows-98", "windows-me", "windows-95" } }, .images = iso, .methods = auto_iso_memdisk, .firmware = .bios, .backend = .win9x_dos, .progress = .core },
    // Windows 8.1 / Server 2012 R2 on BIOS: the WORK copy as before the
    // UEFI native start (the BIOS Core's native start is Windows 7/Vista/10).
    .{ .id = "win81-bios-chainload", .systems = .{ .ids = &.{"windows-8-1"} }, .images = iso, .methods = &.{.automatic}, .firmware = .bios, .backend = .chainload, .progress = .micro_linux },
    .{ .id = "win81-bios-other-iso", .systems = .{ .ids = &.{"windows-8-1"} }, .images = iso, .methods = &.{.direct_iso}, .firmware = .bios, .backend = null, .progress = .none },
    .{ .id = "windows-pe-bios-iso", .systems = .{ .ids = &.{ "windows-7", "windows-vista", "windows-10" } }, .images = iso, .methods = auto_iso, .firmware = .bios, .backend = .windows_bios_iso, .progress = .core },
    // ---- any firmware
    .{ .id = "win7-no-chainload", .systems = .{ .ids = &.{"windows-7"} }, .methods = &.{.chainload}, .backend = null, .progress = .none },
    .{ .id = "nt5-staging", .systems = .nt5_staging, .images = iso, .methods = &.{.automatic}, .backend = .xp_staging, .progress = .core },
    .{ .id = "win10-11-uefi-native", .systems = .{ .native = .modern }, .images = iso, .methods = auto_iso, .backend = .windows_iso, .progress = .direct_iso },
    .{ .id = "win7-uefi-native", .systems = .{ .native = .win7 }, .images = iso, .methods = auto_iso, .backend = .windows_iso, .host_only = true, .progress = .direct_iso },
    .{ .id = "vista-uefi-pe10", .systems = .{ .native = .vista }, .images = iso, .methods = auto_iso, .backend = .windows_iso, .host_only = true, .progress = .direct_iso },
    .{ .id = "iso-work-chainload", .images = iso, .methods = &.{ .automatic, .chainload }, .backend = .chainload, .progress = .micro_linux },
    .{ .id = "efi-chainload", .images = &.{.efi}, .methods = &.{.chainload}, .backend = .chainload, .progress = .efi_image },
    .{ .id = "wim-wimboot", .images = &.{.wim}, .methods = &.{ .automatic, .wimboot }, .backend = .wimboot, .progress = .micro_linux },
    .{ .id = "vhd-vhdboot", .images = &.{ .vhd, .vhdx }, .methods = &.{ .automatic, .vhdboot }, .backend = .vhdboot, .progress = .micro_linux },
    .{ .id = "efi-direct", .images = &.{.efi}, .methods = &.{ .automatic, .direct_efi }, .backend = .direct_efi, .progress = .efi_image },
};

/// No firmware CSM (the UEFI menu's secure_boot.csm() is not likely on): the
/// profile that replaces a base profile's start. CSM presence is not a routing
/// input, so these are not rules of `profiles`: the base row still decides the
/// selection, the menu swaps the start (docs/design/csmwrap-integration.md).
pub const CsmwrapVariant = struct {
    base: []const u8,
    id: []const u8,
    /// How the start differs from the base profile's (golden text).
    start: []const u8,
    /// Only for 32-bit media (the base profile's x64 start is unchanged).
    x86_media_only: bool = false,
};

pub const csmwrap_variants = [_]CsmwrapVariant{
    .{ .base = "xp-x86-sp3-uefi-csm", .id = "xp-x86-sp3-uefi-csmwrap", .start = "same micro-Linux staging + usos.xp_boot=csmwrap (CSMWrap ESP at the disk end)" },
    .{ .base = "vista-uefi-pe10", .id = "vista-x64-sp2-uefi-csmwrap", .start = "micro-Linux step 610: MBR disk, Windows partition + PE10 staging partition + CSMWrap ESP; Vista Setup in BIOS mode (InstallTo)" },
    .{ .base = "win10-11-uefi-native", .id = "win-x86-uefi-csmwrap", .start = "x86 media only: micro-Linux step 610: MBR disk, Windows partition + the ISO's own WinPE staging + CSMWrap ESP; Setup in BIOS mode (InstallTo)", .x86_media_only = true },
    // 32-bit Windows 7 / Vista / Server 2008: the same layout, but an x86 PE10
    // donor (Windows 10 x86 Setup ISO) is staged instead of the ISO's own PE.
    .{ .base = "win7-uefi-native", .id = "win-nt6-x86-uefi-csmwrap", .start = "x86 media only: micro-Linux step 610: MBR disk, Windows partition + x86 PE10 donor staging + CSMWrap ESP; the ISO's Setup in BIOS mode (InstallTo)", .x86_media_only = true },
    .{ .base = "vista-uefi-pe10", .id = "win-nt6-x86-uefi-csmwrap", .start = "x86 media only: micro-Linux step 610: MBR disk, Windows partition + x86 PE10 donor staging + CSMWrap ESP; the ISO's Setup in BIOS mode (InstallTo)", .x86_media_only = true },
};

pub fn csmwrapVariant(base_id: []const u8) ?*const CsmwrapVariant {
    return csmwrapVariantFor(base_id, false);
}

/// `x86_media`: the selected image is 32-bit (win-x86-uefi-csmwrap).
pub fn csmwrapVariantFor(base_id: []const u8, x86_media: bool) ?*const CsmwrapVariant {
    // 32-bit media: an x86-only variant of the base wins (Vista x86 is not
    // the Vista x64 PE10 path).
    if (x86_media) for (&csmwrap_variants) |*variant| {
        if (variant.x86_media_only and std.mem.eql(u8, variant.base, base_id)) return variant;
    };
    for (&csmwrap_variants) |*variant| {
        if (variant.x86_media_only) continue;
        if (std.mem.eql(u8, variant.base, base_id)) return variant;
    }
    return null;
}

test "CSMWrap variants replace existing UEFI profiles and have their own ids" {
    const systems = @import("systems.zig");
    for (csmwrap_variants) |variant| {
        const base = findById(variant.base) orelse return error.TestUnexpectedResult;
        try std.testing.expect(base.firmware != .bios);
        try std.testing.expect(findById(variant.id) == null);
    }
    const vista = select(systems.findById("windows-vista").?, .iso, .automatic, .uefi).?;
    try std.testing.expectEqualStrings("vista-x64-sp2-uefi-csmwrap", csmwrapVariant(vista.id).?.id);
    const server = select(systems.findById("windows-server-2008").?, .iso, .automatic, .uefi).?;
    try std.testing.expectEqualStrings("vista-x64-sp2-uefi-csmwrap", csmwrapVariant(server.id).?.id);
    try std.testing.expect(csmwrapVariant("win7-uefi-native") == null);
    // Windows 8.1 / 10: x64 media keep the native UEFI start, x86 media go
    // through CSMWrap.
    for ([_][]const u8{ "windows-10", "windows-8-1", "windows-embedded-8-1-industry" }) |id| {
        const modern = select(systems.findById(id).?, .iso, .automatic, .uefi).?;
        try std.testing.expect(csmwrapVariant(modern.id) == null);
        try std.testing.expectEqualStrings("win-x86-uefi-csmwrap", csmwrapVariantFor(modern.id, true).?.id);
    }
    // Windows 7 / Vista / Server 2008: x86 media through the x86 PE10 donor.
    for ([_][]const u8{ "windows-7", "windows-vista", "windows-server-2008" }) |id| {
        const legacy = select(systems.findById(id).?, .iso, .automatic, .uefi).?;
        try std.testing.expectEqualStrings("win-nt6-x86-uefi-csmwrap", csmwrapVariantFor(legacy.id, true).?.id);
    }
    try std.testing.expectEqualStrings("vista-x64-sp2-uefi-csmwrap", csmwrapVariantFor("vista-uefi-pe10", false).?.id);
}

/// The profile that decides this selection, or null when no rule applies.
/// `firmware == null` is the firmware-less choice (only `.any` rules).
/// A returned profile with `backend == null` refuses the selection.
pub fn select(system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: ?Firmware) ?*const Profile {
    for (&profiles) |*profile| {
        if (profile.matches(system, image, method, firmware)) return profile;
    }
    return null;
}

/// The backend chosen for a selection (null: refused or no rule).
pub fn backend(system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: ?Firmware) ?Backend {
    const profile = select(system, image, method, firmware) orelse return null;
    return profile.backend;
}

pub fn findById(id: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (std.mem.eql(u8, profile.id, id)) return profile;
    }
    return null;
}

test "profile ids are unique and every trait names a catalog system" {
    const systems = @import("systems.zig");
    for (profiles, 0..) |a, i| {
        for (profiles[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
    }
    for (traits_table) |entry| {
        try std.testing.expect(systems.findById(entry.system_id) != null);
        // A routed system names a catalog system that is not routed itself.
        if (entry.route_as) |base| {
            try std.testing.expect(systems.findById(base) != null);
            try std.testing.expect(ownTraits(base).route_as == null);
        }
    }
    for (profiles) |profile| switch (profile.systems) {
        .ids => |ids| for (ids) |id| try std.testing.expect(systems.findById(id) != null),
        else => {},
    };
}

test "XP on UEFI selects the UEFI-CSM profile and refuses everything else" {
    const systems = @import("systems.zig");
    const xp = systems.findById("windows-xp").?;
    try std.testing.expectEqualStrings("xp-x86-sp3-uefi-csm", select(xp, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqualStrings("xp-uefi-other", select(xp, .iso, .chainload, .uefi).?.id);
    try std.testing.expect(backend(xp, .iso, .chainload, .uefi) == null);
    try std.testing.expectEqualStrings("nt5-staging", select(xp, .iso, .automatic, .bios).?.id);
    try std.testing.expectEqualStrings("nt5-staging", select(xp, .iso, .automatic, null).?.id);
}

test "Windows NT 4.0 Workstation, Server and Terminal Server on UEFI: the VM install, nothing else" {
    const systems = @import("systems.zig");
    for ([_][]const u8{ "windows-nt-4", "windows-nt-4-server", "windows-nt-4-tse" }) |id| {
        const nt4 = systems.findById(id).?;
        try std.testing.expectEqualStrings("nt4-x86-qemu-csmwrap", select(nt4, .iso, .automatic, .uefi).?.id);
        try std.testing.expectEqual(Backend.win9x_uefi, backend(nt4, .iso, .automatic, .uefi).?);
        try std.testing.expect(backend(nt4, .iso, .chainload, .uefi) == null);
        try std.testing.expectEqual(AnswerFormat.winnt_sif, traits(id).answer);
    }
}

test "Windows NT 3.51 / 3.5 / 3.1 Workstation and Server on UEFI: the VM install, nothing else" {
    const systems = @import("systems.zig");
    for ([_][]const u8{ "windows-nt-3-51", "windows-nt-3-51-server", "windows-nt-3-5", "windows-nt-3-5-server", "windows-nt-3-1", "windows-nt-3-1-server" }) |id| {
        const nt3 = systems.findById(id).?;
        try std.testing.expectEqualStrings("nt3-x86-qemu-csmwrap", select(nt3, .iso, .automatic, .uefi).?.id);
        try std.testing.expectEqual(Backend.win9x_uefi, backend(nt3, .iso, .automatic, .uefi).?);
        try std.testing.expect(backend(nt3, .iso, .chainload, .uefi) == null);
        try std.testing.expectEqual(AnswerFormat.winnt_sif, traits(id).answer);
    }
}

test "Custom OS and FreeDOS on UEFI: the image written to the target disk, nothing else" {
    const systems = @import("systems.zig");
    for (custom_image_ids) |id| {
        const entry = systems.findById(id).?;
        for ([_]ImageKind{ .iso, .img }) |image| {
            try std.testing.expectEqualStrings("custom-image-uefi", select(entry, image, .automatic, .uefi).?.id);
            try std.testing.expectEqual(Backend.win9x_uefi, backend(entry, image, .automatic, .uefi).?);
        }
        try std.testing.expect(backend(entry, .efi, .automatic, .uefi) == null);
        try std.testing.expect(backend(entry, .iso, .chainload, .uefi) == null);
    }
    // FreeDOS keeps its BIOS Core routes.
    try std.testing.expect(!std.mem.eql(u8, "custom-image-uefi", select(systems.findById("freedos").?, .iso, .automatic, .bios).?.id));
}

test "Windows 10/11 and 7/Vista native UEFI profiles" {
    const systems = @import("systems.zig");
    try std.testing.expectEqualStrings("win10-11-uefi-native", select(systems.findById("windows-10").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqualStrings("windows-pe-bios-iso", select(systems.findById("windows-10").?, .iso, .automatic, .bios).?.id);
    try std.testing.expectEqualStrings("iso-work-chainload", select(systems.findById("windows-10").?, .iso, .chainload, .uefi).?.id);
    try std.testing.expectEqualStrings("win7-uefi-native", select(systems.findById("windows-7").?, .iso, .direct_iso, .uefi).?.id);
    try std.testing.expectEqualStrings("vista-uefi-pe10", select(systems.findById("windows-vista").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqual(NativeUefi.vista, traits("windows-vista").native_uefi);
    try std.testing.expectEqual(NativeUefi.modern, traits("windows-8-1").native_uefi);
    try std.testing.expectEqual(NativeUefi.none, traits("windows-8").native_uefi);
    try std.testing.expectEqualStrings("win10-11-uefi-native", select(systems.findById("windows-8-1").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqualStrings("win81-bios-chainload", select(systems.findById("windows-8-1").?, .iso, .automatic, .bios).?.id);
    try std.testing.expectEqualStrings("win10-11-uefi-native", select(systems.findById("windows-server-2012-r2").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqualStrings("iso-work-chainload", select(systems.findById("windows-8").?, .iso, .automatic, .uefi).?.id);
    // Windows 8: x86 CSMWrap only for its 32-bit media, the routing unchanged;
    // Server 2012 (route_as windows-8) takes the trait but has no x86 media.
    try std.testing.expect(traits("windows-8").x86_csmwrap and !traits("windows-8-1").x86_csmwrap and !traits("windows-10").x86_csmwrap);
    if (native_windows7_enabled) {
        try std.testing.expectEqualStrings("win10-11-uefi-native", select(systems.findById("windows-embedded-8-1-industry").?, .iso, .automatic, .uefi).?.id);
        try std.testing.expectEqualStrings("windows-8-1", iconId("windows-embedded-8-1-industry"));
    }
    try std.testing.expectEqual(AnswerFormat.winnt_sif, traits("windows-2000").answer);
}

test "x64 Windows 7/Vista media without an EFI loader starts through the PE donor" {
    // Retail Win7 SP1 / Vista x64: bootmgr + boot.wim (x64), no efi\boot\bootx64.efi.
    const bios_only_x64 = windows_media.classify(.{ .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true, .wim_arch = 9 });
    try std.testing.expect(!bios_only_x64.uefi_x64);
    for ([_][]const u8{ "windows-7", "windows-vista", "windows-server-2008-r2", "windows-server-2008" }) |id| {
        try std.testing.expect(mediaBlock(id, bios_only_x64, .uefi_x64) == null);
        try std.testing.expect(mediaBlock(id, bios_only_x64, .bios) == null);
    }
    // Windows 8+ and their Server releases keep the loader gate.
    for ([_][]const u8{ "windows-10", "windows-11", "windows-8-1", "windows-8", "windows-server-2022", "windows-server-2012-r2" }) |id| {
        try std.testing.expectEqual(windows_media.Block.no_uefi_loader, mediaBlock(id, bios_only_x64, .uefi_x64).?);
    }
    // 32-bit Windows 7 media is still blocked on x64 UEFI.
    const x86 = windows_media.classify(.{ .bootmgr = true, .boot_wim = true, .setup_exe = true, .install_image = true, .wim_arch = 0 });
    try std.testing.expectEqual(windows_media.Block.needs_32bit_uefi_or_bios, mediaBlock("windows-7", x86, .uefi_x64).?);
    try std.testing.expect(mediaBlock("windows-7", x86, .bios) == null);
    // ARM64 and IA64 stay blocked.
    const arm = windows_media.classify(.{ .efi_aa64 = true, .boot_wim = true, .setup_exe = true, .install_image = true });
    try std.testing.expectEqual(windows_media.Block.arm64_media, mediaBlock("windows-7", arm, .uefi_x64).?);
    var ia64 = bios_only_x64;
    ia64.install.ia64 = true;
    try std.testing.expectEqual(windows_media.Block.ia64_media, mediaBlock("windows-server-2008-r2", ia64, .uefi_x64).?);
}

test "Windows Server follows the client release it shares a Setup with" {
    const systems = @import("systems.zig");
    const Case = struct { id: []const u8, base: []const u8 };
    const cases = [_]Case{
        .{ .id = "windows-server-2025", .base = "windows-10" },
        .{ .id = "windows-server-2022", .base = "windows-10" },
        .{ .id = "windows-server-2019", .base = "windows-10" },
        .{ .id = "windows-server-2016", .base = "windows-10" },
        .{ .id = "windows-server-2012-r2", .base = "windows-8-1" },
        .{ .id = "windows-server-2012", .base = "windows-8" },
        .{ .id = "windows-server-2008-r2", .base = "windows-7" },
        .{ .id = "windows-server-2008", .base = "windows-vista" },
    };
    for (cases) |case| {
        const server = systems.findById(case.id).?;
        const client = systems.findById(case.base).?;
        try std.testing.expectEqualStrings(case.base, routeId(case.id));
        const a = traits(case.id);
        const b = traits(case.base);
        try std.testing.expectEqualStrings(case.id, a.system_id);
        try std.testing.expectEqual(b.native_uefi, a.native_uefi);
        try std.testing.expectEqual(b.secure_boot_off, a.secure_boot_off);
        try std.testing.expectEqual(b.answer, a.answer);
        try std.testing.expectEqualSlices(BootMethod, client.boot_methods, server.boot_methods);
        for (std.enums.values(ImageKind)) |image| for (std.enums.values(BootMethod)) |method| for ([_]?Firmware{ .bios, .uefi, null }) |firmware| {
            try std.testing.expectEqual(select(client, image, method, firmware), select(server, image, method, firmware));
        };
    }
    try std.testing.expect(traits("windows-server-2012").no_inbox_nvme);
    try std.testing.expect(!traits("windows-server-2012-r2").no_inbox_nvme);
    try std.testing.expect(!traits("windows-8").no_inbox_nvme);
    try std.testing.expectEqualStrings("windows-10", routeId("windows-10"));
    try std.testing.expectEqualStrings("Windows Server 2008 R2", windowsFolder(systems.findById("windows-server-2008-r2").?).?);
    try std.testing.expect(windowsFolder(systems.findById("ubuntu").?) == null);
}

test "variants inherit the same existing backend and keep separate DATA directories" {
    const systems = @import("systems.zig");
    const rows = .{
        .{ "windows-whistler", "windows-xp" },
        .{ "windows-neptune", "windows-2000" },
        .{ "windows-longhorn", "windows-vista" },
        .{ "windows-7-beta", "windows-7" },
        .{ "windows-embedded-standard-7", "windows-7" },
        .{ "windows-embedded-posready-7", "windows-7" },
        .{ "windows-flp", "windows-embedded-posready-2009" },
        .{ "citrix-winframe-1-8", "windows-nt-3-51-server" },
        .{ "windows-millennium", "windows-me" },
        .{ "windows-nashville", "windows-95" },
        .{ "windows-chicago", "windows-95" },
        .{ "windows-memphis", "windows-98" },
        .{ "windows-nt-3-beta", "windows-nt-3-51" },
        .{ "windows-nt-4-beta", "windows-nt-4" },
        .{ "windows-cairo", "windows-nt-4" },
    };
    inline for (rows) |row| {
        const variant = systems.findById(row[0]).?;
        const base = systems.findById(row[1]).?;
        try std.testing.expectEqualStrings(row[1], routeId(row[0]));
        try std.testing.expect(!std.mem.eql(u8, variant.image_directory, base.image_directory));
        try std.testing.expectEqual(select(base, .iso, .automatic, .uefi), select(variant, .iso, .automatic, .uefi));
    }
}
