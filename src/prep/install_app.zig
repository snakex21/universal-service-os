//! Common firmware ISO -> verified WIM -> new Windows disk pipeline.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const layout = @import("windows_layout.zig");
const identity = @import("identity.zig");
const parts = @import("partitions.zig");
const optical = @import("optical.zig");
const fat32 = @import("fat32.zig");
const ntfs = @import("ntfs.zig");
const wim = @import("wim.zig");
const wim_app = @import("wim_app.zig");
const app = @import("app.zig");
const progress = @import("progress.zig");
const readahead = @import("readahead.zig");

pub const Options = struct { target_drive: u8 = 'C', strict_rpfix: bool = true, verify_scope: wim_app.VerifyScope = .selected, post_apply_context: ?*anyopaque = null, post_apply: ?wim_app.PostApply = null };
const Serials = struct { fat32: u32, system_ntfs: u64 };
fn serials(ids: layout.Ids) Serials {
    var fat = std.mem.readInt(u32, ids.esp[0..4], .little);
    // GUID version4 in byte7 makes this fallback neither0 norFFFFFFFF.
    if (fat == 0 or fat == 0xffffffff) fat = std.mem.readInt(u32, ids.esp[4..8], .little);
    var system = std.mem.readInt(u64, ids.esp[8..16], .little);
    // The RFC4122 variant in byte8 guarantees nonzero after this toggle.
    if (system == ids.base.ntfs_serial) system ^= @as(u64, 1) << 63;
    return .{ .fat32 = fat, .system_ntfs = system };
}
const Source = struct {
    input: wim.Input,
    last_error: ?p.Error = null,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Source = @ptrCast(@alignCast(ctx));
        self.input.read_fn(self.input.context, offset, out) catch |err| {
            self.last_error = err;
            return err;
        };
    }
    fn opticalInput(self: *Source) optical.Input {
        return .{ .context = self, .size = self.input.size, .read_fn = read };
    }
};
const Preparation = struct {
    mode: layout.Mode,
    ids: layout.Ids,
    selection: layout.Selection,
    expected_disk: p.Disk,
    result: ?layout.Layout = null,
    attempted: bool = false,
    fn prepare(ctx: *anyopaque, disk: p.Disk, ids: identity.Identifiers, a: std.mem.Allocator, log: app.Logger) anyerror!parts.Partition {
        const self: *Preparation = @ptrCast(@alignCast(ctx));
        if (self.attempted) return error.TargetAlreadyPrepared;
        if (disk.context != self.expected_disk.context or disk.sector_bytes != self.expected_disk.sector_bytes or
            disk.sectors != self.expected_disk.sectors or disk.read_fn != self.expected_disk.read_fn or
            disk.write_fn != self.expected_disk.write_fn or disk.flush_fn != self.expected_disk.flush_fn or
            !std.meta.eql(ids, self.ids.base)) return error.SourceTargetConflict;
        self.attempted = true;
        // Selected metadata is verified before format. File SHA1 is checked
        // during apply, and the Windows volume stays dirty until success.
        // create() repeats identity validation and scans every target byte.
        var blank_progress = progress.Reporter.init(log, "scan-blank-target");
        var selection = self.selection;
        selection.progress = blank_progress.sink();
        const disk_layout = try layout.create(disk, self.mode, self.ids, selection, a);
        const serial = serials(self.ids);
        if (self.mode == .uefi) {
            const esp = try a.create(fat32.Volume); defer a.destroy(esp);
            esp.* = try fat32.format(disk, disk_layout.esp.?, .{ .serial = serial.fat32 });
            log.say("INSTALL_SYSTEM FAT32 start={d} bytes={d} serial={x:0>8} fresh=true\n", .{ disk_layout.system.start_bytes, disk_layout.system.size_bytes, serial.fat32 });
        } else {
            const system = try a.create(ntfs.Ntfs); defer a.destroy(system);
            system.* = try ntfs.Ntfs.init(disk, disk_layout.system, a, serial.system_ntfs);
            defer system.deinit();
            try system.format();
            try system.finish();
            log.say("INSTALL_SYSTEM NTFS start={d} bytes={d} serial={x:0>16} fresh=true empty=true\n", .{ disk_layout.system.start_bytes, disk_layout.system.size_bytes, serial.system_ntfs });
        }
        self.result = disk_layout;
        log.say("INSTALL_LAYOUT mode={s} windows_start={d} windows_bytes={d} selected_metadata_verified_before_target_write=true\n", .{ @tagName(self.mode), disk_layout.windows.start_bytes, disk_layout.windows.size_bytes });
        return disk_layout.windows;
    }
};
fn findWim(volume: *const optical.Volume, stream: *optical.Stream, a: std.mem.Allocator) !void {
    if (volume.findInto("sources\\install.wim", &stream.node)) |_| {
        if (stream.node.directory) return error.NotFile;
        return;
    } else |err| if (err != error.NotFound) return err;
    if (volume.findInto("sources\\install.esd", &stream.node)) |_| return error.InstallEsdUnsupported
    else |err| if (err != error.NotFound) return err;
    try volume.findInto("sources", &stream.node);
    const iterator = try a.create(optical.Iterator); defer a.destroy(iterator);
    const entry = try a.create(optical.Entry); defer a.destroy(entry);
    try volume.listInto(&stream.node, iterator);
    while (try iterator.next(entry)) {
        const name = entry.nameSlice();
        if (name.len >= 11 and optical.equalName(name[0..7], &.{ 'i', 'n', 's', 't', 'a', 'l', 'l' }) and
            optical.equalName(name[name.len - 4 ..], &.{ '.', 's', 'w', 'm' })) return error.InstallSwmUnsupported;
    }
    return error.NotFound;
}
fn sourceFailure(log: app.Logger, stage: []const u8, reason: anyerror) void {
    log.say("INSTALL_ISO_ERROR stage={s} original={s} target_write_started=false\n", .{ stage, @errorName(reason) });
    switch (reason) {
        error.InstallEsdUnsupported => log.say("ISO_SOURCE_UNSUPPORTED install.esd requires solid-ESD support; use unsplit install.wim\n", .{}),
        error.InstallSwmUnsupported => log.say("ISO_SOURCE_UNSUPPORTED split install*.swm needs a multi-part source set; use unsplit install.wim\n", .{}),
        error.NotFound => log.say("ISO_SOURCE_MISSING sources\\install.wim (no install.esd or install*.swm)\n", .{}),
        else => {},
    }
}
/// `iso` is the read-only byte stream of an ISO file on the source NTFS DATA
/// volume (or a read-only block source). Identity tokens must identify entire
/// backing media, not just partitions/adapter objects. The firmware caller owns
/// discovery and explicit user selection; this function never selects a disk.
pub fn run(disk: p.Disk, mode: layout.Mode, ids: layout.Ids, selection: layout.Selection,
    tracker: *p.TrackedAllocator, iso: wim.Input, selected: u32, options: Options, log: app.Logger) !layout.Layout
{
    try selection.validate();
    try ids.validate();
    if (selected == 0) return error.InvalidImageIndex;
    if (options.target_drive < 'A' or options.target_drive > 'Z') return error.InvalidTargetDrive;
    // NTFS's writer currently supports512byte sectors. Refuse4Kn before the
    // layout callback can write GPT or an otherwise supported4Kn ESP.
    if (disk.sector_bytes != 512) return error.Unsupported;
    const expected = try layout.plan(disk, mode);
    if (expected.windows.size_bytes < 64 * layout.mib) return error.NoSpace;
    const a = tracker.allocator();
    const volume = try a.create(optical.Volume); defer a.destroy(volume);
    const stream = try a.create(optical.Stream); defer a.destroy(stream);
    var source: Source = .{ .input = iso };
    optical.Volume.openInto(source.opticalInput(), volume) catch |err| {
        sourceFailure(log, "open", source.last_error orelse err);
        return err;
    };
    stream.* = .{ .input = volume.input, .node = .{} };
    findWim(volume, stream, a) catch |err| {
        sourceFailure(log, "find-install-wim", source.last_error orelse err);
        return err;
    };
    var preparation: Preparation = .{ .mode = mode, .ids = ids, .selection = selection, .expected_disk = disk };
    const start = log.now();
    log.say("INSTALL_ISO kind={s} udf_revision={x} image={d} wim_bytes={d} intermediate_copy=false\n", .{ @tagName(volume.kind), volume.udf_state.revision, selected, stream.node.size });
    var cache = try readahead.Cache.init(a, .{ .context = stream, .size = stream.node.size, .read_fn = optical.Stream.read });
    defer cache.deinit();
    defer log.say("SOURCE_READAHEAD capacity={d} requests={d} upstream_reads={d} upstream_bytes={d} hits={d}\n", .{ readahead.capacity, cache.stats.requests, cache.stats.upstream_reads, cache.stats.upstream_bytes, cache.stats.hits });
    const cached = cache.reader();
    wim_app.runWithOptions(disk, if (mode == .uefi) .gpt else .mbr, ids.base, tracker,
        .{ .context = cached.context, .size = cached.size, .read_fn = cached.read_fn }, selected,
        .{ .target_drive = options.target_drive, .strict_rpfix = options.strict_rpfix, .verify_scope = options.verify_scope,
           .prepare_context = &preparation, .prepare_partition = Preparation.prepare,
           .post_apply_context = options.post_apply_context, .post_apply = options.post_apply }, log) catch |err| {
        if (stream.last_error) |original| log.say("ISO_STREAM_ERROR original={s} mapped={s}\n", .{ @errorName(original), @errorName(err) });
        if (source.last_error) |original| log.say("ISO_SOURCE_ERROR original={s} mapped={s}\n", .{ @errorName(original), @errorName(err) });
        return err;
    };
    const result = preparation.result orelse return error.TargetNotPrepared;
    log.say("INSTALL_APPLY PASS mode={s} image={d} seconds={d} alloc_peak={d} boot_files=false intermediate_copy=false\n", .{ @tagName(mode), selected, log.now() -| start, tracker.peak });
    return result;
}

