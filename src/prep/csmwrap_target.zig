//! The 32-bit Windows 10 CSMWrap route of MiniOS: the pure parts of the
//! Alpine micro-Linux step 610 (tools/vista_csmwrap_prepare.sh,
//! tools/vista_csmwrap_target.sh with X86_SELF=1, tools/xp_csmwrap_esp.sh,
//! tools/display_profile.sh, tools/answer_plan.sh), ported 1:1 so that
//! MiniOS writes the same disk the Alpine route writes. Host-tested; the
//! firmware I/O lives in src/prep/uefi_main.zig (runCsmwrapSetup).
//!
//! Disk (vista_csmwrap_target.sh header):
//!   MBR     USOS MBR code (xp-geometry-fix-mbr-440.bin), new disk signature
//!   slot 1  NTFS "Windows", inactive, 1 MiB .. staging start (Setup's InstallTo)
//!   slot 2  NTFS "USOS-SETUP", active, 1 GiB before the ESP: NT60 boot code,
//!           bootmgr from the ISO root, boot\bcd, boot\boot.sdi, sources\boot.wim
//!   slot 3  CSMWrap ESP, 64 MiB at the end (xp_csmwrap_esp.sh)
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

pub const esp_tail: u64 = 133120; // ESP_TAIL / USOS_XP_ESP_TAIL_SECTORS
pub const esp_sectors: u64 = 131072; // xp_csmwrap_esp.sh ESP_SECTORS
pub const staging_size: u64 = 2097152; // STAGING_SECTORS
pub const min_sectors: u64 = 33554432; // MIN_SECTORS (16 GiB)
pub const max_sectors: u64 = 4294967295; // MBR: below 2 TiB
pub const windows_first: u64 = 2048;
pub const mbr_code_bytes = 440;
pub const nt60_bytes = 8192;
pub const profile_x86 = "win-x86-uefi-csmwrap";
pub const staging_label = "USOS-SETUP";
pub const windows_label = "Windows";

pub const Layout = struct {
    total: u64,
    windows_start: u64,
    windows_sectors: u64,
    staging_start: u64,
    staging_sectors: u64,
    esp_start: u64,

    /// vista_csmwrap_target.sh: the same shell arithmetic (integer division).
    pub fn compute(total: u64) !Layout {
        if (total < min_sectors) return error.DiskSmallerThan16GiB;
        if (total > max_sectors) return error.DiskLargerThan2TiB;
        const esp_start = (total - esp_tail + 2047) / 2048 * 2048;
        const staging_start = (esp_start - staging_size) / 2048 * 2048;
        return .{
            .total = total,
            .windows_start = windows_first,
            .windows_sectors = staging_start - windows_first,
            .staging_start = staging_start,
            .staging_sectors = esp_start - staging_start,
            .esp_start = esp_start,
        };
    }
};

fn le32(out: []u8, value: u64) void {
    std.mem.writeInt(u32, out[0..4], @truncate(value), .little);
}

/// Step 1: the MBR the script assembles with printf (440 bytes of USOS code,
/// the signature, two entries with "beyond 8 GiB" CHS, slots 3/4 empty).
pub fn buildMbr(code: *const [mbr_code_bytes]u8, signature: u32, l: Layout) [512]u8 {
    var mbr: [512]u8 = @splat(0);
    @memcpy(mbr[0..440], code);
    std.mem.writeInt(u32, mbr[440..444], signature, .little);
    const chs = [_]u8{ 0xfe, 0xff, 0xff, 0x07, 0xfe, 0xff, 0xff };
    mbr[446] = 0x00;
    @memcpy(mbr[447..454], &chs);
    le32(mbr[454..458], l.windows_start);
    le32(mbr[458..462], l.windows_sectors);
    mbr[462] = 0x80;
    @memcpy(mbr[463..470], &chs);
    le32(mbr[470..474], l.staging_start);
    le32(mbr[474..478], l.staging_sectors);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    return mbr;
}

/// `od -An -tx4 -j440 -N4`: the signature as eight lower-case hex digits.
pub fn signatureHex(buffer: *[8]u8, signature: u32) []const u8 {
    _ = std.fmt.bufPrint(buffer, "{x:0>8}", .{signature}) catch unreachable;
    return buffer;
}

