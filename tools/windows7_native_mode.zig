// Native resolution for the Windows 7 / Vista UefiSeven path (no CSM).
//
// UefiSeven 1.30 always switches GOP to 1024x768 and describes exactly that
// mode in its VBE table, so Windows on the Standard VGA driver stays at
// 1024x768. The dispatcher arms two boot-services hooks around UefiSeven:
//
//  1. StartImage: the first image UefiSeven starts (the Windows boot manager).
//     Before it runs, USOS picks the monitor-native GOP mode (EDID preferred
//     timing, else the largest 32 bpp mode; src/platform/uefi/edid_mode.zig),
//     switches GOP to it and replaces UefiSeven's one-mode table and handler
//     at C0000 with the USOS multi-mode layout (tools/windows7_vbe_table.zig,
//     tools/windows7_vbe_handler.S): 0x00F1 = 1024x768 as a centred window
//     (Windows' boot graphics look for it), 0x00F2 = native. Ring log.
//  2. ExitBootServices (winload): the Windows boot library may switch GOP back
//     to one of its own resolutions (1024x768 / 800x600). If the GOP mode then
//     differs from the native one, USOS sets the native mode again and
//     re-patches the table right before the firmware's ExitBootServices, so
//     the hardware scanout and the VBE table agree when Windows takes over.
//     If that SetMode fails, the table is re-synced to whatever GOP shows, so
//     a failure never leaves a table that disagrees with the scanout.
//
// No file I/O and no allocation happen inside the ExitBootServices hook.
// A SetMode there could still change the memory map; if the firmware then
// rejects the caller's map key, the hook fetches a fresh key (static buffer)
// and calls ExitBootServices once more.
const std = @import("std");
const uefi = std.os.uefi;
const edid_mode = @import("edid_mode");
const table = @import("windows7_vbe_table.zig");
const trace = @import("windows7_uefi_trace.zig");
const handler = @import("windows7_vbe_handler");

const Gop = uefi.protocol.GraphicsOutput;
const cc = uefi.cc;
const StartImageFn = *const fn (uefi.Handle, ?*usize, ?*[*]u16) callconv(cc) uefi.Status;
const ExitBootServicesFn = *const fn (uefi.Handle, uefi.tables.MemoryMapKey) callconv(cc) uefi.Status;

