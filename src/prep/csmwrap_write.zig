//! SPDX-License-Identifier: GPL-3.0-or-later
//! The disk writes of the MiniOS Win10 x86 CSMWrap route (port of the Alpine
//! step 610, tools/vista_csmwrap_target.sh steps 1 - 4 + the NT60 boot code),
//! shared by the UEFI client (uefi_main.runCsmwrapSetup) and the host
//! harness (csmwrap_disk_main.zig) that writes the same bytes into a raw
//! image file for validation with Windows' own tools. Every input is read
//! and checked by the caller before this runs; this only writes `disk`.
const std = @import("std");
const platform = @import("platform.zig");
const ntfs = @import("ntfs.zig");
const app = @import("app.zig");
const wim = @import("wim.zig");
const csm = @import("csmwrap_target.zig");
const pe10 = @import("pe10_inject.zig");
const W = std.unicode.utf8ToUtf16LeStringLiteral;

pub const MemorySource = struct {
    bytes: []const u8,
    pub fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *MemorySource = @ptrCast(@alignCast(ctx));
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    pub fn source(self: *MemorySource) ntfs.Source {
        return .{ .context = self, .size = self.bytes.len, .read_fn = read };
    }
};

pub const Inputs = struct {
    mbr_code: *const [csm.mbr_code_bytes]u8,
    nt60: *const [csm.nt60_bytes]u8,
    signature: u32,
    layout: csm.Layout,
    bootmgr: ntfs.Source,
    bcd: []const u8,
    sdi: ntfs.Source,
    donor: *wim.Archive,
    boot_index: u32,
    injection: *const pe10.Injection,
    display_exe: ?[]const u8 = null,
    display_text: ?[]const u8 = null,
    nvme: bool,
    /// NTFS time of every file written (FILETIME units).
    timestamp: u64,
    windows_serial: u64,
    staging_serial: u64,
    wim_guid: [16]u8,
};

fn sha256Of(source: ntfs.Source, buffer: []u8) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var at: u64 = 0;
    while (at < source.size) {
        const len: usize = @intCast(@min(buffer.len, source.size - at));
        try source.read_fn(source.context, at, buffer[0..len]);
        hash.update(buffer[0..len]);
        at += len;
    }
    return hash.finalResult();
}
/// cp + cmp: the file on the new NTFS must hash like its source.
fn copyChecked(fs: *ntfs.Ntfs, parent: u64, name: []const u16, source: ntfs.Source, timestamp: u64, buffer: []u8) !u64 {
    const number = try fs.writeFile(parent, name, source, .{ .timestamp = timestamp });
    const want = try sha256Of(source, buffer);
    if (!std.mem.eql(u8, &want, &(try fs.hashFile(number)))) return error.CopyReadbackMismatch;
    return number;
}
pub fn zeroSectors(disk: platform.Disk, first: u64, count: u64, buffer: []u8) !void {
    @memset(buffer, 0);
    var done: u64 = 0;
    while (done < count) {
        const n: u64 = @min(count - done, buffer.len / 512);
        try disk.write((first + done) * 512, buffer[0..@intCast(n * 512)]);
        done += n;
    }
}

