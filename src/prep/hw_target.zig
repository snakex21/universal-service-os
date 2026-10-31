//! SPDX-License-Identifier: GPL-3.0-or-later
//! Hardware (non-QEMU) target support for the MiniOS install workload.
//!
//! The QEMU gates require a target whose every byte is zero (a fresh image)
//! and a host-written token. On real hardware the USOS flow asks the one disk
//! question, writes the token to the chosen disk only, and the disk holds old
//! data. `VirtualBlank` restores the blank-disk contract without a full-disk
//! wipe:
//!
//! * reads of a 1 MiB chunk MiniOS never wrote return zeros (the writer sees
//!   exactly what it sees on a fresh image);
//! * the first write into a chunk zeroes the whole chunk on the device first
//!   (unless the write covers it completely), so stale bytes never survive
//!   next to new data;
//! * `fillRange` zeroes every untouched chunk of the regions Windows reads
//!   as metadata (ESP, MSR, the Windows volume up to the NTFS allocation
//!   high-water mark), making them byte-identical to a fresh-image run.
//!
//! Untouched chunks beyond the allocation high-water mark keep old bytes:
//! they are free clusters, which a fresh image would hold as zeros and which
//! NTFS never reads as metadata.
const std = @import("std");
const p = @import("platform.zig");

pub const chunk_bytes: u64 = 1024 * 1024;
const zero_bytes = 64 * 1024;

pub const VirtualBlank = struct {
    base: p.Disk,
    allocator: std.mem.Allocator,
    touched: []u64,
    zeros: []align(4096) u8,
    stats: Stats = .{},

    pub const Stats = struct { first_touch_zeroed: u64 = 0, full_chunk_writes: u64 = 0, virtual_zero_reads: u64 = 0, gap_chunks_zeroed: u64 = 0 };

    pub fn init(allocator: std.mem.Allocator, base: p.Disk) !VirtualBlank {
        const bytes = try base.bytes();
        const chunks = std.math.divCeil(u64, bytes, chunk_bytes) catch return error.Bounds;
        const words: usize = @intCast(std.math.divCeil(u64, chunks, 64) catch return error.Bounds);
        const touched = try allocator.alloc(u64, words);
        errdefer allocator.free(touched);
        @memset(touched, 0);
        const zeros = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), zero_bytes);
        @memset(zeros, 0);
        return .{ .base = base, .allocator = allocator, .touched = touched, .zeros = zeros };
    }
    pub fn deinit(self: *VirtualBlank) void {
        self.allocator.free(self.touched);
        self.allocator.free(self.zeros);
        self.* = undefined;
    }
    pub fn disk(self: *VirtualBlank) p.Disk {
        return .{ .context = self, .sector_bytes = self.base.sector_bytes, .sectors = self.base.sectors, .read_fn = read, .write_fn = write, .flush_fn = flush, .profiler = self.base.profiler };
    }
    pub fn isTouched(self: *const VirtualBlank, index: u64) bool {
        return self.touched[@intCast(index / 64)] & (@as(u64, 1) << @intCast(index % 64)) != 0;
    }
    fn mark(self: *VirtualBlank, index: u64) void {
        self.touched[@intCast(index / 64)] |= @as(u64, 1) << @intCast(index % 64);
    }
    fn chunkEnd(self: *const VirtualBlank, index: u64) !u64 {
        return @min((index + 1) * chunk_bytes, try self.base.bytes());
    }
    fn zeroChunk(self: *VirtualBlank, index: u64) p.Error!void {
        var at = index * chunk_bytes;
        const end = try self.chunkEnd(index);
        while (at < end) {
            const n: usize = @intCast(@min(end - at, self.zeros.len));
            try self.base.write(at, self.zeros[0..n]);
            at += n;
        }
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            const index = at / chunk_bytes;
            const end = try self.chunkEnd(index);
            var n: usize = @intCast(@min(out.len - done, end - at));
            // Merge consecutive chunks of the same state into one device read.
            if (self.isTouched(index)) {
                var next = index + 1;
                while (done + n < out.len and self.isTouched(next)) : (next += 1) n = @intCast(@min(out.len - done, (try self.chunkEnd(next)) - at));
                try self.base.read(at, out[done..][0..n]);
            } else {
                self.stats.virtual_zero_reads +|= 1;
                @memset(out[done..][0..n], 0);
            }
            done += n;
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        if (input.len == 0) return;
        const first = offset / chunk_bytes;
        const last = (offset + input.len - 1) / chunk_bytes;
        var index = first;
        while (index <= last) : (index += 1) {
            if (self.isTouched(index)) continue;
            const start = index * chunk_bytes;
            const end = try self.chunkEnd(index);
            if (offset <= start and offset + input.len >= end) {
                self.stats.full_chunk_writes +|= 1;
            } else {
                try self.zeroChunk(index);
                self.stats.first_touch_zeroed +|= 1;
            }
            self.mark(index);
        }
        try self.base.write(offset, input);
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *VirtualBlank = @ptrCast(@alignCast(ctx));
        try self.base.flush();
    }
    /// Zeroes every untouched chunk overlapping [start, end) on the device.
    pub fn fillRange(self: *VirtualBlank, start: u64, end: u64) p.Error!void {
        if (end <= start) return;
        const last = (@min(end, try self.base.bytes()) - 1) / chunk_bytes;
        var index = start / chunk_bytes;
        while (index <= last) : (index += 1) {
            if (self.isTouched(index)) continue;
            try self.zeroChunk(index);
            self.mark(index);
            self.stats.gap_chunks_zeroed +|= 1;
        }
    }
};

