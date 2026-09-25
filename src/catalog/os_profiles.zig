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

/// The Windows 7 / Vista native wimboot start is UEFI-only code; the
/// freestanding BIOS Core compiles those rules out.
pub const native_windows7_enabled = builtin.os.tag != .freestanding;

pub const AnswerFormat = enum {
    winnt_sif,
    autounattend_xml,

    pub fn extension(self: AnswerFormat) []const u8 {
        return switch (self) {
            .winnt_sif => ".sif",
            .autounattend_xml => ".xml",
        };
    }

    pub fn fileKindLabel(self: AnswerFormat) []const u8 {
        return switch (self) {
            .winnt_sif => "WINNT.SIF",
            .autounattend_xml => "unattend.xml",
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
    answer: AnswerFormat = .autounattend_xml,
    /// Every UEFI path of this system needs Secure Boot off (CSM, UefiSeven,
    /// boot managers older than Secure Boot).
    secure_boot_off: bool = false,
    native_uefi: NativeUefi = .none,
    /// An ISO of this system is prepared by the NT5 (XP/2000) staging.
    nt5_staging: bool = false,
};

pub const traits_table = [_]SystemTraits{
    .{ .system_id = "windows-xp", .answer = .winnt_sif, .secure_boot_off = true, .nt5_staging = true },
    .{ .system_id = "windows-2000", .answer = .winnt_sif, .nt5_staging = true },
    .{ .system_id = "windows-7", .secure_boot_off = true, .native_uefi = .win7 },
    .{ .system_id = "windows-vista", .secure_boot_off = true, .native_uefi = .vista },
    .{ .system_id = "windows-10", .native_uefi = .modern },
    .{ .system_id = "windows-11", .native_uefi = .modern },
};

pub fn traits(system_id: []const u8) SystemTraits {
    for (traits_table) |entry| {
        if (std.mem.eql(u8, entry.system_id, system_id)) return entry;
    }
    return .{ .system_id = system_id };
}

pub const Systems = union(enum) {
    any,
    ids: []const []const u8,
    /// NT5 staging systems of the Windows legacy family (XP, 2000).
    nt5_staging,
    /// Systems whose ISO starts natively on UEFI with this kind.
    native: NativeUefi,

    fn matches(self: Systems, system: *const SystemEntry) bool {
        return switch (self) {
            .any => true,
            .ids => |ids| for (ids) |id| {
                if (std.mem.eql(u8, id, system.id)) break true;
            } else false,
            .nt5_staging => system.family == .windows_legacy and traits(system.id).nt5_staging,
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
const auto_iso = &[_]BootMethod{ .automatic, .direct_iso };
const auto_iso_memdisk = &[_]BootMethod{ .automatic, .direct_iso, .memdisk };

/// Ordered: firmware-specific rules first, then the firmware-independent
/// ones (the former resolveBackend). First match wins.
pub const profiles = [_]Profile{
    // ---- UEFI only
    .{ .id = "xp-x86-sp3-uefi-csm", .systems = .{ .ids = &.{"windows-xp"} }, .images = iso, .methods = &.{.automatic}, .firmware = .uefi, .backend = .xp_uefi_staging, .progress = .xp_uefi },
    .{ .id = "xp-uefi-other", .systems = .{ .ids = &.{"windows-xp"} }, .firmware = .uefi, .backend = null, .progress = .none },
    // ---- BIOS only
    .{ .id = "linux-live-bios", .systems = .{ .ids = &.{"other-linux"} }, .images = iso, .methods = auto_iso, .firmware = .bios, .backend = .linux_live_iso, .progress = .core },
    .{ .id = "dos-fat16-bios", .systems = .{ .ids = &.{ "ms-dos", "windows-3-1", "windows-3-11" } }, .images = iso, .methods = auto_iso_memdisk, .firmware = .bios, .backend = .dos_bios_iso, .progress = .core },
    .{ .id = "win98se-dos-bios", .systems = .{ .ids = &.{"windows-98-se"} }, .images = iso, .methods = auto_iso_memdisk, .firmware = .bios, .backend = .win9x_dos, .progress = .core },
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
    for (traits_table) |entry| try std.testing.expect(systems.findById(entry.system_id) != null);
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

test "Windows 10/11 and 7/Vista native UEFI profiles" {
    const systems = @import("systems.zig");
    try std.testing.expectEqualStrings("win10-11-uefi-native", select(systems.findById("windows-10").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqualStrings("windows-pe-bios-iso", select(systems.findById("windows-10").?, .iso, .automatic, .bios).?.id);
    try std.testing.expectEqualStrings("iso-work-chainload", select(systems.findById("windows-10").?, .iso, .chainload, .uefi).?.id);
    try std.testing.expectEqualStrings("win7-uefi-native", select(systems.findById("windows-7").?, .iso, .direct_iso, .uefi).?.id);
    try std.testing.expectEqualStrings("vista-uefi-pe10", select(systems.findById("windows-vista").?, .iso, .automatic, .uefi).?.id);
    try std.testing.expectEqual(NativeUefi.vista, traits("windows-vista").native_uefi);
    try std.testing.expectEqual(NativeUefi.none, traits("windows-8-1").native_uefi);
    try std.testing.expectEqual(AnswerFormat.winnt_sif, traits("windows-2000").answer);
}