/// Step 2: the first 16 sectors of the formatted staging volume with the
/// NT60 NTFS boot code over bytes 84..8191 (the formatter's BPB stays).
pub fn applyNt60(boot: *[nt60_bytes]u8, code: *const [nt60_bytes]u8) void {
    @memcpy(boot[84..], code[84..]);
}

/// Step 4: usos-csmwrap-target.ini.
pub fn targetIni(buffer: []u8, signature: u32, l: Layout, nvme: bool) ![]const u8 {
    var hex: [8]u8 = undefined;
    return std.fmt.bufPrint(buffer, "disk_signature={s}\r\nstaging_start={d}\r\nstaging_sectors={d}\r\nesp_start={d}\r\ndisk_sectors={d}\r\nwindows_start={d}\r\nwindows_sectors={d}\r\ntarget_bus={s}\r\n", .{
        signatureHex(&hex, signature), l.staging_start, l.staging_sectors, l.esp_start, l.total, l.windows_start, l.windows_sectors, if (nvme) "nvme" else "other",
    });
}

/// Step 5 (xp_csmwrap_esp.sh): the first free slot gets the ESP entry; an
/// existing ESP, a missing signature or an overlapping partition refuse.
/// Returns the slot (1..4).
pub fn addEspEntry(mbr: *[512]u8, start: u64) !u8 {
    if (mbr[510] != 0x55 or mbr[511] != 0xaa) return error.TargetMbrNoSignature;
    const end = start + esp_sectors;
    var free: u8 = 0;
    for (0..4) |i| {
        const off = 446 + 16 * i;
        const kind = mbr[off + 4];
        const first: u64 = std.mem.readInt(u32, mbr[off + 8 ..][0..4], .little);
        const count: u64 = std.mem.readInt(u32, mbr[off + 12 ..][0..4], .little);
        if (kind == 0) {
            if (free == 0) free = @intCast(i + 1);
            continue;
        }
        if (kind == 239) return error.TargetAlreadyHasEsp;
        if (first + count > start and first < end) return error.PartitionOverlapsEsp;
    }
    if (free == 0) return error.NoFreeMbrSlot;
    const off = 446 + 16 * @as(usize, free - 1);
    const entry = [_]u8{ 0x00, 0xfe, 0xff, 0xff, 0xef, 0xfe, 0xff, 0xff };
    @memcpy(mbr[off..][0..8], &entry);
    le32(mbr[off + 8 ..][0..4], start);
    le32(mbr[off + 12 ..][0..4], esp_sectors);
    return free;
}

/// csmwrap.ini of this route: quiet unless EFI\USOS\csmwrap-verbose.flag;
/// none of the 2000 / 9x / diagnostic keys.
pub fn csmwrapIni(verbose: bool) []const u8 {
    return if (verbose) "serial = false\r\nverbose = true\r\n" else "serial = false\r\nverbose = false\r\n";
}

/// Step 6: the final read-back of the partition table.
pub fn verifyFinal(mbr: *const [512]u8, l: Layout) !void {
    if (mbr[462] != 0x80) return error.StagingNotActive;
    if (mbr[466] != 7) return error.StagingType;
    if (mbr[482] != 239) return error.EspSlot;
    if (std.mem.readInt(u32, mbr[486..490], .little) != l.esp_start) return error.EspStart;
    if (mbr[446] != 0) return error.WindowsActive;
    if (mbr[450] != 7) return error.WindowsType;
    if (std.mem.readInt(u32, mbr[454..458], .little) != l.windows_start) return error.WindowsStart;
}

// ------------------------------------------------------------ request.ini

pub const Answer = union(enum) { none, profile, file: []const u8 };
pub const Request = struct {
    iso: []const u8,
    donor: []const u8,
    folder: []const u8,
    answer: Answer,
    profile: []const u8,
    /// "Systems/Windows/<folder>" (vista_request_directory).
    source_directory: []const u8,
};

/// vista_csmwrap_value: the first `key=` line, CR stripped.
pub fn iniValue(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], key)) return line[eq + 1 ..];
    }
    return null;
}