var original_start: ?StartImageFn = null;
var original_exit: ?ExitBootServicesFn = null;
var skip_image: ?uefi.Handle = null;
var log: ?*trace.Session = null;
var target_gop: ?*Gop = null;
var native_mode: u32 = 0;
var exit_result: enum { not_called, already_native, reset_native, resync_failed } = .not_called;
var map_buffer: [64 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

fn window() []u8 {
    return @as([*]u8, @ptrFromInt(0xc0000))[0..table.window_size];
}

fn fixCrc(bs: *uefi.tables.BootServices) void {
    bs.hdr.crc32 = 0;
    var crc: u32 = 0;
    if (bs._calculateCrc32(@ptrCast(bs), bs.hdr.header_size, &crc) == .success) bs.hdr.crc32 = crc;
}

pub const flag_name = "usos-native-res.flag";

/// The experiment runs only with usos-native-res.flag beside the dispatcher.
pub fn enabled(device: uefi.Handle, dir: []const u16) bool {
    var buffer: [128]u8 = undefined;
    const text = trace.readSmall(device, dir, std.unicode.utf8ToUtf16LeStringLiteral(flag_name), &buffer);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return false;
    config = table.parseFlag(text);
    return true;
}

var config: table.FlagConfig = .{};

/// Arm the StartImage hook. `uefiseven` is the image the dispatcher itself
/// starts next; calls for it pass through.
pub fn arm(uefiseven: uefi.Handle, session: *trace.Session) void {
    const bs = uefi.system_table.boot_services orelse return;
    if (original_start != null) return;
    log = session;
    skip_image = uefiseven;
    original_start = bs._startImage;
    bs._startImage = startHook;
    fixCrc(bs);
}

/// Remove the StartImage hook if UefiSeven returned without starting anything.
pub fn disarm() void {
    const bs = uefi.system_table.boot_services orelse return;
    if (original_start) |orig| {
        bs._startImage = orig;
        original_start = null;
        fixCrc(bs);
    }
}

fn startHook(image: uefi.Handle, size: ?*usize, data: ?*[*]u16) callconv(cc) uefi.Status {
    const orig = original_start orelse return .load_error;
    if (skip_image != null and image == skip_image.?) return orig(image, size, data);
    disarm();
    applyNative();
    return orig(image, size, data);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    if (log) |l| l.print("USOS native mode: " ++ fmt, args);
}

/// The GOP instance UefiSeven described (ConOut handle first, then any).
/// The physical GOP (a GOP handle with a device path that is not the ConOut
/// handle). The ConOut GOP is often the console splitter's virtual one: QEMU
/// run 2026-10-21 showed the boot manager's text console switching the
/// physical GOP to 1024x768 while the splitter's Mode still said 1920x1080,
/// so mode checks must read the physical GOP. Falls back to the ConOut GOP.
fn findGop(bs: *uefi.tables.BootServices) ?*Gop {
    const conout = uefi.system_table.console_out_handle;
    if (bs.locateHandleBuffer(.{ .by_protocol = &Gop.guid }) catch null) |handles| {
        defer bs.freePool(@ptrCast(handles.ptr)) catch {};
        for (handles) |h| {
            if (conout != null and h == conout.?) continue;
            if ((bs.handleProtocol(uefi.protocol.DevicePath, h) catch null) == null) continue;
            if (bs.handleProtocol(Gop, h) catch null) |g| return g;
        }
    }
    if (conout) |h| {
        if (bs.handleProtocol(Gop, h) catch null) |g| return g;
    }
    return bs.locateProtocol(Gop, null) catch null;
}

/// EDID of the active output: EDID_ACTIVE, else EDID_DISCOVERED, on the GOP
/// handle first, then on any handle that has it (the ConOut GOP may be the
/// console splitter's virtual one).
pub fn readEdid(bs: *uefi.tables.BootServices, gop_handle: ?uefi.Handle) ?[]const u8 {
    const kinds = [_]type{ uefi.protocol.edid.Active, uefi.protocol.edid.Discovered };
    inline for (kinds) |Kind| {
        if (gop_handle) |h| {
            if (bs.handleProtocol(Kind, h) catch null) |e| {
                if (e.edid) |p| if (e.size_of_edid >= 128) return p[0..e.size_of_edid];
            }
        }
        if (bs.locateProtocol(Kind, null) catch null) |e| {
            if (e.edid) |p| if (e.size_of_edid >= 128) return p[0..e.size_of_edid];
        }
    }
    return null;
}

fn usable(info: *const Gop.Mode.Info) bool {
    const fmt_ok = info.pixel_format == .blue_green_red_reserved_8_bit_per_color or info.pixel_format == .red_green_blue_reserved_8_bit_per_color;
    return fmt_ok and info.horizontal_resolution >= 640 and info.vertical_resolution >= 480 and
        info.pixels_per_scan_line >= info.horizontal_resolution and @as(u64, info.pixels_per_scan_line) * 4 <= 0xffff;
}

fn currentFramebuffer(gop: *Gop) table.Framebuffer {
    const info = gop.mode.info;
    return .{
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .stride_pixels = info.pixels_per_scan_line,
        .base = gop.mode.frame_buffer_base,
        .size = gop.mode.frame_buffer_size,
        .bgr = info.pixel_format == .blue_green_red_reserved_8_bit_per_color,
    };
}

fn windowWritable() bool {
    const p: *volatile u8 = @ptrFromInt(0xc0000 + table.window_size - 1);
    const old = p.*;
    p.* = old ^ 0x5a;
    const ok = p.* == old ^ 0x5a;
    p.* = old;
    return ok;
}

fn gopHandle(bs: *uefi.tables.BootServices, gop: *Gop) ?uefi.Handle {
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &Gop.guid }) catch return null) orelse return null;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    for (handles) |h| {
        const g = (bs.handleProtocol(Gop, h) catch null) orelse continue;
        if (g == gop) return h;
    }
    return null;
}