test "installation serial derivation preserves nonzero FAT and distinct NTFS IDs" {
    var seed: [128]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    var ids = try layout.Ids.fromEntropy(seed);
    for ([_]u32{0,0xffffffff}) |bad| {
        std.mem.writeInt(u32, ids.esp[0..4], bad, .little);
        const serial = serials(ids);
        try std.testing.expect(serial.fat32 != 0 and serial.fat32 != 0xffffffff);
        try std.testing.expect(serial.system_ntfs != 0 and serial.system_ntfs != ids.base.ntfs_serial);
    }
    ids.base.ntfs_serial = std.mem.readInt(u64, ids.esp[8..16], .little);
    try std.testing.expect(serials(ids).system_ntfs != ids.base.ntfs_serial);
}

test "layout preparation rejects hidden target data before format and refuses a retry" {
    const Probe = struct {
        writes: usize = 0,
        fn read(_: *anyopaque, at: u64, out: []u8) p.Error!void {
            @memset(out,0); const poison = 73 * layout.mib + 19;
            if (at <= poison and poison-at < out.len) out[@intCast(poison-at)] = 1;
        }
        fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx)); self.writes += 1; return error.Io;
        }
        fn flush(_: *anyopaque) p.Error!void { return error.Io; }
        fn log(_: *anyopaque, _: []const u8) void {}
        fn clock(_: *anyopaque) u64 { return 0; }
    };
    var probe: Probe = .{};
    const disk: p.Disk = .{ .context = &probe, .sector_bytes = 512, .sectors = 512*layout.mib/512, .read_fn = Probe.read, .write_fn = Probe.write, .flush_fn = Probe.flush };
    var seed: [128]u8 = undefined; for (&seed,0..) |*b,i| b.* = @intCast(i+1);
    const ids = try layout.Ids.fromEntropy(seed);
    var preparation: Preparation = .{ .mode = .bios, .ids = ids, .selection = .{.explicit=true,.source_identity=1,.target_identity=2,.boot_identity=3}, .expected_disk=disk };
    const log: app.Logger = .{ .context = &probe, .write_fn = Probe.log, .clock_fn = Probe.clock };
    try std.testing.expectError(error.TargetNotBlank,Preparation.prepare(&preparation,disk,ids.base,std.testing.allocator,log));
    try std.testing.expectError(error.TargetAlreadyPrepared,Preparation.prepare(&preparation,disk,ids.base,std.testing.allocator,log));
    try std.testing.expectEqual(@as(usize,0),probe.writes);
    try std.testing.expect(preparation.result == null);
}
