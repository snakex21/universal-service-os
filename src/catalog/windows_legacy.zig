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
    // Windows 95/98/Me: the BIOS Core's DOS Setup, and from UEFI the
    // micro-Linux disk preparation with a CSMWrap ESP (profile
    // w9x-uefi-csmwrap, experimental; docs/win9x-modern-2026-09-30.md 4c).
    win9x("windows-me", "Windows Me"),
    win9x("windows-98-se", "Windows 98 SE"),
    win9x("windows-98", "Windows 98"),
    win9x("windows-95", "Windows 95"),
    anyFirmware(legacy("windows-3-11", "Windows 3.11", "Windows 3.11", false)),
    anyFirmware(legacy("windows-3-1", "Windows 3.1", "Windows 3.1", false)),
};

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
