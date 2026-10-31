//! UEFI boot provisioning from the applied, read-only Windows NTFS volume.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
const nt = @import("ntfs_ro");
const fat = @import("fat32.zig");
const bcd = @import("bcd.zig");
const app = @import("app.zig");
const u = std.unicode.utf8ToUtf16LeStringLiteral;
pub const Arch = @import("boot_source.zig").Arch;
/// hardware_flow: the in-process hardware path (uefi_main.zig, USOSPREP_HW_V1)
/// provisions right after its own successful apply of the same disk; the
/// QEMU-only host bcdboot comparison is not repeated there (logged as such).
pub const Gates = struct { layout_apply: bool = false, bcd_reference: bool = false, diagnostic_deferred: bool = false, hardware_flow: bool = false };
pub const Options = struct {
    arch: Arch,
    loader_guid: [16]u8,
    timestamp: u64,
    locale: []const u16 = u("en-US"),
    description: []const u16 = u("Windows"),
    gates: Gates = .{},
};
pub const Stats = struct { files: u32 = 0, bytes: u64 = 0, main_sha256: [32]u8, bcd_sha256: [32]u8 };
fn get(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn put(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
pub fn formatGuid(raw: [16]u8) ![38]u8 {
    if (raw[7] >> 4 != 4 or raw[8] >> 6 != 2) return error.InvalidLoaderGuid;
    var text: [38]u8 = undefined;
    _ = try std.fmt.bufPrint(&text, "{{{x:0>8}-{x:0>4}-{x:0>4}-{s}-{s}}}", .{ get(u32, &raw, 0), get(u16, &raw, 4), get(u16, &raw, 6), std.fmt.bytesToHex(raw[8..10], .lower), std.fmt.bytesToHex(raw[10..16], .lower) });
    return text;
}
fn header(bytes: []u8, lba: u64, backup: u64, table: u64, disk: p.Disk, ids: wl.Ids) !u32 {
    if (!std.mem.eql(u8, bytes[0..8], "EFI PART") or get(u32, bytes, 8) != 0x10000 or get(u32, bytes, 12) != 92 or get(u32, bytes, 20) != 0 or
        get(u64, bytes, 24) != lba or get(u64, bytes, 32) != backup or get(u64, bytes, 40) != 34 or get(u64, bytes, 48) != disk.sectors - 34 or
        !std.mem.eql(u8, bytes[56..72], &ids.base.disk_guid) or get(u64, bytes, 72) != table or get(u32, bytes, 80) != 128 or get(u32, bytes, 84) != 128) return error.BootDiskIdentityMismatch;
    const crc = get(u32, bytes, 16);
    put(u32, bytes, 16, 0);
    const actual = std.hash.Crc32.hash(bytes[0..92]);
    put(u32, bytes, 16, crc);
    if (crc != actual) return error.BootDiskIdentityMismatch;
    return get(u32, bytes, 88);
}
fn entry(raw: []const u8, kind: [16]u8, id: [16]u8, part: @import("partitions.zig").Partition) !void {
    if (!std.mem.eql(u8, raw[0..16], &kind) or !std.mem.eql(u8, raw[16..32], &id) or get(u64, raw, 32) != part.start_bytes / 512 or
        get(u64, raw, 40) != (part.start_bytes + part.size_bytes) / 512 - 1 or get(u64, raw, 48) != 0) return error.BootDiskIdentityMismatch;
}
/// Validate the actual primary and backup GPT, not just caller-supplied layout.
pub fn validateDisk(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids, a: std.mem.Allocator) !void {
    try ids.validate();
    if (prepared.mode != .uefi or disk.sector_bytes != 512 or !std.meta.eql(prepared, try wl.plan(disk, .uefi))) return error.BootDiskIdentityMismatch;
    const sector = try a.alloc(u8, 512);
    defer a.free(sector);
    const table = try a.alloc(u8, 16384);
    defer a.free(table);
    try disk.read(0, sector);
    if (get(u16, sector, 510) != 0xaa55 or sector[446] != 0 or sector[450] != 0xee or get(u32, sector, 454) != 1 or get(u32, sector, 458) != @min(disk.sectors - 1, std.math.maxInt(u32)) or sector[466] != 0 or sector[482] != 0 or sector[498] != 0) return error.BootDiskIdentityMismatch;
    try disk.read(512, sector);
    const crc = try header(sector, 1, disk.sectors - 1, 2, disk, ids);
    try disk.read(1024, table);
    if (std.hash.Crc32.hash(table) != crc) return error.BootDiskIdentityMismatch;
    try entry(table[0..128], wl.esp_type, ids.esp, prepared.esp.?);
    try entry(table[128..256], wl.msr_type, ids.msr, prepared.msr.?);
    try entry(table[256..384], wl.ntfs_type, ids.base.partition_guid, prepared.windows);
    if (!std.mem.allEqual(u8, table[384..], 0)) return error.BootDiskIdentityMismatch;
    const backup_table = disk.sectors - 33;
    try disk.read((disk.sectors - 1) * 512, sector);
    if (try header(sector, disk.sectors - 1, 1, backup_table, disk, ids) != crc) return error.BootDiskIdentityMismatch;
    for (0..32) |i| {
        try disk.read((backup_table + i) * 512, sector);
        if (!std.mem.eql(u8, sector, table[i * 512 ..][0..512])) return error.BootDiskIdentityMismatch;
    }
    try disk.read(prepared.windows.start_bytes, sector);
    if (!std.mem.eql(u8, sector[3..11], "NTFS    ") or get(u16, sector, 11) != 512 or get(u64, sector, 72) != ids.base.ntfs_serial) return error.BootDiskIdentityMismatch;
}
fn freshEsp(volume: *fat.Volume, scratch: []u8) !void {
    if (volume.next_cluster != 3 or volume.free_clusters != volume.g.cluster_count - 1) return error.BootEspNotEmpty;
    const start = volume.partition.start_bytes + @as(u64, volume.g.first_data_sector) * volume.g.sector_bytes;
    const size = volume.g.clusterBytes();
    var offset: u64 = 0;
    var labels: usize = 0;
    var ended = false;
    while (offset < size) {
        const count: usize = @intCast(@min(scratch.len, size - offset));
        try volume.disk.read(start + offset, scratch[0..count]);
        var at: usize = 0;
        while (at < count) : (at += 32) {
            const raw = scratch[at..][0..32];
            if (raw[0] == 0) {
                ended = true;
                if (!std.mem.allEqual(u8, raw, 0)) return error.BootEspNotEmpty;
                continue;
            }
            if (ended or raw[11] != 8 or labels != 0) return error.BootEspNotEmpty;
            labels += 1;
        }
        offset += count;
    }
    if (labels != 1) return error.BootEspNotEmpty;
}
const Context = @import("boot_source.zig").Context;
const Item = @import("boot_source.zig").Item;
const samePath = @import("boot_source.zig").samePath;
fn copy(self: *Context, volume: *fat.Volume, item: Item, target: []const u8) !void {
    try self.open(item.source);
    defer self.large.deinit();
    if (self.large.size() != item.size) return error.BootSourceSizeChanged;
    var output = try volume.createFile(target, item.size);
    var at: u64 = 0;
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    while (at < item.size) {
        const n: usize = @intCast(@min(self.buffer.len, item.size - at));
        try self.large.readAt(self.fs, .{ .context = self, .read_fn = Context.read }, at, self.buffer[0..n]);
        sha.update(self.buffer[0..n]);
        try output.write(self.buffer[0..n]);
        at += n;
    }
    const actual = sha.finalResult();
    if (!std.mem.eql(u8, &actual, &item.sha256)) {
        self.log.say("BOOT_SOURCE_HASH_CHANGED path={s} expected={s} actual={s}\n", .{ target, std.fmt.bytesToHex(item.sha256, .lower), std.fmt.bytesToHex(actual, .lower) });
        return error.BootSourceHashChanged;
    }
    try output.finish();
    self.log.say("BOOT_FILE path={s} bytes={d} sha256={s}\n", .{ target, item.size, std.fmt.bytesToHex(actual, .lower) });
}

/// This is deliberately unavailable before both preceding external gates pass.
/// It never discovers a disk, opens the Windows NTFS writer or copies vendor
/// payloads from the host. All source bytes come from the applied Windows.
pub fn provisionUefi(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids, tracker: *p.TrackedAllocator, options: Options, log: app.Logger) !Stats {
    if (!options.gates.layout_apply or !(options.gates.bcd_reference or options.gates.hardware_flow)) return error.PrerequisiteGateMissing;
    try validateDisk(disk, prepared, ids, tracker.allocator());
    return provisionValidated(disk,prepared,ids,tracker,options,log);
}

/// Dedicated QEMU reference path. The input must be an already bounded
/// writable overlay over the separately pinned reference VHDX. Only its ESP
/// may be formatted or written; the Windows NTFS remains read-only.
pub fn provisionReference(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids, tracker: *p.TrackedAllocator, options: Options, fat_serial: u32, log: app.Logger) !Stats {
    if (!options.gates.layout_apply or !options.gates.diagnostic_deferred) return error.PrerequisiteGateMissing;
    _=try formatGuid(options.loader_guid);
    const diag=@import("diagnostic_boot_disk.zig");
    if (prepared.mode!=.uefi or prepared.sector_bytes!=512 or prepared.disk_bytes!=32*1024*1024*1024 or
        prepared.esp==null or prepared.msr==null or
        prepared.esp.?.start_bytes!=diag.esp.start_bytes or prepared.esp.?.size_bytes!=diag.esp.size_bytes or
        prepared.windows.start_bytes!=diag.windows.start_bytes or prepared.windows.size_bytes!=diag.windows.size_bytes or
        prepared.system.start_bytes!=diag.esp.start_bytes or prepared.system.size_bytes!=diag.esp.size_bytes or
        prepared.msr.?.start_bytes!=34*512 or prepared.msr.?.size_bytes!=(32768-34)*512 or
        !std.mem.eql(u8,&ids.base.disk_guid,&(try bcd.parseGuid("{d82f1b66-1271-4683-867c-55b5f7070868}"))) or
        !std.mem.eql(u8,&ids.base.partition_guid,&(try bcd.parseGuid("{87c4f69b-6413-4c94-9c91-ce38d027d22e}"))) or
        !std.mem.eql(u8,&ids.esp,&(try bcd.parseGuid("{f8f81433-5702-4694-acfb-ffe9586ad29f}"))) or
        !std.mem.eql(u8,&ids.msr,&(try bcd.parseGuid("{e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10}"))) or
        ids.base.ntfs_serial!=0xe46231e86231c05a or ids.base.mbr_signature!=0 or options.arch!=.x64) return error.DiagnosticIdentityMismatch;
    var target=try @import("diagnostic_boot_target.zig").EspOnly.init(disk,tracker.allocator());
    const guarded=target.disk();
    _=try fat.format(guarded,prepared.esp.?,.{.serial=fat_serial});
    return provisionValidated(guarded,prepared,ids,tracker,options,log);
}

fn provisionValidated(disk: p.Disk, prepared: wl.Layout, ids: wl.Ids, tracker: *p.TrackedAllocator, options: Options, log: app.Logger) !Stats {
    const guid = try formatGuid(options.loader_guid);
    const a = tracker.allocator();
    const volume = try a.create(fat.Volume);
    defer a.destroy(volume);
    volume.* = try fat.Volume.openExisting(disk, prepared.esp.?);
    const buffer = try a.alloc(u8, 65536);
    defer a.free(buffer);
    try freshEsp(volume, buffer);
    const fs = try a.create(nt.FileSystem);
    defer a.destroy(fs);
    const large = try a.create(nt.LargeFile);
    defer a.destroy(large);
    const page = try a.alloc(nt.DirectoryItem, 32);
    defer a.free(page);
    var ctx: Context = .{ .disk = disk, .allocator = a, .fs = fs, .large = large, .buffer = buffer, .page = page, .log = log };
    defer ctx.deinit();
    fs.* = try nt.mountAllocated(.{ .context = &ctx, .read_fn = Context.read }, .{ .start_bytes = prepared.windows.start_bytes, .size_bytes = prepared.windows.size_bytes }, a);
    defer fs.deinit();
    ctx.pe(u("Windows\\System32\\winload.efi"), options.arch) catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/System32/winload.efi original={s}\n", .{@errorName(err)});
        return err;
    };
    ctx.pe(u("Windows\\Boot\\EFI\\bootmgfw.efi"), options.arch) catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/Boot/EFI/bootmgfw.efi original={s}\n", .{@errorName(err)});
        return err;
    };
    ctx.collect(u("Windows\\Boot\\EFI"), "EFI/Microsoft/Boot") catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/Boot/EFI original={s}\n", .{@errorName(err)});
        return err;
    };
    const before_fonts = ctx.items.items.len;
    ctx.collect(u("Windows\\Boot\\Fonts"), "EFI/Microsoft/Boot/Fonts") catch |err| {
        log.say("BOOT_REQUIRED_SOURCE source=Windows/Boot/Fonts original={s}\n", .{@errorName(err)});
        return err;
    };
    var fonts: usize = 0;
    for (ctx.items.items[before_fonts..]) |item| if (!item.directory) {
        fonts += 1;
    };
    if (fonts == 0) return error.MissingBootFonts;
    const before_resources = ctx.items.items.len;
    ctx.collect(u("Windows\\Boot\\Resources"), "EFI/Microsoft/Boot/Resources") catch |err| {
        switch (err) {
            error.OutOfMemory, error.BootInventoryBudget, error.BootPathBudget, error.BootDirectoryLoop, error.BootTargetCollision => return err,
            else => {},
        }
        ctx.rollback(before_resources);
        log.say("BOOT_OPTIONAL_SKIPPED source=Windows/Boot/Resources original={s}\n", .{@errorName(err)});
    };
    var main: ?Item = null;
    var need: u64 = 4;
    for (ctx.items.items) |item| {
        if (std.ascii.eqlIgnoreCase(item.target, "EFI/Microsoft/Boot/BCD")) return error.BootTargetCollision;
        if (std.ascii.eqlIgnoreCase(item.target, "EFI/Microsoft/Boot/bootmgfw.efi")) main = item;
        need += if (item.directory) @as(u64, 1) else (item.size + volume.g.clusterBytes() - 1) / volume.g.clusterBytes();
    }
    const loader = main orelse return error.MissingBootManager;
    const store = try bcd.create(a, .{ .mode = .uefi, .system = .{ .gpt = .{ .disk = ids.base.disk_guid, .partition = ids.esp } }, .windows = .{ .gpt = .{ .disk = ids.base.disk_guid, .partition = ids.base.partition_guid } }, .loader_id = &guid, .locale = options.locale, .description = options.description, .timestamp = options.timestamp });
    defer a.free(store);
    need += (loader.size + store.len + volume.g.clusterBytes() - 1) / volume.g.clusterBytes() + (@as(u64, @intCast(ctx.items.items.len)) * 672 + volume.g.clusterBytes() - 1) / volume.g.clusterBytes() + 4;
    if (need > volume.free_clusters) return error.NoSpace;
    log.say("BOOT_PREFLIGHT PASS files_and_dirs={d} reserved_clusters={d} all_source_hashes=true alloc_peak={d}\n", .{ ctx.items.items.len, need, tracker.peak });
    _ = try volume.mkdir("EFI");
    _ = try volume.mkdir("EFI/Microsoft");
    _ = try volume.mkdir("EFI/Boot");
    var stats: Stats = .{ .main_sha256 = loader.sha256, .bcd_sha256 = undefined };
    for (ctx.items.items) |item| if (item.directory) {
        _ = try volume.mkdir(item.target);
    } else {
        copy(&ctx, volume, item, item.target) catch |err| {
            log.say("BOOT_COPY_ERROR path={s} original={s}\n", .{ item.target, @errorName(err) });
            return err;
        };
        stats.files += 1;
        stats.bytes += item.size;
    };
    const fallback = if (options.arch == .x64) "EFI/Boot/BOOTX64.EFI" else "EFI/Boot/BOOTIA32.EFI";
    try copy(&ctx, volume, loader, fallback);
    stats.files += 1;
    stats.bytes += loader.size;
    var output = try volume.createFile("EFI/Microsoft/Boot/BCD", store.len);
    try output.write(store);
    try output.finish();
    stats.files += 1;
    stats.bytes += store.len;
    std.crypto.hash.sha2.Sha256.hash(store, &stats.bcd_sha256, .{});
    try volume.flush();
    log.say("BOOT_UEFI PASS arch={s} files={d} bytes={d} bcd_sha256={s} fallback_sha256={s} alloc_peak={d}\n", .{ @tagName(options.arch), stats.files, stats.bytes, std.fmt.bytesToHex(stats.bcd_sha256, .lower), std.fmt.bytesToHex(stats.main_sha256, .lower), tracker.peak });
    return stats;
}

test "boot target comparison uses Windows Unicode case folding" {
    try std.testing.expect(samePath("EFI/Żółć", "efi/ŻÓŁĆ"));
    try std.testing.expect(!samePath("EFI/Boot", "EFI/Boots"));
}
