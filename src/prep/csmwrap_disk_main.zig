//! usosprep-csmwrap-disk IMAGE.raw ISO SUPPORT.cpio MODERN.cpio MBR440 NT60
//!     nvme|other [--answer XML] [--usosres EXE] [--seed 128HEX]
//! Host harness of the MiniOS Win10 x86 CSMWrap route: runs the same disk
//! writes as the UEFI client (csmwrap_write.zig, called by
//! uefi_main.runCsmwrapSetup) against an existing raw image file (sparse,
//! the size of the target disk), with MiniOS's own ISO reader, WIM
//! export+update writer and NTFS formatter. Step 5 (the CSMWrap FAT32 ESP)
//! needs the stick's CSMWrap files: here only its MBR slot is added (the
//! partition area stays zero). Validation: Windows' own chkdsk / bcdedit /
//! DISM on the image attached as a VHD (tools/tests/minios_csmwrap_vhd.ps1).
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const platform = @import("platform.zig");
const app = @import("app.zig");
const wim = @import("wim.zig");
const optical = @import("optical.zig");
const csm = @import("csmwrap_target.zig");
const pe10 = @import("pe10_inject.zig");
const wim_update = @import("wim_update.zig");
const writer = @import("csmwrap_write.zig");
const bcd_lowmem = @import("bcd_lowmem");
const fat32 = @import("fat32.zig");
const hw = @import("hw_target.zig");

