//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const boot = @import("boot_bios_files.zig");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
const ntfs = @import("ntfs.zig");
const app = @import("app.zig");
const t = std.testing;
const u = std.unicode.utf8ToUtf16LeStringLiteral;
fn ids() !wl.Ids {
    var seed: [128]u8 = undefined;
    for (&seed, 0..) |*byte, i| byte.* = @intCast(i + 1);
    return wl.Ids.fromEntropy(seed);
}
const Probe = struct {
    reads: usize = 0,
    writes: usize = 0,
    fn read(ctx: *anyopaque, _: u64, _: []u8) p.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.reads += 1;
        return error.Io;
    }
    fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        return error.Io;
    }
    fn flush(_: *anyopaque) p.Error!void {
        return error.Io;
    }
    fn log(_: *anyopaque, _: []const u8) void {}
    fn clock(_: *anyopaque) u64 {
        return 0;
    }
};
test "BIOS prerequisite gates default off before allocator or target access" {
    var probe: Probe = .{};
    const disk: p.Disk = .{ .context = &probe, .sectors = wl.mib, .read_fn = Probe.read, .write_fn = Probe.write, .flush_fn = Probe.flush };
    const prepared = try wl.plan(disk, .bios);
    const id = try ids();
    var tracker: p.TrackedAllocator = .{ .backing = t.allocator };
    const code: [512]u8 = @splat(0);
    const log: app.Logger = .{ .context = &probe, .write_fn = Probe.log, .clock_fn = Probe.clock };
    try t.expectError(error.PrerequisiteGateMissing, boot.provisionBios(disk, prepared, id, &tracker, .{ .loader_guid = id.msr, .timestamp = 1 }, .{ .mbr = &code, .pbr = &code }, log));
    try t.expectEqual(@as(usize, 0), probe.reads + probe.writes + tracker.current);
    var buffer: [512]u8 = undefined;
    try t.expectError(error.BootManagerTooLarge, boot.bootmgrRun(disk, prepared.system, boot.max_bootmgr_bytes + 1, @splat(0), t.allocator, &buffer));
    try t.expectEqual(@as(usize, 0), probe.reads);
}
test "BIOS own-template ABI refuses absent magic and previously bound run" {
    var mbr: [512]u8 = @splat(0);
    var pbr: [512]u8 = @splat(0);
    const code: boot.OwnBootCode = .{ .mbr = &mbr, .pbr = &pbr };
    try t.expectError(error.InvalidOwnBootCode, boot.validateBootCode(code));
    mbr[0] = 0xfa;
    pbr[84] = 0xfa;
    @memcpy(mbr[432..440], "USOSMB1\x00");
    @memcpy(pbr[492..500], "USOSPB1\x00");
    std.mem.writeInt(u16, mbr[510..512], 0xaa55, .little);
    std.mem.writeInt(u16, pbr[510..512], 0xaa55, .little);
    try boot.validateBootCode(code);
    pbr[480] = 1;
    try t.expectError(error.InvalidOwnBootCode, boot.validateBootCode(code));
    pbr[480] = 0;
    pbr[488] = 1;
    try t.expectError(error.InvalidOwnBootCode, boot.validateBootCode(code));
    pbr[488] = 0;
    pbr[492] ^= 1;
    try t.expectError(error.InvalidOwnBootCode, boot.validateBootCode(code));
}
const LayoutProbe = struct {
    mbr: [512]u8 = @splat(0),
    system: [512]u8 = @splat(0),
    windows: [512]u8 = @splat(0),
    bad_backup: bool = false,
    layout: wl.Layout,
    writes: usize = 0,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *LayoutProbe = @ptrCast(@alignCast(ctx));
        if (out.len != 512) return error.Bounds;
        const data: *const [512]u8 = if (at == 0) &self.mbr else if (at == self.layout.system.start_bytes or at == self.layout.system.start_bytes + self.layout.system.size_bytes - 512) &self.system else if (at == self.layout.windows.start_bytes or at == self.layout.windows.start_bytes + self.layout.windows.size_bytes - 512) &self.windows else return error.Bounds;
        @memcpy(out, data);
        if (self.bad_backup and at == self.layout.system.start_bytes + self.layout.system.size_bytes - 512) out[72] ^= 1;
    }
    fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
        const self: *LayoutProbe = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        return error.Io;
    }
    fn flush(_: *anyopaque) p.Error!void {
        return error.Io;
    }
};
fn fakeBoot(out: *[512]u8, start: u64, size: u64, serial: u64) void {
    @memcpy(out[3..11], "NTFS    ");
    out[13] = 8;
    std.mem.writeInt(u16, out[11..13], 512, .little);
    std.mem.writeInt(u32, out[28..32], @intCast(start / 512), .little);
    std.mem.writeInt(u64, out[40..48], size / 512 - 1, .little);
    std.mem.writeInt(u64, out[72..80], serial, .little);
    std.mem.writeInt(u16, out[510..512], 0xaa55, .little);
}
test "BIOS actual MBR and both NTFS primary-backup identities bind before writes" {
    var probe: LayoutProbe = .{ .layout = undefined };
    const disk: p.Disk = .{ .context = &probe, .sectors = wl.mib, .read_fn = LayoutProbe.read, .write_fn = LayoutProbe.write, .flush_fn = LayoutProbe.flush };
    const layout = try wl.plan(disk, .bios);
    probe.layout = layout;
    const id = try ids();
    std.mem.writeInt(u32, probe.mbr[440..444], id.base.mbr_signature, .little);
    std.mem.writeInt(u16, probe.mbr[510..512], 0xaa55, .little);
    probe.mbr[446] = 0x80;
    probe.mbr[450] = 7;
    probe.mbr[466] = 7;
    std.mem.writeInt(u32, probe.mbr[454..458], @intCast(layout.system.start_bytes / 512), .little);
    std.mem.writeInt(u32, probe.mbr[458..462], @intCast(layout.system.size_bytes / 512), .little);
    std.mem.writeInt(u32, probe.mbr[470..474], @intCast(layout.windows.start_bytes / 512), .little);
    std.mem.writeInt(u32, probe.mbr[474..478], @intCast(layout.windows.size_bytes / 512), .little);
    fakeBoot(&probe.system, layout.system.start_bytes, layout.system.size_bytes, 0x123456789abcdef0);
    fakeBoot(&probe.windows, layout.windows.start_bytes, layout.windows.size_bytes, id.base.ntfs_serial);
    try t.expectEqual(@as(u64, 0x123456789abcdef0), try boot.validateDisk(disk, layout, id));
    probe.mbr[446] = 0;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(disk, layout, id));
    probe.mbr[446] = 0x80;
    probe.windows[72] ^= 1;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(disk, layout, id));
    probe.windows[72] ^= 1;
    probe.bad_backup = true;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(disk, layout, id));
    try t.expectEqual(@as(usize, 0), probe.writes);
}
const Sparse = struct {
    pages: std.AutoHashMap(u64, [4096]u8),
    writes: usize = 0,
    protected_start: ?u64 = null,
    forbidden_writes: usize = 0,
    fn init() Sparse {
        return .{ .pages = std.AutoHashMap(u64, [4096]u8).init(t.allocator) };
    }
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Sparse = @ptrCast(@alignCast(ctx));
        @memset(out, 0);
        var done: usize = 0;
        while (done < out.len) {
            const offset = at + done;
            const within: usize = @intCast(offset % 4096);
            const n = @min(out.len - done, 4096 - within);
            if (self.pages.getPtr(offset / 4096)) |page| @memcpy(out[done..][0..n], page[within..][0..n]);
            done += n;
        }
    }
    fn write(ctx: *anyopaque, at: u64, data: []const u8) p.Error!void {
        const self: *Sparse = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (self.protected_start) |start| if (at >= start or data.len > start -| at) {
            self.forbidden_writes += 1;
            return error.Bounds;
        };
        var done: usize = 0;
        while (done < data.len) {
            const offset = at + done;
            const within: usize = @intCast(offset % 4096);
            const n = @min(data.len - done, 4096 - within);
            if (std.mem.allEqual(u8, data[done..][0..n], 0) and !self.pages.contains(offset / 4096)) {
                done += n;
                continue;
            }
            const result = self.pages.getOrPut(offset / 4096) catch return error.NoSpace;
            if (!result.found_existing) result.value_ptr.* = @splat(0);
            @memcpy(result.value_ptr[within..][0..n], data[done..][0..n]);
            done += n;
        }
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *Sparse) p.Disk {
        return .{ .context = self, .sectors = wl.mib, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};
const Data = struct {
    fragmented: bool,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Data = @ptrCast(@alignCast(ctx));
        for (out, 0..) |*byte, i| byte.* = if (self.fragmented and (at + i) / 4096 % 2 == 0) 0 else @truncate((at + i) *% 13 +% 7);
    }
};
test "BIOS BOOTMGR binding resolves SHA and refuses physical fragmentation or sparse data" {
    {
        var fresh = Sparse.init();
        defer fresh.pages.deinit();
        const part = (try wl.plan(fresh.disk(), .bios)).system;
        const empty = try t.allocator.create(ntfs.Ntfs);
        defer t.allocator.destroy(empty);
        empty.* = try ntfs.Ntfs.init(fresh.disk(), part, t.allocator, 0x112233);
        defer empty.deinit();
        try empty.format();
        try empty.finish();
        try boot.requireEmptySystem(fresh.disk(), part, t.allocator);
    }
    var memory = Sparse.init();
    defer memory.pages.deinit();
    const disk = memory.disk();
    const part = (try wl.plan(disk, .bios)).system;
    var data: Data = .{ .fragmented = false };
    const fs = try t.allocator.create(ntfs.Ntfs);
    defer t.allocator.destroy(fs);
    fs.* = try ntfs.Ntfs.init(disk, part, t.allocator, 0xabcdef);
    defer fs.deinit();
    try fs.format();
    const size = 12289;
    _ = try fs.writeFile(5, u("bootmgr"), .{ .context = &data, .size = size, .read_fn = Data.read }, .{});
    try fs.finish();
    try t.expectError(error.BootSystemNotEmpty, boot.requireEmptySystem(disk, part, t.allocator));
    var scratch: [16384]u8 = undefined;
    try Data.read(&data, 0, scratch[0..size]);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(scratch[0..size], &expected, .{});
    const writes = memory.writes;
    const run = try boot.bootmgrRun(disk, part, size, expected, t.allocator, &scratch);
    try t.expectEqual(@as(u16, 25), run.sectors);
    try t.expect(run.lba > part.start_bytes / 512);
    expected[0] ^= 1;
    try t.expectError(error.BootManagerReadbackHashMismatch, boot.bootmgrRun(disk, part, size, expected, t.allocator, &scratch));
    try t.expectEqual(writes, memory.writes);
    var fragmented = Sparse.init();
    defer fragmented.pages.deinit();
    const other = try t.allocator.create(ntfs.Ntfs);
    defer t.allocator.destroy(other);
    other.* = try ntfs.Ntfs.init(fragmented.disk(), part, t.allocator, 0xabcdee);
    defer other.deinit();
    try other.format();
    inline for (.{ "hole0", "keep0", "hole1", "keep1", "hole2", "keep2", "hole3" }) |name| {
        _ = try other.writeFile(5, std.unicode.utf8ToUtf16LeStringLiteral(name), .{ .context = &data, .size = 4096, .read_fn = Data.read }, .{});
    }
    inline for (.{ "hole0", "hole1", "hole2", "hole3" }) |name| try other.removeFile(5, std.unicode.utf8ToUtf16LeStringLiteral(name));
    const record = try other.writeFile(5, u("bootmgr"), .{ .context = &data, .size = size, .read_fn = Data.read }, .{ .max_run_clusters = 1 });
    try t.expect((try other.fileStats(record)).run_count > 1);
    try other.finish();
    try t.expectError(error.BootManagerNotContiguous, boot.bootmgrRun(fragmented.disk(), part, size, @splat(0), t.allocator, &scratch));
    var sparse = Sparse.init();
    defer sparse.pages.deinit();
    const flagged = try t.allocator.create(ntfs.Ntfs);
    defer t.allocator.destroy(flagged);
    flagged.* = try ntfs.Ntfs.init(sparse.disk(), part, t.allocator, 0xabcddd);
    defer flagged.deinit();
    try flagged.format();
    data.fragmented = true;
    _ = try flagged.writeFile(5, u("bootmgr"), .{ .context = &data, .size = size, .read_fn = Data.read }, .{ .sparse = true });
    try flagged.finish();
    try t.expectError(error.BootManagerUnsupportedData, boot.bootmgrRun(sparse.disk(), part, size, @splat(0), t.allocator, &scratch));
}
const Bytes = struct {
    bytes: []const u8,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Bytes = @ptrCast(@alignCast(ctx));
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
test "BIOS synthetic provisioning preserves source Windows and BPB then refuses populated system" {
    // Generated project fixture, not Windows or a CPU boot test. Fake own-code
    // bytes prove the patch ABI; real assembled code belongs to the QEMU gate.
    var memory = Sparse.init();
    defer memory.pages.deinit();
    const disk = memory.disk();
    const id = try ids();
    const prepared = try wl.create(disk, .bios, id, .{ .explicit = true, .source_identity = 1, .target_identity = 2, .boot_identity = 3 }, t.allocator);
    {
        const system = try t.allocator.create(ntfs.Ntfs);
        defer t.allocator.destroy(system);
        system.* = try ntfs.Ntfs.init(disk, prepared.system, t.allocator, 0x123456789abcde);
        defer system.deinit();
        try system.format();
        try system.finish();
    }
    {
        const windows = try t.allocator.create(ntfs.Ntfs);
        defer t.allocator.destroy(windows);
        windows.* = try ntfs.Ntfs.init(disk, prepared.windows, t.allocator, id.base.ntfs_serial);
        defer windows.deinit();
        try windows.format();
        const win = try windows.mkdir(5, u("Windows"), .{});
        const sys = try windows.mkdir(win, u("System32"), .{});
        var pe: [160]u8 = @splat(0);
        @memcpy(pe[0..2], "MZ");
        std.mem.writeInt(u32, pe[60..64], 64, .little);
        @memcpy(pe[64..68], "PE\x00\x00");
        std.mem.writeInt(u16, pe[68..70], 0x14c, .little);
        std.mem.writeInt(u16, pe[84..86], 72, .little);
        std.mem.writeInt(u16, pe[88..90], 0x10b, .little);
        std.mem.writeInt(u16, pe[156..158], 16, .little);
        var header: Bytes = .{ .bytes = &pe };
        _ = try windows.writeFile(sys, u("winload.exe"), .{ .context = &header, .size = pe.len, .read_fn = Bytes.read }, .{});
        const bootdir = try windows.mkdir(win, u("Boot"), .{});
        const pcat = try windows.mkdir(bootdir, u("PCAT"), .{});
        const fonts = try windows.mkdir(bootdir, u("Fonts"), .{});
        var data: Data = .{ .fragmented = false };
        _ = try windows.writeFile(pcat, u("bootmgr"), .{ .context = &data, .size = 12289, .read_fn = Data.read }, .{});
        _ = try windows.writeFile(fonts, u("test.ttf"), .{ .context = &data, .size = 1025, .read_fn = Data.read }, .{});
        try windows.finish();
    }
    var original_mbr: [512]u8 = undefined;
    try disk.read(0, &original_mbr);
    var original_pbr: [512]u8 = undefined;
    try disk.read(prepared.system.start_bytes, &original_pbr);
    memory.protected_start = prepared.windows.start_bytes;
    var code_mbr: [512]u8 = @splat(0);
    var code_pbr: [512]u8 = @splat(0);
    code_mbr[0] = 0xfa;
    code_pbr[84] = 0xfa;
    @memcpy(code_mbr[432..440], "USOSMB1\x00");
    @memcpy(code_pbr[492..500], "USOSPB1\x00");
    std.mem.writeInt(u16, code_mbr[510..512], 0xaa55, .little);
    std.mem.writeInt(u16, code_pbr[510..512], 0xaa55, .little);
    const code: boot.OwnBootCode = .{ .mbr = &code_mbr, .pbr = &code_pbr };
    var tracker: p.TrackedAllocator = .{ .backing = t.allocator, .limit = 16 * 1024 * 1024 };
    var sink: u8 = 0;
    const log: app.Logger = .{ .context = &sink, .write_fn = Probe.log, .clock_fn = Probe.clock };
    const options: boot.Options = .{ .loader_guid = id.msr, .timestamp = 132537600000000000, .gates = .{ .layout_apply = true, .bcd_reference = true } };
    const result = try boot.provisionBios(disk, prepared, id, &tracker, options, code, log);
    try t.expectEqual(@as(u32, 3), result.files);
    try t.expectEqual(@as(u16, 25), result.bootmgr_sectors);
    try t.expectEqual(@as(usize, 0), tracker.current);
    try t.expectEqual(@as(usize, 0), memory.forbidden_writes);
    var after: [512]u8 = undefined;
    try disk.read(0, &after);
    try t.expectEqualSlices(u8, original_mbr[440..512], after[440..512]);
    try disk.read(prepared.system.start_bytes, &after);
    try t.expectEqualSlices(u8, original_pbr[0..84], after[0..84]);
    try t.expectEqual(result.bootmgr_lba, std.mem.readInt(u64, after[480..488], .little));
    try t.expectEqual(result.bootmgr_sectors, std.mem.readInt(u16, after[488..490], .little));
    var backup: [512]u8 = undefined;
    try disk.read(prepared.system.start_bytes + prepared.system.size_bytes - 512, &backup);
    try t.expectEqualSlices(u8, &after, &backup);
    const writes = memory.writes;
    try t.expectError(error.BootSystemNotEmpty, boot.provisionBios(disk, prepared, id, &tracker, options, code, log));
    try t.expectEqual(writes, memory.writes);
    try t.expectEqual(@as(usize, 0), tracker.current);
}
