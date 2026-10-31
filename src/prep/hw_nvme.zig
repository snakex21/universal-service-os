//! SPDX-License-Identifier: GPL-3.0-or-later
//! 32-bit Windows 10 on an NVMe disk through MiniOS (CSMWrap route).
//!
//! The Alpine route installs the polled usosnvme "modern" package from the
//! Setup WinPE (tools/windows_nvme_modern.cmd + usos-nvme-modern.exe): the
//! stornvme service keeps its name but points at an own usosnvme.sys, and an
//! exact-ID signed INF is staged in the DriverStore, because Microsoft's
//! stornvme under CSMWrap on the X470 loses the disk (docs/nvme-nt6-2026-10-12.md
//! sections 13-20). MiniOS has no WinPE and no DISM, so the same end state is
//! reached in two steps:
//!
//! 1. offline, in the applied image (this file + uefi_main.zig HwApply):
//!    usosnvme.sys into System32\drivers, the package into \USOS\nvme-modern
//!    and a same-length in-place edit of the stornvme ImagePath in the SYSTEM
//!    hive (`...\stornvme.sys` -> `...\usosnvme.sys`, no cell allocation,
//!    hive header untouched). The first boot (specialize) therefore already
//!    runs on usosnvme; Microsoft's stornvme.sys file is not changed.
//! 2. online, in specialize (`online_cmd`, one RunSynchronous command added
//!    to the answer): the package certificate into LocalMachine Root and
//!    TrustedPublisher, pnputil /add-driver /install, then the stornvme
//!    service values the Alpine helper sets (ImagePath, Start 0,
//!    StartOverride 0, Parameters\PnpInterface 5). A PnP install of
//!    stornvme.inf during specialize may reset ImagePath; this command runs
//!    in the same pass, so the next boot (OOBE) uses usosnvme again.
//!
//! WinRE is not given the driver on this route (the Alpine route does it).
const std = @import("std");

pub const package_dir = "\\EFI\\USOS\\minios\\nvme";
pub const package_files = [_][]const u8{ "usosnvme.sys", "usosnvme.inf", "usosnvme.cat", "usosnvme.cer" };

pub const Reader = struct {
    context: *anyopaque,
    size: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror!void,
    fn read(self: Reader, at: u64, out: []u8) !void {
        if (at > self.size or out.len > self.size - at) return error.HiveBounds;
        try self.read_fn(self.context, at, out);
    }
};

const bins: u64 = 4096;
fn le(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}

/// Reads an allocated cell's content (without the size field), at most
/// out.len bytes; returns the cell's full content length.
fn cell(r: Reader, offset: u32, out: []u8) !usize {
    if (offset == 0xffffffff or offset % 8 != 0) return error.HiveCorrupt;
    var raw: [4]u8 = undefined;
    try r.read(bins + offset, &raw);
    const size = std.mem.readInt(i32, &raw, .little);
    if (size >= 0 or -size < 8 or -size > 16 * 1024 * 1024) return error.HiveCorrupt;
    const len: usize = @intCast(-size - 4);
    try r.read(bins + offset + 4, out[0..@min(len, out.len)]);
    return len;
}

fn nameEquals(raw: []const u8, compressed: bool, wanted: []const u8) bool {
    if (compressed) {
        if (raw.len != wanted.len) return false;
        for (raw, wanted) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
        return true;
    }
    if (raw.len != wanted.len * 2) return false;
    for (wanted, 0..) |b, i| {
        const c = le(u16, raw, i * 2);
        if (c > 0x7f or std.ascii.toLower(@intCast(c)) != std.ascii.toLower(b)) return false;
    }
    return true;
}

