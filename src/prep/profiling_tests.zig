//! Deterministic clocks; no hardware timer, sleeps, IO or global state.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("profiling.zig");
const Clock = struct {
    ticks: u64 = 0,
    valid: bool = true,
    calls: usize = 0,
    fn read(ctx: *anyopaque) ?u64 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return if (self.valid) self.ticks else null;
    }
    fn clock(self: *@This()) p.Clock { return .{ .context = self, .read_fn = read, .frequency_hz = 3579545, .name = "test-extended" }; }
};
fn count(snapshot: p.Snapshot, category: p.Category) p.Counter { return snapshot.counters[@intFromEnum(category)]; }

test "nested MFT source and SHA decoder scopes preserve inclusive and exclusive ticks" {
    var clock: Clock = .{};
    var profiler = p.Profiler.init(clock.clock());
    const mft = profiler.begin(.mft);
    clock.ticks = 10;
    const source = profiler.begin(.source_io);
    clock.ticks = 30; profiler.end(source);
    clock.ticks = 35;
    const sha = profiler.begin(.sha);
    clock.ticks = 40;
    const decode = profiler.begin(.decode);
    clock.ticks = 48; profiler.end(decode);
    clock.ticks = 55; profiler.end(sha);
    clock.ticks = 70; profiler.end(mft);
    profiler.filesDone(12);
    const stats = profiler.snapshot();
    try std.testing.expect(stats.available);
    try std.testing.expectEqual(@as(u64, 8), stats.clock_reads);
    try std.testing.expectEqual(@as(u64, 70), count(stats, .mft).inclusive_ticks);
    try std.testing.expectEqual(@as(u64, 30), count(stats, .mft).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 20), count(stats, .source_io).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 20), count(stats, .sha).inclusive_ticks);
    try std.testing.expectEqual(@as(u64, 12), count(stats, .sha).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 8), count(stats, .decode).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 12), stats.files);
    try std.testing.expectEqual(@as(?u64, 70), stats.elapsed_ticks);
    try std.testing.expectEqual(@as(u64, 1), count(stats, .mft).measured);
    try std.testing.expectEqual(@as(usize, 0), profiler.depth);
}

test "same category recursion and target IO do not double count exclusive time" {
    var clock: Clock = .{}; var profiler = p.Profiler.init(clock.clock());
    const outer = profiler.begin(.index); clock.ticks = 5;
    const inner = profiler.begin(.index); clock.ticks = 10;
    const target = profiler.begin(.target_io); clock.ticks = 20;
    profiler.end(target); clock.ticks = 30; profiler.end(inner); clock.ticks = 40; profiler.end(outer);
    const stats = profiler.snapshot();
    try std.testing.expectEqual(@as(u64, 65), count(stats, .index).inclusive_ticks);
    try std.testing.expectEqual(@as(u64, 30), count(stats, .index).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 10), count(stats, .target_io).exclusive_ticks);
    try std.testing.expectEqual(@as(u64, 2), count(stats, .index).calls);
}

test "absent null or invalid-frequency clock reports unavailable rather than measured zero" {
    var clock: Clock = .{ .valid = false };
    var profiler = p.Profiler.init(clock.clock());
    profiler.end(profiler.begin(.decode));
    var stats = profiler.snapshot();
    try std.testing.expect(!stats.available);
    try std.testing.expectEqual(@as(u64, 0), count(stats, .decode).measured);
    try std.testing.expectEqual(@as(u64, 1), count(stats, .decode).invalid);
    try std.testing.expectEqual(@as(u64, 2), stats.invalid_samples);
    var no_clock = p.Profiler.init(null); no_clock.end(no_clock.begin(.sha));
    stats = no_clock.snapshot();
    try std.testing.expect(!stats.available);
    try std.testing.expectEqualStrings("unavailable", stats.clock_name);
    try std.testing.expectEqual(@as(u64, 0), stats.clock_reads);
    var bad = clock.clock(); bad.frequency_hz = 0;
    var invalid = p.Profiler.init(bad); invalid.end(invalid.begin(.sha));
    try std.testing.expect(!invalid.snapshot().available);
    try std.testing.expectEqual(@as(u64, 0), invalid.snapshot().clock_reads);
}

