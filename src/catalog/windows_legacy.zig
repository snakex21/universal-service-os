const builtin = @import("builtin");
const BootMethod = @import("boot_method.zig").BootMethod;
const SystemEntry = @import("system_entry.zig").SystemEntry;

const methods = [_]BootMethod{ .automatic, .direct_iso, .chainload, .memdisk, .disk_image, .floppy_image };

pub const entries = [_]SystemEntry{
    .{
        .id = "windows-xp",
        .name = "Windows XP",
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\Windows XP\\Images",
        .unattended_directory = "\\Systems\\Windows\\Windows XP\\Unattended",
        .firmware = .any,
        .boot_methods = &methods,
    },
} ++ uefiOnly(.{
    // Windows XP Media Center Edition 2005 (XP x86 SP3 Setup with the Media
    // Center components in CMPNENTS): the XP flow from UEFI (os_profiles.zig
    // route_as windows-xp, profile xp-x86-sp3-uefi-csm) with its own DATA
    // folder (usos.xp_edition=mce). The BIOS Core leaves it out (size budget).
    uefiLegacy("windows-xp-mce", "Windows XP Media Center Edition 2005", "Windows XP Media Center Edition 2005"),
}) ++ [_]SystemEntry{
    // XP Professional x64 (NT 5.2 amd64): the NT5 staging with an AMD64
    // source (profile xp-x64-sp2-uefi-csm from UEFI, experimental).
    .{
        .id = "windows-xp-x64",
        .name = "Windows XP x64",
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\Windows XP x64\\Images",
        .unattended_directory = "\\Systems\\Windows\\Windows XP x64\\Unattended",
        .firmware = .any,
        .boot_methods = &methods,
    },
    // BIOS staging, and from UEFI the XP UEFI-CSM / CSMWrap preparation
    // (profile w2k-x86-sp4-uefi-csm, experimental).
    .{
        .id = "windows-2000",
        .name = "Windows 2000",
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\Windows 2000\\Images",
        .unattended_directory = "\\Systems\\Windows\\Windows 2000\\Unattended",
        .firmware = .any,
        .boot_methods = &methods,
    },
    // Windows NT 4.0 Workstation: from UEFI the whole install runs in QEMU
    // on the target (profile nt4-x86-qemu-csmwrap, experimental;
    // docs/nt4-2026-10-07.md), then the SP6a system starts through CSMWrap.
    anyFirmware(legacy("windows-nt-4", "Windows NT 4.0", "Windows NT 4.0", true)),
} ++ uefiOnly(.{
    // Windows NT 3.51 Workstation: the NT 4.0 VM flow (profile
    // nt3-x86-qemu-csmwrap, experimental; docs/nt351-2026-10-08.md). UEFI
    // only: the BIOS Core has no NT 3.51 path (and no room).
    uefiLegacy("windows-nt-3-51", "Windows NT 3.51", "Windows NT 3.51"),
}) ++ [_]SystemEntry{
    // Windows 95/98/Me: the BIOS Core's DOS Setup, and from UEFI the
    // micro-Linux disk preparation with a CSMWrap ESP (profile
    // w9x-uefi-csmwrap, experimental; docs/win9x-modern-2026-09-30.md 4c).
    win9x("windows-me", "Windows Me"),
    win9x("windows-98-se", "Windows 98 SE"),
    win9x("windows-98", "Windows 98"),
    win9x("windows-95", "Windows 95"),
} ++ uefiOnly(.{
    // Windows for Workgroups 3.11: the Windows 3.1 flow (SETUP /H:USOS.SHH).
    early("windows-wfw-3-11", "Windows for Workgroups 3.11", "Windows for Workgroups 3.11"),
}) ++ [_]SystemEntry{
    anyFirmware(legacy("windows-3-11", "Windows 3.11", "Windows 3.11", false)),
    anyFirmware(legacy("windows-3-1", "Windows 3.1", "Windows 3.1", false)),
} ++ uefiOnly(.{
    // Windows 1.0x-3.0 (docs/windows-early-2026-10-07.md): MS-DOS 6.22, then
    // their original Setup from A: (SUBST to C:\WINSETUP), own start menu.
    early("windows-3-0", "Windows 3.0", "Windows 3.0"),
    early("windows-2-11-386", "Windows 2.11 (386)", "Windows 2.11 (386)"),
    early("windows-2-11-286", "Windows 2.11 (286)", "Windows 2.11 (286)"),
    early("windows-2-03", "Windows 2.03", "Windows 2.03"),
    early("windows-1-04", "Windows 1.04", "Windows 1.04"),
    early("windows-1-01", "Windows 1.01", "Windows 1.01"),
});

/// Only the UEFI menu's DOS-family preparation (w9x-uefi-csmwrap) stages
/// these; the BIOS Core (freestanding, size budget) leaves them out.
const freestanding = builtin.os.tag == .freestanding;

pub fn uefiOnly(comptime list: anytype) [if (freestanding) 0 else list.len]SystemEntry {
    var result: [if (freestanding) 0 else list.len]SystemEntry = undefined;
    if (!freestanding) {
        inline for (list, 0..) |entry, i| result[i] = entry;
    }
    return result;
}

/// A UEFI-only entry with an Unattended folder (Windows NT 3.51).
fn uefiLegacy(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    var result = legacy(id, name, folder, true);
    result.firmware = .uefi;
    return result;
}

/// `folder`: the DATA folder (Systems\Windows\<folder>\Images); no "/".
fn early(comptime id: []const u8, comptime name: []const u8, comptime folder: []const u8) SystemEntry {
    var result = legacy(id, name, folder, false);
    result.firmware = .uefi;
    return result;
}

fn legacy(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime folder: []const u8,
    comptime unattended: bool,
) SystemEntry {
    return .{
        .id = id,
        .name = name,
        .category = .windows,
        .family = .windows_legacy,
        .image_directory = "\\Systems\\Windows\\" ++ folder ++ "\\Images",
        .unattended_directory = if (unattended) "\\Systems\\Windows\\" ++ folder ++ "\\Unattended" else null,
        .firmware = .bios,
        .boot_methods = &methods,
    };
}

fn win9x(comptime id: []const u8, comptime name: []const u8) SystemEntry {
    return anyFirmware(legacy(id, name, name, true));
}

/// BIOS-only installers that UEFI starts through the DOS-family CSMWrap
/// preparation (profile w9x-uefi-csmwrap).
fn anyFirmware(entry: SystemEntry) SystemEntry {
    var result = entry;
    result.firmware = .any;
    return result;
}