const HostFile = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64 = 0,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (at > self.size or out.len > self.size - at) return error.Bounds;
        if ((self.file.readPositionalAll(self.io, out, at) catch return error.Io) != out.len) return error.Io;
    }
    fn write(ctx: *anyopaque, at: u64, input: []const u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.file.writePositionalAll(self.io, input, at) catch return error.Io;
    }
    fn flush(_: *anyopaque) platform.Error!void {}
    fn open(io: std.Io, path: []const u8, writable: bool) !HostFile {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = if (writable) .read_write else .read_only });
        return .{ .io = io, .file = f, .size = (try f.stat(io)).size };
    }
};
const Log = struct {
    fn write(_: *anyopaque, text: []const u8) void {
        std.debug.print("{s}", .{text});
    }
    fn clock(_: *anyopaque) u64 {
        return 0;
    }
};
fn streamSource(stream: *optical.Stream) @import("ntfs.zig").Source {
    return .{ .context = stream, .size = stream.node.size, .read_fn = optical.Stream.read };
}
fn find(volume: *optical.Volume, stream: *optical.Stream, path: []const u8) !void {
    stream.* = .{ .input = volume.input, .node = undefined };
    try volume.findInto(path, &stream.node);
    if (stream.node.directory) return error.IsoBootFileMissing;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const image_path = args.next() orelse return 2;
    const iso_path = args.next() orelse return 2;
    const support_path = args.next() orelse return 2;
    const helpers_path = args.next() orelse return 2;
    const mbr_path = args.next() orelse return 2;
    const nt60_path = args.next() orelse return 2;
    const bus = args.next() orelse return 2;
    var answer_path: ?[]const u8 = null;
    var usosres_path: ?[]const u8 = null;
    var csmwrap_dir: ?[]const u8 = null;
    var dump_dir: ?[]const u8 = null;
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    while (args.next()) |flag| {
        const value = args.next() orelse return 2;
        if (std.mem.eql(u8, flag, "--answer")) answer_path = value else if (std.mem.eql(u8, flag, "--usosres")) usosres_path = value else if (std.mem.eql(u8, flag, "--csmwrap")) csmwrap_dir = value else if (std.mem.eql(u8, flag, "--dump-adds")) dump_dir = value else if (std.mem.eql(u8, flag, "--seed")) {
            if (value.len != 128) return 2;
            _ = try std.fmt.hexToBytes(&seed, value);
        } else return 2;
    }
    if (!std.mem.endsWith(u8, image_path, ".raw") and !std.mem.endsWith(u8, image_path, ".vhd")) return 2;
    const nvme = std.mem.eql(u8, bus, "nvme");
    const cwd = std.Io.Dir.cwd();

    var tracker = platform.TrackedAllocator{ .backing = gpa, .limit = 256 * 1024 * 1024 };
    const allocator = tracker.allocator();
    const mbr_code = try cwd.readFileAlloc(io, mbr_path, gpa, .limited(4096));
    defer gpa.free(mbr_code);
    const nt60 = try cwd.readFileAlloc(io, nt60_path, gpa, .limited(16384));
    defer gpa.free(nt60);
    if (mbr_code.len != csm.mbr_code_bytes or nt60.len != csm.nt60_bytes) return 3;
    var support_file = try HostFile.open(io, support_path, false);
    defer support_file.file.close(io);
    var helpers_file = try HostFile.open(io, helpers_path, false);
    defer helpers_file.file.close(io);
    const support: wim_update.Source = .{ .context = &support_file, .size = support_file.size, .read_fn = HostFile.read };
    const helpers: wim_update.Source = .{ .context = &helpers_file, .size = helpers_file.size, .read_fn = HostFile.read };
    const answer: ?[]u8 = if (answer_path) |p| try cwd.readFileAlloc(io, p, gpa, .limited(1 << 20)) else null;
    defer if (answer) |a| gpa.free(a);

    var iso = try HostFile.open(io, iso_path, false);
    defer iso.file.close(io);
    const volume = try gpa.create(optical.Volume);
    defer gpa.destroy(volume);
    try optical.Volume.openInto(.{ .context = &iso, .size = iso.size, .read_fn = HostFile.read }, volume);
    const streams = try gpa.alloc(optical.Stream, 4);
    defer gpa.free(streams);
    try find(volume, &streams[0], "boot\\bcd");
    try find(volume, &streams[1], "boot\\boot.sdi");
    try find(volume, &streams[2], "sources\\boot.wim");
    try find(volume, &streams[3], "bootmgr");
    const wim_input: wim.Input = .{ .context = &streams[2], .size = streams[2].node.size, .read_fn = optical.Stream.read };
    var header: [208]u8 = undefined;
    try wim_input.read(0, &header);
    const boot_index = std.mem.readInt(u32, header[120..124], .little);
    if (boot_index == 0) return error.DonorHasNoBootImage;
    var donor = try wim.Archive.open(allocator, wim_input, boot_index);
    defer donor.deinit();

    const bcd = try gpa.alloc(u8, bcd_lowmem.max_hive);
    defer gpa.free(bcd);
    var bcd_len: usize = @intCast(streams[0].node.size);
    try optical.Stream.read(&streams[0], 0, bcd[0..bcd_len]);
    if (nvme) {
        const outcome = try bcd_lowmem.apply(bcd, &bcd_len, bcd_lowmem.truncatememory);
        if ((try bcd_lowmem.check(bcd[0..bcd_len], bcd_lowmem.truncatememory)) != true) return error.BcdSelfCheck;
        std.debug.print("[VISTA_CSMWRAP] [BCD_LOWMEM] truncatememory 0x100000000 {s} ({d} bytes)\n", .{ @tagName(outcome), bcd_len });
    }

    var image = try HostFile.open(io, image_path, true);
    defer image.file.close(io);
    if (image.size % 512 != 0) return 4;
    const total = image.size / 512;
    const l = try csm.Layout.compute(total);
    std.debug.print("[VISTA_CSMWRAP] disk_sectors={d} staging_start={d} staging_sectors={d} esp_start={d} x86_self=1\n", .{ total, l.staging_start, l.staging_sectors, l.esp_start });
    var signature: u32 = 0;
    {
        var i: usize = 0;
        while (i < 16) : (i += 4) {
            const v = std.mem.readInt(u32, seed[i..][0..4], .little);
            if (v != 0 and v != 0xffffffff) {
                signature = v;
                break;
            }
        }
        if (signature == 0) signature = 0x55534f53;
    }
    var target_ini_buf: [512]u8 = undefined;
    const target_ini = try csm.targetIni(&target_ini_buf, signature, l, nvme);
    const injection = try gpa.create(pe10.Injection);
    defer gpa.destroy(injection);
    injection.* = .{};
    try injection.build(.{ .support = support, .helpers = helpers, .source_ini = "USOSISO1\r\nhost-harness\r\n", .target_ini = target_ini, .answer = answer, .modern_nvme = nvme, .pe_nvme = nvme });
    // --dump-adds DIR: the add list as host files + DIR/update.txt in the
    // Alpine route's `wimlib-imagex update` format, nothing written to IMAGE.
    if (dump_dir) |dir| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        for (injection.list(), 0..) |add, i| {
            const bytes = try gpa.alloc(u8, @intCast(add.source.size));
            defer gpa.free(bytes);
            try add.source.read_fn(add.source.context, 0, bytes);
            var name: [1024]u8 = undefined;
            const host = try std.fmt.bufPrint(&name, "{s}/add{d:0>2}_{s}", .{ dir, i, std.fs.path.basename(add.path) });
            const out = try cwd.createFile(io, host, .{});
            try out.writePositionalAll(io, bytes, 0);
            out.close(io);
            var line: [2048]u8 = undefined;
            try list.appendSlice(gpa, try std.fmt.bufPrint(&line, "add \"{s}\" \"{s}\"\n", .{ host, add.path }));
        }
        var upath: [1024]u8 = undefined;
        const out = try cwd.createFile(io, try std.fmt.bufPrint(&upath, "{s}/update.txt", .{dir}), .{});
        try out.writePositionalAll(io, list.items, 0);
        out.close(io);
        std.debug.print("DUMP adds={d} boot_index={d}\n", .{ injection.list().len, boot_index });
        return 0;
    }
    const display = csm.displayDecision(answer, false);
    var display_buf: [128]u8 = undefined;
    var display_text: ?[]const u8 = null;
    const exe: ?[]u8 = if (usosres_path) |p| try cwd.readFileAlloc(io, p, gpa, .limited(4 << 20)) else null;
    defer if (exe) |e| gpa.free(e);
    if (exe != null) switch (display) {
        .request => |req| display_text = try csm.displayText(&display_buf, req, null),
        else => {},
    };
    var guid: [16]u8 = seed[32..48].*;
    guid[6] = (guid[6] & 0x0f) | 0x40;
    guid[8] = (guid[8] & 0x3f) | 0x80;
    const d: platform.Disk = .{ .context = &image, .sectors = total, .read_fn = HostFile.read, .write_fn = HostFile.write, .flush_fn = HostFile.flush };
    var stage: []const u8 = "start";
    const log: app.Logger = .{ .context = &image, .write_fn = Log.write, .clock_fn = Log.clock };
    writer.write(allocator, d, .{
        .mbr_code = mbr_code[0..csm.mbr_code_bytes],
        .nt60 = nt60[0..csm.nt60_bytes],
        .signature = signature,
        .layout = l,
        .bootmgr = streamSource(&streams[3]),
        .bcd = bcd[0..bcd_len],
        .sdi = streamSource(&streams[1]),
        .donor = &donor,
        .boot_index = boot_index,
        .injection = injection,
        .display_exe = if (display_text != null) exe else null,
        .display_text = display_text,
        .nvme = nvme,
        .timestamp = 0x01dd4a1b00000000,
        .windows_serial = std.mem.readInt(u64, seed[16..24], .little) | 1,
        .staging_serial = std.mem.readInt(u64, seed[24..32], .little) | 1,
        .wim_guid = guid,
    }, &stage, log) catch |err| {
        std.debug.print("USOSPREP HOST FAIL stage={s} {s} alloc_peak={d}\n", .{ stage, @errorName(err), tracker.peak });
        return 1;
    };
    // Step 5: the FAT ESP with the same fat32.zig as writeCsmwrapEsp (host
    // files from --csmwrap DIR = EFI/USOS/csmwrap of a built stick), else
    // only the ESP slot.
    if (csmwrap_dir) |dir| try writeEsp(io, gpa, d, l.esp_start, dir);
    var sector0: [512]u8 = undefined;
    try d.read(0, &sector0);
    _ = try csm.addEspEntry(&sector0, l.esp_start);
    try d.write(0, &sector0);
    try csm.verifyFinal(&sector0, l);
    var sig_hex: [8]u8 = undefined;
    std.debug.print("[VISTA_CSMWRAP] PREPARED PASS signature={s} windows_sectors={d} x86_self=1 alloc_peak={d}\n", .{ csm.signatureHex(&sig_hex, signature), l.windows_sectors, tracker.peak });
    return 0;
}

