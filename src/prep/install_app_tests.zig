//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const app = @import("app.zig");
const p = @import("platform.zig");
const layout = @import("windows_layout.zig");
const wim = @import("wim.zig");
const install = @import("install_app.zig");
const t = std.testing;
const Source = struct {
    bytes: []const u8,
    reads: usize = 0,
    failure: ?p.Error = null,
    failure_at: ?u64 = null,
    failure_len: ?usize = null,
    fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
        const self: *Source = @ptrCast(@alignCast(ctx)); self.reads += 1;
        if (self.failure) |reason| {
            if ((self.failure_at == null or at == self.failure_at.?) and
                (self.failure_len == null or out.len == self.failure_len.?)) return reason;
        }
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
    fn input(self: *Source) wim.Input { return .{ .context = self, .size = self.bytes.len, .read_fn = read }; }
};
const Target = struct {
    reads: usize = 0, writes: usize = 0, flushes: usize = 0,
    sector: u32 = 512,
    fn read(ctx: *anyopaque, _: u64, out: []u8) p.Error!void {
        const self: *Target = @ptrCast(@alignCast(ctx)); self.reads += 1; @memset(out,0);
    }
    fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void {
        const self: *Target = @ptrCast(@alignCast(ctx)); self.writes += 1; return error.Io;
    }
    fn flush(ctx: *anyopaque) p.Error!void {
        const self: *Target = @ptrCast(@alignCast(ctx)); self.flushes += 1; return error.Io;
    }
    fn disk(self: *Target) p.Disk {
        return .{ .context = self, .sector_bytes = self.sector, .sectors = 512 * layout.mib / self.sector,
            .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};
const Log = struct {
    bytes: [8192]u8 = undefined, len: usize = 0,
    fn write(ctx: *anyopaque, text: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ctx));
        std.debug.assert(text.len <= self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..text.len],text); self.len += text.len;
    }
    fn clock(_: *anyopaque) u64 { return 0; }
    fn logger(self: *Log) app.Logger { return .{ .context = self, .write_fn = write, .clock_fn = clock }; }
    fn has(self: *Log, needle: []const u8) bool { return std.mem.indexOf(u8,self.bytes[0..self.len],needle) != null; }
};
fn ids() !layout.Ids {
    var bytes: [128]u8 = undefined;
    for (&bytes,0..) |*b,i| b.* = @intCast(i+1);
    return layout.Ids.fromEntropy(bytes);
}
const selection: layout.Selection = .{ .explicit = true, .source_identity = 1, .target_identity = 2, .boot_identity = 3 };
test "install source and boot identity conflicts,4Kn and index0 refuse before all IO" {
    var source: Source = .{ .bytes = "not accessed" };
    var target: Target = .{}; var log: Log = .{};
    var tracker: p.TrackedAllocator = .{ .backing = t.allocator, .limit = 16 * 1024 * 1024 };
    var requested = selection;
    requested.target_identity = requested.source_identity;
    try t.expectError(error.SourceTargetConflict,install.run(target.disk(),.bios,try ids(),requested,&tracker,source.input(),1,.{},log.logger()));
    requested = selection; requested.target_identity = requested.boot_identity;
    try t.expectError(error.SourceTargetConflict,install.run(target.disk(),.bios,try ids(),requested,&tracker,source.input(),1,.{},log.logger()));
    requested = selection; requested.explicit = false;
    try t.expectError(error.SourceTargetConflict,install.run(target.disk(),.bios,try ids(),requested,&tracker,source.input(),1,.{},log.logger()));
    try t.expectError(error.InvalidImageIndex,install.run(target.disk(),.bios,try ids(),selection,&tracker,source.input(),0,.{},log.logger()));
    target.sector = 4096;
    try t.expectError(error.Unsupported,install.run(target.disk(),.uefi,try ids(),selection,&tracker,source.input(),1,.{},log.logger()));
    try t.expectEqual(@as(usize,0),source.reads + target.reads + target.writes + target.flushes);
    try t.expectEqual(@as(usize,0),tracker.current);
}
fn both(comptime T: type, out: []u8, at: usize, value: T) void {
    std.mem.writeInt(T,out[at..][0..@sizeOf(T)],value,.little);
    std.mem.writeInt(T,out[at+@sizeOf(T)..][0..@sizeOf(T)],value,.big);
}
fn record(out: []u8, lba: u32, bytes: u32, directory: bool, name: []const u8) void {
    const length = 33 + name.len + @intFromBool(name.len % 2 == 0);
    @memset(out[0..length],0); out[0] = @intCast(length); out[25] = if(directory) 2 else 0;
    out[32] = @intCast(name.len); both(u32,out,2,lba); both(u32,out,10,bytes); both(u16,out,28,1);
    @memcpy(out[33..][0..name.len],name);
}
fn ownIso(out: []u8, name: []const u8) void {
    @memset(out,0);
    const pvd=out[16*2048..][0..2048]; @memcpy(pvd[0..7],"\x01CD001\x01");
    both(u32,pvd,80,@intCast(out.len/2048)); both(u16,pvd,120,1); both(u16,pvd,124,1); both(u16,pvd,128,2048);
    record(pvd[156..],20,2048,true,"\x00");
    @memcpy(out[17*2048..][0..7],"\xffCD001\x01");
    record(out[20*2048..],21,2048,true,"SOURCES");
    record(out[21*2048..],24,512,false,name);
}
test "install ISO detects ESD and SWM with explicit errors and no target IO" {
    const bytes=try t.allocator.alloc(u8,32*2048); defer t.allocator.free(bytes);
    for ([_][]const u8{"INSTALL.ESD;1","INSTALL2.SWM;1"},[_]anyerror{error.InstallEsdUnsupported,error.InstallSwmUnsupported}) |name,expected| {
        ownIso(bytes,name);
        var source: Source=.{.bytes=bytes}; var target: Target=.{}; var log: Log=.{};
        var tracker: p.TrackedAllocator=.{.backing=t.allocator,.limit=16*1024*1024};
        try t.expectError(expected,install.run(target.disk(),.uefi,try ids(),selection,&tracker,source.input(),1,.{},log.logger()));
        try t.expect(log.has("ISO_SOURCE_UNSUPPORTED"));
        try t.expectEqual(@as(usize,0),target.reads+target.writes+target.flushes);
        try t.expectEqual(@as(usize,0),tracker.current);
    }
}
test "install rejects invalid WIM before preparation and keeps original source stream error" {
    const bytes=try t.allocator.alloc(u8,32*2048); defer t.allocator.free(bytes); ownIso(bytes,"INSTALL.WIM;1");
    var source: Source=.{.bytes=bytes}; var target: Target=.{}; var log: Log=.{};
    var tracker: p.TrackedAllocator=.{.backing=t.allocator,.limit=16*1024*1024};
    try t.expectError(error.UnsupportedWimHeader,install.run(target.disk(),.bios,try ids(),selection,&tracker,source.input(),1,.{},log.logger()));
    try t.expectEqual(@as(usize,0),target.reads+target.writes+target.flushes);
    try t.expectEqual(@as(usize,0),tracker.current);
    source.failure=error.Unsupported; source.failure_at=24*2048; source.failure_len=208;
    try t.expectError(error.Unsupported,install.run(target.disk(),.bios,try ids(),selection,&tracker,source.input(),1,.{},log.logger()));
    try t.expect(log.has("ISO_STREAM_ERROR original=Unsupported mapped=Unsupported"));
    try t.expect(log.has("ISO_SOURCE_ERROR original=Unsupported mapped=Unsupported"));
    try t.expectEqual(@as(usize,0),target.reads+target.writes+target.flushes);
    try t.expectEqual(@as(usize,0),tracker.current);
}
