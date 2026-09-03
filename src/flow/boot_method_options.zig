const std = @import("std");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const compatibility = @import("../catalog/boot_compatibility.zig");
const capability = @import("preparation_capability.zig");

pub const Option = struct {
    method: BootMethod,
    enabled: bool,
    reason: []const u8,
};

pub fn collect(system: *const SystemEntry, image: ImageKind, out: []Option) usize {
    var len: usize = 0;
    for (system.boot_methods) |method| {
        if (len >= out.len) break;
        const compatible = compatibility.methodSupportsImage(method, image);
        const implemented = compatible and capability.supports(system.id, image, method);
        out[len] = .{
            .method = method,
            .enabled = implemented,
            .reason = if (implemented) "" else if (!compatible) incompatibleReason(method) else backendReason(method),
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
    const len = collect(windows11, .iso, &options);

    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(usize, 3), enabledCount(options[0..len]));
    try std.testing.expect(options[0].method == .automatic and options[0].enabled);
    try std.testing.expect(options[1].method == .direct_iso and options[1].enabled);
    try std.testing.expect(options[2].method == .wimboot and !options[2].enabled);
    try std.testing.expectEqualStrings("[requires WIM]", options[2].reason);
    try std.testing.expect(options[3].method == .vhdboot and !options[3].enabled);
    try std.testing.expectEqualStrings("[requires VHD or VHDX]", options[3].reason);
    try std.testing.expect(options[5].method == .chainload and options[5].enabled);
}

test "standalone WIM exposes Automatic and WIMBoot as real methods" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .wim, &options);

    var automatic_ready = false;
    var wimboot_ready = false;
    for (options[0..len]) |option| {
        if (option.method == .automatic) automatic_ready = option.enabled;
        if (option.method == .wimboot) wimboot_ready = option.enabled;
    }
    try std.testing.expect(automatic_ready);
    try std.testing.expect(wimboot_ready);
}

test "VHD and VHDX expose Automatic and VHDBoot as real methods" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    inline for (.{ ImageKind.vhd, ImageKind.vhdx }) |kind| {
        var options: [10]Option = undefined;
        const len = collect(windows11, kind, &options);
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

test "disabled method reasons distinguish incompatible image from missing backend" {
    const systems = @import("../catalog/systems.zig");
    const windows11 = systems.findById("windows-11").?;
    var options: [10]Option = undefined;
    const len = collect(windows11, .efi, &options);

    var found_direct_efi = false;
    var found_iso = false;
    for (options[0..len]) |option| {
        if (option.method == .direct_efi) {
            found_direct_efi = true;
            try std.testing.expect(option.enabled);
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