const Key = struct { subkeys: u32, subkey_list: u32, values: u32, value_list: u32 };
fn key(r: Reader, offset: u32) !Key {
    var nk: [80]u8 = undefined;
    const len = try cell(r, offset, &nk);
    if (len < 76 or !std.mem.eql(u8, nk[0..2], "nk")) return error.HiveCorrupt;
    return .{ .subkeys = le(u32, &nk, 20), .subkey_list = le(u32, &nk, 28), .values = le(u32, &nk, 36), .value_list = le(u32, &nk, 40) };
}
fn keyNamed(r: Reader, offset: u32, wanted: []const u8) !bool {
    var nk: [76 + 512]u8 = undefined;
    const len = try cell(r, offset, &nk);
    if (len < 76 or !std.mem.eql(u8, nk[0..2], "nk")) return error.HiveCorrupt;
    const name_len = le(u16, &nk, 72);
    if (name_len > 512 or 76 + name_len > len) return false;
    return nameEquals(nk[76..][0..name_len], le(u16, &nk, 2) & 0x20 != 0, wanted);
}

fn subkey(r: Reader, parent: u32, wanted: []const u8) !?u32 {
    const k = try key(r, parent);
    if (k.subkeys == 0) return null;
    return try searchList(r, k.subkey_list, wanted, 0);
}
fn searchList(r: Reader, list: u32, wanted: []const u8, depth: u8) !?u32 {
    if (depth > 2) return error.HiveCorrupt;
    var head: [4]u8 = undefined;
    const len = try cell(r, list, &head);
    const count = le(u16, &head, 2);
    const stride: u32 = if (std.mem.eql(u8, head[0..2], "lf") or std.mem.eql(u8, head[0..2], "lh")) 8 else if (std.mem.eql(u8, head[0..2], "li") or std.mem.eql(u8, head[0..2], "ri")) 4 else return error.HiveCorrupt;
    if (4 + @as(usize, count) * stride > len) return error.HiveCorrupt;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var entry: [4]u8 = undefined;
        try r.read(bins + list + 4 + 4 + i * stride, &entry);
        const target = std.mem.readInt(u32, &entry, .little);
        if (std.mem.eql(u8, head[0..2], "ri")) {
            if (try searchList(r, target, wanted, depth + 1)) |found| return found;
        } else if (try keyNamed(r, target, wanted)) return target;
    }
    return null;
}

const ValueRef = struct { kind: u32, len: u32, inline_data: u32, data_cell: ?u32 };
fn value(r: Reader, parent: u32, wanted: []const u8) !?ValueRef {
    const k = try key(r, parent);
    if (k.values == 0) return null;
    if (k.values > 4096) return error.HiveCorrupt;
    var i: u32 = 0;
    while (i < k.values) : (i += 1) {
        var entry: [4]u8 = undefined;
        try r.read(bins + k.value_list + 4 + i * 4, &entry);
        var vk: [20 + 256]u8 = undefined;
        const len = try cell(r, std.mem.readInt(u32, &entry, .little), &vk);
        if (len < 20 or !std.mem.eql(u8, vk[0..2], "vk")) return error.HiveCorrupt;
        const name_len = le(u16, &vk, 2);
        if (name_len > 256 or 20 + name_len > len) continue;
        if (!nameEquals(vk[20..][0..name_len], le(u16, &vk, 16) & 1 != 0, wanted)) continue;
        const size = le(u32, &vk, 4);
        if (size & 0x80000000 != 0) return .{ .kind = le(u32, &vk, 12), .len = size & 0x7fffffff, .inline_data = le(u32, &vk, 8), .data_cell = null };
        return .{ .kind = le(u32, &vk, 12), .len = size, .inline_data = 0, .data_cell = le(u32, &vk, 8) };
    }
    return null;
}

pub const Patch = struct {
    /// Byte offset in the hive file of the 16 bytes to replace.
    offset: u64,
    control_set: u32,
    /// The value as found, UTF-16 converted to ASCII (log).
    found: [96]u8 = undefined,
    found_len: usize = 0,
};
pub const replacement = std.unicode.utf8ToUtf16LeStringLiteral("usosnvme");