fn copyHost(io: std.Io, gpa: std.mem.Allocator, volume: *fat32.Volume, from: []const u8, to: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, from, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var out = try volume.createFile(to, bytes.len);
    try out.write(bytes);
    try out.finish();
}
fn writeEsp(io: std.Io, gpa: std.mem.Allocator, d: platform.Disk, esp_start: u64, dir: []const u8) !void {
    var zero: [65536]u8 = undefined;
    try writer.zeroSectors(d, esp_start, 2048, &zero);
    var volume = try fat32.format(d, .{ .start_bytes = esp_start * 512, .size_bytes = hw.csmwrap_esp_sectors * 512 }, .{ .serial = 0x1234abcd, .label = "CSMWRAP    ".* });
    for ([_][]const u8{ "EFI", "EFI/BOOT", "CSMWRAP", "CSMWRAP/patches", "CSMWRAP/licenses" }) |sub| _ = try volume.mkdir(sub);
    var path: [1024]u8 = undefined;
    try copyHost(io, gpa, &volume, try std.fmt.bufPrint(&path, "{s}/csmwrapx64.efi", .{dir}), "EFI/BOOT/BOOTX64.EFI");
    const ini = csm.csmwrapIni(false);
    var out = try volume.createFile("EFI/BOOT/csmwrap.ini", ini.len);
    try out.write(ini);
    try out.finish();
    for ([_][]const u8{ "LICENSE-CSMWrap-LGPL-2.1.txt", "COPYING-SeaBIOS-LGPLv3.txt", "COPYING-SeaBIOS-GPLv3.txt", "SOURCES.txt" }) |name| {
        var dst: [160]u8 = undefined;
        try copyHost(io, gpa, &volume, try std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, name }), try std.fmt.bufPrint(&dst, "CSMWRAP/{s}", .{name}));
    }
    try volume.flush();
    std.debug.print("CSMWRAP_ESP PASS start={d} (host: BOOTX64.EFI, csmwrap.ini, licences; source and patches not copied)\n", .{esp_start});
}
