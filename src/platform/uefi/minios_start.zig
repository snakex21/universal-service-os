//! Windows 10/11 x64 through MiniOS instead of Windows Setup (profile option
//! `prep_env=minios`, experimental; docs/minios-hardware-flow.md).
//!
//! The menu writes \USOSPREP.CFG (USOSPREP_HW_V1) and, for a USOS profile,
//! \USOSPREP.XML (the rendered answer, staged by MiniOS as
//! Windows\Panther\unattend.xml) on the USOS ESP, starts
//! \EFI\USOS\minios\usosprep-x64.efi and, when it reports success, restarts
//! into the new Windows. MiniOS asks the one disk question itself. Any
//! failure or a cancelled disk question returns an error: the caller logs it
//! and continues with the default path (the ISO's own Windows Setup).
//! Every start records its outcome in EFI\USOS\Logs\minios-start.txt;
//! MiniOS writes its own log to EFI\USOS\Logs\MINIOS-<build>.LOG.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const answer = usos.flow.answer;
const data_volume = @import("data_volume.zig");
const settings_store = @import("settings_store.zig");
const esp_image = @import("esp_image_start.zig");
const serial = @import("serial.zig");

pub const app_path = "\\EFI\\USOS\\minios\\usosprep-x64.efi";
pub const config_path = "\\USOSPREP.CFG";
pub const answer_path = "\\USOSPREP.XML";
pub const record_path = "\\EFI\\USOS\\Logs\\minios-start.txt";

const plan = usos.flow.minios_plan;
pub const wanted = plan.wanted;

fn record(root: *uefi.protocol.File, comptime fmt: []const u8, args: anytype) void {
    var text: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&text, "USOS {s} MiniOS start: " ++ fmt ++ "\r\n", .{usos.build_info.id} ++ args) catch return;
    serial.writeAscii(line);
    settings_store.replaceFile(root, record_path, line) catch {};
}

fn randomToken() ![64]u8 {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const rng = (bs.locateProtocol(uefi.protocol.Rng, null) catch null) orelse return error.EntropyUnavailable;
    var bytes: [32]u8 = undefined;
    try rng.getRNG(null, &bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn deleteFile(root: *uefi.protocol.File, comptime path: []const u8) void {
    const file = root.open(std.unicode.utf8ToUtf16LeStringLiteral(path), .read_write, .{}) catch return;
    _ = file.delete() catch {};
}

/// Returns only when MiniOS did not finish (the caller falls back to Setup).
pub fn run(root: *uefi.protocol.File, system_id: []const u8, image_directory: []const u8, name: []const u8, profile: *const answer.Profile, xml: ?[]const u8, images: ?*const answer.editions.List) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.MiniosRequiresX64;
    const index = plan.imageIndex(profile, system_id, images) orelse {
        record(root, "not started: the profile names no edition found on this ISO (MiniOS has no edition list); Windows Setup instead", .{});
        return error.MiniosNeedsEdition;
    };
    var catalog = data_volume.openCatalog() catch |err| {
        record(root, "not started: DATA not readable ({s})", .{@errorName(err)});
        return err;
    };
    const media = catalog.block.io.media;
    const start = catalog.partition.start_lba * 512;
    var boot: [512]u8 align(4096) = undefined;
    catalog.block.io.readBlocks(media.media_id, catalog.partition.start_lba, &boot) catch |err| {
        record(root, "not started: DATA boot sector unreadable ({s})", .{@errorName(err)});
        return err;
    };
    if (!std.mem.eql(u8, boot[3..11], "NTFS    ")) return error.DataNotNtfs;
    const source: plan.Source = .{ .disk_bytes = (media.last_block + 1) * 512, .start = start, .size = catalog.partition.sectorCount() * 512, .serial = std.mem.readInt(u64, boot[72..80], .little) };
    var path: [512]u8 = undefined;
    const iso_path = try std.fmt.bufPrint(&path, "{s}/{s}", .{ image_directory, name });
    const token = randomToken() catch |err| {
        record(root, "not started: no firmware RNG ({s})", .{@errorName(err)});
        return err;
    };
    var text: [1536]u8 = undefined;
    const cfg = try plan.formatConfig(&text, token, index, source, iso_path, usos.build_info.id, plan.localeTag(profile), xml != null);
    try settings_store.replaceFile(root, config_path, cfg);
    if (xml) |bytes| try settings_store.replaceFile(root, answer_path, bytes) else deleteFile(root, answer_path);
    // A rendered answer may hold a key or password: never left behind.
    defer deleteFile(root, answer_path);
    serial.writeAscii("[MINIOS] menu -> usosprep-x64.efi (USOSPREP_HW_V1)\r\n");
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const image = esp_image.load(root, app_path) catch |err| {
        record(root, "not started: {s} not loadable ({s})", .{ app_path, @errorName(err) });
        return err;
    };
    defer _ = bs._unloadImage(image);
    const status = @import("verified_image.zig").start(image) catch |err| {
        record(root, "failed to start ({s}); see EFI\\USOS\\Logs\\MINIOS-{s}.LOG", .{ @errorName(err), usos.build_info.id });
        return err;
    };
    switch (status) {
        .success => {
            record(root, "PASS image={d}; restarting into the new Windows", .{index});
            deleteFile(root, answer_path);
            uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
        },
        .aborted => {
            record(root, "disk question cancelled, nothing written; Windows Setup instead", .{});
            return error.MiniosCancelled;
        },
        else => {
            record(root, "FAILED status={s}; see EFI\\USOS\\Logs\\MINIOS-{s}.LOG; Windows Setup instead", .{ @tagName(status), usos.build_info.id });
            return error.MiniosFailed;
        },
    }
}
