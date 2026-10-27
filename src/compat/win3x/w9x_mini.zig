//! `usos-fb-ui --w9x-setup-mini SETUPDIR HELPERDIR` (micro-Linux,
//! tools/w9x_csmwrap_target.sh) and the host tool
//! `usos-win3x-display w9x-mini SETUPDIR HELPERDIR`: prepare the mini-Windows
//! that Windows 95/98/Me Setup unpacks from SETUPDIR/MINI.CAB into
//! C:\WININST0.400 and starts in standard mode (DOSX + KRNL386, no VxD,
//! shell=winsetup.bin / w98setup.bin) for its licence, key and wizard pages.
//!
//! 1. VGA.DRV in MINI.CAB is the Windows 3.1 driver (sha256 53312ed0...,
//!    every 95/98 medium checked), so the X470 latch fault (locked XCHG with
//!    video memory loads the latches from byte |3, docs/win3x-vga-redraw-
//!    2026-10-23.md) breaks Setup's drawing the same way it broke Windows
//!    3.1: the same plan of display_table.zig patches it.
//! 2. HELPERDIR given (not "-") and holding USOSKEY.DRV and VBMOUSE.DRV:
//!    the USB keyboard/mouse bridge of the Windows 3.1 standard-mode flow
//!    (USOSKEY.COM + VBMOUSE.EXE resident in DOS, loaded by INSTALL.BAT
//!    before SETUP): both drivers go into the cabinet, and its SYSTEM.INI
//!    gets `drivers=usoskey.drv` and `mouse.drv=vbmouse.drv` in [boot]
//!    (VBMOUSE.DRV has the module name MOUSE; Setup itself only swaps the
//!    MSMOUS31.DRV file for NOMOUSE/LMOUSE31, which no longer is the mouse
//!    driver).
//!
//! 3. HELPERDIR also holding USOSPID.DRV (tools/w9x_csmwrap_target.sh
//!    leaves it there only for a 950 / OSR2 native phase 1 with a staged OEM
//!    Product ID, C:\USOS9X\USOSPID.KEY): it goes into the cabinet with the
//!    bridge and drivers= names it after usoskey.drv; it types that ID into
//!    SUWIN's Product ID page (src/platform/bios/win9x/usospid.c). The log
//!    then says `pid=on` (else `pid=off`) right before the bridge line.
//!
//! The cabinet is written again with the original header (set ID, cabinet
//! chain names) as one MSZIP folder of stored blocks (cab.zig) and replaces
//! MINI.CAB only after it parsed back to exactly the intended files. Unknown
//! drivers stay as they are; a second run changes nothing. The log goes to
//! stderr and HELPERDIR (or SETUPDIR)/USOSMINI.TXT; its last line is
//! `bridge=on` when the cabinet has the bridge, else `bridge=off`.
//! Exit: 0 done (also when nothing changed), 2 usage, 3 I/O error.
const std = @import("std");
const cab = @import("cab.zig");
const patch = @import("display_patch.zig");
const table = @import("display_table.zig");

pub const log_name = "USOSMINI.TXT";
pub const key_driver = "USOSKEY.DRV";
pub const mouse_driver = "VBMOUSE.DRV";
pub const pid_driver = "USOSPID.DRV";
const max_cab = 8 * 1024 * 1024;
const max_driver = 1024 * 1024;

pub const Helpers = struct { usoskey: []const u8, vbmouse: []const u8, usospid: ?[]const u8 = null };
pub const Result = struct { data: ?[]u8, bridge: bool, pid: bool = false };

const Log = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    fn line(self: *Log, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[W9X_MINI] " ++ fmt ++ "\n", args);
        const s = std.fmt.allocPrint(self.gpa, fmt ++ "\r\n", args) catch return;
        defer self.gpa.free(s);
        self.text.appendSlice(self.gpa, s) catch {};
    }
};

fn hexOf(digest: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn keyOf(line: []const u8) ?[]const u8 {
    const t = trim(line);
    if (t.len == 0 or t[0] == ';' or t[0] == '[') return null;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    return trim(t[0..eq]);
}

fn isSection(line: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(trim(line), name);
}

fn hasWord(value: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t,");
    while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w, word)) return true;
    return false;
}

