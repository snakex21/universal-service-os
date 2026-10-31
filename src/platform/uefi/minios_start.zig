//! MiniOS starts from the USOS menu (route policy, minios_plan.x86CsmwrapPrep;
//! docs/minios-hardware-flow.md "Route policy").
//!
//! * `run`: Windows 10/11 x64 through MiniOS instead of Windows Setup, only
//!   with the profile option `prep_env=minios` (experimental; the profile's
//!   edition is applied; any failure falls back to Windows Setup).
//! * `runCsmwrap`: 32-bit Windows 10 without CSM, the default preparation of
//!   that route (no profile option, no stick flag; 8 / 8.1 stay on Alpine; the old
//!   EFI\USOS\win9x\minios.flag is no longer read). MiniOS is the port of the
//!   Alpine micro-Linux step 610: the menu writes request.ini and
//!   usos-source.ini (windows_native_iso.prepareX86Csmwrap) and the answer
//!   plan exactly as for Alpine, asks the flow's one disk question, then
//!   MiniOS writes the disk; after the Alpine route's "start the prepared
//!   disk" notice the PC restarts into the ISO's own WinPE and Windows Setup.
//!   No fallback to Alpine: a failure shows the MiniOS error page.
//!
//! The menu writes \USOSPREP.CFG (USOSPREP_HW_V1) on the USOS ESP and starts
//! \EFI\USOS\minios\usosprep-x64.efi. Every start records its outcome in
//! EFI\USOS\Logs\minios-start.txt; MiniOS writes its own log to
//! EFI\USOS\Logs\MINIOS-<build>.LOG.
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
pub const x86CsmwrapPrep = plan.x86CsmwrapPrep;
pub const Route = plan.Route;

/// The edition of a GPT start ("4 Windows 10 Pro (profile)"), in every
/// later record line; "Windows Setup" on the CSMWrap route.
var edition_text: [128]u8 = undefined;
var edition_len: usize = 0;

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

/// The menu's error page after a failed MiniOS run (no other preparation
/// starts): the stage and reason MiniOS wrote to
/// EFI\USOS\Logs\minios-result.txt (else the menu's own error), and the
/// log path. Waits for the user, then the caller returns to the menu.
pub fn showFailure(root: *uefi.protocol.File, err: anyerror) void {
    var raw: [256]u8 = undefined;
    var stage: []const u8 = "menu";
    var reason: []const u8 = @errorName(err);
    if (root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\Logs\\minios-result.txt"), .read, .{})) |file| {
        defer file.close() catch {};
        const n = file.read(&raw) catch 0;
        var lines = std.mem.tokenizeAny(u8, raw[0..n], "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "stage=")) stage = line[6..];
            if (std.mem.startsWith(u8, line, "reason=")) reason = line[7..];
        }
    } else |_| {}
    var log_buf: [96]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_buf, "EFI\\USOS\\Logs\\MINIOS-{s}.LOG", .{usos.build_info.id}) catch "EFI\\USOS\\Logs";
    // boot.lx.minios_* (the micro-Linux table: not in the Legacy Core).
    var a: [160]u8 = undefined;
    var b: [160]u8 = undefined;
    var c: [256]u8 = undefined;
    var ea: [96]u8 = undefined;
    var eb: [96]u8 = undefined;
    var ec: [160]u8 = undefined;
    const lines = [_][]const u8{
        view.trFormat(&a, std.fmt.bufPrint(&ea, "Stage: {s}", .{stage}) catch stage),
        view.trFormat(&b, std.fmt.bufPrint(&eb, "Reason: {s}", .{reason}) catch reason),
        view.trFormat(&c, std.fmt.bufPrint(&ec, "No other preparation was started. Log on the USB drive: {s}", .{log_path}) catch log_path),
    };
    record(root, "FAILED stage={s} reason={s} edition={s}; no other preparation started (MiniOS only); back to the menu", .{ stage, reason, edition_text[0..edition_len] });
    view.refreshFramebuffer();
    view.notice(view.tr("MiniOS did not finish"), .warning, .warning, view.tr("Windows was not installed"), &lines);
    view.waitForDismiss();
}

/// DATA's identity for MiniOS (it finds the partition by size and serial).
fn dataSource(root: *uefi.protocol.File) !plan.Source {
    var catalog = data_volume.openCatalog() catch |err| {
        record(root, "not started: DATA not readable ({s})", .{@errorName(err)});
        return err;
    };
    const media = catalog.block.io.media;
    var boot: [512]u8 align(4096) = undefined;
    catalog.block.io.readBlocks(media.media_id, catalog.partition.start_lba, &boot) catch |err| {
        record(root, "not started: DATA boot sector unreadable ({s})", .{@errorName(err)});
        return err;
    };
    if (!std.mem.eql(u8, boot[3..11], "NTFS    ")) return error.DataNotNtfs;
    return .{ .disk_bytes = (media.last_block + 1) * 512, .start = catalog.partition.start_lba * 512, .size = catalog.partition.sectorCount() * 512, .serial = std.mem.readInt(u64, boot[72..80], .little) };
}

