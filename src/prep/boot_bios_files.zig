//! Experimental BIOS boot provisioning; the PBR loads a pinned BOOTMGR copy
//! from the MBR gap (pinBootmgr), independent of the NTFS file's placement.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
const parts = @import("partitions.zig");
const nt = @import("ntfs_ro");
const writer = @import("ntfs.zig");
const source = @import("boot_source.zig");
const bcd = @import("bcd.zig");
const boot = @import("boot_files.zig");
const app = @import("app.zig");
const u = std.unicode.utf8ToUtf16LeStringLiteral;
pub const OwnBootCode = struct { mbr: *const [512]u8, pbr: *const [512]u8 };
pub const Options = struct {
    loader_guid: [16]u8,
    timestamp: u64,
    locale: []const u16 = u("en-US"),
    description: []const u16 = u("Windows"),
    gates: boot.Gates = .{},
};
pub const Stats = struct {
    files: u32 = 0,
    bytes: u64 = 0,
    main_sha256: [32]u8,
    bcd_sha256: [32]u8,
    bootmgr_lba: u64 = 0,
    bootmgr_sectors: u16 = 0,
};
/// tools/minios/bootcode/pbr.S accepts at most 960 sectors (Windows 10 22H2
/// x86 BOOTMGR: 413738 bytes = 809 sectors; Win7: 750).
pub const max_bootmgr_sectors: u64 = 960;
pub const max_bootmgr_bytes: u64 = max_bootmgr_sectors * 512;
fn get(comptime T: type, data: []const u8, at: usize) T {
    return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, data: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, data[at..][0..@sizeOf(T)], value, .little);
}
pub fn validateBootCode(code: OwnBootCode) !void {
    if (!std.mem.eql(u8, code.mbr[432..440], "USOSMB1\x00") or
        !std.mem.eql(u8, code.pbr[492..500], "USOSPB1\x00") or
        get(u16, code.mbr, 510) != 0xaa55 or get(u16, code.pbr, 510) != 0xaa55 or
        code.mbr[0] == 0 or code.pbr[84] == 0 or get(u64, code.pbr, 480) != 0 or get(u16, code.pbr, 488) != 0)
        return error.InvalidOwnBootCode;
}
fn partition(raw: []const u8, active: u8, expected: parts.Partition) !void {
    if (raw[0] != active or raw[4] != 7 or get(u32, raw, 8) != expected.start_bytes / 512 or get(u32, raw, 12) != expected.size_bytes / 512)
        return error.BootDiskIdentityMismatch;
}
fn ntfsBoot(disk: p.Disk, part: parts.Partition, serial: ?u64, out: *[512]u8) !u64 {
    try disk.read(part.start_bytes, out);
    const actual = get(u64, out, 72);
    if (!std.mem.eql(u8, out[3..11], "NTFS    ") or get(u16, out, 11) != 512 or out[13] != 8 or
        get(u16, out, 510) != 0xaa55 or get(u32, out, 28) != part.start_bytes / 512 or
        get(u64, out, 40) != part.size_bytes / 512 - 1 or actual == 0 or (serial != null and serial.? != actual)) return error.BootDiskIdentityMismatch;
    var backup: [512]u8 = undefined;
    try disk.read(part.start_bytes + part.size_bytes - 512, &backup);
    if (!std.mem.eql(u8, out, &backup)) return error.BootDiskIdentityMismatch;
    return actual;
}
/// Before any writer is opened, bind both partitions and preserve the actual
/// validated system NTFS serial. This does not trust caller-supplied geometry.
pub fn validateDisk(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids) !u64 {
    try ids.validate();
    if (prepared.mode != .bios or disk.sector_bytes != 512 or !std.meta.eql(prepared, try wl.plan(disk, .bios))) return error.BootDiskIdentityMismatch;
    var block: [512]u8 = undefined;
    try disk.read(0, &block);
    if (get(u32, &block, 440) != ids.base.mbr_signature or get(u16, &block, 510) != 0xaa55 or
        !std.mem.allEqual(u8, block[478..510], 0)) return error.BootDiskIdentityMismatch;
    try partition(block[446..462], 0x80, prepared.system);
    try partition(block[462..478], 0, prepared.windows);
    _ = try ntfsBoot(disk, prepared.windows, ids.base.ntfs_serial, &block);
    const serial = try ntfsBoot(disk, prepared.system, null, &block);
    if (serial == ids.base.ntfs_serial) return error.BootDiskIdentityMismatch;
    return serial;
}
const DiskReader = struct {
    disk: p.Disk,
    original: ?p.Error = null,
    fn read(ctx: *anyopaque, at: u64, out: []u8) error{ Io, OutOfBounds }!void {
        const self: *DiskReader = @ptrCast(@alignCast(ctx));
        self.disk.read(at, out) catch |err| {
            self.original = err;
            return if (err == error.Bounds) error.OutOfBounds else error.Io;
        };
    }
};
fn emptyDirectory(fs: *const nt.FileSystem, reader: *DiskReader, components: []const []const u16, page: []nt.DirectoryItem, extend: bool) !void {
    const names = [_][]const u16{ u("$MFT"), u("$MFTMirr"), u("$LogFile"), u("$Volume"), u("$AttrDef"), u("."), u("$Bitmap"), u("$Boot"), u("$BadClus"), u("$Secure"), u("$UpCase"), u("$Extend") };
    const ext = [_][]const u16{ u("$Quota"), u("$ObjId"), u("$Reparse") };
    const expected: []const []const u16 = if (extend) &ext else &names;
    const result = try nt.listDirectoryPage(fs.*, .{ .context = reader, .read_fn = DiskReader.read }, components, 0, page);
    if (result.has_more or result.count != expected.len) return error.BootSystemNotEmpty;
    var seen: u16 = 0;
    for (page[0..result.count]) |item| {
        const name = item.name[0..item.name_len];
        var found = false;
        for (expected, 0..) |wanted, i| if (std.mem.eql(u16, name, wanted)) {
            const bit: u16 = @as(u16, 1) << @intCast(i);
            if (seen & bit != 0 or item.file_reference & 0xffffffffffff != (if (extend) i + 24 else i) or
                item.attributes & 0x400 != 0 or item.isDirectory() != (!extend and (i == 5 or i == 11))) return error.BootSystemNotEmpty;
            seen |= bit;
            found = true;
            break;
        };
        if (!found) return error.BootSystemNotEmpty;
    }
}
pub fn requireEmptySystem(disk: p.Disk, system: parts.Partition, a: std.mem.Allocator) !void {
    var reader: DiskReader = .{ .disk = disk };
    const fs = try a.create(nt.FileSystem);
    defer a.destroy(fs);
    fs.* = try nt.mountAllocated(.{ .context = &reader, .read_fn = DiskReader.read }, .{ .start_bytes = system.start_bytes, .size_bytes = system.size_bytes }, a);
    defer fs.deinit();
    const page = try a.alloc(nt.DirectoryItem, 16);
    defer a.free(page);
    try emptyDirectory(fs, &reader, &.{}, page, false);
    try emptyDirectory(fs, &reader, &.{u("$Extend")}, page, true);
}
const Directory = struct { path: []const u8, record: u64 };
fn parentOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}
fn leafOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}
fn parentRecord(list: []const Directory, path: []const u8) !u64 {
    if (path.len == 0) return 5;
    for (list) |item| if (source.samePath(item.path, path)) return item.record;
    return error.BootParentMissing;
}
const CopyInput = struct {
    context: *source.Context,
    cursor: u64 = 0,
    hash: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    original: ?anyerror = null,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *CopyInput = @ptrCast(@alignCast(ctx));
        if (at != self.cursor) return error.Unsupported;
        self.context.large.readAt(self.context.fs, .{ .context = self.context, .read_fn = source.Context.read }, at, out) catch |err| {
            self.original = err;
            return error.Io;
        };
        self.hash.update(out);
        self.cursor += out.len;
    }
};
fn copy(ctx: *source.Context, target: *writer.Ntfs, parent: u64, item: source.Item, timestamp: u64) !void {
    ctx.last_error = null;
    try ctx.open(item.source);
    defer ctx.large.deinit();
    if (ctx.large.size() != item.size) return error.BootSourceSizeChanged;
    var input: CopyInput = .{ .context = ctx };
    const name = try std.unicode.utf8ToUtf16LeAlloc(ctx.allocator, leafOf(item.target));
    defer ctx.allocator.free(name);
    _ = target.writeFile(parent, name, .{ .context = &input, .size = item.size, .read_fn = CopyInput.read }, .{ .timestamp = timestamp }) catch |err| {
        const original: anyerror = if (ctx.last_error) |raw| raw else input.original orelse err;
        ctx.log.say("BOOT_COPY_ERROR path={s} original={s} mapped={s}\n", .{ item.target, @errorName(original), @errorName(err) });
        return err;
    };
    const actual = input.hash.finalResult();
    if (input.cursor != item.size or !std.mem.eql(u8, &actual, &item.sha256)) return error.BootSourceHashChanged;
    ctx.log.say("BOOT_FILE path={s} bytes={d} sha256={s}\n", .{ item.target, item.size, std.fmt.bytesToHex(actual, .lower) });
}
const Memory = struct {
    bytes: []const u8,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
pub fn bootmgrRun(disk: p.Disk, system: parts.Partition, size: u64, expected: [32]u8, a: std.mem.Allocator, scratch: []u8) !struct { lba: u64, sectors: u16 } {
    if (size < 512 or size > max_bootmgr_bytes or scratch.len < 512) return error.BootManagerTooLarge;
    var reader: DiskReader = .{ .disk = disk };
    const fs = try a.create(nt.FileSystem);
    defer a.destroy(fs);
    fs.* = try nt.mountAllocated(.{ .context = &reader, .read_fn = DiskReader.read }, .{ .start_bytes = system.start_bytes, .size_bytes = system.size_bytes }, a);
    defer fs.deinit();
    const file = try a.create(nt.LargeFile);
    defer a.destroy(file);
    nt.openLargeFile(fs, .{ .context = &reader, .read_fn = DiskReader.read }, &.{u("bootmgr")}, a, file) catch |err| {
        if (err == error.UnsupportedFileData) return error.BootManagerUnsupportedData;
        return err;
    };
    defer file.deinit();
    if (file.size() != size or file.resident.len != 0 or file.runCount() != 1) return error.BootManagerNotContiguous;
    const run = file.runs.items[0];
    const count = (size + 511) / 512;
    if (run.sparse or run.vcn != 0 or run.lcn < 0 or run.clusters < (size + fs.cluster_bytes - 1) / fs.cluster_bytes) return error.BootManagerNotContiguous;
    const start = std.math.mul(u64, @intCast(run.lcn), fs.cluster_bytes) catch return error.BootManagerRunBounds;
    const bytes = count * 512;
    if (start < 8192 or start >= system.size_bytes or bytes > system.size_bytes - start or count > max_bootmgr_sectors) return error.BootManagerRunBounds;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var at: u64 = 0;
    while (at < size) {
        const n: usize = @intCast(@min(scratch.len, size - at));
        try file.readAt(fs, .{ .context = &reader, .read_fn = DiskReader.read }, at, scratch[0..n]);
        hash.update(scratch[0..n]);
        at += n;
    }
    const actual = hash.finalResult();
    if (!std.mem.eql(u8, &actual, &expected)) return error.BootManagerReadbackHashMismatch;
    return .{ .lba = (system.start_bytes + start) / 512, .sectors = @intCast(count) };
}
/// The PBR's BOOTMGR copy: a pinned image in the MBR gap (sectors 1..2047,
/// before the 1 MiB system partition), outside every file system. Windows
/// (servicing, defrag/optimise, chkdsk) may move or rewrite \bootmgr on the
/// system partition; the PBR keeps loading this verified copy, which no file
/// system owns. BOOTMGR finds BCD through its own NTFS driver from the BPB at
/// 0x7c00 (system partition), so where its own bytes came from does not
/// matter. LBA 1024 + 960 sectors ends at 1983 < 2048.
pub const pinned_bootmgr_lba: u64 = 1024;
pub fn pinBootmgr(disk: p.Disk, system: parts.Partition, run_lba: u64, sectors: u16, size: u64, expected: [32]u8, a: std.mem.Allocator) !u64 {
    if (disk.sector_bytes != 512 or sectors == 0 or sectors > max_bootmgr_sectors or size > @as(u64, sectors) * 512 or size + 511 < @as(u64, sectors) * 512) return error.BootManagerPinBounds;
    if (system.start_bytes / 512 < pinned_bootmgr_lba + max_bootmgr_sectors) return error.BootManagerPinBounds;
    const bytes = try a.alloc(u8, @as(usize, sectors) * 512);
    defer a.free(bytes);
    try disk.read(run_lba * 512, bytes);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..@intCast(size)], &actual, .{});
    if (!std.mem.eql(u8, &actual, &expected)) return error.BootManagerReadbackHashMismatch;
    try disk.write(pinned_bootmgr_lba * 512, bytes);
    try disk.flush();
    const check = try a.alloc(u8, bytes.len);
    defer a.free(check);
    try disk.read(pinned_bootmgr_lba * 512, check);
    if (!std.mem.eql(u8, check, bytes)) return error.BootManagerPinReadbackMismatch;
    return pinned_bootmgr_lba;
}
/// The NTFS \bootmgr is checked (one verified run, hash), then pinned into
/// the MBR gap (pinBootmgr); the PBR loads the pinned copy, so a later move
/// or update of the file on the system partition does not break the boot.
pub fn provisionBios(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids, tracker: *p.TrackedAllocator, options: Options, code: OwnBootCode, log: app.Logger) !Stats {
    // Hardware flow (USOSPREP_HW_V1): this run applied the disk itself; the
    // host bcdboot comparison is not rerun there (as provisionUefi).
    if (!options.gates.layout_apply or !(options.gates.bcd_reference or options.gates.hardware_flow)) return error.PrerequisiteGateMissing;
    try validateBootCode(code);
    const guid = try boot.formatGuid(options.loader_guid);
    const a = tracker.allocator();
    const system_serial = try validateDisk(disk, prepared, ids);
    try requireEmptySystem(disk, prepared.system, a);
    const fs = try a.create(nt.FileSystem);
    defer a.destroy(fs);
    const large = try a.create(nt.LargeFile);
    defer a.destroy(large);
    const buffer = try a.alloc(u8, 65536);
    defer a.free(buffer);
    const page = try a.alloc(nt.DirectoryItem, 32);
    defer a.free(page);
    var ctx: source.Context = .{ .disk = disk, .allocator = a, .fs = fs, .large = large, .buffer = buffer, .page = page, .log = log };
    defer ctx.deinit();
    fs.* = try nt.mountAllocated(.{ .context = &ctx, .read_fn = source.Context.read }, .{ .start_bytes = prepared.windows.start_bytes, .size_bytes = prepared.windows.size_bytes }, a);
    defer fs.deinit();
    ctx.pe(u("Windows\\System32\\winload.exe"), .ia32) catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/System32/winload.exe original={s}\n", .{@errorName(err)});
        return err;
    };
    ctx.collect(u("Windows\\Boot\\PCAT"), "Boot") catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/Boot/PCAT original={s}\n", .{@errorName(err)});
        return err;
    };
    const before_fonts = ctx.items.items.len;
    ctx.collect(u("Windows\\Boot\\Fonts"), "Boot/Fonts") catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/Boot/Fonts original={s}\n", .{@errorName(err)});
        return err;
    };
    var fonts: usize = 0;
    for (ctx.items.items[before_fonts..]) |item| if (!item.directory) {
        fonts += 1;
    };
    if (fonts == 0) return error.MissingBootFonts;
    const before_resources = ctx.items.items.len;
    ctx.collect(u("Windows\\Boot\\Resources"), "Boot/Resources") catch |err| {
        switch (err) {
            error.OutOfMemory, error.BootInventoryBudget, error.BootPathBudget, error.BootDirectoryLoop, error.BootTargetCollision => return err,
            else => {},
        }
        ctx.rollback(before_resources);
        log.say("BOOT_OPTIONAL_SKIPPED source=Windows/Boot/Resources original={s}\n", .{@errorName(err)});
    };
    var manager: ?usize = null;
    var total: u64 = 0;
    for (ctx.items.items, 0..) |item, i| {
        if (source.samePath(item.target, "Boot/BCD")) return error.BootTargetCollision;
        if (!item.directory) total = std.math.add(u64, total, item.size + 8192) catch return error.NoSpace;
        if (source.samePath(item.target, "Boot/bootmgr")) manager = i;
    }
    const index = manager orelse return error.MissingBootManager;
    if (ctx.items.items[index].directory or ctx.items.items[index].size < 512 or ctx.items.items[index].size > max_bootmgr_bytes) return error.BootManagerTooLarge;
    const root_name = try a.dupe(u8, "bootmgr");
    a.free(ctx.items.items[index].target);
    ctx.items.items[index].target = root_name;
    const loader = ctx.items.items[index];
    const store = try bcd.create(a, .{ .mode = .bios, .system = .{ .mbr = .{ .signature = ids.base.mbr_signature, .offset = prepared.system.start_bytes } }, .windows = .{ .mbr = .{ .signature = ids.base.mbr_signature, .offset = prepared.windows.start_bytes } }, .loader_id = &guid, .locale = options.locale, .description = options.description, .timestamp = options.timestamp });
    defer a.free(store);
    if (total + store.len + 12 * wl.mib >= prepared.system.size_bytes) return error.NoSpace;
    log.say("BOOT_PREFLIGHT BIOS PASS items={d} bootmgr_bytes={d} max={d} fresh_system_serial={x}; fixed-run experimental loader\n", .{ ctx.items.items.len, loader.size, max_bootmgr_bytes, system_serial });
    const target = try a.create(writer.Ntfs);
    defer a.destroy(target);
    try writer.Ntfs.initInto(disk, prepared.system, a, system_serial, target);
    defer target.deinit();
    try target.format();
    try copy(&ctx, target, 5, loader, options.timestamp);
    var directories: std.ArrayList(Directory) = .empty;
    defer directories.deinit(a);
    var stats: Stats = .{ .files = 1, .bytes = loader.size, .main_sha256 = loader.sha256, .bcd_sha256 = undefined };
    for (ctx.items.items, 0..) |item, i| {
        if (i == index) continue;
        const parent = try parentRecord(directories.items, parentOf(item.target));
        if (item.directory) {
            const name = try std.unicode.utf8ToUtf16LeAlloc(a, leafOf(item.target));
            defer a.free(name);
            const record = try target.mkdir(parent, name, .{ .timestamp = options.timestamp });
            try directories.append(a, .{ .path = item.target, .record = record });
        } else {
            try copy(&ctx, target, parent, item, options.timestamp);
            stats.files += 1;
            stats.bytes += item.size;
        }
    }
    var memory: Memory = .{ .bytes = store };
    _ = try target.writeFile(try parentRecord(directories.items, "Boot"), u("BCD"), .{ .context = &memory, .size = store.len, .read_fn = Memory.read }, .{ .timestamp = options.timestamp });
    stats.files += 1;
    stats.bytes += store.len;
    std.crypto.hash.sha2.Sha256.hash(store, &stats.bcd_sha256, .{});
    try target.finish();
    const run = try bootmgrRun(disk, prepared.system, loader.size, loader.sha256, a, buffer);
    const pinned = try pinBootmgr(disk, prepared.system, run.lba, run.sectors, loader.size, loader.sha256, a);
    log.say("BOOT_BIOS_PIN bootmgr file_lba={d} pinned_lba={d} sectors={d}; PBR loads the pinned copy (MBR gap)\n", .{ run.lba, pinned, run.sectors });
    stats.bootmgr_lba = pinned;
    stats.bootmgr_sectors = run.sectors;
    // Publish executable boot sectors last, after filesystem completion and
    // read-only BOOTMGR run resolution plus independent read-back hashing.
    var mbr: [512]u8 = undefined;
    try disk.read(0, &mbr);
    var pbr: [512]u8 = undefined;
    _ = try ntfsBoot(disk, prepared.system, system_serial, &pbr);
    @memcpy(mbr[0..440], code.mbr[0..440]);
    @memcpy(pbr[84..510], code.pbr[84..510]);
    put(u64, &pbr, 480, pinned);
    put(u16, &pbr, 488, run.sectors);
    try disk.write(prepared.system.start_bytes + prepared.system.size_bytes - 512, &pbr);
    try disk.write(prepared.system.start_bytes, &pbr);
    try disk.write(0, &mbr);
    try disk.flush();
    log.say("BOOT_BIOS PASS files={d} bytes={d} bootmgr_lba={d} sectors={d} bcd_sha256={s}; pinned copy in the MBR gap\n", .{ stats.files, stats.bytes, pinned, run.sectors, std.fmt.bytesToHex(stats.bcd_sha256, .lower) });
    return stats;
}