fn unsafe(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "..") != null or (value.len > 0 and value[0] == '/');
}

/// usos_vista_csmwrap_prepare's request checks, for the routes MiniOS
/// takes over: profile win-x86-uefi-csmwrap, the ISO is its own donor.
pub fn parseRequest(text: []const u8) !Request {
    const iso = iniValue(text, "iso") orelse return error.RequestHasNoIso;
    const donor = iniValue(text, "donor") orelse return error.RequestHasNoDonor;
    const folder = iniValue(text, "folder") orelse "Windows Vista";
    const answer_text = iniValue(text, "answer") orelse "none";
    const profile = iniValue(text, "profile") orelse "vista-x64-sp2-uefi-csmwrap";
    if (!std.mem.eql(u8, profile, profile_x86)) return error.RequestProfileNotMiniOs;
    for ([_][]const u8{ iso, donor, folder, answer_text }) |v| if (unsafe(v)) return error.RequestUnsafePath;
    const dir = try requestDirectory(iso, folder);
    // MiniOS: 32-bit Windows 10 only, whose own WinPE boots (no PE10 donor).
    if (!std.mem.eql(u8, donor, iso)) return error.RequestExternalDonor;
    const answer: Answer = if (std.mem.eql(u8, answer_text, "none"))
        .none
    else if (std.mem.eql(u8, answer_text, "profile"))
        .profile
    else if (std.mem.startsWith(u8, answer_text, "file:")) blk: {
        const name = answer_text[5..];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return error.RequestUnsafeAnswerName;
        break :blk .{ .file = name };
    } else return error.RequestUnknownAnswer;
    return .{ .iso = iso, .donor = donor, .folder = folder, .answer = answer, .profile = profile, .source_directory = dir };
}

/// vista_request_directory: ISO under Systems/{Windows,Betas}/<folder>/Images/.
pub fn requestDirectory(iso: []const u8, folder: []const u8) ![]const u8 {
    if (folder.len == 0 or std.mem.indexOfAny(u8, folder, "/\\") != null or std.mem.indexOf(u8, folder, "..") != null) return error.RequestInconsistentDirectory;
    for ([_][]const u8{ "Systems/Windows/", "Systems/Betas/" }) |prefix| {
        if (!std.mem.startsWith(u8, iso, prefix)) continue;
        const rest = iso[prefix.len..];
        if (!std.mem.startsWith(u8, rest, folder) or !std.mem.startsWith(u8, rest[folder.len..], "/Images/")) continue;
        const image = rest[folder.len + "/Images/".len ..];
        if (image.len == 0 or std.mem.indexOfAny(u8, image, "/\\") != null or std.mem.indexOf(u8, image, "..") != null) return error.RequestInconsistentDirectory;
        return iso[0 .. prefix.len + folder.len];
    }
    return error.RequestInconsistentDirectory;
}

// --------------------------------------------------------- answer plan

/// usos_answer_plan_value: `key` in the [answer] section (case-insensitive key).
pub fn planValue(text: []const u8, key: []const u8) ?[]const u8 {
    var section_answer = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > 0 and line[0] == '[') {
            section_answer = std.ascii.eqlIgnoreCase(line, "[answer]");
            continue;
        }
        if (!section_answer) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (eq != 0 and std.ascii.eqlIgnoreCase(line[0..eq], key)) return line[eq + 1 ..];
    }
    return null;
}

/// usos_answer_plan_take PLAN autounattend_xml: the checks before the copy.
pub fn checkPlan(text: []const u8) !void {
    if (!std.mem.eql(u8, planValue(text, "source") orelse "", "profile")) return error.AnswerPlanHasNoProfile;
    if (!std.mem.eql(u8, planValue(text, "format") orelse "", "autounattend_xml")) return error.AnswerPlanFormat;
    if (!std.mem.eql(u8, planValue(text, "file") orelse "", "EFI/USOS/answer/autounattend.xml")) return error.AnswerPlanUnexpectedFile;
}

// ------------------------------------------------------------- display