/// Whether [boot] of `ini` already names the bridge.
pub fn iniHasBridge(ini: []const u8) bool {
    var in_boot = false;
    var drivers = false;
    var mouse = false;
    var it = std.mem.splitScalar(u8, ini, '\n');
    while (it.next()) |line| {
        if (trim(line).len > 0 and trim(line)[0] == '[') {
            in_boot = isSection(line, "[boot]");
            continue;
        }
        if (!in_boot) continue;
        const key = keyOf(line) orelse continue;
        const value = trim(line)[std.mem.indexOfScalar(u8, trim(line), '=').? + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "drivers") and hasWord(value, "usoskey.drv")) drivers = true;
        if (std.ascii.eqlIgnoreCase(key, "mouse.drv") and std.ascii.eqlIgnoreCase(trim(value), "vbmouse.drv")) mouse = true;
    }
    return drivers and mouse;
}

/// SYSTEM.INI of the mini-Windows with the bridge in [boot]: an existing
/// drivers= line gets usoskey.drv appended, else `drivers=usoskey.drv` is
/// put right after the [boot] header; every mouse.drv= line becomes
/// `mouse.drv=vbmouse.drv` (one is added when there is none). Line endings
/// (CRLF in the cabinet) and every other line are kept.
pub fn editSystemIni(gpa: std.mem.Allocator, ini: []const u8) error{ NoBootSection, OutOfMemory }![]u8 {
    return editSystemIniWith(gpa, ini, false);
}

/// Whether [boot] drivers= of `ini` names usospid.drv.
pub fn iniHasPid(ini: []const u8) bool {
    var in_boot = false;
    var it = std.mem.splitScalar(u8, ini, '\n');
    while (it.next()) |line| {
        if (trim(line).len > 0 and trim(line)[0] == '[') {
            in_boot = isSection(line, "[boot]");
            continue;
        }
        if (!in_boot) continue;
        const key = keyOf(line) orelse continue;
        const value = trim(line)[std.mem.indexOfScalar(u8, trim(line), '=').? + 1 ..];
        if (std.ascii.eqlIgnoreCase(key, "drivers") and hasWord(value, "usospid.drv")) return true;
    }
    return false;
}

