const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const FirmwareRequirement = @import("../catalog/firmware_requirement.zig").FirmwareRequirement;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const systems = @import("../catalog/systems.zig");
const native_windows7_enabled = @import("builtin").os.tag != .freestanding;
fn nativeLegacyNt(system_id: []const u8) bool {
    return native_windows7_enabled and (std.mem.eql(u8, system_id, "windows-7") or std.mem.eql(u8, system_id, "windows-vista"));
}

pub const unavailable_reason = "No implemented boot backend supports this selection.";

pub const Backend = enum {
    windows_iso,
    xp_staging,
    xp_uefi_staging,
    windows_bios_iso,
    win9x_dos,
    dos_bios_iso,
    linux_live_iso,
    wimboot,
    vhdboot,
    direct_efi,
    chainload,

    pub fn firmwareRequirement(self: Backend) FirmwareRequirement {
        return switch (self) {
            .xp_staging, .windows_bios_iso, .win9x_dos, .dos_bios_iso, .linux_live_iso => .bios,
            .xp_uefi_staging, .windows_iso, .wimboot, .vhdboot, .direct_efi, .chainload => .uefi,
        };
    }

    pub fn method(self: Backend) BootMethod {
        return switch (self) {
            .windows_iso => .direct_iso,
            .xp_uefi_staging, .xp_staging, .windows_bios_iso, .win9x_dos, .dos_bios_iso, .linux_live_iso => .direct_iso,
            .wimboot => .wimboot,
            .vhdboot => .vhdboot,
            .direct_efi => .direct_efi,
            .chainload => .chainload,
        };
    }
};

pub fn supportsSystem(system_id: []const u8) bool {
    return systems.findById(system_id) != null;
}

pub fn resolveForFirmware(system: *const SystemEntry, image: ImageKind, method: BootMethod, firmware: @import("../core/firmware.zig").Firmware) ?Backend {
    if (firmware == .uefi and std.mem.eql(u8, system.id, "windows-xp"))
        return if (image == .iso and method == .automatic) .xp_uefi_staging else null;
    if (firmware == .bios and std.mem.eql(u8, system.id, "other-linux") and image == .iso and
        (method == .automatic or method == .direct_iso)) return .linux_live_iso;
    if (firmware == .bios and (std.mem.eql(u8, system.id, "ms-dos") or std.mem.eql(u8, system.id, "windows-3-1") or std.mem.eql(u8, system.id, "windows-3-11")) and image == .iso and
        (method == .automatic or method == .direct_iso or method == .memdisk)) return .dos_bios_iso;
    if (firmware == .bios and std.mem.eql(u8, system.id, "windows-98-se") and image == .iso and
        (method == .automatic or method == .direct_iso or method == .memdisk)) return .win9x_dos;
    if (firmware == .bios and (std.mem.eql(u8, system.id, "windows-7") or std.mem.eql(u8, system.id, "windows-vista") or std.mem.eql(u8, system.id, "windows-10")) and image == .iso and
        (method == .automatic or method == .direct_iso)) return .windows_bios_iso;
    return resolveBackend(system, image, method);
}

pub fn resolveBackend(system: *const SystemEntry, image: ImageKind, method: BootMethod) ?Backend {
    if (method == .chainload and std.mem.eql(u8, system.id, "windows-7")) return null;
    const is_xp = system.family == .windows_legacy and
        (std.mem.eql(u8, system.id, "windows-xp") or std.mem.eql(u8, system.id, "windows-2000"));
    return switch (method) {
        .automatic => switch (image) {
            .iso => if (is_xp)
                .xp_staging
            else if (std.mem.eql(u8, system.id, "windows-11") or nativeLegacyNt(system.id))
                .windows_iso
            else
                .chainload,
            .wim => .wimboot,
            .vhd, .vhdx => .vhdboot,
            .efi => .direct_efi,
            else => null,
        },
        .direct_iso => if (image == .iso and (std.mem.eql(u8, system.id, "windows-11") or nativeLegacyNt(system.id)))
            .windows_iso
        else
            null,
        .wimboot => if (image == .wim) .wimboot else null,
        .vhdboot => if (image == .vhd or image == .vhdx) .vhdboot else null,
        .direct_efi => if (image == .efi) .direct_efi else null,
        .chainload => switch (image) {
            .iso, .efi => .chainload,
            else => null,
        },
        else => null,
    };
}

pub fn resolve(system_id: []const u8, image: ImageKind, method: BootMethod) ?BootMethod {
    const system = systems.findById(system_id) orelse return null;
    const backend = resolveBackend(system, image, method) orelse return null;
    return backend.method();
}

