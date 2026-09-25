//! Secure Boot state and the menu entries that cannot run while it is on.
//!
//! USOS starts under Secure Boot through a Microsoft-signed shim and its own
//! MOK key. Everything USOS itself loads is signed, but some flows hand the
//! machine to code no Secure Boot database will accept: CSM/legacy boot
//! (Windows XP through CSMWrap), Windows 7 through UefiSeven and the old
//! Windows 7/Vista boot managers. Those entries are marked instead of failing.
const std = @import("std");
const Backend = @import("preparation_capability.zig").Backend;

pub const State = enum {
    /// SecureBoot variable missing: pre-2.3.1 firmware or Legacy BIOS.
    unsupported,
    disabled,
    /// Setup Mode (no Platform Key): signatures are not enforced.
    setup_mode,
    enforcing,

    /// Derives the state from the EFI global variables SecureBoot and
    /// SetupMode (each one byte; null when the variable does not exist).
    pub fn fromVariables(secure_boot: ?u8, setup_mode: ?u8) State {
        const enabled = secure_boot orelse return .unsupported;
        if (setup_mode) |mode| {
            if (mode == 1) return .setup_mode;
        }
        return if (enabled == 1) .enforcing else .disabled;
    }

    pub fn enforced(self: State) bool {
        return self == .enforcing;
    }
};

/// Systems whose every UEFI path needs Secure Boot off: XP boots through
/// CSMWrap/CSM; Windows 7 and Vista use UefiSeven (int10) and boot managers
/// that predate Secure Boot.
pub fn systemRequiresSecureBootOff(system_id: []const u8) bool {
    return @import("../catalog/os_profiles.zig").traits(system_id).secure_boot_off;
}

/// Backend-level check used again right before starting (defence in depth
/// for selections that bypass the system list).
pub fn backendRequiresSecureBootOff(system_id: []const u8, backend: Backend) bool {
    return switch (backend) {
        .xp_uefi_staging => true,
        .windows_iso => systemRequiresSecureBootOff(system_id),
        // BIOS-only backends never run under UEFI Secure Boot; the firmware
        // check rejects them first.
        .xp_staging, .windows_bios_iso, .win9x_dos, .dos_bios_iso, .linux_live_iso => false,
        .wimboot, .vhdboot, .direct_efi, .chainload => false,
    };
}

pub fn blocked(state: State, system_id: []const u8) bool {
    return state.enforced() and systemRequiresSecureBootOff(system_id);
}

test "state follows SecureBoot and SetupMode" {
    try std.testing.expectEqual(State.unsupported, State.fromVariables(null, null));
    try std.testing.expectEqual(State.disabled, State.fromVariables(0, 0));
    try std.testing.expectEqual(State.enforcing, State.fromVariables(1, 0));
    try std.testing.expectEqual(State.enforcing, State.fromVariables(1, null));
    try std.testing.expectEqual(State.setup_mode, State.fromVariables(1, 1));
    try std.testing.expectEqual(State.setup_mode, State.fromVariables(0, 1));
    try std.testing.expect(State.enforcing.enforced());
    try std.testing.expect(!State.setup_mode.enforced());
}

test "only CSM and pre-Secure-Boot Windows paths are blocked" {
    try std.testing.expect(blocked(.enforcing, "windows-xp"));
    try std.testing.expect(blocked(.enforcing, "windows-7"));
    try std.testing.expect(blocked(.enforcing, "windows-vista"));
    try std.testing.expect(!blocked(.enforcing, "windows-11"));
    try std.testing.expect(!blocked(.enforcing, "windows-10"));
    try std.testing.expect(!blocked(.disabled, "windows-xp"));
    try std.testing.expect(!blocked(.setup_mode, "windows-7"));
    try std.testing.expect(backendRequiresSecureBootOff("windows-xp", .xp_uefi_staging));
    try std.testing.expect(backendRequiresSecureBootOff("windows-7", .windows_iso));
    try std.testing.expect(!backendRequiresSecureBootOff("windows-11", .windows_iso));
    try std.testing.expect(!backendRequiresSecureBootOff("windows-10", .wimboot));
}