/// editSystemIni; `pid`: drivers= also names usospid.drv (after usoskey.drv).
pub fn editSystemIniWith(gpa: std.mem.Allocator, ini: []const u8, pid: bool) error{ NoBootSection, OutOfMemory }![]u8 {
    // pre-scan [boot]
    var has_drivers = false;
    var has_mouse = false;
    var has_boot = false;
    {
        var in_boot = false;
        var it = std.mem.splitScalar(u8, ini, '\n');
        while (it.next()) |line| {
            if (trim(line).len > 0 and trim(line)[0] == '[') {
                in_boot = isSection(line, "[boot]");
                if (in_boot) has_boot = true;
                continue;
            }
            if (!in_boot) continue;
            const key = keyOf(line) orelse continue;
            if (std.ascii.eqlIgnoreCase(key, "drivers")) has_drivers = true;
            if (std.ascii.eqlIgnoreCase(key, "mouse.drv")) has_mouse = true;
        }
    }
    if (!has_boot) return error.NoBootSection;
    const eol: []const u8 = if (std.mem.indexOf(u8, ini, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_boot = false;
    var it = std.mem.splitScalar(u8, ini, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const cr = line.len > 0 and line[line.len - 1] == '\r';
        if (trim(line).len > 0 and trim(line)[0] == '[') {
            const entering = isSection(line, "[boot]");
            try out.appendSlice(gpa, line);
            if (entering and !in_boot) {
                if (!has_drivers) {
                    if (!cr and eol.len == 2) try out.append(gpa, '\r');
                    try out.appendSlice(gpa, "\ndrivers=usoskey.drv");
                    if (pid) try out.appendSlice(gpa, " usospid.drv");
                    if (cr) try out.append(gpa, '\r');
                }
                if (!has_mouse) {
                    if (!cr and eol.len == 2) try out.append(gpa, '\r');
                    try out.appendSlice(gpa, "\nmouse.drv=vbmouse.drv");
                    if (cr) try out.append(gpa, '\r');
                }
            }
            in_boot = entering;
            continue;
        }
        const key = if (in_boot) keyOf(line) else null;
        if (key != null and std.ascii.eqlIgnoreCase(key.?, "mouse.drv")) {
            try out.appendSlice(gpa, "mouse.drv=vbmouse.drv");
            if (cr) try out.append(gpa, '\r');
        } else if (key != null and std.ascii.eqlIgnoreCase(key.?, "drivers")) {
            const body = if (cr) line[0 .. line.len - 1] else line;
            const value = body[std.mem.indexOfScalar(u8, body, '=').? + 1 ..];
            try out.appendSlice(gpa, std.mem.trimEnd(u8, body, " \t"));
            var empty = trim(value).len == 0;
            for ([_][]const u8{ "usoskey.drv", "usospid.drv" }, [_]bool{ true, pid }) |word, wanted| {
                if (!wanted or hasWord(value, word)) continue;
                if (!empty) try out.append(gpa, ' ');
                try out.appendSlice(gpa, word);
                empty = false;
            }
            if (cr) try out.append(gpa, '\r');
        } else {
            try out.appendSlice(gpa, line);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The new MINI.CAB (or null when nothing changes / on a problem, logged)
/// and whether the resulting cabinet carries the bridge.
pub fn rebuild(gpa: std.mem.Allocator, raw: []const u8, helpers: ?Helpers, log: anytype) Result {
    var c = cab.parse(gpa, raw) catch |err| {
        log.line("MINI.CAB: cannot read ({s}); left as is", .{@errorName(err)});
        return .{ .data = null, .bridge = false };
    };
    defer c.deinit(gpa);
    var files: std.ArrayList(cab.File) = .empty;
    defer files.deinit(gpa);
    files.appendSlice(gpa, c.files) catch return .{ .data = null, .bridge = false };
    var owned: [2]?[]u8 = .{ null, null };
    defer for (owned) |o| if (o) |b| gpa.free(b);
    var changed = false;

    // 1. the display driver
    if (c.find("VGA.DRV")) |i| {
        const digest = patch.sha256(c.files[i].data);
        switch (patch.find(&table.plans, digest)) {
            .patched => |p| log.line("VGA.DRV: {s} already patched", .{p.label}),
            .unknown => log.line("VGA.DRV: unknown driver (sha256 {s}); left as is", .{&hexOf(digest)}),
            .plan => |p| {
                if (patch.applyPlan(gpa, p, c.files[i].data)) |new_body| {
                    owned[0] = new_body;
                    files.items[i].data = new_body;
                    changed = true;
                    log.line("VGA.DRV: {s} patched ({d} sites), sha256 {s} -> {s}", .{
                        p.label, p.sites, &hexOf(digest), &hexOf(patch.sha256(new_body)),
                    });
                } else |err| log.line("VGA.DRV: {s}: {s}; left as is", .{ p.label, @errorName(err) });
            },
        }
    } else log.line("MINI.CAB has no VGA.DRV", .{});

    // 2. the USB keyboard/mouse bridge (3. with it: the Product ID helper)
    var bridge = false;
    var pid = false;
    if (helpers) |h| bridge: {
        const ini_i = c.find("SYSTEM.INI") orelse {
            log.line("MINI.CAB has no SYSTEM.INI; bridge not added", .{});
            break :bridge;
        };
        const new_ini = editSystemIniWith(gpa, c.files[ini_i].data, h.usospid != null) catch |err| {
            log.line("SYSTEM.INI: {s}; bridge not added", .{@errorName(err)});
            break :bridge;
        };
        if (std.mem.eql(u8, new_ini, c.files[ini_i].data)) {
            gpa.free(new_ini);
        } else {
            owned[1] = new_ini;
            files.items[ini_i].data = new_ini;
            changed = true;
        }
        const template = c.files[ini_i];
        for ([_]struct { []const u8, ?[]const u8 }{ .{ key_driver, h.usoskey }, .{ mouse_driver, h.vbmouse }, .{ pid_driver, h.usospid } }) |d| {
            const name, const maybe = d;
            const data = maybe orelse continue;
            const at = for (files.items, 0..) |f, k| {
                if (std.ascii.eqlIgnoreCase(f.name, name)) break k;
            } else null;
            if (at) |k| {
                if (std.mem.eql(u8, files.items[k].data, data)) continue;
                files.items[k].data = data;
            } else {
                files.append(gpa, .{ .name = name, .data = data, .date = template.date, .time = template.time, .attribs = 0x20 }) catch {
                    log.line("out of memory; left as is", .{});
                    return .{ .data = null, .bridge = false };
                };
            }
            changed = true;
        }
        bridge = true;
        pid = h.usospid != null;
        if (h.usospid) |b| log.line("product id helper: {s} ({d} bytes, sha256 {s}); drivers=usoskey.drv usospid.drv", .{ pid_driver, b.len, &hexOf(patch.sha256(b)) });
        log.line("bridge: {s} ({d} bytes, sha256 {s}) and {s} ({d} bytes, sha256 {s}); SYSTEM.INI [boot] drivers=usoskey.drv, mouse.drv=vbmouse.drv", .{
            key_driver, h.usoskey.len, &hexOf(patch.sha256(h.usoskey)), mouse_driver, h.vbmouse.len, &hexOf(patch.sha256(h.vbmouse)),
        });
    } else if (c.find("SYSTEM.INI")) |ini_i| {
        bridge = iniHasBridge(c.files[ini_i].data) and c.find(key_driver) != null and c.find(mouse_driver) != null;
        pid = bridge and iniHasPid(c.files[ini_i].data) and c.find(pid_driver) != null;
    }

    if (!changed) {
        log.line("MINI.CAB: nothing to change", .{});
        return .{ .data = null, .bridge = bridge, .pid = pid };
    }
    const out = cab.build(gpa, &c, files.items) catch |err| {
        log.line("MINI.CAB: cannot write ({s}); left as is", .{@errorName(err)});
        return .{ .data = null, .bridge = false };
    };
    // self-check: the new cabinet must read back to exactly these files
    var check = cab.parse(gpa, out) catch |err| {
        gpa.free(out);
        log.line("MINI.CAB: self-check failed ({s}); left as is", .{@errorName(err)});
        return .{ .data = null, .bridge = false };
    };
    defer check.deinit(gpa);
    const same = check.files.len == files.items.len and for (check.files, files.items) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.data, b.data)) break false;
    } else true;
    if (!same) {
        gpa.free(out);
        log.line("MINI.CAB: self-check differs; left as is", .{});
        return .{ .data = null, .bridge = false };
    }
    log.line("MINI.CAB: rewritten, {d} files, {d} -> {d} bytes, sha256 {s}", .{ files.items.len, raw.len, out.len, &hexOf(patch.sha256(out)) });
    return .{ .data = out, .bridge = bridge, .pid = pid };
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, setup_path: []const u8, helper_path: []const u8) u8 {
    var log = Log{ .gpa = gpa };
    defer log.text.deinit(gpa);
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, setup_path, .{}) catch |err| {
        log.line("cannot open {s}: {s}", .{ setup_path, @errorName(err) });
        return 3;
    };
    defer dir.close(io);
    var hdir: ?std.Io.Dir = null;
    if (!std.mem.eql(u8, helper_path, "-")) {
        hdir = cwd.openDir(io, helper_path, .{}) catch |err| blk: {
            log.line("cannot open {s}: {s}; bridge not added", .{ helper_path, @errorName(err) });
            break :blk null;
        };
    }
    defer if (hdir) |*h| h.close(io);
    const status = runIn(io, gpa, dir, hdir, &log);
    const log_dir = hdir orelse dir;
    log_dir.writeFile(io, .{ .sub_path = log_name, .data = log.text.items }) catch {};
    return status;
}

fn runIn(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, hdir: ?std.Io.Dir, log: *Log) u8 {
    var helpers: ?Helpers = null;
    var key_buf: ?[]u8 = null;
    var mouse_buf: ?[]u8 = null;
    var pid_buf: ?[]u8 = null;
    defer if (key_buf) |b| gpa.free(b);
    defer if (mouse_buf) |b| gpa.free(b);
    defer if (pid_buf) |b| gpa.free(b);
    if (hdir) |h| {
        key_buf = h.readFileAlloc(io, key_driver, gpa, .limited(max_driver)) catch null;
        mouse_buf = h.readFileAlloc(io, mouse_driver, gpa, .limited(max_driver)) catch null;
        pid_buf = h.readFileAlloc(io, pid_driver, gpa, .limited(max_driver)) catch null;
        if (key_buf != null and mouse_buf != null) {
            helpers = .{ .usoskey = key_buf.?, .vbmouse = mouse_buf.?, .usospid = pid_buf };
        } else log.line("{s} or {s} missing in the helper folder; bridge not added", .{ key_driver, mouse_driver });
    }
    const name = "MINI.CAB";
    const raw = dir.readFileAlloc(io, name, gpa, .limited(max_cab)) catch |err| {
        log.line("{s}: {s}; nothing patched", .{ name, @errorName(err) });
        log.line("pid=off", .{});
        log.line("bridge=off", .{});
        return if (err == error.FileNotFound) 0 else 3;
    };
    defer gpa.free(raw);
    const result = rebuild(gpa, raw, helpers, log);
    var status: u8 = 0;
    var bridge = result.bridge;
    var pid = result.pid;
    if (result.data) |data| {
        defer gpa.free(data);
        const tmp = "USOSMINI.TMP";
        if (dir.writeFile(io, .{ .sub_path = tmp, .data = data })) |_| {
            std.Io.Dir.rename(dir, tmp, dir, name, io) catch |err| {
                log.line("{s}: rename error {s}; left as is", .{ name, @errorName(err) });
                dir.deleteFile(io, tmp) catch {};
                status = 3;
                bridge = false;
                pid = false;
            };
        } else |err| {
            log.line("{s}: write error {s}; left as is", .{ name, @errorName(err) });
            status = 3;
            bridge = false;
            pid = false;
        }
    }
    // pid= first: `bridge=` stays the last line (tools/w9x_csmwrap_target.sh).
    log.line("pid={s}", .{if (pid) "on" else "off"});
    log.line("bridge={s}", .{if (bridge) "on" else "off"});
    return status;
}

test "SYSTEM.INI of the mini-Windows gets the bridge once" {
    const gpa = std.testing.allocator;
    const ini = "[boot]           \r\nlanguage.dll=langhun.dll\r\nshell=winsetup.bin\r\n; setup.exe\r\nmouse.drv=msmous31.drv\r\nkeyboard.drv=keyboard.drv\r\n\r\n[keyboard]\r\nmouse.drv=other\r\n";
    try std.testing.expect(!iniHasBridge(ini));
    const a = try editSystemIni(gpa, ini);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("[boot]           \r\ndrivers=usoskey.drv\r\nlanguage.dll=langhun.dll\r\nshell=winsetup.bin\r\n; setup.exe\r\nmouse.drv=vbmouse.drv\r\nkeyboard.drv=keyboard.drv\r\n\r\n[keyboard]\r\nmouse.drv=other\r\n", a);
    try std.testing.expect(iniHasBridge(a));
    const b = try editSystemIni(gpa, a);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    // an existing drivers= line is extended, a missing mouse.drv added
    const c = try editSystemIni(gpa, "[boot]\r\ndrivers=mmsystem.dll \r\n");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("[boot]\r\nmouse.drv=vbmouse.drv\r\ndrivers=mmsystem.dll usoskey.drv\r\n", c);
    try std.testing.expectError(error.NoBootSection, editSystemIni(gpa, "[keyboard]\r\n"));
}

test "a cabinet with an unknown driver gets only the bridge, then nothing" {
    const gpa = std.testing.allocator;
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3;
    header[25] = 1;
    header[26] = 1;
    const like = cab.Cabinet{ .header = &header, .folder_reserve = 0, .data_reserve = 0, .folder_extra = &.{}, .compress = 1, .files = &.{}, .body = &.{} };
    const files = [_]cab.File{
        .{ .name = "VGA.DRV", .data = "not a known driver", .date = 7, .time = 8, .attribs = 0x20 },
        .{ .name = "SYSTEM.INI", .data = "[boot]\r\nmouse.drv=msmous31.drv\r\n", .date = 7, .time = 8, .attribs = 0x20 },
    };
    const raw = try cab.build(gpa, &like, &files);
    defer gpa.free(raw);
    var log = Log{ .gpa = gpa };
    defer log.text.deinit(gpa);
    const r = rebuild(gpa, raw, .{ .usoskey = "KEY", .vbmouse = "MOUSE" }, &log);
    try std.testing.expect(r.bridge);
    const out = r.data.?;
    defer gpa.free(out);
    var c = try cab.parse(gpa, out);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), c.files.len);
    try std.testing.expectEqualStrings("not a known driver", c.files[0].data);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv\r\nmouse.drv=vbmouse.drv\r\n", c.files[1].data);
    try std.testing.expectEqualStrings("USOSKEY.DRV", c.files[2].name);
    try std.testing.expectEqualStrings("MOUSE", c.files[3].data);
    const again = rebuild(gpa, out, .{ .usoskey = "KEY", .vbmouse = "MOUSE" }, &log);
    try std.testing.expect(again.data == null and again.bridge);
    const plain = rebuild(gpa, out, null, &log);
    try std.testing.expect(plain.data == null and plain.bridge);
}