pub fn supports(system_id: []const u8, image: ImageKind, method: BootMethod) bool {
    const system = systems.findById(system_id) orelse return false;
    return resolveBackend(system, image, method) != null;
}

pub fn validate(system_id: []const u8, image: ImageKind, method: BootMethod) !void {
    const system = systems.findById(system_id) orelse return error.UnsupportedSystem;
    if (resolveBackend(system, image, method) != null) return;

    const image_compatible = switch (method) {
        .automatic => image == .iso or image == .wim or image == .vhd or image == .vhdx or image == .efi,
        .direct_iso => image == .iso,
        .wimboot => image == .iso or image == .wim,
        .vhdboot => image == .vhd or image == .vhdx,
        .direct_efi => image == .efi,
        .chainload => image == .iso or image == .img or image == .efi,
        .memdisk => image == .iso or image == .img,
        .disk_image, .floppy_image => image == .img,
    };
    if (!image_compatible) return error.UnsupportedImage;
    return error.UnsupportedMethod;
}

test "Windows 11 ISO keeps verified ISO preparation as automatic path" {
    try std.testing.expectEqual(BootMethod.direct_iso, resolve("windows-11", .iso, .automatic).?);
    try std.testing.expectEqual(BootMethod.direct_iso, resolve("windows-11", .iso, .direct_iso).?);
}

