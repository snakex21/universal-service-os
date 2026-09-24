const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const Firmware = @import("../core/firmware.zig").Firmware;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const compatibility = @import("../catalog/boot_compatibility.zig");
const capability = @import("preparation_capability.zig");
const validation = @import("backend_validation.zig");

pub const Option = struct {
    method: BootMethod,
    backend: ?capability.Backend,
    enabled: bool,
    firmware_compatible: bool,
    validation_status: ?validation.Status,
    reason: []const u8,
};

pub fn collect(system: *const SystemEntry, image: ImageKind, firmware: Firmware, out: []Option) usize {
    var len: usize = 0;
    for (system.boot_methods) |method| {
        if (len >= out.len) break;
        const compatible = compatibility.methodSupportsImage(method, image);
        const resolved = if (compatible) capability.resolveForFirmware(system, image, method, firmware) else null;
        const implemented = resolved != null;
        const firmware_requirement = if (resolved) |backend| backend.firmwareRequirement() else method.firmwareRequirement();
        const firmware_compatible = firmware_requirement.accepts(firmware);
        out[len] = .{
            .method = method,
            .backend = resolved,
            .enabled = implemented and firmware_compatible,
            .firmware_compatible = firmware_compatible,
            .validation_status = if (resolved) |backend| validation.statusSelection(backend, system.id, image) else if (compatible) validation.status(method) else null,
            .reason = if (!firmware_compatible) firmware_requirement.mismatchReason(firmware) else if (implemented) "" else if (!compatible) incompatibleReason(method) else backendReason(method),
        };
        len += 1;
    }
    return len;
}

pub fn enabledCount(options: []const Option) usize {
    var count: usize = 0;
    for (options) |option| {
        if (option.enabled) count += 1;
    }
    return count;
}

test "Windows 7 has ISO boot without a chainload menu option" {
    const windows7 = @import("../catalog/systems.zig").findById("windows-7").?;
    var options: [10]Option = undefined;
    const count = collect(windows7, .iso, .uefi, &options);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expect(options[0].method == .automatic and options[0].enabled);
    try std.testing.expect(options[1].method == .direct_iso and options[1].enabled);
    for (options[0..count]) |option| try std.testing.expect(option.method != .chainload);
}

fn incompatibleReason(method: BootMethod) []const u8 {
    return switch (method) {
        .automatic => "[no compatible automatic path]",
        .direct_iso => "[requires ISO]",
        .wimboot => "[requires WIM]",
        .vhdboot => "[requires VHD or VHDX]",
        .direct_efi => "[requires EFI]",
        .chainload => "[requires ISO, IMG or EFI]",
        .memdisk => "[requires ISO or IMG]",
        .disk_image => "[requires IMG]",
        .floppy_image => "[requires IMG]",
    };
}

fn backendReason(method: BootMethod) []const u8 {
    return switch (method) {
        .automatic => "[no implemented backend]",
        else => "[backend not implemented]",
    };
}

test "Windows 11 ISO keeps planned methods visible and enables implemented ISO paths" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .iso, .uefi, &options);

    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(usize, 3), enabledCount(options[0..len]));
    // Automatic / ISO: the native wimboot start (QEMU-validated so far).
    try std.testing.expect(options[0].method == .automatic and options[0].enabled);
    try std.testing.expectEqual(validation.Status.tested_in_vm, options[0].validation_status.?);
    try std.testing.expect(options[1].method == .direct_iso and options[1].enabled);
    try std.testing.expectEqual(validation.Status.tested_in_vm, options[1].validation_status.?);
    try std.testing.expect(options[2].method == .wimboot and !options[2].enabled);
    try std.testing.expectEqualStrings("[requires WIM]", options[2].reason);
    try std.testing.expect(options[3].method == .vhdboot and !options[3].enabled);
    try std.testing.expectEqualStrings("[requires VHD or VHDX]", options[3].reason);
    try std.testing.expect(options[5].method == .chainload and options[5].enabled);
    try std.testing.expectEqual(validation.Status.validated_hardware, options[5].validation_status.?);
}

test "standalone WIM exposes Automatic and WIMBoot as real methods" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .wim, .uefi, &options);

    var automatic_ready = false;
    var wimboot_ready = false;
    for (options[0..len]) |option| {
        if (option.method == .automatic) {
            automatic_ready = option.enabled;
            try std.testing.expectEqual(validation.Status.tested_in_vm, option.validation_status.?);
        }
        if (option.method == .wimboot) {
            wimboot_ready = option.enabled;
            try std.testing.expectEqual(validation.Status.tested_in_vm, option.validation_status.?);
        }
    }
    try std.testing.expect(automatic_ready);
    try std.testing.expect(wimboot_ready);
}

test "VHD and VHDX expose Automatic and VHDBoot as real methods" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    inline for (.{ ImageKind.vhd, ImageKind.vhdx }) |kind| {
        var options: [10]Option = undefined;
        const len = collect(windows11, kind, .uefi, &options);
        var automatic_ready = false;
        var vhdboot_ready = false;
        for (options[0..len]) |option| {
            if (option.method == .automatic) automatic_ready = option.enabled;
            if (option.method == .vhdboot) vhdboot_ready = option.enabled;
        }
        try std.testing.expect(automatic_ready);
        try std.testing.expect(vhdboot_ready);
    }
}

test "BIOS runtime keeps Direct EFI visible but unavailable with firmware reason" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .efi, .bios, &options);

    var found_direct_efi = false;
    for (options[0..len]) |option| {
        if (option.method == .direct_efi) {
            found_direct_efi = true;
            try std.testing.expect(!option.enabled);
            try std.testing.expect(!option.firmware_compatible);
            try std.testing.expectEqualStrings("[requires UEFI; running BIOS]", option.reason);
        }
    }
    try std.testing.expect(found_direct_efi);
}

test "disabled method reasons distinguish incompatible image from missing backend" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .efi, .uefi, &options);

    var found_direct_efi = false;
    var found_iso = false;
    for (options[0..len]) |option| {
        if (option.method == .direct_efi) {
            found_direct_efi = true;
            try std.testing.expect(option.enabled);
            try std.testing.expectEqual(validation.Status.tested_in_vm, option.validation_status.?);
            try std.testing.expectEqualStrings("", option.reason);
        }
        if (option.method == .direct_iso) {
            found_iso = true;
            try std.testing.expect(!option.enabled);
            try std.testing.expectEqualStrings("[requires ISO]", option.reason);
        }
    }
    try std.testing.expect(found_direct_efi);
    try std.testing.expect(found_iso);
}