fn applyNative() void {
    const bs = uefi.system_table.boot_services orelse return;
    const cur = table.recognize(window()) orelse {
        say("no UefiSeven VBE table at C0000; resolution left to the firmware", .{});
        return;
    };
    const gop = findGop(bs) orelse {
        say("no GOP; table stays {d}x{d}", .{ cur.width, cur.height });
        return;
    };
    if (!windowWritable()) {
        say("C0000 not writable after UefiSeven; table stays {d}x{d}", .{ cur.width, cur.height });
        return;
    }
    const before = gop.mode.mode;
    var candidates: [64]edid_mode.Candidate = undefined;
    const count: u32 = @min(gop.mode.max_mode, candidates.len);
    for (0..count) |i| {
        candidates[i] = if (gop.queryMode(@intCast(i))) |info| .{
            .width = info.horizontal_resolution,
            .height = info.vertical_resolution,
            .usable = usable(info) and info.horizontal_resolution <= config.max_width and info.vertical_resolution <= config.max_height,
        } else |_| .{ .width = 0, .height = 0, .usable = false };
    }
    say("flag: max {d}x{d}, {s}", .{ config.max_width, config.max_height, if (config.single) "native mode only" else "1024x768 window + native" });
    const edid = readEdid(bs, gopHandle(bs, gop));
    const preferred = if (edid) |e| edid_mode.preferredResolution(e) else null;
    if (preferred) |p| say("EDID preferred timing {d}x{d}", .{ p.width, p.height }) else say("no usable EDID ({s})", .{if (edid == null) "no EDID protocol" else "invalid block"});
    const pick = edid_mode.pickMode(candidates[0..count], preferred) orelse {
        say("no 32 bpp GOP mode; table stays {d}x{d}", .{ cur.width, cur.height });
        return;
    };
    const c = candidates[pick.index];
    say("GOP mode {d} {d}x{d} ({s}); UefiSeven had mode {d} {d}x{d}", .{ pick.index, c.width, c.height, @tagName(pick.reason), before, cur.width, cur.height });
    if (pick.index != before) {
        gop.setMode(@intCast(pick.index)) catch |err| {
            say("SetMode {d} failed ({s}); table stays {d}x{d}", .{ pick.index, @errorName(err), cur.width, cur.height });
            gop.setMode(before) catch {};
            return;
        };
    }
    const fb = currentFramebuffer(gop);
    // Windows 7's boot graphics look for a 1024x768 VBE mode (QEMU: with only
    // a native mode it stopped at "Starting Windows"), so 1024x768 stays as
    // mode 0x00F1 (a centred window) and the native mode is 0x00F2.
    var sizes_buf: [2][2]u32 = undefined;
    var n: usize = 0;
    if (!config.single and !(fb.width == 1024 and fb.height == 768) and table.windowFits(fb, 1024, 768)) {
        sizes_buf[n] = .{ 1024, 768 };
        n += 1;
    }
    sizes_buf[n] = .{ fb.width, fb.height };
    n += 1;
    if (config.native_first and n == 2) std.mem.swap([2]u32, &sizes_buf[0], &sizes_buf[1]);
    table.buildMulti(window(), fb, sizes_buf[0..n], handler.code) catch |err| {
        say("multi-mode table not built ({s}); GOP back to mode {d}, UefiSeven table kept", .{ @errorName(err), before });
        gop.setMode(before) catch {};
        return;
    };
    for (0..n) |i| {
        const m = table.multiMode(window(), i);
        say("VBE mode 0x{x:0>4}: {d}x{d}x32, LFB {x:0>8}, {d} bytes/line", .{ table.mode_number + i, m.width, m.height, m.lfb, m.bytes_per_line });
    }
    say("USOS VBE handler at C000:0200 ({d} bytes); ExitBootServices check armed", .{handler.code.len});
    target_gop = gop;
    native_mode = @intCast(pick.index);
    original_exit = bs._exitBootServices;
    bs._exitBootServices = exitHook;
    fixCrc(bs);
}

/// QEMU harness only (the ring log's debugcon mirror; never on hardware):
/// no file I/O is allowed inside ExitBootServices.
fn qemuNote(comptime fmt: []const u8, args: anytype) void {
    const l = log orelse return;
    if (!l.mirror) return;
    var text: [160]u8 = undefined;
    trace.debugcon(std.fmt.bufPrint(&text, "USOS native mode (ExitBootServices): " ++ fmt ++ "\r\n", args) catch return);
}

fn exitHook(image: uefi.Handle, key: uefi.tables.MemoryMapKey) callconv(cc) uefi.Status {
    const bs = uefi.system_table.boot_services orelse return .invalid_parameter;
    const orig = original_exit orelse return .invalid_parameter;
    bs._exitBootServices = orig;
    original_exit = null;
    fixCrc(bs);
    const gop = target_gop orelse return orig(image, key);
    if (gop.mode.mode == native_mode) {
        exit_result = .already_native;
        qemuNote("GOP still mode {d} {d}x{d}", .{ native_mode, gop.mode.info.horizontal_resolution, gop.mode.info.vertical_resolution });
        return orig(image, key);
    }
    // The boot library switched modes (not seen in QEMU with bootmgr 6.1):
    // switch back so the scanout matches the table (no logging, no
    // allocation by USOS).
    const was = gop.mode.mode;
    const switched = gop._set_mode(gop, native_mode) == .success;
    exit_result = if (switched) .reset_native else .resync_failed;
    qemuNote("boot library left mode {d}; SetMode {d} {s}; now {d}x{d}", .{ was, native_mode, if (switched) "ok" else "FAILED", gop.mode.info.horizontal_resolution, gop.mode.info.vertical_resolution });
    const status = orig(image, key);
    qemuNote("firmware ExitBootServices returned {d}", .{@intFromEnum(status)});
    if (status != .invalid_parameter) return status;
    // SetMode may have changed the memory map: one retry with a fresh key.
    var size: usize = map_buffer.len;
    var fresh: uefi.tables.MemoryMapKey = undefined;
    var desc_size: usize = 0;
    var desc_version: u32 = 0;
    if (bs._getMemoryMap(&size, &map_buffer, &fresh, &desc_size, &desc_version) != .success) return status;
    return orig(image, fresh);
}