pub const Display = union(enum) {
    /// profile display=keep or display-keep.txt: nothing staged.
    keep,
    /// the user's own answer sets <HorizontalResolution>: nothing staged.
    user_mode,
    /// an invalid request in a USOS answer: nothing staged.
    invalid,
    /// stage USOSRES with this request.
    request: []const u8,
};

/// usos_display_from_xml: the one `<!-- USOS-DISPLAY=value -->` line
/// (value without spaces). More than one: error.Duplicate. None: null.
pub fn displayFromXml(xml: []const u8) error{Duplicate}!?[]const u8 {
    const head = "<!-- USOS-DISPLAY=";
    const tail = " -->";
    var found: ?[]const u8 = null;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, xml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, head) or !std.mem.endsWith(u8, line, tail) or line.len < head.len + tail.len) continue;
        const value = line[head.len .. line.len - tail.len];
        if (std.mem.indexOfScalar(u8, value, ' ') != null) continue;
        found = value;
        n += 1;
    }
    if (n > 1) return error.Duplicate;
    return found;
}

/// usos_display_valid.
pub fn displayValid(value: []const u8) bool {
    const modes = [_][]const u8{ "auto", "1024x768", "1280x1024", "1920x1080" };
    const depths = [_][]const u8{ "auto", "16", "32" };
    for (modes) |m| for (depths) |d| {
        if (value.len == m.len + 1 + d.len and std.mem.startsWith(u8, value, m) and value[m.len] == 'x' and std.mem.endsWith(u8, value, d)) return true;
    };
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Step 2b of vista_csmwrap_target.sh (USOS_DISPLAY_KEEP = `keep_file`).
/// Note the script's order: a duplicate request in a USOS answer clears
/// display_request, and the next line then makes it autoxauto.
pub fn displayDecision(xml: ?[]const u8, keep_file: bool) Display {
    const keep_request: ?[]const u8 = if (xml) |x| (displayFromXml(x) catch null) else null;
    if (keep_file) return .keep;
    if (keep_request) |r| if (std.mem.startsWith(u8, r, "keep")) return .keep;
    if (xml) |x| {
        if (std.mem.indexOf(u8, x, "\\USOS\\NT6\\USOSRES.EXE") != null) {
            const request = (displayFromXml(x) catch null) orelse "autoxauto";
            return if (displayValid(request)) .{ .request = request } else .invalid;
        }
        if (containsIgnoreCase(x, "<HorizontalResolution>")) return .user_mode;
    }
    return .{ .request = "autoxauto" };
}

/// usos_display_native: display-native.txt (first 32 bytes, CR/LF removed)
/// when it is WxH with 320..8192 x 200..8192, no leading zeros.
pub fn displayNative(buffer: *[32]u8, raw: []const u8) ?[]const u8 {
    var n: usize = 0;
    for (raw[0..@min(raw.len, 32)]) |c| {
        if (c == '\r' or c == '\n') continue;
        buffer[n] = c;
        n += 1;
    }
    const text = buffer[0..n];
    var parts = std.mem.splitScalar(u8, text, 'x');
    const w_text = parts.next() orelse return null;
    const h_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    for ([_][]const u8{ w_text, h_text }) |t| {
        if (t.len == 0 or t[0] == '0') return null;
        for (t) |c| if (!std.ascii.isDigit(c)) return null;
    }
    const w = std.fmt.parseInt(u32, w_text, 10) catch return null;
    const h = std.fmt.parseInt(u32, h_text, 10) catch return null;
    if (w < 320 or h < 200 or w > 8192 or h > 8192) return null;
    return text;
}

/// usos_display_stage: DISPLAY.TXT.
pub fn displayText(buffer: []u8, request: []const u8, native: ?[]const u8) ![]const u8 {
    var n = (try std.fmt.bufPrint(buffer, "{s}\r\n", .{request})).len;
    if (native) |line| n += (try std.fmt.bufPrint(buffer[n..], "native={s}\r\n", .{line})).len;
    return buffer[0..n];
}

// --------------------------------------------------------------- NVMe

/// The modern NVMe helpers the script requires in modern-support.cpio
/// before the first write.
pub const modern_nvme_helpers = [_][]const u8{ "usos-nvme-modern.exe", "usos-nvme-modern.cmd", "modern-usosnvme.inf", "modern-usosnvme.cat", "modern-usosnvme.cer", "modern-usosnvme.sys" };

/// w9x_nvme_hwid allow list of the modern package: Micron 3400, QEMU NVMe.
pub fn modernNvmeCovers(vendor: u16, device: u16) bool {
    return (vendor == 0x1344 and device == 0x5407) or (vendor == 0x1b36 and device == 0x0010);
}

// ---------------------------------------------------------------- tests
const testing = std.testing;

test "layout: the script's arithmetic, 16 GiB / 2 TiB gates" {
    const l = try Layout.compute(1000215216); // 512 GB NVMe
    try testing.expectEqual(@as(u64, (1000215216 - 133120 + 2047) / 2048 * 2048), l.esp_start);
    try testing.expectEqual((l.esp_start - 2097152) / 2048 * 2048, l.staging_start);
    try testing.expectEqual(l.esp_start - l.staging_start, l.staging_sectors);
    try testing.expectEqual(l.staging_start - 2048, l.windows_sectors);
    try testing.expect(l.esp_start + esp_sectors <= l.total);
    try testing.expectError(error.DiskSmallerThan16GiB, Layout.compute(min_sectors - 1));
    try testing.expectError(error.DiskLargerThan2TiB, Layout.compute(max_sectors + 1));
    _ = try Layout.compute(min_sectors);
    _ = try Layout.compute(max_sectors);
}

test "MBR, target ini, ESP slot and final read-back" {
    var code: [440]u8 = undefined;
    for (&code, 0..) |*b, i| b.* = @truncate(i);
    const l = try Layout.compute(268435456);
    var mbr = buildMbr(&code, 0x1a2b3c4d, l);
    try testing.expectEqualSlices(u8, &code, mbr[0..440]);
    try testing.expectEqualSlices(u8, &.{ 0x4d, 0x3c, 0x2b, 0x1a, 0, 0 }, mbr[440..446]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xfe, 0xff, 0xff, 0x07, 0xfe, 0xff, 0xff }, mbr[446..454]);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xfe, 0xff, 0xff, 0x07, 0xfe, 0xff, 0xff }, mbr[462..470]);
    try testing.expect(std.mem.allEqual(u8, mbr[478..510], 0));
    try testing.expectError(error.EspSlot, verifyFinal(&mbr, l));
    try testing.expectEqual(@as(u8, 3), try addEspEntry(&mbr, l.esp_start));
    try verifyFinal(&mbr, l);
    try testing.expectError(error.TargetAlreadyHasEsp, addEspEntry(&mbr, l.esp_start));
    var other = buildMbr(&code, 1, l);
    try testing.expectError(error.PartitionOverlapsEsp, addEspEntry(&other, l.staging_start));
    var buffer: [512]u8 = undefined;
    const ini = try targetIni(&buffer, 0x0000abcd, l, true);
    try testing.expect(std.mem.startsWith(u8, ini, "disk_signature=0000abcd\r\nstaging_start="));
    try testing.expect(std.mem.endsWith(u8, ini, "\r\ntarget_bus=nvme\r\n"));
    var boot: [8192]u8 = @splat(1);
    var nt60: [8192]u8 = @splat(2);
    applyNt60(&boot, &nt60);
    try testing.expect(std.mem.allEqual(u8, boot[0..84], 1) and std.mem.allEqual(u8, boot[84..], 2));
}