/// Locates the stornvme ImagePath in an offline SYSTEM hive and the 8
/// UTF-16 characters "stornvme" of its `\stornvme.sys` tail. Refuses a hive
/// whose base block is not clean (the sequence numbers differ: Windows would
/// replay its logs over the change) or any value it does not recognise.
pub fn findStornvmeImagePath(r: Reader) !Patch {
    var base: [512]u8 = undefined;
    try r.read(0, &base);
    if (!std.mem.eql(u8, base[0..4], "regf")) return error.HiveCorrupt;
    if (le(u32, &base, 4) != le(u32, &base, 8)) return error.HiveDirty;
    const root = le(u32, &base, 36);
    var control_set: u32 = 1;
    if (try subkey(r, root, "Select")) |select| {
        if (try value(r, select, "Current")) |current| {
            var number = current.inline_data;
            if (current.data_cell) |data_cell| {
                var raw: [4]u8 = .{ 0, 0, 0, 0 };
                if (current.len == 4 and try cell(r, data_cell, &raw) >= 4) number = std.mem.readInt(u32, &raw, .little) else number = 0;
            }
            if (current.kind == 4 and current.len == 4 and number >= 1 and number <= 999) control_set = number;
        }
    }
    var name_buf: [16]u8 = undefined;
    const set_name = try std.fmt.bufPrint(&name_buf, "ControlSet{d:0>3}", .{control_set});
    const set = (try subkey(r, root, set_name)) orelse return error.HiveNoControlSet;
    const services = (try subkey(r, set, "Services")) orelse return error.HiveNoServices;
    const service = (try subkey(r, services, "stornvme")) orelse return error.HiveNoStornvme;
    const image = (try value(r, service, "ImagePath")) orelse return error.HiveNoImagePath;
    if ((image.kind != 1 and image.kind != 2) or image.data_cell == null or image.len < 26 or image.len > 512 or image.len % 2 != 0) return error.HiveImagePathUnexpected;
    var data: [512]u8 = undefined;
    const cell_len = try cell(r, image.data_cell.?, &data);
    if (cell_len < image.len) return error.HiveCorrupt;
    const chars = image.len / 2;
    var ascii: [256]u8 = undefined;
    var n: usize = 0;
    for (0..chars) |i| {
        const c = le(u16, &data, i * 2);
        if (c == 0) break;
        if (c > 0x7e) return error.HiveImagePathUnexpected;
        ascii[n] = @intCast(c);
        n += 1;
    }
    var patch: Patch = .{ .offset = 0, .control_set = control_set };
    patch.found_len = @min(n, patch.found.len);
    @memcpy(patch.found[0..patch.found_len], ascii[0..patch.found_len]);
    const tail = "\\stornvme.sys";
    if (n < tail.len or !std.ascii.eqlIgnoreCase(ascii[n - tail.len .. n], tail)) return error.HiveImagePathUnexpected;
    const at = n - tail.len + 1;
    patch.offset = bins + image.data_cell.? + 4 + at * 2;
    return patch;
}

/// One RunSynchronous command in the answer's specialize pass (added after
/// the existing ones; a missing Deployment component or specialize pass is
/// created). The output is the whole new answer.
pub fn addSpecializeCommand(out: []u8, xml: []const u8, path: []const u8) ![]u8 {
    var cmd_buf: [1024]u8 = undefined;
    const pass_open = "<settings pass=\"specialize\">";
    if (std.mem.indexOf(u8, xml, pass_open)) |pass_at| {
        const pass_end = std.mem.indexOfPos(u8, xml, pass_at, "</settings>") orelse return error.AnswerMalformed;
        const pass = xml[pass_at..pass_end];
        if (std.mem.indexOf(u8, pass, "<RunSynchronous>")) |rs_rel| {
            const close_rel = std.mem.indexOfPos(u8, pass, rs_rel, "</RunSynchronous>") orelse return error.AnswerMalformed;
            var highest: u32 = 0;
            var it: usize = rs_rel;
            while (std.mem.indexOfPos(u8, pass[0..close_rel], it, "<Order>")) |o| {
                const e = std.mem.indexOfPos(u8, pass, o, "</Order>") orelse return error.AnswerMalformed;
                const v = std.fmt.parseInt(u32, std.mem.trim(u8, pass[o + 7 .. e], " \r\n\t"), 10) catch return error.AnswerMalformed;
                highest = @max(highest, v);
                it = e;
            }
            const cmd = try std.fmt.bufPrint(&cmd_buf, "  <RunSynchronousCommand wcm:action=\"add\">\n          <Order>{d}</Order>\n          <Path>{s}</Path>\n        </RunSynchronousCommand>\n      ", .{ highest + 1, path });
            return splice(out, xml, pass_at + close_rel, cmd);
        }
        const arch = if (std.mem.indexOf(u8, pass, "processorArchitecture=\"amd64\"") != null) "amd64" else "x86";
        const cmd = try std.fmt.bufPrint(&cmd_buf, "  <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"{s}\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\">\n      <RunSynchronous>\n        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>1</Order>\n          <Path>{s}</Path>\n        </RunSynchronousCommand>\n      </RunSynchronous>\n    </component>\n  ", .{ arch, path });
        return splice(out, xml, pass_end, cmd);
    }
    const end = std.mem.lastIndexOf(u8, xml, "</unattend>") orelse return error.AnswerMalformed;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "  <settings pass=\"specialize\">\n    <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"x86\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\">\n      <RunSynchronous>\n        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>1</Order>\n          <Path>{s}</Path>\n        </RunSynchronousCommand>\n      </RunSynchronous>\n    </component>\n  </settings>\n", .{path});
    return splice(out, xml, end, cmd);
}
fn splice(out: []u8, xml: []const u8, at: usize, insert: []const u8) ![]u8 {
    const total = xml.len + insert.len;
    if (total > out.len) return error.NoSpace;
    @memcpy(out[0..at], xml[0..at]);
    @memcpy(out[at..][0..insert.len], insert);
    @memcpy(out[at + insert.len ..][0 .. xml.len - at], xml[at..]);
    return out[0..total];
}

