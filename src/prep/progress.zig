//! Bounded guest telemetry; callback invocations do not perform host polling.
//! SPDX-License-Identifier: GPL-3.0-or-later
const p = @import("platform.zig");
const app = @import("app.zig");
const profiling = @import("profiling.zig");
pub const byte_interval: u64 = 256 * 1024 * 1024;
pub const resource_interval: u64 = 2000;

pub const Reporter = struct {
    log: app.Logger,
    stage: []const u8,
    started: u64,
    last_bytes: u64 = 0,
    last_resources: u64 = 0,
    emitted: bool = false,
    complete: bool = false,
    files_start: u64 = 0,
    pub fn init(log: app.Logger, stage: []const u8) Reporter {
        return .{ .log = log, .stage = stage, .started = log.now(), .files_start = if (log.profiler) |pr| pr.snapshot().files else 0 };
    }
    pub fn sink(self: *Reporter) p.Progress { return .{ .context = self, .report_fn = callback }; }
    fn callback(ctx: *anyopaque, update: p.ProgressUpdate) void {
        const self: *Reporter = @ptrCast(@alignCast(ctx));
        self.report(update);
    }
    pub fn report(self: *Reporter, update: p.ProgressUpdate) void {
        if (self.complete) return;
        const end = update.total != 0 and update.current >= update.total;
        if (self.emitted and !end and update.bytes -| self.last_bytes < byte_interval and
            update.resources -| self.last_resources < resource_interval) return;
        self.emit(update, end);
    }
    /// Allows an explicit terminal report for an empty phase, or when a
    /// caller's total is discovered only at the end. Does not repeat EOF.
    pub fn finish(self: *Reporter, update: p.ProgressUpdate) void {
        if (!self.complete) self.emit(update, true);
    }
    fn emit(self: *Reporter, update: p.ProgressUpdate, end: bool) void {
        const seconds = self.log.now() -| self.started;
        const speed = rateMilli(update.bytes, seconds);
        const stats = self.log.telemetry();
        const block = stats.io_kind == .block_io;
        self.log.say("PROGRESS_IO stage={s} monotonic_ms={?d} target_calls={d} target_reads={d} target_writes={d} target_flushes={d} target_bytes={d}\n", .{self.stage, stats.monotonic_ms, stats.target_io.calls(), stats.target_io.read_calls, stats.target_io.write_calls, stats.target_io.flush_calls, stats.target_io.bytes()});
        self.log.say("PROGRESS stage={s} seconds={d} current={d} total={d} bytes={d} resources={d} mib_per_s={d}.{d:0>3} blockio_calls={d} blockio_bytes={d} io_calls={d} io_bytes={d} io_kind={s} alloc_peak={d} stack_high_water={d} stack_available={any} complete={any}\n", .{
            self.stage, seconds, update.current, update.total, update.bytes, update.resources,
            speed / 1000, speed % 1000, if (block) stats.io.calls() else 0, if (block) stats.io.bytes() else 0,
            stats.io.calls(), stats.io.bytes(), @tagName(stats.io_kind), stats.alloc_peak,
            stats.stack_high_water, stats.stack_available, end,
        });
        if (self.log.profiler) |pr| {
            const snapshot = pr.snapshot();
            const valid = snapshot.available and snapshot.invalid_samples == 0 and snapshot.nesting_errors == 0 and snapshot.depth_overflows == 0;
            const files = snapshot.files -| self.files_start;
            self.log.say("PROGRESS_TIME stage={s} clock={s} valid={any} files={d} files_per_s_milli={d} decode_ms={?d} sha_ms={?d} source_io_ms={?d} target_io_ms={?d} mft_ms={?d} index_ms={?d} clock_reads={d} invalid={d} nesting_errors={d} depth_overflows={d} target_calls={d} scope=cumulative_exclusive rate_basis=rtc_seconds\n", .{
                self.stage, snapshot.clock_name, valid, files, if (seconds == 0) 0 else files *| 1000 / seconds,
                categoryMs(snapshot, .decode, valid), categoryMs(snapshot, .sha, valid), categoryMs(snapshot, .source_io, valid),
                categoryMs(snapshot, .target_io, valid), categoryMs(snapshot, .mft, valid), categoryMs(snapshot, .index, valid),
                snapshot.clock_reads, snapshot.invalid_samples, snapshot.nesting_errors, snapshot.depth_overflows, snapshot.counters[@intFromEnum(profiling.Category.target_io)].measured,
            });
        }
        self.last_bytes = update.bytes;
        self.last_resources = update.resources;
        self.emitted = true;
        self.complete = end;
        if (self.log.progress_fn) |observe| observe(self.log.context, self.stage, update);
    }
};
fn categoryMs(snapshot: profiling.Snapshot, category: profiling.Category, valid: bool) ?u64 {
    if (!valid) return null;
    return profiling.milliseconds(snapshot.counters[@intFromEnum(category)].exclusive_ticks, snapshot.frequency_hz);
}
pub fn rateMilli(bytes: u64, seconds: u64) u64 {
    if (seconds == 0) return 0;
    // Split the MiB quotient/remainder before scaling. Both products fit
    // u64 for every byte count, preserving exact integer milli-MiB/s without
    // introducing a 128-bit divide helper in the i486 firmware.
    const mib: u64 = 1024 * 1024;
    return ((bytes / mib) * 1000 + ((bytes % mib) * 1000) / mib) / seconds;
}

test { _ = @import("progress_tests.zig"); }