test "request.ini of the x86 route" {
    const r = try parseRequest("version=1\r\nprofile=win-x86-uefi-csmwrap\r\niso=Systems/Windows/Windows 10/Images/w10x86.iso\r\ndonor=Systems/Windows/Windows 10/Images/w10x86.iso\r\nfolder=Windows 10\r\nanswer=file:my.xml\r\n");
    try testing.expectEqualStrings("Systems/Windows/Windows 10", r.source_directory);
    try testing.expectEqualStrings("my.xml", r.answer.file);
    try testing.expectError(error.RequestExternalDonor, parseRequest("profile=win-x86-uefi-csmwrap\r\niso=Systems/Windows/Windows 8.1/Images/a.iso\r\ndonor=Systems/Windows/Windows 10/Images/b.iso\r\nfolder=Windows 8.1\r\n"));
    try testing.expectError(error.RequestProfileNotMiniOs, parseRequest("iso=Systems/Windows/Windows Vista/Images/a.iso\r\ndonor=x\r\n"));
    try testing.expectError(error.RequestUnsafePath, parseRequest("profile=win-x86-uefi-csmwrap\r\niso=Systems/Windows/W/Images/../a.iso\r\ndonor=a\r\nfolder=W\r\n"));
    try testing.expectError(error.RequestInconsistentDirectory, parseRequest("profile=win-x86-uefi-csmwrap\r\niso=Systems/Windows/W/Images/a.iso\r\ndonor=Systems/Windows/W/Images/a.iso\r\nfolder=X\r\n"));
    const none = try parseRequest("profile=win-x86-uefi-csmwrap\r\niso=Systems/Betas/B/Images/a.iso\r\ndonor=Systems/Betas/B/Images/a.iso\r\nfolder=B\r\n");
    try testing.expect(none.answer == .none);
    try testing.expectEqualStrings("Systems/Betas/B", none.source_directory);
}