const Started = enum { success, cancelled };

/// The flow's time zone for the RTC conversion (src/flow/rtc_zone.zig): the
/// profile's zone, else the media language's default zone.
pub fn profileZone(profile: ?*const answer.Profile) ?*const answer.tables.TimeZone {
    const p = profile orelse return null;
    return p.timeZone() orelse answer.tables.timeZone(answer.tables.timeZoneForLanguage(plan.localeTag(p)));
}

/// rtc_shift for MiniOS: local minus UTC now. The RTC holds local time (the
/// X470 does; Windows' convention); MiniOS stamps NTFS times in UTC.
fn rtcShift(root: *uefi.protocol.File, zone: ?*const answer.tables.TimeZone) i32 {
    const got = uefi.system_table.runtime_services.getTime() catch {
        record(root, "clock: GetTime failed; RTC taken as UTC (rtc_shift=0)", .{});
        return 0;
    };
    const t = got[0];
    if (zone) |z| {
        if (usos.flow.rtc_zone.shiftSeconds(z, .{ .year = t.year, .month = t.month, .day = t.day, .hour = t.hour, .minute = t.minute, .second = t.second })) |s| {
            record(root, "clock: RTC local time in {s} ({s}), rtc_shift={d}", .{ z.id, z.windows, s });
            return s;
        }
    }
    if (usos.flow.rtc_zone.efiShiftSeconds(t.timezone, @bitCast(t.daylight))) |s| {
        record(root, "clock: no flow time zone; EFI_TIME.TimeZone={d}, rtc_shift={d}", .{ t.timezone, s });
        return s;
    }
    record(root, "clock: no flow time zone and EFI_TIME.TimeZone unspecified; RTC taken as UTC (rtc_shift=0)", .{});
    return 0;
}

/// Loads and starts MiniOS with the config already on the ESP.
fn start(root: *uefi.protocol.File, route: Route) !Started {
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
            record(root, "PASS route={s} edition={s}", .{ @tagName(route), edition_text[0..edition_len] });
            return .success;
        },
        .aborted => {
            record(root, "cancelled, nothing written", .{});
            return .cancelled;
        },
        else => {
            record(root, "FAILED route={s} status={s}; see EFI\\USOS\\Logs\\MINIOS-{s}.LOG", .{ @tagName(route), @tagName(status), usos.build_info.id });
            return error.MiniosFailed;
        },
    }
}

/// GPT route. Returns only when MiniOS did not finish (the caller falls back
/// to Setup), or with error.MiniosDiskCancelled when the user left the disk
/// question (the caller then returns to the menu: no second disk question).
/// The profile's edition is required (no edition screen, no default).
pub fn run(root: *uefi.protocol.File, system: *const usos.catalog.SystemEntry, system_name: []const u8, image_directory: []const u8, name: []const u8, profile: *const answer.Profile, xml: ?[]const u8, images: ?*const answer.editions.List) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.MiniosRequiresX64;
    var shown: [96]u8 = undefined;
    const shown_name = std.fmt.bufPrint(&shown, "{s} (MiniOS)", .{system_name}) catch system_name;
    const index = plan.imageIndex(profile, system.id, images) orelse {
        record(root, "not started (gpt_uefi): the profile names no edition of this ISO; Windows Setup instead", .{});
        return error.MiniosNeedsEdition;
    };
    edition_len = if (std.fmt.bufPrint(&edition_text, "{d} (profile)", .{index})) |t| t.len else |_| 0;
    const source = try dataSource(root);
    var path: [512]u8 = undefined;
    const iso_path = try std.fmt.bufPrint(&path, "{s}/{s}", .{ image_directory, name });
    const token = randomToken() catch |err| {
        record(root, "not started: no firmware RNG ({s})", .{@errorName(err)});
        return err;
    };
    // The flow's one disk question, in the USOS menu; MiniOS asks nothing.
    const disk = switch (minios_disk.ask(.gpt_uefi, shown_name)) {
        .disk => |d| d,
        .cancelled => {
            record(root, "disk question cancelled in the menu, nothing written; back to the menu", .{});
            return error.MiniosDiskCancelled;
        },
        .none => {
            record(root, "not started (gpt_uefi): no disk MiniOS can install to; Windows Setup instead", .{});
            return error.MiniosNoDisk;
        },
    };
    var text: [2560]u8 = undefined;
    const base_cfg = try plan.formatConfig(&text, token, index, source, iso_path, usos.build_info.id, plan.localeTag(profile), xml != null);
    const disk_cfg = try plan.appendDisk(&text, base_cfg, &disk);
    const cfg = try plan.appendClock(&text, disk_cfg, rtcShift(root, profileZone(profile)));
    try settings_store.replaceFile(root, config_path, cfg);
    if (xml) |bytes| try settings_store.replaceFile(root, answer_path, bytes) else deleteFile(root, answer_path);
    // A rendered answer may hold a key or password: never left behind.
    defer deleteFile(root, answer_path);
    serial.writeAscii("[MINIOS] menu -> usosprep-x64.efi (USOSPREP_HW_V1)\r\n");
    var detail_en: [160]u8 = undefined;
    view.miniosStatus(.gpt_uefi, std.fmt.bufPrint(&detail_en, "Writing the {s} image to the selected disk.", .{shown_name}) catch "Preparing the disk", system_name);
    switch (try start(root, .gpt_uefi)) {
        .success => {
            deleteFile(root, answer_path);
            uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
        },
        .cancelled => return error.MiniosCancelled,
    }
}