/// Steps 1 - 4 and the NT60 boot code. `stage` follows the step for the
/// caller's failure report. The CSMWrap ESP (step 5) and the final read-back
/// (step 6) stay with the caller (they need the stick's files).
pub fn write(allocator: std.mem.Allocator, d: platform.Disk, in: Inputs, stage: *[]const u8, log: app.Logger) !void {
    const l = in.layout;
    const total = d.sectors;
    const zero = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(zero);

    // ---- 1. Partition table: erase both GPT copies, then the new MBR.
    stage.* = "partition table";
    try zeroSectors(d, 0, 2048, zero);
    try zeroSectors(d, total - 2048, 2048, zero);
    try d.flush();
    const mbr = csm.buildMbr(in.mbr_code, in.signature, l);
    try d.write(0, &mbr);
    try d.flush();
    var readback: [512]u8 = undefined;
    try d.read(0, &readback);
    if (!std.mem.eql(u8, &readback, &mbr)) return error.MbrReadbackMismatch;
    var sig_hex: [8]u8 = undefined;
    log.say("[VISTA_CSMWRAP] MBR PASS signature={s}\n", .{csm.signatureHex(&sig_hex, in.signature)});

    // ---- 2. NTFS: Windows (inactive), staging with the NT60 boot code.
    stage.* = "Windows partition";
    const fs = try allocator.create(ntfs.Ntfs);
    defer allocator.destroy(fs);
    try ntfs.Ntfs.initInto(d, .{ .start_bytes = l.windows_start * 512, .size_bytes = l.windows_sectors * 512 }, allocator, in.windows_serial, fs);
    fs.label = W(csm.windows_label);
    {
        defer fs.deinit();
        try fs.format();
        // 2b. USOSRES.EXE + DISPLAY.TXT into \USOS\NT6 (optional).
        if (in.display_exe) |exe| stage_display: {
            const usos_dir = fs.mkdir(5, W("USOS"), .{ .attributes = 0x10, .timestamp = in.timestamp }) catch |err| {
                log.say("[VISTA_CSMWRAP] DISPLAY staging failed ({s}); display unchanged\n", .{@errorName(err)});
                break :stage_display;
            };
            const nt6 = fs.mkdir(usos_dir, W("NT6"), .{ .attributes = 0x10, .timestamp = in.timestamp }) catch |err| {
                log.say("[VISTA_CSMWRAP] DISPLAY staging failed ({s}); display unchanged\n", .{@errorName(err)});
                break :stage_display;
            };
            var exe_src: MemorySource = .{ .bytes = exe };
            var txt_src: MemorySource = .{ .bytes = in.display_text.? };
            const exe_number = fs.writeFile(nt6, W("USOSRES.EXE"), exe_src.source(), .{ .timestamp = in.timestamp }) catch |err| {
                log.say("[VISTA_CSMWRAP] DISPLAY staging failed ({s}); display unchanged\n", .{@errorName(err)});
                break :stage_display;
            };
            _ = fs.writeFile(nt6, W("DISPLAY.TXT"), txt_src.source(), .{ .timestamp = in.timestamp }) catch |err| {
                log.say("[VISTA_CSMWRAP] DISPLAY staging failed ({s}); display unchanged\n", .{@errorName(err)});
                break :stage_display;
            };
            var want: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(exe, &want, .{});
            if (!std.mem.eql(u8, &want, &(try fs.hashFile(exe_number)))) return error.DisplayReadbackMismatch;
            const text = in.display_text.?;
            log.say("[VISTA_CSMWRAP] DISPLAY request={s} apply=first-sign-in vm=deferred\n", .{std.mem.trimEnd(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\r') orelse text.len], "\r\n")});
        }
        try fs.finish();
    }
    log.say("[VISTA_CSMWRAP] Windows partition PASS start={d} sectors={d}\n", .{ l.windows_start, l.windows_sectors });

    // ---- 3. + 4. Staging: bootmgr, boot\bcd, boot\boot.sdi, sources\boot.wim.
    stage.* = "staging partition";
    try ntfs.Ntfs.initInto(d, .{ .start_bytes = l.staging_start * 512, .size_bytes = l.staging_sectors * 512 }, allocator, in.staging_serial, fs);
    fs.label = W(csm.staging_label);
    {
        defer fs.deinit();
        try fs.format();
        const buffer = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(buffer);
        _ = try copyChecked(fs, 5, W("bootmgr"), in.bootmgr, in.timestamp, buffer);
        const boot_dir = try fs.mkdir(5, W("boot"), .{ .attributes = 0x10, .timestamp = in.timestamp });
        var bcd_src: MemorySource = .{ .bytes = in.bcd };
        _ = try copyChecked(fs, boot_dir, W("bcd"), bcd_src.source(), in.timestamp, buffer);
        _ = try copyChecked(fs, boot_dir, W("boot.sdi"), in.sdi, in.timestamp, buffer);
        log.say("[VISTA_CSMWRAP] PE10 boot files PASS boot_index={d}\n", .{in.boot_index});
        const sources = try fs.mkdir(5, W("sources"), .{ .attributes = 0x10, .timestamp = in.timestamp });
        stage.* = "PE10 image";
        _ = try pe10.writeStagingBootWim(allocator, fs, sources, in.donor, in.injection, .{ .guid = in.wim_guid, .timestamp = in.timestamp });
        if (in.nvme) log.say("[VISTA_CSMWRAP] PE10 NVMe: stornvme service runs usosnvme PASS\n", .{});
        log.say("[VISTA_CSMWRAP] PE10 image PASS files={d}\n", .{in.injection.list().len});
        try fs.finish();
    }
    // NT60 boot code over the formatter's boot code (BPB kept), + backup.
    stage.* = "NT60 boot code";
    var boot: [csm.nt60_bytes]u8 = undefined;
    try d.read(l.staging_start * 512, &boot);
    csm.applyNt60(&boot, in.nt60);
    try d.write(l.staging_start * 512, &boot);
    try d.write((l.staging_start + l.staging_sectors - 1) * 512, boot[0..512]);
    try d.flush();
    var boot_check: [csm.nt60_bytes]u8 = undefined;
    try d.read(l.staging_start * 512, &boot_check);
    if (!std.mem.eql(u8, &boot, &boot_check)) return error.Nt60ReadbackMismatch;
    log.say("[VISTA_CSMWRAP] NT60 NTFS boot code PASS\n", .{});
}