pub const specialize_path = "cmd.exe /c &quot;%SystemDrive%\\USOS\\nvme-modern\\usos-nvme-online.cmd&quot;";

/// Specialize step 2 (as SYSTEM). Never fails the pass; every result goes to
/// \USOS\nvme-modern\online.log on the new Windows disk.
pub const online_cmd =
    "@echo off\r\n" ++
    "rem USOS MiniOS: usosnvme for 32-bit Windows 10 on NVMe (specialize step).\r\n" ++
    "rem Same end state as tools\\windows_nvme_modern.cmd on the Alpine route.\r\n" ++
    "set \"P=%SystemDrive%\\USOS\\nvme-modern\"\r\n" ++
    "set \"L=%P%\\online.log\"\r\n" ++
    "set \"S=HKLM\\SYSTEM\\CurrentControlSet\\Services\\stornvme\"\r\n" ++
    "echo [USOS] MiniOS NVMe online step %DATE% %TIME%>>\"%L%\"\r\n" ++
    "reg.exe query \"%S%\" /v ImagePath >>\"%L%\" 2>&1\r\n" ++
    "certutil.exe -f -addstore Root \"%P%\\usosnvme.cer\" >>\"%L%\" 2>&1\r\n" ++
    "echo [USOS] certutil Root exit=%ERRORLEVEL%>>\"%L%\"\r\n" ++
    "certutil.exe -f -addstore TrustedPublisher \"%P%\\usosnvme.cer\" >>\"%L%\" 2>&1\r\n" ++
    "echo [USOS] certutil TrustedPublisher exit=%ERRORLEVEL%>>\"%L%\"\r\n" ++
    "pnputil.exe /add-driver \"%P%\\usosnvme.inf\" /install >>\"%L%\" 2>&1\r\n" ++
    "echo [USOS] pnputil exit=%ERRORLEVEL% (0 or 3010 = staged)>>\"%L%\"\r\n" ++
    "reg.exe add \"%S%\" /v ImagePath /t REG_EXPAND_SZ /d \"\\SystemRoot\\System32\\drivers\\usosnvme.sys\" /f >>\"%L%\" 2>&1\r\n" ++
    "echo [USOS] ImagePath exit=%ERRORLEVEL%>>\"%L%\"\r\n" ++
    "reg.exe add \"%S%\" /v Start /t REG_DWORD /d 0 /f >>\"%L%\" 2>&1\r\n" ++
    "reg.exe query \"%S%\\StartOverride\" >nul 2>&1 && reg.exe add \"%S%\\StartOverride\" /v 0 /t REG_DWORD /d 0 /f >>\"%L%\" 2>&1\r\n" ++
    "reg.exe add \"%S%\\Parameters\\PnpInterface\" /v 5 /t REG_DWORD /d 1 /f >>\"%L%\" 2>&1\r\n" ++
    "reg.exe query \"%S%\" >>\"%L%\" 2>&1\r\n" ++
    "pnputil.exe /enum-drivers >>\"%L%\" 2>&1\r\n" ++
    "echo [USOS] MiniOS NVMe online step done>>\"%L%\"\r\n" ++
    "exit /b 0\r\n";

