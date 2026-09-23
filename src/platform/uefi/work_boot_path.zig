//! Where the prepared WORK partition keeps its UEFI boot entry.
//!
//! WORK must never carry the removable-media fallback `\EFI\BOOT\BOOTX64.EFI`
//! (or BOOTIA32/BOOTAA64): AMI Aptio and other firmware list every partition
//! that has it as a separate "UEFI: <disk>, Partition N" boot option. The
//! preparation scripts therefore publish the chain under `\EFI\USOS-WORK\`
//! (see tools/work_boot_relocate.sh). WORK volumes prepared by older builds
//! still have `\EFI\BOOT\`; for one release the chainloader falls back to it
//! when the new path is missing (the update engine also migrates it).
//!
//! Pure path policy only (no UEFI calls), so it is unit-tested on the host.
const std = @import("std");
const builtin = @import("builtin");

pub const primary_dir = "EFI/USOS-WORK";
/// Removable-media path used by WORK volumes prepared before the move.
/// Kept as a read-only fallback for one release; remove it afterwards.
pub const legacy_dir = "EFI/BOOT";

pub fn entryName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .x86 => "BOOTIA32.EFI",
        else => "BOOTX64.EFI",
    };
}

pub const Candidates = [2][]const u8;

/// Boot entry paths in lookup order: the new location first, then the
/// legacy removable-media path.
pub fn candidatesFor(comptime arch: std.Target.Cpu.Arch) Candidates {
    const name = comptime entryName(arch);
    return .{ primary_dir ++ "/" ++ name, legacy_dir ++ "/" ++ name };
}

pub const candidates: Candidates = candidatesFor(builtin.cpu.arch);

pub const Selection = struct {
    path: []const u8,
    legacy: bool,
};

/// Returns the first candidate for which `exists(context, path)` is true.
pub fn select(list: Candidates, context: anytype, comptime exists: fn (@TypeOf(context), []const u8) bool) ?Selection {
    for (list, 0..) |path, index| {
        if (exists(context, path)) return .{ .path = path, .legacy = index != 0 };
    }
    return null;
}

const FakeVolume = struct {
    files: []const []const u8,

    fn has(self: *const FakeVolume, path: []const u8) bool {
        for (self.files) |file| {
            if (std.ascii.eqlIgnoreCase(file, path)) return true;
        }
        return false;
    }
};

test "work boot path prefers EFI/USOS-WORK" {
    const volume = FakeVolume{ .files = &.{ "EFI/USOS-WORK/BOOTX64.EFI", "EFI/BOOT/BOOTX64.EFI" } };
    const chosen = select(candidatesFor(.x86_64), &volume, FakeVolume.has).?;
    try std.testing.expectEqualStrings("EFI/USOS-WORK/BOOTX64.EFI", chosen.path);
    try std.testing.expect(!chosen.legacy);
}

test "work boot path falls back to legacy EFI/BOOT" {
    const volume = FakeVolume{ .files = &.{"EFI/BOOT/BOOTX64.EFI"} };
    const chosen = select(candidatesFor(.x86_64), &volume, FakeVolume.has).?;
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTX64.EFI", chosen.path);
    try std.testing.expect(chosen.legacy);
}

test "work boot path reports missing entry" {
    const volume = FakeVolume{ .files = &.{ "EFI/USOS-WORK/win7.efi", "sources/install.wim" } };
    try std.testing.expect(select(candidatesFor(.x86_64), &volume, FakeVolume.has) == null);
}

test "work boot path uses the architecture entry name" {
    const ia32 = candidatesFor(.x86);
    try std.testing.expectEqualStrings("EFI/USOS-WORK/BOOTIA32.EFI", ia32[0]);
    try std.testing.expectEqualStrings("EFI/BOOT/BOOTIA32.EFI", ia32[1]);
    const aa64 = candidatesFor(.aarch64);
    try std.testing.expectEqualStrings("EFI/USOS-WORK/BOOTAA64.EFI", aa64[0]);
}
