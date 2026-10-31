//! Optional nested timing using an already extended monotonic platform clock.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
pub const Category = enum { decode, sha, source_io, target_io, mft, index };
pub const category_count = @typeInfo(Category).@"enum".fields.len;
pub const max_depth = 16;
pub const Clock = struct {
    context: *anyopaque,
    /// Returns an extended monotonic tick, or null when unavailable/ambiguous.
    /// Raw wrapping PM/TSC values are not accepted as monotonic timestamps.
    read_fn: *const fn (*anyopaque) ?u64,
    frequency_hz: u64,
    name: []const u8,
};
pub const Counter = struct {
    calls: u64 = 0,
    measured: u64 = 0,
    invalid: u64 = 0,
    inclusive_ticks: u64 = 0,
    exclusive_ticks: u64 = 0,
};
pub const Token = struct { depth: usize = 0, serial: u64 = 0, active: bool = false };
const Frame = struct { category: Category, serial: u64, start: ?u64, children: u64 = 0, invalid: bool = false };
pub const Snapshot = struct {
    available: bool,
    clock_name: []const u8,
    frequency_hz: u64,
    counters: [category_count]Counter,
    clock_reads: u64,
    invalid_samples: u64,
    nonmonotonic: bool,
    nesting_errors: u64,
    depth_overflows: u64,
    files: u64,
    elapsed_ticks: ?u64,
};
pub const Profiler = struct {
    clock: ?Clock,
    counters: [category_count]Counter = @splat(.{}),
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,
    serial: u64 = 0,
    clock_reads: u64 = 0,
    invalid_samples: u64 = 0,
    nonmonotonic: bool = false,
    nesting_errors: u64 = 0,
    depth_overflows: u64 = 0,
    files: u64 = 0,
    last: ?u64 = null,
    first: ?u64 = null,
    available: bool = false,

    pub fn init(clock: ?Clock) Profiler {
        if (clock) |source| {
            if (source.frequency_hz == 0 or source.frequency_hz > std.math.maxInt(u64) / 1000 or source.name.len == 0) return .{ .clock = null, .invalid_samples = 1 };
        }
        return .{ .clock = clock };
    }
    fn sample(self: *Profiler) ?u64 {
        if (self.nonmonotonic) return null;
        const clock = self.clock orelse return null;
        self.clock_reads +|= 1;
        const tick = clock.read_fn(clock.context) orelse {
            self.invalid_samples +|= 1;
            self.available = false;
            return null;
        };
        if (self.last) |last| if (tick < last) {
            // A provider which forgot to extend a wrapping clock must never
            // turn the wrap into a huge positive interval or fictional zero.
            self.invalid_samples +|= 1;
            self.nonmonotonic = true;
            self.available = false;
            return null;
        };
        self.last = tick;
        if (self.first == null) self.first = tick;
        self.available = true;
        return tick;
    }
    pub fn begin(self: *Profiler, category: Category) Token {
        const counter = &self.counters[@intFromEnum(category)];
        counter.calls +|= 1;
        if (self.clock == null or self.nonmonotonic) {
            counter.invalid +|= 1;
            return .{};
        }
        if (self.depth == max_depth) {
            self.depth_overflows +|= 1;
            counter.invalid +|= 1;
            // Unknown child time makes its ancestors' exclusive time unknown.
            for (self.stack[0..self.depth]) |*frame| frame.invalid = true;
            return .{};
        }
        self.serial +%= 1;
        const token: Token = .{ .depth = self.depth, .serial = self.serial, .active = true };
        self.stack[self.depth] = .{ .category = category, .serial = token.serial, .start = self.sample() };
        self.depth += 1;
        return token;
    }
    pub fn end(self: *Profiler, token: Token) void {
        if (!token.active) return;
        if (self.depth == 0 or token.depth != self.depth - 1 or self.stack[token.depth].serial != token.serial) {
            self.nesting_errors +|= 1;
            for (self.stack[0..self.depth]) |frame| self.counters[@intFromEnum(frame.category)].invalid +|= 1;
            self.depth = 0;
            return;
        }
        const frame = self.stack[token.depth];
        self.depth -= 1;
        const counter = &self.counters[@intFromEnum(frame.category)];
        const finish = self.sample();
        if (frame.invalid or frame.start == null or finish == null or finish.? < frame.start.? or finish.? - frame.start.? < frame.children) {
            counter.invalid +|= 1;
            if (self.depth != 0) self.stack[self.depth - 1].invalid = true;
            return;
        }
        const elapsed = finish.? - frame.start.?;
        counter.measured +|= 1;
        counter.inclusive_ticks +|= elapsed;
        counter.exclusive_ticks +|= elapsed - frame.children;
        if (self.depth != 0) self.stack[self.depth - 1].children +|= elapsed;
    }
    pub fn filesDone(self: *Profiler, count: u64) void { self.files +|= count; }
    /// Optional phase-boundary sample. snapshot itself performs no clock IO.
    pub fn now(self: *Profiler) ?u64 { return self.sample(); }
    pub fn snapshot(self: *const Profiler) Snapshot {
        return .{ .available = self.available and !self.nonmonotonic, .clock_name = if (self.clock) |clock| clock.name else "unavailable",
            .frequency_hz = if (self.clock) |clock| clock.frequency_hz else 0, .counters = self.counters, .clock_reads = self.clock_reads,
            .invalid_samples = self.invalid_samples, .nonmonotonic = self.nonmonotonic, .nesting_errors = self.nesting_errors,
            .depth_overflows = self.depth_overflows, .files = self.files,
            .elapsed_ticks = if (self.available and !self.nonmonotonic and self.invalid_samples == 0 and self.first != null and self.last != null) self.last.? - self.first.? else null };
    }
};
/// Unit conversion without u128 divide helpers on i486. Overflow saturates.
pub fn milliseconds(ticks: u64, frequency_hz: u64) ?u64 {
    if (frequency_hz == 0 or frequency_hz > std.math.maxInt(u64) / 1000) return null;
    const whole = ticks / frequency_hz;
    const fraction = ticks % frequency_hz;
    if (whole > std.math.maxInt(u64) / 1000) return std.math.maxInt(u64);
    return whole * 1000 +| fraction * 1000 / frequency_hz;
}
test { _ = @import("profiling_tests.zig"); }