test "answer plan checks" {
    const plan = "; USOS plan\r\n[plan]\r\nversion=1\r\nfile=nope\r\n[answer]\r\nsource=profile\r\nname=Dom\r\nformat=autounattend_xml\r\nfile=EFI/USOS/answer/autounattend.xml\r\narch=x86\r\nkey=yes\r\n";
    try checkPlan(plan);
    try testing.expectEqualStrings("x86", planValue(plan, "ARCH").?);
    try testing.expectError(error.AnswerPlanFormat, checkPlan("[answer]\r\nsource=profile\r\nformat=nt5_settings\r\n"));
    try testing.expectError(error.AnswerPlanHasNoProfile, checkPlan("[answer]\r\nsource=none\r\n"));
}

test "display decision follows display_profile.sh + step 2b" {
    const usos = "<unattend>\n<!-- USOS-DISPLAY=1920x1080x32 -->\n<Path>%SystemDrive%\\USOS\\NT6\\USOSRES.EXE</Path>\n";
    try testing.expectEqualStrings("1920x1080x32", displayDecision(usos, false).request);
    try testing.expect(displayDecision(usos, true) == .keep);
    try testing.expect(displayDecision("<!-- USOS-DISPLAY=keepx1024x768 -->\r\n", false) == .keep);
    try testing.expectEqualStrings("autoxauto", displayDecision(null, false).request);
    try testing.expectEqualStrings("autoxauto", displayDecision("<unattend/>", false).request);
    try testing.expect(displayDecision("<horizontalresolution>1024</horizontalresolution>", false) == .user_mode);
    try testing.expect(displayDecision("\\USOS\\NT6\\USOSRES.EXE\n<!-- USOS-DISPLAY=1x1 -->\n", false) == .invalid);
    // Duplicate request in a USOS answer: the script ends at autoxauto.
    try testing.expectEqualStrings("autoxauto", displayDecision("\\USOS\\NT6\\USOSRES.EXE\n<!-- USOS-DISPLAY=autox16 -->\n<!-- USOS-DISPLAY=autox32 -->\n", false).request);
    // The marker must be the whole line.
    try testing.expectEqualStrings("autoxauto", displayDecision("\\USOS\\NT6\\USOSRES.EXE\n  <!-- USOS-DISPLAY=autox16 -->\n", false).request);
    var nb: [32]u8 = undefined;
    try testing.expectEqualStrings("2560x1440", displayNative(&nb, "2560x1440\r\n").?);
    try testing.expect(displayNative(&nb, "0x10") == null and displayNative(&nb, "100x100") == null and displayNative(&nb, " 1920x1080") == null);
    var tb: [64]u8 = undefined;
    try testing.expectEqualStrings("autoxauto\r\nnative=2560x1440\r\n", try displayText(&tb, "autoxauto", "2560x1440"));
}

test "NVMe allow list" {
    try testing.expect(modernNvmeCovers(0x1344, 0x5407) and modernNvmeCovers(0x1b36, 0x0010));
    try testing.expect(!modernNvmeCovers(0x144d, 0xa808));
}
