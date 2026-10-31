//! Windows 10/11 x64 through MiniOS instead of Windows Setup, and 32-bit
//! Windows 10 without CSM through MiniOS instead of the Alpine preparation
//! (profile option `prep_env=minios`, experimental;
//! docs/minios-hardware-flow.md).
//!
//! The menu writes \USOSPREP.CFG (USOSPREP_HW_V1) and, for a USOS profile,
//! \USOSPREP.XML (the rendered answer, staged by MiniOS as
//! Windows\Panther\unattend.xml) on the USOS ESP, starts
//! \EFI\USOS\minios\usosprep-x64.efi and, when it reports success, restarts
//! into the new Windows. MiniOS asks the one disk question itself. Any
//! failure or a cancelled disk question returns an error: the caller logs it
//! and continues with the default path (the ISO's own Windows Setup, or the
//! Alpine micro-Linux preparation on the 32-bit CSMWrap route).
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
const minios_disk = @import("minios_disk.zig");
const view = @import("manual_view.zig");

pub const app_path = "\\EFI\\USOS\\minios\\usosprep-x64.efi";
pub const config_path = "\\USOSPREP.CFG";
pub const answer_path = "\\USOSPREP.XML";
pub const record_path = "\\EFI\\USOS\\Logs\\minios-start.txt";

const plan = usos.flow.minios_plan;
pub const wanted = plan.wanted;
pub const wantedX86Csmwrap = plan.wantedX86Csmwrap;
pub const Route = plan.Route;

fn fallbackName(route: Route) []const u8 {
    return if (route == .mbr_csmwrap) "the Alpine preparation (CSMWrap)" else "Windows Setup";
}

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

/// The usosnvme package MiniOS stages for an NVMe target on the CSMWrap
/// route (src/prep/hw_nvme.zig): without it NVMe disks are not offered.
fn nvmePackage(root: *uefi.protocol.File) bool {
    inline for (.{ "usosnvme.sys", "usosnvme.inf", "usosnvme.cat", "usosnvme.cer" }) |file| {
        const handle = root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\minios\\nvme\\" ++ file), .read, .{}) catch return false;
        handle.close() catch {};
    }
    return true;
}

/// Returns only when MiniOS did not finish (the caller falls back to Setup),
/// or with error.MiniosDiskCancelled when the user left the disk question
/// (the caller then returns to the menu: no second disk question).
/// `system_name` names the system on the USOS screens ("Windows 10").
pub fn run(root: *uefi.protocol.File, route: Route, system_id: []const u8, system_name: []const u8, image_directory: []const u8, name: []const u8, profile: *const answer.Profile, xml: ?[]const u8, images: ?*const answer.editions.List) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.MiniosRequiresX64;
    const index = plan.imageIndex(profile, system_id, images) orelse {
        record(root, "not started ({s}): the profile names no edition found on this ISO (MiniOS has no edition list); {s} instead", .{ @tagName(route), fallbackName(route) });
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
    // The flow's one disk question, in the USOS menu; MiniOS asks nothing.
    var shown: [96]u8 = undefined;
    const shown_name = std.fmt.bufPrint(&shown, "{s} (MiniOS)", .{system_name}) catch system_name;
    const nvme_package = nvmePackage(root);
    const disk = switch (minios_disk.ask(route, shown_name, nvme_package)) {
        .disk => |d| d,
        .cancelled => {
            record(root, "disk question cancelled in the menu, nothing written; back to the menu", .{});
            return error.MiniosDiskCancelled;
        },
        .none => {
            record(root, "not started ({s}): no disk MiniOS can install to (usosnvme package {s}); {s} instead", .{ @tagName(route), if (nvme_package) "present" else "missing", fallbackName(route) });
            return error.MiniosNoDisk;
        },
    };
    var text: [2560]u8 = undefined;
    const base_cfg = try plan.formatConfig(&text, route, token, index, source, iso_path, usos.build_info.id, plan.localeTag(profile), xml != null);
    const cfg = try plan.appendDisk(&text, base_cfg, &disk);
    try settings_store.replaceFile(root, config_path, cfg);
    if (xml) |bytes| try settings_store.replaceFile(root, answer_path, bytes) else deleteFile(root, answer_path);
    // A rendered answer may hold a key or password: never left behind.
    defer deleteFile(root, answer_path);
    serial.writeAscii(if (route == .mbr_csmwrap) "[MINIOS] menu -> usosprep-x64.efi (USOSPREP_HW_V1 mode=mbr csmwrap=on)\r\n" else "[MINIOS] menu -> usosprep-x64.efi (USOSPREP_HW_V1)\r\n");
    // MiniOS runs quietly (ui=quiet): this USOS screen stays until the
    // restart and names the environment.
    var detail_en: [160]u8 = undefined;
    view.miniosStatus(route, std.fmt.bufPrint(&detail_en, "Writing the {s} image to the selected disk.", .{shown_name}) catch "Preparing the disk", system_name);
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
            record(root, "PASS route={s} image={d}; restarting into the new Windows", .{ @tagName(route), index });
            deleteFile(root, answer_path);
            uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
        },
        .aborted => {
            record(root, "disk question cancelled, nothing written; {s} instead", .{fallbackName(route)});
            return error.MiniosCancelled;
        },
        else => {
            record(root, "FAILED route={s} status={s}; see EFI\\USOS\\Logs\\MINIOS-{s}.LOG; {s} instead", .{ @tagName(route), @tagName(status), usos.build_info.id, fallbackName(route) });
            return error.MiniosFailed;
        },
    }
}