/// Previous logs are kept: USOSPREP.LOG -> .1 -> .2 ... up to `keep` files.
/// Returns the rename plan (oldest first) for `keep` generations.
pub fn rotationName(buffer: []u8, generation: usize) ![]const u8 {
    if (generation == 0) return std.fmt.bufPrint(buffer, "\\USOSPREP.LOG", .{});
    return std.fmt.bufPrint(buffer, "\\USOSPREP.{d}.LOG", .{generation});
}

/// Hardware configuration (USOSPREP_HW_V1), written by the USOS menu.
pub const Hardware = struct {
    /// The disk the user chose in the USOS menu (disk_path= hex device path
    /// body + disk_sectors=); MiniOS then asks no disk question of its own.
    /// Empty: the old MiniOS text disk question (kept for direct starts).
    disk_path: [max_disk_path]u8 = @splat(0),
    disk_path_len: usize = 0,
    disk_sectors: u64 = 0,
    /// ui=quiet: nothing on the text console (the menu's own status screen
    /// stays visible); the log file is unchanged.
    quiet: bool = false,
    build: [32]u8 = @splat(0),
    build_len: usize = 0,
    locale: [32]u8 = @splat(0),
    locale_len: usize = 0,
    unattend: bool = false,
    boot_entry: bool = true,
    /// mode=mbr: BIOS-boot Windows (32-bit Windows 10) started through a
    /// CSMWrap ESP at the end of the disk (csmwrap=on, required with mbr).
    csmwrap: bool = false,

    pub fn buildId(self: *const Hardware) []const u8 {
        return self.build[0..self.build_len];
    }
    pub fn localeText(self: *const Hardware) []const u8 {
        return if (self.locale_len == 0) "en-US" else self.locale[0..self.locale_len];
    }
};

pub const max_disk_path = 256;

/// disk_path=: lowercase/uppercase hex of a device path body (no End node),
/// 4..max_disk_path bytes, whole nodes.
pub fn parseDiskPath(out: *[max_disk_path]u8, hex: []const u8) !usize {
    if (hex.len < 8 or hex.len % 2 != 0 or hex.len / 2 > max_disk_path) return error.InvalidArgument;
    const bytes = std.fmt.hexToBytes(out, hex) catch return error.InvalidArgument;
    var at: usize = 0;
    while (at < bytes.len) {
        if (bytes.len - at < 4) return error.InvalidArgument;
        const len = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
        if (len < 4 or len > bytes.len - at or bytes[at] == 0x7f) return error.InvalidArgument;
        at += len;
    }
    return bytes.len;
}

