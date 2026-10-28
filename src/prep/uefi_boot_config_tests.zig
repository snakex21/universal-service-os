//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const boot = @import("uefi_boot_config.zig");
const valid = "USOSBOOT_QEMU_ONLY_V1\n" ++
    "target_bytes=26843545600\n" ++
    "disk_guid=0102030405060748890a0b0c0d0e0f10\n" ++
    "windows_guid=1112131415161748991a1b1c1d1e1f20\n" ++
    "esp_guid=2122232425262748a92a2b2c2d2e2f30\n" ++
    "msr_guid=3132333435363748b93a3b3c3d3e3f40\n" ++
    "loader_guid=4142434445464748894a4b4c4d4e4f50\n" ++
    "ntfs_serial=123456789abcdef0\n" ++
    "mbr_signature=12345678\n" ++
    "layout_receipt_sha256=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20\n" ++
    "bcd_receipt_sha256=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\n" ++
    "layout_gate=pass\nbcd_gate=pass\narch=x64\nlocale=en-US\n";

test "boot config pins every identity and two explicit completed gates" {
    const cfg = try boot.parse(valid);
    try std.testing.expectEqual(@as(u64, 26843545600), cfg.target_bytes);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), cfg.ids.base.ntfs_serial);
    try std.testing.expectEqual(boot.Arch.x64, cfg.arch);
    try std.testing.expectEqualStrings("en-US", cfg.locale);
    try std.testing.expectEqual(@as(u8, 0x48), cfg.ids.msr[7]);
    try std.testing.expectEqual(@as(u8, 0x21), cfg.bcd_receipt_sha256[0]);
}
fn changed(old: []const u8, replacement: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, valid, old) orelse unreachable;
    return std.mem.concat(std.testing.allocator, u8, &.{ valid[0..at], replacement, valid[at + old.len ..] });
}
test "boot config refuses missing duplicate unknown or unpassed prerequisites" {
    try std.testing.expectError(error.InvalidBootConfig, boot.parse("USOSPREP_QEMU_ONLY\n"));
    inline for (.{ "layout_gate=pass\n", "bcd_gate=pass\n", "msr_guid=3132333435363748b93a3b3c3d3e3f40\n" }) |line| {
        const text = try changed(line, "");
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidBootConfig, boot.parse(text));
    }
    inline for (.{ "arch=x64\n", "first_disk=true\n" }) |line| {
        const text = try std.mem.concat(std.testing.allocator, u8, &.{ valid, line });
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidBootConfig, boot.parse(text));
    }
    const pending = try changed("bcd_gate=pass", "bcd_gate=pending");
    defer std.testing.allocator.free(pending);
    try std.testing.expectError(error.BootPrerequisiteGateNotPassed, boot.parse(pending));
}
test "boot config refuses corrupt identities geometry locale and empty digest" {
    inline for (.{
        .{ "target_bytes=26843545600", "target_bytes=26843545601" },
        .{ "target_bytes=26843545600", "target_bytes=67108864" },
        .{ "mbr_signature=12345678", "mbr_signature=0" },
        .{ "ntfs_serial=123456789abcdef0", "ntfs_serial=0" },
        .{ "arch=x64", "arch=arm64" },
        .{ "locale=en-US", "locale=../../bad" },
        .{ "loader_guid=4142434445464748894a4b4c4d4e4f50", "loader_guid=0102030405060748890a0b0c0d0e0f10" },
        .{ "layout_receipt_sha256=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20", "layout_receipt_sha256=0000000000000000000000000000000000000000000000000000000000000000" },
    }) |pair| {
        const text = try changed(pair[0], pair[1]);
        defer std.testing.allocator.free(text);
        if (std.mem.startsWith(u8, pair[0], "mbr_signature=") or std.mem.startsWith(u8, pair[0], "ntfs_serial=")) {
            try std.testing.expectError(error.InvalidArgument, boot.parse(text));
        } else try std.testing.expectError(error.InvalidBootConfig, boot.parse(text));
    }
}
test "separate reference config pins exact disk and leaves production parser unchanged" {
    const diagnostic="USOSBOOT_REFERENCE_QEMU_ONLY_V1\n" ++
        "target_bytes=34359738368\n" ++
        "disk_guid=661b2fd871128346867c55b5f7070868\n" ++
        "windows_guid=9bf6c4871364944c9c91ce38d027d22e\n" ++
        "esp_guid=3314f8f802579446acfbffe9586ad29f\n" ++
        "msr_guid=4eb4d9e5b0bcef48a0d88e8d834c4e10\n" ++
        "loader_guid=4142434445464748894a4b4c4d4e4f50\n" ++
        "ntfs_serial=e46231e86231c05a\nmbr_signature=0\n" ++
        "layout_receipt_sha256=0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20\n" ++
        "bcd_receipt_sha256=2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40\n" ++
        "layout_gate=pass\nbcd_gate=deferred\narch=x64\nlocale=en-US\n";
    const got=try boot.parseReferenceDiagnostic(diagnostic);
    try std.testing.expectEqual(@as(u32,0),got.ids.base.mbr_signature);
    try std.testing.expectError(error.InvalidBootConfig,boot.parse(diagnostic));
    try std.testing.expectError(error.InvalidBootConfig,boot.parseReferenceDiagnostic(valid));
    var changed_text=try std.testing.allocator.dupe(u8,diagnostic);defer std.testing.allocator.free(changed_text);
    const at=std.mem.indexOf(u8,changed_text,"661b2fd8").?;changed_text[at]='0';
    try std.testing.expectError(error.InvalidBootConfig,boot.parseReferenceDiagnostic(changed_text));
    const gate_at=std.mem.indexOf(u8,diagnostic,"bcd_gate=deferred").?;
    const bad_gate=try std.mem.concat(std.testing.allocator,u8,&.{diagnostic[0..gate_at],"bcd_gate=pass",diagnostic[gate_at+"bcd_gate=deferred".len..]});defer std.testing.allocator.free(bad_gate);
    try std.testing.expectError(error.BootPrerequisiteGateNotPassed,boot.parseReferenceDiagnostic(bad_gate));
}