test "raw24bit wrap invalidates timing while provider-extended ticks remain exact" {
    var clock: Clock = .{ .ticks = 0xfffffe }; var profiler = p.Profiler.init(clock.clock());
    const token = profiler.begin(.source_io); clock.ticks = 2; profiler.end(token);
    var stats = profiler.snapshot();
    try std.testing.expect(!stats.available); try std.testing.expect(stats.nonmonotonic);
    try std.testing.expectEqual(@as(u64, 0), count(stats, .source_io).measured);
    try std.testing.expectEqual(@as(u64, 1), count(stats, .source_io).invalid);
    var extended = p.Profiler.init(clock.clock()); clock.ticks = 0xfffffe;
    const good = extended.begin(.source_io); clock.ticks = 0x1000002; extended.end(good);
    stats = extended.snapshot(); try std.testing.expect(stats.available);
    try std.testing.expectEqual(@as(u64, 4), count(stats, .source_io).exclusive_ticks);
}

test "ambiguous child sample cannot fabricate parent exclusive time" {
    var clock: Clock = .{}; var profiler = p.Profiler.init(clock.clock());
    const outer = profiler.begin(.mft); clock.ticks = 5;
    const inner = profiler.begin(.target_io); clock.valid = false; profiler.end(inner);
    clock.valid = true; clock.ticks = 30; profiler.end(outer);
    const stats = profiler.snapshot();
    try std.testing.expectEqual(@as(u64, 0), count(stats, .mft).measured);
    try std.testing.expectEqual(@as(u64, 1), count(stats, .mft).invalid);
    try std.testing.expectEqual(@as(u64, 1), count(stats, .target_io).invalid);
}

test "nesting misuse and fixed-depth overflow are bounded and explicitly reported" {
    var clock: Clock = .{}; var profiler = p.Profiler.init(clock.clock());
    var tokens: [p.max_depth + 1]p.Token = undefined;
    for (&tokens) |*token| token.* = profiler.begin(.mft);
    try std.testing.expectEqual(@as(u64, 1), profiler.snapshot().depth_overflows);
    var i = tokens.len; while (i != 0) { i -= 1; clock.ticks += 1; profiler.end(tokens[i]); }
    try std.testing.expectEqual(@as(usize, 0), profiler.depth);
    try std.testing.expectEqual(@as(u64, 0), count(profiler.snapshot(), .mft).measured);
    try std.testing.expectEqual(@as(u64, p.max_depth + 1), count(profiler.snapshot(), .mft).invalid);
    const outer = profiler.begin(.sha); _ = profiler.begin(.index); profiler.end(outer);
    try std.testing.expectEqual(@as(u64, 1), profiler.snapshot().nesting_errors);
    try std.testing.expectEqual(@as(usize, 0), profiler.depth);
}

test "tick conversion is exact at PMtimer frequency and handles missing clock" {
    try std.testing.expectEqual(@as(?u64, 12345), p.milliseconds(3579545 * @as(u64, 12) + 3579545 * 345 / 1000 + 1, 3579545));
    try std.testing.expectEqual(@as(?u64, null), p.milliseconds(1, 0));
    try std.testing.expectEqual(@as(?u64, null), p.milliseconds(1, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), p.milliseconds(std.math.maxInt(u64), 1));
}

test "later invalid provider makes a previously measured snapshot explicitly unavailable" {
    var clock: Clock = .{}; var profiler = p.Profiler.init(clock.clock());
    const token = profiler.begin(.decode); clock.ticks = 100; profiler.end(token);
    try std.testing.expect(profiler.snapshot().available);
    try std.testing.expectEqual(@as(?u64, 100), profiler.snapshot().elapsed_ticks);
    clock.valid = false;
    try std.testing.expectEqual(@as(?u64, null), profiler.now());
    const stats = profiler.snapshot();
    try std.testing.expect(!stats.available);
    try std.testing.expectEqual(@as(?u64, null), stats.elapsed_ticks);
    // Earlier genuine measurements remain distinguishable from invalid data.
    try std.testing.expectEqual(@as(u64, 1), count(stats, .decode).measured);
    try std.testing.expectEqual(@as(u64, 100), count(stats, .decode).inclusive_ticks);
    try std.testing.expectEqual(@as(u64, 1), stats.invalid_samples);
}