test "disk_path parses whole device path nodes only" {
    var out: [max_disk_path]u8 = undefined;
    // PciRoot-like ACPI node (12 bytes) + NVMe node (16 bytes).
    const hex = "02010c00d041030a00000000" ++ "03171000010000000000000000000000";
    try std.testing.expectEqual(@as(usize, 28), try parseDiskPath(&out, hex));
    try std.testing.expectError(error.InvalidArgument, parseDiskPath(&out, hex[0 .. hex.len - 2]));
    try std.testing.expectError(error.InvalidArgument, parseDiskPath(&out, "7fff0400"));
    try std.testing.expectError(error.InvalidArgument, parseDiskPath(&out, "zz010c00"));
}

pub fn validBuildId(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
pub fn validLocale(value: []const u8) bool {
    if (value.len < 2 or value.len > 32) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

/// Fresh RFC 4122 v4 loader GUID derived (domain-separated) from the run's
/// validated entropy; it differs from every layout GUID by construction check.
pub fn loaderGuid(seed: [64]u8, avoid: []const [16]u8) ![16]u8 {
    var counter: u8 = 0;
    while (counter < 8) : (counter += 1) {
        var digest: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&seed);
        hash.update("USOSPREP hardware loader GUID v1");
        hash.update(&.{counter});
        hash.final(&digest);
        var guid = digest[0..16].*;
        guid[7] = (guid[7] & 0x0f) | 0x40;
        guid[8] = (guid[8] & 0x3f) | 0x80;
        var clash = false;
        for (avoid) |other| clash = clash or std.mem.eql(u8, &guid, &other);
        if (!clash) return guid;
    }
    return error.EntropyUnavailable;
}

// ------------------------------------------------- MBR + CSMWrap (x86 Windows)

/// The CSMWrap ESP of the Alpine route (tools/xp_csmwrap_esp.sh,
/// tools/vista_csmwrap_target.sh): 64 MiB, MBR type 0xEF, slot 3, MiB-aligned
/// inside the last 133120 sectors. Windows ends where it starts.
pub const csmwrap_esp_sectors: u64 = 131072;
pub const csmwrap_tail_sectors: u64 = 133120;
pub const mbr_max_sectors: u64 = 0xffffffff;
/// Pinned like tools/xp_csmwrap_esp.sh (CSMWrap 3.1.2-usos18).
pub const csmwrap_sha256 = "0188057913ee7b4680027e45c53c45048deb8583c599c3c0672d98748704e0a4";

pub fn csmwrapEspStart(total_sectors: u64) !u64 {
    if (total_sectors < 32 * 1024 * 1024 or total_sectors > mbr_max_sectors) return error.Unsupported;
    const start = std.mem.alignForward(u64, total_sectors - csmwrap_tail_sectors, 2048);
    if (start + csmwrap_esp_sectors > total_sectors) return error.NoSpace;
    return start;
}

/// A primary MBR entry (CHS fields "beyond 8 GiB", as the Alpine scripts).
pub fn mbrEntry(out: []u8, active: bool, kind: u8, start: u64, count: u64) !void {
    if (out.len != 16 or start == 0 or count == 0 or start > mbr_max_sectors or count > mbr_max_sectors - start) return error.InvalidArgument;
    out[0] = if (active) 0x80 else 0;
    out[1..4].* = .{ 0xfe, 0xff, 0xff };
    out[4] = kind;
    out[5..8].* = .{ 0xfe, 0xff, 0xff };
    std.mem.writeInt(u32, out[8..12], @intCast(start), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(count), .little);
}

/// Publishes the CSMWrap ESP as slot 3 of an MBR whose slots 1 (system,
/// active) and 2 (Windows) end before it and whose slots 3 and 4 are empty.
pub fn addCsmwrapEntry(mbr: *[512]u8, esp_start: u64) !void {
    if (std.mem.readInt(u16, mbr[510..512], .little) != 0xaa55 or !std.mem.allEqual(u8, mbr[478..510], 0)) return error.BootDiskIdentityMismatch;
    for (0..2) |slot| {
        const raw = mbr[446 + slot * 16 ..][0..16];
        const first = std.mem.readInt(u32, raw[8..12], .little);
        const count = std.mem.readInt(u32, raw[12..16], .little);
        if (raw[4] != 7 or first == 0 or @as(u64, first) + count > esp_start) return error.BootDiskIdentityMismatch;
    }
    try mbrEntry(mbr[478..494], false, 0xef, esp_start, csmwrap_esp_sectors);
}

/// The display request of a USOS answer (<!-- USOS-DISPLAY=... -->, as
/// tools/display_profile.sh usos_display_from_xml): null = nothing staged
/// (keep, an invalid or duplicate request, or a user answer that sets its own
/// <HorizontalResolution>); no answer or no request: auto.
pub fn displayRequest(xml: ?[]const u8) ?[]const u8 {
    const text = xml orelse return "autoxauto";
    const marker = "<!-- USOS-DISPLAY=";
    const at = std.mem.indexOf(u8, text, marker) orelse {
        if (std.mem.indexOf(u8, text, "<HorizontalResolution>") != null and std.mem.indexOf(u8, text, "\\USOS\\NT6\\USOSRES.EXE") == null) return null;
        return "autoxauto";
    };
    if (std.mem.indexOfPos(u8, text, at + marker.len, marker) != null) return null;
    const rest = text[at + marker.len ..];
    const end = std.mem.indexOf(u8, rest, " -->") orelse return null;
    const value = rest[0..end];
    if (std.mem.startsWith(u8, value, "keep")) return null;
    return if (validDisplay(value)) value else null;
}
fn validDisplay(value: []const u8) bool {
    const x = std.mem.lastIndexOfScalar(u8, value, 'x') orelse return false;
    const mode = value[0..x];
    const depth = value[x + 1 ..];
    const modes = [_][]const u8{ "auto", "1024x768", "1280x1024", "1920x1080" };
    const depths = [_][]const u8{ "auto", "16", "32" };
    var ok_mode = false;
    for (modes) |m| ok_mode = ok_mode or std.mem.eql(u8, m, mode);
    var ok_depth = false;
    for (depths) |d| ok_depth = ok_depth or std.mem.eql(u8, d, depth);
    return ok_mode and ok_depth;
}

/// DISPLAY.TXT for USOSRES: the request, then native=WxH from the menu's
/// EDID record (EFI\USOS\display-native.txt) when it is well formed.
pub fn displayText(buffer: []u8, request: []const u8, native_file: ?[]const u8) ![]const u8 {
    var n = (try std.fmt.bufPrint(buffer, "{s}\r\n", .{request})).len;
    if (native_file) |raw| {
        const line = std.mem.trim(u8, raw[0..@min(raw.len, 32)], " \r\n");
        if (nativeMode(line)) n += (try std.fmt.bufPrint(buffer[n..], "native={s}\r\n", .{line})).len;
    }
    return buffer[0..n];
}
fn nativeMode(line: []const u8) bool {
    const x = std.mem.indexOfScalar(u8, line, 'x') orelse return false;
    if (x == 0 or x + 1 >= line.len or line[0] == '0' or line[x + 1] == '0') return false;
    const w = std.fmt.parseInt(u32, line[0..x], 10) catch return false;
    const h = std.fmt.parseInt(u32, line[x + 1 ..], 10) catch return false;
    return w >= 320 and h >= 200 and w <= 8192 and h <= 8192;
}

const Memory = struct {
    bytes: []u8,
    writes: usize = 0,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, at: u64, in: []const u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        @memcpy(self.bytes[@intCast(at)..][0..in.len], in);
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *Memory) p.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};

