const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const Backend = @import("preparation_capability.zig").Backend;

pub const Status = enum {
    validated_hardware,
    tested_in_vm,
    experimental,

    pub fn badge(self: Status) []const u8 {
        return switch (self) {
            .validated_hardware => "",
            .tested_in_vm => "[TESTED IN VM]",
            .experimental => "[EXPERIMENTAL]",
        };
    }

    pub fn helpLabel(self: Status) []const u8 {
        return switch (self) {
            .validated_hardware => "READY",
            .tested_in_vm => "TESTED IN VM",
            .experimental => "EXPERIMENTAL",
        };
    }
};

pub fn statusBackend(backend: Backend) Status {
    return switch (backend) {
        .xp_uefi_staging, .win9x_dos => .experimental,
        // Green production-path QEMU validation plus physical-media validation.
        .windows_iso,
        .chainload,
        => .validated_hardware,

        // Green VM E2E, but no completed physical-media validation yet.
        .windows_bios_iso,
        .dos_bios_iso,
        .linux_live_iso,
        .xp_staging,
        .direct_efi,
        .wimboot,
        .vhdboot,
        => .tested_in_vm,
    };
}

pub fn statusSelection(backend: Backend, system_id: []const u8, image: @import("../catalog/image_kind.zig").ImageKind) Status {
    // Win7's ISO preparation has its own EFI compatibility and driver path.
    // Its QEMU result must not inherit Windows 10/11's physical validation.
    if (backend == .chainload and image == .iso and std.mem.eql(u8, system_id, "windows-7")) return .tested_in_vm;
    if (@import("builtin").os.tag != .freestanding and backend == .windows_iso and image == .iso and std.mem.eql(u8, system_id, "windows-7")) return .tested_in_vm;
    return statusBackend(backend);
}

pub fn status(method: BootMethod) Status {
    return switch (method) {
        .direct_iso, .chainload => .validated_hardware,
        .direct_efi, .wimboot, .vhdboot => .tested_in_vm,
        .automatic, .memdisk, .disk_image, .floppy_image => .experimental,
    };
}

test "backend validation status is authoritative" {
    try std.testing.expectEqual(Status.validated_hardware, status(.direct_iso));
    try std.testing.expectEqual(Status.validated_hardware, status(.chainload));
    try std.testing.expectEqual(Status.tested_in_vm, status(.direct_efi));
    try std.testing.expectEqual(Status.tested_in_vm, status(.wimboot));
    try std.testing.expectEqual(Status.tested_in_vm, status(.vhdboot));
    try std.testing.expectEqual(Status.experimental, status(.memdisk));
    try std.testing.expectEqual(Status.experimental, status(.disk_image));
    try std.testing.expectEqual(Status.experimental, status(.floppy_image));
}

test "validation badges are defined only here" {
    try std.testing.expectEqualStrings("", Status.validated_hardware.badge());
    try std.testing.expectEqualStrings("[TESTED IN VM]", Status.tested_in_vm.badge());
    try std.testing.expectEqualStrings("[EXPERIMENTAL]", Status.experimental.badge());
}
