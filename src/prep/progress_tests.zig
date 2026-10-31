//! Self-authored telemetry fixtures; no image or physical storage is opened.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const progress = @import("progress.zig");
const app = @import("app.zig");
const layout = @import("windows_layout.zig");
const mib: u64 = 1024 * 1024;
test "category timing and completed-file rate never label an invalid clock as zero" {
    const Ticks = struct {
        value: ?u64 = 0,
        fn read(ctx: *anyopaque) ?u64 { return @as(*@This(), @ptrCast(@alignCast(ctx))).value; }
    };
    var ticks: Ticks = .{};
    var profile = p.profiling.Profiler.init(.{ .context = &ticks, .read_fn = Ticks.read, .frequency_hz = 1000, .name = "fixture" });
    var probe: Probe = .{};
    var log = probe.logger(); log.profiler = &profile;
    var reporter = progress.Reporter.init(log, "timed");
    const timing = profile.begin(.decode);
    ticks.value = 12; profile.end(timing); profile.filesDone(3);
    probe.seconds = 102;
    reporter.finish(.{ .current = 3, .total = 3, .bytes = 100, .resources = 3 });
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.used], "valid=true files=3 files_per_s_milli=1500 decode_ms=12") != null);
    ticks.value = null; _ = profile.now();
    probe.used = 0;
    var invalid = progress.Reporter.init(log, "invalid");
    invalid.finish(.{ .current = 3, .total = 3, .bytes = 100, .resources = 3 });
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.used], "valid=false files=0 files_per_s_milli=0 decode_ms=null sha_ms=null") != null);
}
const Probe = struct {
    text: [8192]u8 = undefined,
    used: usize = 0,
    clock_reads: usize = 0,
    snapshot_reads: usize = 0,
    seconds: u64 = 100,
    io: p.IoCounters = .{},
    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        std.debug.assert(bytes.len <= self.text.len - self.used);
        @memcpy(self.text[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
    fn clock(ctx: *anyopaque) u64 {
        const self: *Probe = @ptrCast(@alignCast(ctx)); self.clock_reads += 1; return self.seconds;
    }
    fn snapshot(ctx: *anyopaque) p.Telemetry {
        const self: *Probe = @ptrCast(@alignCast(ctx)); self.snapshot_reads += 1;
        return .{ .io = self.io, .io_kind = .block_io, .alloc_peak = 1234567, .stack_high_water = 76543, .stack_available = true };
    }
    fn logger(self: *Probe) app.Logger { return .{ .context = self, .write_fn = write, .clock_fn = clock, .telemetry_fn = snapshot }; }
    fn lines(self: *const Probe) usize { return std.mem.count(u8, self.text[0..self.used], "PROGRESS "); }
};

test "progress bytes and resources throttle telemetry reads, with one final event" {
    var probe: Probe = .{};
    var reporter = progress.Reporter.init(probe.logger(), "verify-all");
    const hook = reporter.sink();
    hook.report(.{ .current = 0, .total = 5000, .bytes = 0, .resources = 0 });
    for (1..2000) |n| hook.report(.{ .current = n, .total = 5000, .bytes = n * 100, .resources = n });
    try std.testing.expectEqual(@as(usize, 1), probe.lines());
    try std.testing.expectEqual(@as(usize, 2), probe.clock_reads); // init + initial line
    try std.testing.expectEqual(@as(usize, 1), probe.snapshot_reads);
    probe.seconds = 102;
    hook.report(.{ .current = 2000, .total = 5000, .bytes = 200000, .resources = 2000 });
    probe.seconds = 104;
    hook.report(.{ .current = 2001, .total = 5000, .bytes = 200000 + progress.byte_interval, .resources = 2001 });
    probe.seconds = 105;
    hook.report(.{ .current = 5000, .total = 5000, .bytes = 300 * mib, .resources = 5000 });
    reporter.finish(.{ .current = 5000, .total = 5000, .bytes = 300 * mib, .resources = 5000 });
    try std.testing.expectEqual(@as(usize, 4), probe.lines());
    try std.testing.expectEqual(@as(usize, 4), probe.snapshot_reads);
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.used], "mib_per_s=60.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.used], "alloc_peak=1234567 stack_high_water=76543 stack_available=true complete=true") != null);
}

test "progress zero time and maximal byte counters have exact bounded rates" {
    try std.testing.expectEqual(@as(u64, 0), progress.rateMilli(mib, 0));
    try std.testing.expectEqual(@as(u64, 250), progress.rateMilli(mib / 2, 2));
    try std.testing.expectEqual(@as(u64, 17592186044415999), progress.rateMilli(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(@as(u64, 0), progress.rateMilli(std.math.maxInt(u64), std.math.maxInt(u64)));
    var probe: Probe = .{};
    var log = probe.logger(); log.telemetry_fn = null;
    try std.testing.expectEqual(p.Telemetry{}, log.telemetry());
    var reporter = progress.Reporter.init(log, "empty");
    reporter.finish(.{ .current = 0, .total = 0, .bytes = 0, .resources = 0 });
    reporter.finish(.{ .current = 0, .total = 0, .bytes = 0, .resources = 0 });
    try std.testing.expectEqual(@as(usize, 1), probe.lines());
    try std.testing.expect(std.mem.indexOf(u8, probe.text[0..probe.used], "blockio_calls=0 blockio_bytes=0 io_calls=0 io_bytes=0 io_kind=unavailable") != null);
}

test "progress Disk counters count attempted IO, preserve errors and saturate" {
    const Backend = struct {
        fail: bool = false,
        fn read(ctx: *anyopaque, _: u64, _: []u8) p.Error!void { if ((@as(*@This(), @ptrCast(@alignCast(ctx)))).fail) return error.Io; }
        fn write(_: *anyopaque, _: u64, _: []const u8) p.Error!void { return error.Unsupported; }
        fn flush(_: *anyopaque) p.Error!void { return error.Io; }
    };
    var backend: Backend = .{}; var counters: p.IoCounters = .{};
    const disk: p.Disk = .{ .context = &backend, .sectors = 1, .read_fn = Backend.read, .write_fn = Backend.write, .flush_fn = Backend.flush, .counters = &counters };
    var buffer: [8]u8 = undefined;
    try disk.read(0, &buffer);
    try disk.read(0, buffer[0..0]);
    try std.testing.expectError(error.Bounds, disk.read(510, &buffer));
    backend.fail = true;
    try std.testing.expectError(error.Io, disk.read(0, &buffer));
    try std.testing.expectError(error.Unsupported, disk.write(0, &buffer));
    try std.testing.expectError(error.Io, disk.flush());
    try std.testing.expectEqual(@as(u64, 2), counters.read_calls);
    try std.testing.expectEqual(@as(u64, 16), counters.read_bytes);
    try std.testing.expectEqual(@as(u64, 1), counters.write_calls);
    try std.testing.expectEqual(@as(u64, 1), counters.flush_calls);
    try std.testing.expectEqual(@as(u64, 3), counters.failed_calls);
    try std.testing.expectEqual(@as(u64, 4), counters.calls());
    counters.read_calls = std.math.maxInt(u64); counters.read_bytes = std.math.maxInt(u64);
    counters.read(100);
    try std.testing.expectEqual(std.math.maxInt(u64), counters.calls());
    try std.testing.expectEqual(std.math.maxInt(u64), counters.bytes());
}

test "progress blank scan reports validated bytes and never changes the target" {
    const Backend = struct {
        poison: ?u64 = null,
        writes: usize = 0,
        fn read(ctx: *anyopaque, at: u64, out: []u8) p.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx)); @memset(out, 0);
            if (self.poison) |bad| if (at <= bad and bad - at < out.len) { out[@intCast(bad - at)] = 1; };
        }
        fn write(ctx: *anyopaque, _: u64, _: []const u8) p.Error!void { const self: *@This() = @ptrCast(@alignCast(ctx)); self.writes += 1; }
        fn flush(_: *anyopaque) p.Error!void {}
    };
    var probe: Probe = .{}; var backend: Backend = .{};
    var reporter = progress.Reporter.init(probe.logger(), "blank-scan");
    const disk: p.Disk = .{ .context = &backend, .sectors = 300 * mib / 512, .read_fn = Backend.read, .write_fn = Backend.write, .flush_fn = Backend.flush, .counters = &probe.io };
    var scratch: [65536]u8 = undefined;
    const selection: layout.Selection = .{ .explicit = true, .source_identity = 1, .target_identity = 2, .boot_identity = 3, .progress = reporter.sink() };
    try layout.requireBlank(disk, selection, &scratch);
    try std.testing.expectEqual(@as(usize, 3), probe.lines()); // initial,256MiB,EOF
    try std.testing.expectEqual(@as(u64, 300 * mib), probe.io.read_bytes);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
    var failed: Probe = .{}; var failed_reporter = progress.Reporter.init(failed.logger(), "blank-failure");
    var bad = selection; bad.progress = failed_reporter.sink(); backend.poison = 17;
    try std.testing.expectError(error.TargetNotBlank, layout.requireBlank(disk, bad, &scratch));
    try std.testing.expectEqual(@as(usize, 1), failed.lines());
    try std.testing.expect(!failed_reporter.complete);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}