test "virtual blank hides stale bytes, zeroes partial first touches and fills gaps" {
    const a = std.testing.allocator;
    const raw = try a.alloc(u8, 8 * chunk_bytes + 512 * 3);
    defer a.free(raw);
    @memset(raw, 0xa5);
    var memory: Memory = .{ .bytes = raw };
    var blank = try VirtualBlank.init(a, memory.disk());
    defer blank.deinit();
    const d = blank.disk();
    var buf: [4096]u8 = undefined;
    try d.read(chunk_bytes - 2048, &buf);
    try std.testing.expect(std.mem.allEqual(u8, &buf, 0));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
    // Partial write into chunk 2: the rest of chunk 2 becomes zero on the device.
    try d.write(2 * chunk_bytes + 4096, "hello");
    try std.testing.expectEqualStrings("hello", raw[2 * chunk_bytes + 4096 ..][0..5]);
    try std.testing.expect(std.mem.allEqual(u8, raw[2 * chunk_bytes .. 2 * chunk_bytes + 4096], 0));
    try std.testing.expect(std.mem.allEqual(u8, raw[2 * chunk_bytes + 4101 .. 3 * chunk_bytes], 0));
    try std.testing.expectEqual(@as(u8, 0xa5), raw[3 * chunk_bytes]);
    // Reads spanning touched and untouched chunks.
    var span: [8]u8 = undefined;
    try d.read(3 * chunk_bytes - 4, &span);
    try std.testing.expect(std.mem.allEqual(u8, &span, 0));
    // A full-chunk write is not pre-zeroed.
    const full = try a.alloc(u8, chunk_bytes);
    defer a.free(full);
    @memset(full, 0x11);
    const before = memory.writes;
    try d.write(4 * chunk_bytes, full);
    try std.testing.expectEqual(before + 1, memory.writes);
    try std.testing.expectEqual(@as(u64, 1), blank.stats.full_chunk_writes);
    // The trailing partial chunk is handled.
    try d.write(8 * chunk_bytes, "end");
    try std.testing.expect(std.mem.allEqual(u8, raw[8 * chunk_bytes + 3 ..], 0));
    try blank.fillRange(0, 4 * chunk_bytes);
    try std.testing.expect(std.mem.allEqual(u8, raw[0 .. 2 * chunk_bytes], 0));
    try std.testing.expectEqual(@as(u8, 0xa5), raw[5 * chunk_bytes]);
    try std.testing.expectEqual(@as(u64, 3), blank.stats.gap_chunks_zeroed);
}