// ---- tests ---------------------------------------------------------------

const regf = @import("regf.zig");
const t = std.testing;
const u = std.unicode.utf8ToUtf16LeStringLiteral;

const Bytes = struct {
    bytes: []const u8,
    fn read(ctx: *anyopaque, at: u64, out: []u8) anyerror!void {
        const self: *Bytes = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
fn utf16z(comptime s: []const u8) []const u8 {
    const w = u(s ++ "\x00");
    return std.mem.sliceAsBytes(w[0..w.len]);
}

test "stornvme ImagePath is found through Select\\Current and patched in place" {
    var hive = try regf.Hive.init(t.allocator, u("ROOT"), 1);
    defer hive.deinit();
    const select = try hive.ensureKey(u("Select"));
    try hive.setValue(select, u("Current"), 4, &[_]u8{ 2, 0, 0, 0 });
    const decoy = try hive.ensureKey(u("ControlSet001\\Services\\stornvme"));
    try hive.setValue(decoy, u("ImagePath"), 2, utf16z("System32\\drivers\\decoy000.sys"));
    for ([_][]const u16{ u("ControlSet002\\Services\\storahci"), u("ControlSet002\\Services\\stornvmf") }) |path| {
        const other = try hive.ensureKey(path);
        try hive.setValue(other, u("ImagePath"), 2, utf16z("System32\\drivers\\stornvme.sys"));
    }
    const svc = try hive.ensureKey(u("ControlSet002\\Services\\StorNVMe"));
    try hive.setValue(svc, u("Start"), 4, &[_]u8{ 0, 0, 0, 0 });
    try hive.setValue(svc, u("ImagePath"), 2, utf16z("System32\\drivers\\stornvme.sys"));
    try hive.seal();
    var bytes = try t.allocator.dupe(u8, hive.bytes.items);
    defer t.allocator.free(bytes);
    var src: Bytes = .{ .bytes = bytes };
    const patch = try findStornvmeImagePath(.{ .context = &src, .size = bytes.len, .read_fn = Bytes.read });
    try t.expectEqual(@as(u32, 2), patch.control_set);
    try t.expectEqualStrings("System32\\drivers\\stornvme.sys", patch.found[0..patch.found_len]);
    try t.expectEqualSlices(u8, std.mem.sliceAsBytes(u("stornvme")), bytes[@intCast(patch.offset)..][0..16]);
    @memcpy(bytes[@intCast(patch.offset)..][0..16], std.mem.sliceAsBytes(replacement));
    var reopened = try regf.Hive.open(t.allocator, bytes, 2);
    defer reopened.deinit();
    const image = (try reopened.getValue((try reopened.findKey(u("ControlSet002\\Services\\stornvme"))).?, u("ImagePath"))).?;
    defer t.allocator.free(image.data);
    try t.expectEqualSlices(u8, utf16z("System32\\drivers\\usosnvme.sys"), image.data);
    // Already patched: refused (no \stornvme.sys tail).
    try t.expectError(error.HiveImagePathUnexpected, findStornvmeImagePath(.{ .context = &src, .size = bytes.len, .read_fn = Bytes.read }));
    // Dirty base block: refused.
    std.mem.writeInt(u32, bytes[4..8], std.mem.readInt(u32, bytes[8..12], .little) + 1, .little);
    try t.expectError(error.HiveDirty, findStornvmeImagePath(.{ .context = &src, .size = bytes.len, .read_fn = Bytes.read }));
}

test "no stornvme service: refused" {
    var hive = try regf.Hive.init(t.allocator, u("ROOT"), 1);
    defer hive.deinit();
    _ = try hive.ensureKey(u("ControlSet001\\Services\\storahci"));
    try hive.seal();
    var src: Bytes = .{ .bytes = hive.bytes.items };
    try t.expectError(error.HiveNoStornvme, findStornvmeImagePath(.{ .context = &src, .size = hive.bytes.items.len, .read_fn = Bytes.read }));
}

test "specialize command is appended after the answer's own commands" {
    var out: [4096]u8 = undefined;
    const with_rs =
        "<unattend>\n  <settings pass=\"windowsPE\"><RunSynchronous><RunSynchronousCommand><Order>9</Order></RunSynchronousCommand></RunSynchronous></settings>\n" ++
        "  <settings pass=\"specialize\">\n    <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"x86\">\n      <RunSynchronous>\n" ++
        "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>1</Order>\n          <Path>a</Path>\n        </RunSynchronousCommand>\n" ++
        "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>2</Order>\n          <Path>b</Path>\n        </RunSynchronousCommand>\n" ++
        "      </RunSynchronous>\n    </component>\n  </settings>\n</unattend>\n";
    const a = try addSpecializeCommand(&out, with_rs, specialize_path);
    try t.expect(std.mem.indexOf(u8, a, "<Order>3</Order>\n          <Path>" ++ specialize_path ++ "</Path>") != null);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, a, "</RunSynchronous>\n    </component>\n  </settings>\n</unattend>") );
    try t.expect(std.mem.indexOf(u8, a, specialize_path).? > std.mem.indexOf(u8, a, "<Path>b</Path>").?);

    const no_deploy = "<unattend>\n  <settings pass=\"specialize\">\n    <component name=\"Microsoft-Windows-Shell-Setup\" processorArchitecture=\"x86\">\n    </component>\n  </settings>\n</unattend>\n";
    const b = try addSpecializeCommand(&out, no_deploy, specialize_path);
    try t.expect(std.mem.indexOf(u8, b, "Microsoft-Windows-Deployment\" processorArchitecture=\"x86\"") != null);
    try t.expect(std.mem.indexOf(u8, b, "<Order>1</Order>") != null);
    try t.expect(std.mem.indexOf(u8, b, "</component>\n  </settings>\n</unattend>") != null);

    const no_pass = "<unattend>\n  <settings pass=\"oobeSystem\">\n  </settings>\n</unattend>\n";
    var out2: [4096]u8 = undefined;
    const c = try addSpecializeCommand(&out2, no_pass, specialize_path);
    try t.expect(std.mem.indexOf(u8, c, "<settings pass=\"specialize\">") != null);
    try t.expect(std.mem.endsWith(u8, c, "</unattend>\n"));
    var tiny: [16]u8 = undefined;
    try t.expectError(error.NoSpace, addSpecializeCommand(&tiny, no_pass, specialize_path));
}