/// The logon sentence the menu wrote for this start (usos_logon_take).
fn logonLine(root: *uefi.protocol.File, buffer: []u8) []const u8 {
    const file = root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\answer\\logon.ini"), .read, .{}) catch return "";
    defer file.close() catch {};
    const n = file.read(buffer) catch return "";
    return usos.flow.answer.logon.iniLine(buffer[0..n]) orelse "";
}

/// CSMWrap route (32-bit Windows 10 without CSM): request.ini,
/// usos-source.ini and the answer plan are already on the ESP (the caller
/// ran the Alpine route's menu half). The one disk question, MiniOS, then
/// the Alpine route's restart notice and the restart. Returns only on
/// failure (error page by the caller) or error.MiniosDiskCancelled.
pub fn runCsmwrap(root: *uefi.protocol.File, system_name: []const u8, zone: ?*const answer.tables.TimeZone) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.MiniosRequiresX64;
    edition_len = if (std.fmt.bufPrint(&edition_text, "Windows Setup", .{})) |t| t.len else |_| 0;
    // Stage 2 "Loading the preparation environment", as the Alpine route's
    // last UEFI frame (its detail names micro-Linux; here MiniOS).
    view.vistaCsmwrapStatus(.loading, "Loading MiniOS from the USB drive", system_name);
    const source = try dataSource(root);
    const token = randomToken() catch |err| {
        record(root, "not started: no firmware RNG ({s})", .{@errorName(err)});
        return err;
    };
    // vista_csmwrap_prepare.sh stage 3, then its disk picker (the same
    // renderer, minios_disk.zig) named by the system as on Alpine.
    view.miniosStage(3, "Detecting disks", "The disk will only be changed after your confirmation.", system_name);
    const disk = switch (minios_disk.ask(.mbr_csmwrap, system_name)) {
        .disk => |d| d,
        .cancelled => {
            record(root, "disk question cancelled in the menu, nothing written; back to the menu", .{});
            return error.MiniosDiskCancelled;
        },
        .none => {
            record(root, "not started (mbr_csmwrap): no target disk found (only the USOS stick); no disk was changed", .{});
            return error.MiniosNoDisk;
        },
    };
    var text: [2048]u8 = undefined;
    const base_cfg = try plan.formatCsmwrapConfig(&text, token, source, usos.build_info.id);
    const disk_cfg = try plan.appendDisk(&text, base_cfg, &disk);
    const cfg = try plan.appendClock(&text, disk_cfg, rtcShift(root, zone));
    try settings_store.replaceFile(root, config_path, cfg);
    deleteFile(root, answer_path);
    serial.writeAscii("[MINIOS] menu -> usosprep-x64.efi (USOSPREP_HW_V1 mode=mbr profile=csmwrap-setup)\r\n");
    // MiniOS runs quietly (ui=quiet, nothing on the text console): the
    // Alpine route's stage 4 page with its own detail line.
    view.miniosStatus(.mbr_csmwrap, "Copying the Windows PE helper and CSMWrap to the selected disk.", system_name);
    switch (try start(root, .mbr_csmwrap)) {
        .success => {},
        .cancelled => return error.MiniosCancelled,
    }
    // Stage 5 of vista_csmwrap_prepare.sh (x86_self=1,
    // usos_ui_notice_continue): the preparation page in done mode with the
    // notice, the logon line (usos_logon_take: EFI\USOS\answer\logon.ini)
    // and the Enter action, then the restart when the user confirms. The
    // renderer translates the texts, as fb_ui_render does on Alpine.
    var title_en: [96]u8 = undefined;
    var body_en: [320]u8 = undefined;
    var logon_buf: [256]u8 = undefined;
    const logon = logonLine(root, &logon_buf);
    view.refreshFramebuffer();
    view.miniosDone(
        std.fmt.bufPrint(&title_en, "{s}: start the prepared disk", .{system_name}) catch system_name,
        std.fmt.bufPrint(&body_en, "After the restart the firmware starts this disk's UEFI entry (CSMWrap; CSM stays off) and the {s} installation continues on it. If the USOS stick starts instead, pick the disk in the firmware boot menu.", .{system_name}) catch system_name,
        "Restart",
        logon,
        system_name,
    );
    view.waitForDismiss();
    record(root, "PASS route=mbr_csmwrap; restart confirmed, restarting into Windows Setup", .{});
    uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
}