test "loader GUID is version 4 and avoids layout GUIDs" {
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    const first = try loaderGuid(seed, &.{});
    try std.testing.expect(first[7] >> 4 == 4 and first[8] >> 6 == 2);
    const second = try loaderGuid(seed, &.{first});
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "build id and locale validation" {
    try std.testing.expect(validBuildId("B261028-155628-7BA80151"));
    try std.testing.expect(!validBuildId("../x"));
    try std.testing.expect(validLocale("pl-PL") and !validLocale("p") and !validLocale("a b"));
    var name: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\\USOSPREP.LOG", try rotationName(&name, 0));
    try std.testing.expectEqualStrings("\\USOSPREP.2.LOG", try rotationName(&name, 2));
}

test "CSMWrap ESP placement and MBR slot 3 match the Alpine route" {
    // 128 GiB disk: the Alpine formula (total - 133120 + 2047) / 2048 * 2048.
    const total: u64 = 268435456;
    const start = try csmwrapEspStart(total);
    try std.testing.expectEqual((total - csmwrap_tail_sectors + 2047) / 2048 * 2048, start);
    try std.testing.expect(start % 2048 == 0 and start + csmwrap_esp_sectors <= total);
    try std.testing.expectError(error.Unsupported, csmwrapEspStart(mbr_max_sectors + 1));
    try std.testing.expectError(error.Unsupported, csmwrapEspStart(1024 * 1024));
    var mbr: [512]u8 = @splat(0);
    try mbrEntry(mbr[446..462], true, 7, 2048, 204800);
    try mbrEntry(mbr[462..478], false, 7, 206848, start - 206848);
    std.mem.writeInt(u16, mbr[510..512], 0xaa55, .little);
    var copy = mbr;
    try addCsmwrapEntry(&copy, start);
    try std.testing.expectEqual(@as(u8, 0), copy[478]);
    try std.testing.expectEqual(@as(u8, 0xef), copy[482]);
    try std.testing.expectEqual(@as(u32, @intCast(start)), std.mem.readInt(u32, copy[486..490], .little));
    try std.testing.expectEqual(@as(u32, csmwrap_esp_sectors), std.mem.readInt(u32, copy[490..494], .little));
    try std.testing.expect(std.mem.eql(u8, copy[0..478], mbr[0..478]));
    // Windows overlapping the ESP, or slot 3 already used: refused.
    try std.testing.expectError(error.BootDiskIdentityMismatch, addCsmwrapEntry(&mbr, start - 1));
    try std.testing.expectError(error.BootDiskIdentityMismatch, addCsmwrapEntry(&copy, start));
}

test "display request follows the Alpine display policy" {
    try std.testing.expectEqualStrings("autoxauto", displayRequest(null).?);
    try std.testing.expectEqualStrings("1920x1080x32", displayRequest("<a/>\n<!-- USOS-DISPLAY=1920x1080x32 -->\n").?);
    try std.testing.expect(displayRequest("<!-- USOS-DISPLAY=keepx1024x768 -->") == null);
    try std.testing.expect(displayRequest("<!-- USOS-DISPLAY=1x1 -->") == null);
    try std.testing.expect(displayRequest("<!-- USOS-DISPLAY=autoxauto --><!-- USOS-DISPLAY=autoxauto -->") == null);
    try std.testing.expect(displayRequest("<HorizontalResolution>1024</HorizontalResolution>") == null);
    try std.testing.expectEqualStrings("autoxauto", displayRequest("<unattend/>").?);
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("autoxauto\r\nnative=2560x1440\r\n", try displayText(&buffer, "autoxauto", "2560x1440\r\n"));
    try std.testing.expectEqualStrings("autoxauto\r\n", try displayText(&buffer, "autoxauto", "0x10"));
    try std.testing.expectEqualStrings("autoxauto\r\n", try displayText(&buffer, "autoxauto", null));
}

test "the 64 MiB CSMWrap ESP is a valid FAT32 volume for the MiniOS writer" {
    const fat32 = @import("fat32.zig");
    const a = std.testing.allocator;
    const raw = try a.alloc(u8, (csmwrap_esp_sectors + 2048) * 512);
    defer a.free(raw);
    @memset(raw, 0);
    var memory: Memory = .{ .bytes = raw };
    const part: fat32.Partition = .{ .start_bytes = 2048 * 512, .size_bytes = csmwrap_esp_sectors * 512 };
    const g = try fat32.geometry(memory.disk(), part);
    try std.testing.expect(g.cluster_count >= 65525 and g.sectors_per_cluster == 1);
    var volume = try fat32.format(memory.disk(), part, .{ .serial = 0x12345678, .label = "CSMWRAP    ".* });
    _ = try volume.mkdir("EFI");
    _ = try volume.mkdir("EFI/BOOT");
    var out = try volume.createFile("EFI/BOOT/csmwrap.ini", 5);
    try out.write("a = b");
    try out.finish();
    try volume.flush();
    try std.testing.expectEqualStrings("FAT32   ", raw[2048 * 512 + 82 ..][0..8]);
}