test "first Linux Live backend is scoped to the Other Linux BIOS ISO profile" {
    const entry = systems.findById("other-linux").?;
    try std.testing.expectEqual(Backend.linux_live_iso, resolveForFirmware(entry, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.linux_live_iso, resolveForFirmware(entry, .iso, .direct_iso, .bios).?);
    try std.testing.expect(resolveForFirmware(entry, .iso, .automatic, .uefi).? != .linux_live_iso);
    try std.testing.expect(resolveForFirmware(entry, .img, .direct_iso, .bios) == null);
    try std.testing.expect(resolveForFirmware(systems.findById("debian").?, .iso, .automatic, .bios).? != .linux_live_iso);
}

test "generic ISO images can use real chainload preparation" {
    try std.testing.expectEqual(BootMethod.chainload, resolve("ubuntu", .iso, .automatic).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("ubuntu", .iso, .chainload).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("windows-10", .iso, .chainload).?);
}

test "EFI images can start directly or through explicit chainload" {
    try std.testing.expectEqual(BootMethod.direct_efi, resolve("ubuntu", .efi, .automatic).?);
    try std.testing.expectEqual(BootMethod.direct_efi, resolve("ubuntu", .efi, .direct_efi).?);
    try std.testing.expectEqual(BootMethod.chainload, resolve("ubuntu", .efi, .chainload).?);
}

test "Windows XP ISO resolves to dedicated XP staging backend" {
    const xp = systems.findById("windows-xp").?;
    try std.testing.expectEqual(Backend.xp_staging, resolveBackend(xp, .iso, .automatic).?);
    try std.testing.expect(resolveBackend(xp, .iso, .direct_iso) == null);
    try std.testing.expect(resolveBackend(xp, .iso, .automatic).? != .chainload);
}

test "one XP entry preserves BIOS staging and routes UEFI ISO to CSM preparation" {
    const xp = systems.findById("windows-xp").?;
    try std.testing.expectEqual(FirmwareRequirement.any, xp.firmware);
    try std.testing.expect(systems.findById("windows-xp-uefi-csm-pae") == null);
    try std.testing.expectEqual(Backend.xp_staging, resolveForFirmware(xp, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.xp_uefi_staging, resolveForFirmware(xp, .iso, .automatic, .uefi).?);
    try std.testing.expect(resolveForFirmware(xp, .efi, .automatic, .uefi) == null);
    try std.testing.expect(resolveForFirmware(xp, .iso, .chainload, .uefi) == null);
}

test "Windows 2000 uses the shared NT5 backend only for an automatic ISO" {
    const win2k = systems.findById("windows-2000").?;
    const backend = resolveForFirmware(win2k, .iso, .automatic, .bios).?;
    try std.testing.expectEqual(Backend.xp_staging, backend);
    try std.testing.expectEqual(FirmwareRequirement.bios, backend.firmwareRequirement());
    try std.testing.expect(resolveBackend(win2k, .iso, .direct_iso) == null);
    try std.testing.expect(resolveBackend(win2k, .img, .automatic) == null);
    try std.testing.expect(resolveBackend(systems.findById("windows-nt-4").?, .iso, .automatic).? != .xp_staging);
}

test "Windows 7 BIOS ISO preparation does not change UEFI or XP routing" {
    const win7 = systems.findById("windows-7").?;
    try std.testing.expect(resolveForFirmware(win7, .iso, .chainload, .uefi) == null);
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(win7, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(win7, .iso, .direct_iso, .bios).?);
    try std.testing.expectEqual(Backend.windows_iso, resolveForFirmware(win7, .iso, .automatic, .uefi).?);
    try std.testing.expectEqual(Backend.windows_iso, resolveForFirmware(win7, .iso, .direct_iso, .uefi).?);
    try std.testing.expect(resolveForFirmware(win7, .wim, .direct_iso, .bios) == null);
    try std.testing.expectEqual(Backend.xp_staging, resolveForFirmware(systems.findById("windows-xp").?, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.windows_iso, resolveForFirmware(systems.findById("windows-11").?, .iso, .automatic, .uefi).?);
}

test "Vista BIOS path is retained and UEFI ISO uses the PE10 donor path" {
    const vista = systems.findById("windows-vista").?;
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(vista, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(vista, .iso, .direct_iso, .bios).?);
    try std.testing.expectEqual(Backend.windows_iso, resolveForFirmware(vista, .iso, .automatic, .uefi).?);
    try std.testing.expectEqual(Backend.windows_iso, resolveForFirmware(vista, .iso, .direct_iso, .uefi).?);
}

test "Windows 10 BIOS ISO uses Windows PE without changing UEFI or other images" {
    const win10 = systems.findById("windows-10").?;
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(win10, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.windows_bios_iso, resolveForFirmware(win10, .iso, .direct_iso, .bios).?);
    try std.testing.expectEqual(Backend.chainload, resolveForFirmware(win10, .iso, .automatic, .uefi).?);
    try std.testing.expect(resolveForFirmware(win10, .iso, .direct_iso, .uefi) == null);
    try std.testing.expect(resolveForFirmware(win10, .wim, .direct_iso, .bios) == null);
    try std.testing.expect(resolveForFirmware(win10, .iso, .memdisk, .bios) == null);
    try std.testing.expectEqual(Backend.wimboot, resolveForFirmware(win10, .wim, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.chainload, resolveForFirmware(systems.findById("windows-8").?, .iso, .automatic, .bios).?);
}

test "Windows 98 SE DOS backend is restricted to BIOS ISO selections" {
    const win98 = systems.findById("windows-98-se").?;
    try std.testing.expectEqual(Backend.win9x_dos, resolveForFirmware(win98, .iso, .automatic, .bios).?);
    try std.testing.expectEqual(Backend.win9x_dos, resolveForFirmware(win98, .iso, .direct_iso, .bios).?);
    try std.testing.expectEqual(Backend.win9x_dos, resolveForFirmware(win98, .iso, .memdisk, .bios).?);
    try std.testing.expect(resolveForFirmware(win98, .img, .memdisk, .bios) == null);
    try std.testing.expect(resolveForFirmware(win98, .iso, .memdisk, .uefi) == null);
    try std.testing.expectEqual(Backend.chainload, resolveForFirmware(win98, .iso, .automatic, .uefi).?);
}

test "MS-DOS and Windows 3.x use the FAT16 BIOS ISO backend only" {
    for ([_][]const u8{ "ms-dos", "windows-3-1", "windows-3-11" }) |id| {
        const entry = systems.findById(id).?;
        for ([_]BootMethod{ .automatic, .direct_iso, .memdisk }) |method|
            try std.testing.expectEqual(Backend.dos_bios_iso, resolveForFirmware(entry, .iso, method, .bios).?);
        try std.testing.expect(resolveForFirmware(entry, .img, .memdisk, .bios) == null);
        try std.testing.expect(resolveForFirmware(entry, .iso, .memdisk, .uefi) == null);
        try std.testing.expect(resolveForFirmware(entry, .iso, .automatic, .uefi).? != .dos_bios_iso);
    }
    try std.testing.expect(resolveForFirmware(systems.findById("freedos").?, .iso, .automatic, .bios).? != .dos_bios_iso);
}

test "standalone WIM and VHD images resolve to their native Windows boot backends" {
    try std.testing.expectEqual(BootMethod.wimboot, resolve("windows-11", .wim, .automatic).?);
    try std.testing.expectEqual(BootMethod.wimboot, resolve("windows-11", .wim, .wimboot).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhd, .automatic).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhd, .vhdboot).?);
    try std.testing.expectEqual(BootMethod.vhdboot, resolve("windows-11", .vhdx, .vhdboot).?);
}