test "online command mirrors the Alpine helper's service values" {
    for ([_][]const u8{ "-addstore Root", "-addstore TrustedPublisher", "/add-driver", "\\SystemRoot\\System32\\drivers\\usosnvme.sys", "/v Start /t REG_DWORD /d 0", "PnpInterface\" /v 5", "exit /b 0" }) |needle|
        try t.expect(std.mem.indexOf(u8, online_cmd, needle) != null);
    try t.expect(std.mem.indexOf(u8, online_cmd, "\n") == std.mem.indexOf(u8, online_cmd, "\r\n").? + 1);
}

test "optional: a real offline SYSTEM hive (zig-out/test-private/SYSTEM, never in the repository)" {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, "zig-out/test-private/SYSTEM", .{ .mode = .read_only }) catch return error.SkipZigTest;
    defer file.close(io);
    const stat = try file.stat(io);
    const bytes = try t.allocator.alloc(u8, @intCast(stat.size));
    defer t.allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRead;
    var src: Bytes = .{ .bytes = bytes };
    const patch = try findStornvmeImagePath(.{ .context = &src, .size = bytes.len, .read_fn = Bytes.read });
    std.debug.print("real hive: ControlSet{d:0>3} ImagePath={s} offset={d}\n", .{ patch.control_set, patch.found[0..patch.found_len], patch.offset });
    try t.expect(std.ascii.eqlIgnoreCase(&.{ bytes[@intCast(patch.offset)], bytes[@intCast(patch.offset + 2)] }, "st"));
}