test "the Product ID helper joins drivers= after usoskey.drv, once" {
    const gpa = std.testing.allocator;
    const a = try editSystemIniWith(gpa, "[boot]\r\nshell=winsetup.bin\r\nmouse.drv=msmous31.drv\r\n", true);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv usospid.drv\r\nshell=winsetup.bin\r\nmouse.drv=vbmouse.drv\r\n", a);
    try std.testing.expect(iniHasBridge(a) and iniHasPid(a));
    const b = try editSystemIniWith(gpa, a, true);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
    const c = try editSystemIniWith(gpa, "[boot]\r\ndrivers=\r\nmouse.drv=x\r\n", true);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv usospid.drv\r\nmouse.drv=vbmouse.drv\r\n", c);
    const d = try editSystemIniWith(gpa, "[boot]\r\ndrivers=mmsystem.dll usoskey.drv\r\nmouse.drv=vbmouse.drv\r\n", true);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=mmsystem.dll usoskey.drv usospid.drv\r\nmouse.drv=vbmouse.drv\r\n", d);
    // without the helper: exactly as before
    const e = try editSystemIniWith(gpa, "[boot]\r\nmouse.drv=x\r\n", false);
    defer gpa.free(e);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv\r\nmouse.drv=vbmouse.drv\r\n", e);
    try std.testing.expect(!iniHasPid(e));
}

