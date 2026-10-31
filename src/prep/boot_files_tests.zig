//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const boot = @import("boot_files.zig");
const p = @import("platform.zig");
const wl = @import("windows_layout.zig");
const bcd = @import("bcd.zig");
const app = @import("app.zig");
const t = std.testing;
fn ids() !wl.Ids {
    var seed: [128]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i + 1);
    return wl.Ids.fromEntropy(seed);
}
const Probe = struct {
    reads: usize = 0,
    writes: usize = 0,
    fn read(ctx: *anyopaque, _: u64, _: []u8) p.Error!void {
        const s: *Probe = @ptrCast(@alignCast(ctx));
        s.reads += 1;
        return error.Io;
    }
    fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
        const s: *Probe = @ptrCast(@alignCast(ctx));
        s.writes += 1;
        return error.Io;
    }
    fn flush(_: *anyopaque) p.Error!void {
        return error.Io;
    }
    fn log(_: *anyopaque, _: []const u8) void {}
    fn now(_: *anyopaque) u64 {
        return 0;
    }
};
test "boot prerequisites default off and refuse before any disk access" {
    var probe: Probe = .{};
    const disk: p.Disk = .{ .context = &probe, .sectors = 512 * wl.mib / 512, .read_fn = Probe.read, .write_fn = Probe.write, .flush_fn = Probe.flush };
    const prepared = try wl.plan(disk, .uefi);
    const identity = try ids();
    var tracker: p.TrackedAllocator = .{ .backing = t.allocator };
    const log: app.Logger = .{ .context = &probe, .write_fn = Probe.log, .clock_fn = Probe.now };
    try t.expectError(error.PrerequisiteGateMissing, boot.provisionUefi(disk, prepared, identity, &tracker, .{ .arch = .x64, .loader_guid = identity.msr, .timestamp = 1 }, log));
    try t.expectEqual(@as(usize, 0), probe.reads + probe.writes + tracker.current);
}
test "diagnostic provisioning rejects unpinned identity before disk writes" {
    var probe: Probe = .{};
    const disk: p.Disk = .{ .context = &probe, .sectors = 512 * wl.mib / 512, .read_fn = Probe.read, .write_fn = Probe.write, .flush_fn = Probe.flush };
    const prepared = try wl.plan(disk, .uefi); const identity = try ids();
    var tracker: p.TrackedAllocator = .{ .backing = t.allocator };
    const log: app.Logger = .{ .context = &probe, .write_fn = Probe.log, .clock_fn = Probe.now };
    try t.expectError(error.PrerequisiteGateMissing,boot.provisionReference(disk,prepared,identity,&tracker,.{.arch=.x64,.loader_guid=identity.msr,.timestamp=1},1,log));
    try t.expectError(error.DiagnosticIdentityMismatch,boot.provisionReference(disk,prepared,identity,&tracker,.{.arch=.x64,.loader_guid=identity.msr,.timestamp=1,.gates=.{.layout_apply=true,.diagnostic_deferred=true}},1,log));
    try t.expectEqual(@as(usize,0),probe.reads+probe.writes+tracker.current);
}
test "boot GUID formats GPT little-endian order and rejects unavailable entropy" {
    const raw = try bcd.parseGuid("{00112233-4455-4677-8899-aabbccddeeff}");
    const text = try boot.formatGuid(raw);
    try t.expectEqualStrings("{00112233-4455-4677-8899-aabbccddeeff}", &text);
    try t.expectError(error.InvalidLoaderGuid, boot.formatGuid(@splat(0)));
}
const Sparse = struct {
    head: []u8,
    tail: []u8,
    serial: u64,
    writes: usize = 0,
    formatted: bool = false,
    const bytes = 512 * wl.mib;
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Sparse = @ptrCast(@alignCast(ctx));
        @memset(out, 0);
        if (at < self.head.len) {
            const n = @min(out.len, self.head.len - @as(usize, @intCast(at)));
            @memcpy(out[0..n], self.head[@intCast(at)..][0..n]);
        }
        const from = @max(at, bytes - self.tail.len);
        const end = @min(at + out.len, bytes);
        if (from < end) @memcpy(out[@intCast(from - at)..][0..@intCast(end - from)], self.tail[@intCast(from - (bytes - self.tail.len))..][0..@intCast(end - from)]);
        if (self.formatted and at == 317 * wl.mib and out.len >= 80) {
            @memcpy(out[3..11], "NTFS    ");
            std.mem.writeInt(u16, out[11..13], 512, .little);
            std.mem.writeInt(u64, out[72..80], self.serial, .little);
        }
    }
    fn write(ctx: *anyopaque, at: u64, data: []const u8) p.Error!void {
        const self: *Sparse = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        if (at <= self.head.len and data.len <= self.head.len - at) {
            @memcpy(self.head[@intCast(at)..][0..data.len], data);
            return;
        }
        if (at >= bytes - self.tail.len and at <= bytes and data.len <= bytes - at) {
            @memcpy(self.tail[@intCast(at - (bytes - self.tail.len))..][0..data.len], data);
            return;
        }
        return error.Io;
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn disk(self: *Sparse) p.Disk {
        return .{ .context = self, .sectors = bytes / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};
test "boot identity checks real primary and backup GPT,partition GUIDs and NTFS serial without writes" {
    const identity = try ids();
    const a = t.allocator;
    const head = try a.alloc(u8, 65536);
    defer a.free(head);
    @memset(head, 0);
    const tail = try a.alloc(u8, 65536);
    defer a.free(tail);
    @memset(tail, 0);
    var memory: Sparse = .{ .head = head, .tail = tail, .serial = identity.base.ntfs_serial };
    const prepared = try wl.create(memory.disk(), .uefi, identity, .{ .explicit = true, .source_identity = 1, .target_identity = 2, .boot_identity = 3 }, a);
    memory.formatted = true;
    const writes = memory.writes;
    try boot.validateDisk(memory.disk(), prepared, identity, a);
    head[512 + 56] ^= 1;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(memory.disk(), prepared, identity, a));
    head[512 + 56] ^= 1;
    tail[tail.len - 512 + 16] ^= 1;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(memory.disk(), prepared, identity, a));
    tail[tail.len - 512 + 16] ^= 1;
    var other = identity;
    other.esp[0] ^= 1;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(memory.disk(), prepared, other, a));
    memory.serial ^= 1;
    try t.expectError(error.BootDiskIdentityMismatch, boot.validateDisk(memory.disk(), prepared, identity, a));
    try t.expectEqual(writes, memory.writes);
}
