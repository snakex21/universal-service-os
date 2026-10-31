//! Strict, separate QEMU boot-provisioning authorization, never a prep profile.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const wl = @import("windows_layout.zig");

pub const Arch = enum { x64, ia32 };
pub const Config = struct {
    target_bytes: u64,
    ids: wl.Ids,
    loader_guid: [16]u8,
    layout_receipt_sha256: [32]u8,
    bcd_receipt_sha256: [32]u8,
    arch: Arch,
    locale: []const u8,
};
const Key = enum {
    target_bytes,
    disk_guid,
    windows_guid,
    esp_guid,
    msr_guid,
    ntfs_serial,
    mbr_signature,
    loader_guid,
    layout_receipt_sha256,
    bcd_receipt_sha256,
    layout_gate,
    bcd_gate,
    arch,
    locale,
};
fn hex(comptime n: usize, text: []const u8) ![n]u8 {
    if (text.len != n * 2) return error.InvalidBootConfig;
    var out: [n]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        const high = std.fmt.charToDigit(text[i * 2], 16) catch return error.InvalidBootConfig;
        const low = std.fmt.charToDigit(text[i * 2 + 1], 16) catch return error.InvalidBootConfig;
        byte.* = high * 16 + low;
    }
    return out;
}
fn digestHealthy(digest: [32]u8) bool {
    return !std.mem.allEqual(u8, &digest, 0) and !std.mem.allEqual(u8, &digest, 0xff);
}
pub fn parse(text: []const u8) !Config {
    return parseMode(text,false);
}
pub fn parseReferenceDiagnostic(text: []const u8) !Config {
    return parseMode(text,true);
}
fn parseMode(text: []const u8, diagnostic: bool) !Config {
    if (text.len == 0 or text.len > 4096) return error.InvalidBootConfig;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidBootConfig, if(diagnostic) "USOSBOOT_REFERENCE_QEMU_ONLY_V1" else "USOSBOOT_QEMU_ONLY_V1")) return error.InvalidBootConfig;
    var result: Config = undefined;
    var seen: u32 = 0;
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidBootConfig;
        const key = std.meta.stringToEnum(Key, line[0..eq]) orelse return error.InvalidBootConfig;
        const bit: u32 = @as(u32, 1) << @intFromEnum(key);
        if (seen & bit != 0) return error.InvalidBootConfig;
        seen |= bit;
        const value = line[eq + 1 ..];
        switch (key) {
            .target_bytes => result.target_bytes = std.fmt.parseInt(u64, value, 10) catch return error.InvalidBootConfig,
            .disk_guid => result.ids.base.disk_guid = try hex(16, value),
            .windows_guid => result.ids.base.partition_guid = try hex(16, value),
            .esp_guid => result.ids.esp = try hex(16, value),
            .msr_guid => result.ids.msr = try hex(16, value),
            .loader_guid => result.loader_guid = try hex(16, value),
            .ntfs_serial => result.ids.base.ntfs_serial = std.fmt.parseInt(u64, value, 16) catch return error.InvalidBootConfig,
            .mbr_signature => result.ids.base.mbr_signature = std.fmt.parseInt(u32, value, 16) catch return error.InvalidBootConfig,
            .layout_receipt_sha256 => result.layout_receipt_sha256 = try hex(32, value),
            .bcd_receipt_sha256 => result.bcd_receipt_sha256 = try hex(32, value),
            .layout_gate => if (!std.mem.eql(u8, value, "pass")) return error.BootPrerequisiteGateNotPassed,
            .bcd_gate => if (!std.mem.eql(u8, value, if(diagnostic) "deferred" else "pass")) return error.BootPrerequisiteGateNotPassed,
            .arch => result.arch = std.meta.stringToEnum(Arch, value) orelse return error.InvalidBootConfig,
            .locale => {
                if (value.len < 2 or value.len > 32) return error.InvalidBootConfig;
                for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidBootConfig;
                result.locale = value;
            },
        }
    }
    if (seen != (@as(u32, 1) << @typeInfo(Key).@"enum".fields.len) - 1) return error.InvalidBootConfig;
    if (result.target_bytes < (1 + 300 + 16 + 64) * wl.mib or result.target_bytes % 512 != 0) return error.InvalidBootConfig;
    if(diagnostic){
        const bcd=@import("bcd.zig");
        if(result.target_bytes!=32*1024*1024*1024 or result.ids.base.mbr_signature!=0 or result.ids.base.ntfs_serial!=0xe46231e86231c05a or result.arch!=.x64 or
            !std.mem.eql(u8,&result.ids.base.disk_guid,&(try bcd.parseGuid("{d82f1b66-1271-4683-867c-55b5f7070868}"))) or
            !std.mem.eql(u8,&result.ids.base.partition_guid,&(try bcd.parseGuid("{87c4f69b-6413-4c94-9c91-ce38d027d22e}"))) or
            !std.mem.eql(u8,&result.ids.esp,&(try bcd.parseGuid("{f8f81433-5702-4694-acfb-ffe9586ad29f}"))) or
            !std.mem.eql(u8,&result.ids.msr,&(try bcd.parseGuid("{e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10}"))))return error.InvalidBootConfig;
    }else try result.ids.validate();
    if (result.loader_guid[7] >> 4 != 4 or result.loader_guid[8] >> 6 != 2) return error.InvalidBootConfig;
    for ([_][16]u8{ result.ids.base.disk_guid, result.ids.base.partition_guid, result.ids.esp, result.ids.msr }) |id| {
        if (std.mem.eql(u8, &id, &result.loader_guid)) return error.InvalidBootConfig;
    }
    if (!digestHealthy(result.layout_receipt_sha256) or !digestHealthy(result.bcd_receipt_sha256) or
        std.mem.eql(u8, &result.layout_receipt_sha256, &result.bcd_receipt_sha256)) return error.InvalidBootConfig;
    return result;
}