test "a cabinet gets USOSPID.DRV only with the helper and the bridge" {
    const gpa = std.testing.allocator;
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3;
    header[25] = 1;
    header[26] = 1;
    const like = cab.Cabinet{ .header = &header, .folder_reserve = 0, .data_reserve = 0, .folder_extra = &.{}, .compress = 1, .files = &.{}, .body = &.{} };
    const files = [_]cab.File{
        .{ .name = "SYSTEM.INI", .data = "[boot]\r\nmouse.drv=msmous31.drv\r\n", .date = 7, .time = 8, .attribs = 0x20 },
    };
    const raw = try cab.build(gpa, &like, &files);
    defer gpa.free(raw);
    var log = Log{ .gpa = gpa };
    defer log.text.deinit(gpa);
    const r = rebuild(gpa, raw, .{ .usoskey = "KEY", .vbmouse = "MOUSE", .usospid = "PID" }, &log);
    try std.testing.expect(r.bridge and r.pid);
    const out = r.data.?;
    defer gpa.free(out);
    var c = try cab.parse(gpa, out);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), c.files.len);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv usospid.drv\r\nmouse.drv=vbmouse.drv\r\n", c.files[0].data);
    try std.testing.expectEqualStrings("USOSPID.DRV", c.files[3].name);
    try std.testing.expectEqualStrings("PID", c.files[3].data);
    // the log names the driver, never more
    try std.testing.expect(std.mem.indexOf(u8, log.text.items, "product id helper: USOSPID.DRV (3 bytes") != null);
    const again = rebuild(gpa, out, .{ .usoskey = "KEY", .vbmouse = "MOUSE", .usospid = "PID" }, &log);
    try std.testing.expect(again.data == null and again.bridge and again.pid);
    const plain = rebuild(gpa, out, null, &log);
    try std.testing.expect(plain.data == null and plain.bridge and plain.pid);
    // no helper: no USOSPID.DRV, drivers= as before
    const none = rebuild(gpa, raw, .{ .usoskey = "KEY", .vbmouse = "MOUSE" }, &log);
    try std.testing.expect(none.bridge and !none.pid);
    defer gpa.free(none.data.?);
    var n = try cab.parse(gpa, none.data.?);
    defer n.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), n.files.len);
    try std.testing.expectEqualStrings("[boot]\r\ndrivers=usoskey.drv\r\nmouse.drv=vbmouse.drv\r\n", n.files[0].data);
}
