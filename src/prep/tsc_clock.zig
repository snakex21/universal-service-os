//! Optional, approximate TSC timing for aggregate firmware profiling.
//! SPDX-License-Identifier: GPL-3.0-or-later
//!
//! The PM timer is read only during one bounded startup calibration. Counter
//! deliberately does not retain its PM callback. RDTSC is not serializing:
//! these spans are approximate aggregate times, not instruction benchmarks.
//! No CPUID, PM port IO, SSE fence or RDTSCP occurs in the sampling path.
const std = @import("std");
const builtin = @import("builtin");

pub const pm_frequency: u32 = 3579545;
pub const Cpuid = struct { a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0 };
pub const Cpu = struct {
    context: *anyopaque,
    has_cpuid_fn: *const fn (*anyopaque) bool,
    cpuid_fn: *const fn (*anyopaque, u32, u32) Cpuid,
};
pub const Capabilities = struct { tsc: bool = false, invariant: bool = false };

/// Call once during startup. Unsupported leaves are never queried.
pub fn detect(cpu: Cpu) Capabilities {
    if (!cpu.has_cpuid_fn(cpu.context)) return .{};
    if (cpu.cpuid_fn(cpu.context, 0, 0).a < 1) return .{};
    if (cpu.cpuid_fn(cpu.context, 1, 0).d & (1 << 4) == 0) return .{};
    const extended = cpu.cpuid_fn(cpu.context, 0x80000000, 0).a;
    return .{ .tsc = true, .invariant = extended >= 0x80000007 and cpu.cpuid_fn(cpu.context, 0x80000007, 0).d & (1 << 8) != 0 };
}

fn hasCpuid(_: *anyopaque) bool {
    if (comptime builtin.cpu.arch == .x86_64) return true;
    if (comptime builtin.cpu.arch != .x86) return false;
    return asm volatile (
        \\pushfl
        \\popl %%eax
        \\movl %%eax, %%ecx
        \\xorl $0x200000, %%eax
        \\pushl %%eax
        \\popfl
        \\pushfl
        \\popl %%eax
        \\pushl %%ecx
        \\popfl
        \\xorl %%ecx, %%eax
        : [changed] "={eax}" (-> u32),
        :
        : .{ .ecx = true, .cc = true, .memory = true }) & 0x200000 != 0;
}
fn cpuLeaf(_: *anyopaque, leaf: u32, subleaf: u32) Cpuid {
    if (comptime builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) return .{};
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a), [b] "={ebx}" (b), [c] "={ecx}" (c), [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf), [subleaf] "{ecx}" (subleaf),
    );
    return .{ .a = a, .b = b, .c = c, .d = d };
}
var cpu_context: u8 = 0;
pub fn nativeCapabilities() Capabilities {
    return detect(.{ .context = &cpu_context, .has_cpuid_fn = hasCpuid, .cpuid_fn = cpuLeaf });
}

/// The local assembly guard must remain inside this noinline function. The
/// emitted-assembly audit allows only this exact guarded instruction block.
/// available is cached from startup detect(), never recomputed per sample.
pub noinline fn readGuarded(available: bool) ?u64 {
    if (comptime builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) return null;
    var low: u32 = undefined;
    var high: u32 = undefined;
    var ok: u32 = undefined;
    asm volatile (
        \\# USOS_TSC_GUARD_BEGIN readGuarded
        \\xorl %%ecx, %%ecx
        \\testb %%bl, %%bl
        \\jz 1f
        \\rdtsc
        \\movl $1, %%ecx
        \\1:
        \\# USOS_TSC_GUARD_END readGuarded
        : [low] "={eax}" (low), [high] "={edx}" (high), [ok] "={ecx}" (ok),
        : [available] "{bl}" (@as(u8, @intFromBool(available))),
        : .{ .cc = true, .memory = true });
    if (ok == 0) return null;
    return (@as(u64, high) << 32) | low;
}
pub fn nativeRead(_: *anyopaque, available: bool) ?u64 { return readGuarded(available); }

pub const Sources = struct {
    context: *anyopaque,
    tsc_fn: *const fn (*anyopaque, bool) ?u64,
    pm_fn: ?*const fn (*anyopaque) ?u32 = null,
    pm_width: u6 = 24,
};
pub const Options = struct {
    /// 50 ms default, 100 ms hard PM-time ceiling.
    target_pm_ticks: u32 = pm_frequency / 20,
    max_samples: u32 = 1000000,
    min_frequency_hz: u64 = 100000,
    max_frequency_hz: u64 = 20000000000,
    /// A longer unsampled pause invalidates timing, not installation.
    max_gap_seconds: u64 = 3600,
};
pub const Failure = enum {
    none, tsc_unavailable, pm_unavailable, coarse_unavailable, invalid_width,
    invalid_options, calibration_timeout, pm_jump, tsc_reversed, tsc_stalled,
    invalid_frequency, tsc_jump, coarse_reversed, drift,
};

/// floor(a*b/d), using checked u64 arithmetic only; never emits u128 division.
pub fn mulDiv(a: u64, b: u32, d: u32) ?u64 {
    if (d == 0) return null;
    const whole = std.math.mul(u64, a / d, b) catch return null;
    // (a%d) and b are each <=u32, so their product cannot overflow u64.
    const fraction = (a % d) * @as(u64, b) / d;
    return std.math.add(u64, whole, fraction) catch null;
}

pub const Counter = struct {
    context: *anyopaque,
    tsc_fn: *const fn (*anyopaque, bool) ?u64,
    valid: bool = false,
    failure: Failure = .tsc_unavailable,
    frequency_hz: u64 = 0,
    invariant: bool = false,
    origin: u64 = 0,
    previous: u64 = 0,
    coarse_start: u64 = 0,
    coarse_previous: u64 = 0,
    validated_tick: u64 = 0,
    max_gap_ticks: u64 = 0,

    pub fn init(capabilities: Capabilities, source: Sources, coarse: ?u64, options: Options) Counter {
        var result: Counter = .{ .context = source.context, .tsc_fn = source.tsc_fn, .invariant = capabilities.invariant };
        // No PM or TSC callback, or CPUID instruction, runs on this exit.
        if (!capabilities.tsc) return result;
        result.failure = .coarse_unavailable;
        const coarse_start = coarse orelse return result;
        result.failure = .pm_unavailable;
        const pm = source.pm_fn orelse return result;
        result.failure = .invalid_width;
        if (source.pm_width != 24 and source.pm_width != 32) return result;
        result.failure = .invalid_options;
        if (options.max_samples == 0 or options.max_samples > 1000000 or
            options.target_pm_ticks < pm_frequency / 20 or options.target_pm_ticks > pm_frequency / 10 or
            options.min_frequency_hz == 0 or options.min_frequency_hz > options.max_frequency_hz or
            options.max_frequency_hz > 100000000000 or options.max_gap_seconds == 0 or options.max_gap_seconds > 3600) return result;
        const mask: u32 = if (source.pm_width == 24) 0xffffff else 0xffffffff;
        result.failure = .pm_unavailable;
        var previous_pm = (pm(source.context) orelse return result) & mask;
        result.failure = .tsc_unavailable;
        const start = source.tsc_fn(source.context, true) orelse return result;
        var elapsed: u32 = 0;
        var samples: u32 = 0;
        while (elapsed < options.target_pm_ticks and samples < options.max_samples) : (samples += 1) {
            result.failure = .pm_unavailable;
            const now = (pm(source.context) orelse return result) & mask;
            const delta = (now -% previous_pm) & mask;
            result.failure = .pm_jump;
            // Also rejects reverse samples masquerading as a nearly full wrap.
            if (delta > pm_frequency / 10 or elapsed > pm_frequency / 10 - delta) return result;
            elapsed += delta;
            previous_pm = now;
        }
        result.failure = .calibration_timeout;
        if (elapsed < options.target_pm_ticks) return result;
        result.failure = .tsc_unavailable;
        const finish = source.tsc_fn(source.context, true) orelse return result;
        result.failure = .tsc_reversed;
        if (finish < start) return result;
        result.failure = .tsc_stalled;
        if (finish == start) return result;
        result.failure = .invalid_frequency;
        const hz = mulDiv(finish - start, pm_frequency, elapsed) orelse return result;
        if (hz < options.min_frequency_hz or hz > options.max_frequency_hz) return result;
        result.max_gap_ticks = std.math.mul(u64, hz, options.max_gap_seconds) catch return result;
        result.frequency_hz = hz;
        result.origin = finish;
        result.previous = finish;
        result.coarse_start = coarse_start;
        result.coarse_previous = coarse_start;
        result.validated_tick = 0;
        result.valid = true;
        result.failure = .none;
        return result;
    }
    fn invalidate(self: *Counter, failure: Failure) ?u64 {
        self.valid = false;
        self.failure = failure;
        return null;
    }
    /// Ticks since calibration. Equal adjacent samples are allowed; a stalled
    /// counter is detected against coarse time by validate() at PROGRESS only.
    pub fn read(self: *Counter) ?u64 {
        if (!self.valid) return null;
        const now = self.tsc_fn(self.context, true) orelse return self.invalidate(.tsc_unavailable);
        if (now < self.previous or now < self.origin) return self.invalidate(.tsc_reversed);
        if (now - self.previous > self.max_gap_ticks) return self.invalidate(.tsc_jump);
        self.previous = now;
        return now - self.origin;
    }
    pub fn clock(context: *anyopaque) ?u64 { return @as(*Counter, @ptrCast(@alignCast(context))).read(); }
    /// Only call at PROGRESS/phase boundaries. No PM callback is retained or
    /// invoked. Quantized RTC tolerance: 2 s +1% of each checked interval.
    /// A VM jump, drift, unavailable RTC or reversal permanently invalidates
    /// detailed timing; callers must report unavailable, never measured zero.
    pub fn validate(self: *Counter, coarse: ?u64) void {
        if (!self.valid) return;
        const wall = coarse orelse { _ = self.invalidate(.coarse_unavailable); return; };
        if (wall < self.coarse_previous or wall < self.coarse_start) { _ = self.invalidate(.coarse_reversed); return; }
        const tick = self.read() orelse return;
        const total_wall = wall - self.coarse_start;
        const step_wall = wall - self.coarse_previous;
        const total_tsc = tick / self.frequency_hz;
        const step_tsc = (tick - self.validated_tick) / self.frequency_hz;
        if (tick == self.validated_tick and step_wall > 2) { _ = self.invalidate(.tsc_stalled); return; }
        if (difference(total_wall, total_tsc) > 2 + total_wall / 100 or difference(step_wall, step_tsc) > 2 + step_wall / 100) {
            _ = self.invalidate(.drift);
            return;
        }
        self.coarse_previous = wall;
        self.validated_tick = tick;
    }
};
fn difference(a: u64, b: u64) u64 { return if (a >= b) a - b else b - a; }

const Fake = struct {
    pm_value: u32 = 0,
    pm_step: u32 = 100000,
    pm_reads: usize = 0,
    tsc_value: u64 = 1000,
    tsc_step: u64 = 100000000,
    tsc_reads: usize = 0,
    pm_available: bool = true,
    tsc_available: bool = true,
    fn pm(context: *anyopaque) ?u32 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.pm_reads += 1;
        if (!self.pm_available) return null;
        const value = self.pm_value;
        self.pm_value +%= self.pm_step;
        return value;
    }
    fn tsc(context: *anyopaque, available: bool) ?u64 {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.tsc_reads += 1;
        if (!available or !self.tsc_available) return null;
        const value = self.tsc_value;
        self.tsc_value +%= self.tsc_step;
        return value;
    }
    fn sources(self: *Fake) Sources { return .{ .context = self, .pm_fn = pm, .tsc_fn = tsc }; }
    fn counter(self: *Fake) Counter { return Counter.init(.{ .tsc = true, .invariant = true }, self.sources(), 100, .{}); }
};

test "TSC capability detection is bounded and never queries CPUID on 486" {
    const F = struct {
        cpuid: bool = false, maximum: u32 = 1, tsc: bool = true, extended: u32 = 0x80000007, invariant: bool = true,
        probes: usize = 0, calls: usize = 0,
        fn has(context: *anyopaque) bool { const self: *@This() = @ptrCast(@alignCast(context)); self.probes += 1; return self.cpuid; }
        fn leaf(context: *anyopaque, number: u32, _: u32) Cpuid {
            const self: *@This() = @ptrCast(@alignCast(context)); self.calls += 1;
            return switch (number) {
                0 => .{ .a = self.maximum }, 1 => .{ .d = if (self.tsc) 1 << 4 else 0 },
                0x80000000 => .{ .a = self.extended }, 0x80000007 => .{ .d = if (self.invariant) 1 << 8 else 0 }, else => unreachable,
            };
        }
        fn cpu(self: *@This()) Cpu { return .{ .context = self, .has_cpuid_fn = has, .cpuid_fn = leaf }; }
    };
    var f: F = .{};
    try std.testing.expectEqualDeep(Capabilities{}, detect(f.cpu()));
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.cpuid = true; f.maximum = 0;
    try std.testing.expect(!detect(f.cpu()).tsc);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    f.maximum = 1; f.tsc = false; f.calls = 0;
    try std.testing.expect(!detect(f.cpu()).tsc);
    try std.testing.expectEqual(@as(usize, 2), f.calls);
    f.tsc = true; f.extended = 0x80000000; f.calls = 0;
    try std.testing.expectEqualDeep(Capabilities{ .tsc = true }, detect(f.cpu()));
    try std.testing.expectEqual(@as(usize, 3), f.calls);
    f.extended = 0x80000007; f.calls = 0;
    try std.testing.expectEqualDeep(Capabilities{ .tsc = true, .invariant = true }, detect(f.cpu()));
    try std.testing.expectEqual(@as(usize, 4), f.calls);
}
test "one startup calibration has the expected frequency and no later PM reads" {
    var f: Fake = .{};
    var c = f.counter();
    try std.testing.expect(c.valid);
    try std.testing.expectEqual(@as(u64, 1789772500), c.frequency_hz);
    try std.testing.expectEqual(@as(usize, 3), f.pm_reads);
    try std.testing.expectEqual(@as(usize, 2), f.tsc_reads);
    f.tsc_step = 0;
    f.tsc_value = c.origin + c.frequency_hz;
    try std.testing.expectEqual(@as(?u64, c.frequency_hz), c.read());
    c.validate(101);
    try std.testing.expect(c.valid);
    try std.testing.expectEqual(@as(usize, 3), f.pm_reads);
    try std.testing.expectEqual(@as(?u64, c.frequency_hz), Counter.clock(&c));
}
test "24 and32 bit PM wraps calibrate without extending any timer afterward" {
    inline for (.{ @as(u6, 24), @as(u6, 32) }) |width| {
        var f: Fake = .{ .pm_value = if (width == 24) 0xffff00 else 0xffffff00 };
        var source = f.sources(); source.pm_width = width;
        const c = Counter.init(.{ .tsc = true }, source, 0, .{});
        try std.testing.expect(c.valid);
        try std.testing.expectEqual(@as(u64, 1789772500), c.frequency_hz);
    }
}
test "unavailable TSC does no PM calibration and all missing inputs fail closed" {
    var f: Fake = .{};
    var c = Counter.init(.{}, f.sources(), 100, .{});
    try std.testing.expectEqual(Failure.tsc_unavailable, c.failure);
    try std.testing.expectEqual(@as(usize, 0), f.pm_reads);
    try std.testing.expectEqual(@as(usize, 0), f.tsc_reads);
    try std.testing.expectEqual(@as(?u64, null), c.read());
    c = Counter.init(.{ .tsc = true }, f.sources(), null, .{});
    try std.testing.expectEqual(Failure.coarse_unavailable, c.failure);
    try std.testing.expectEqual(@as(usize, 0), f.pm_reads);
    var source = f.sources(); source.pm_fn = null;
    c = Counter.init(.{ .tsc = true }, source, 0, .{});
    try std.testing.expectEqual(Failure.pm_unavailable, c.failure);
    source = f.sources(); source.pm_width = 16;
    c = Counter.init(.{ .tsc = true }, source, 0, .{});
    try std.testing.expectEqual(Failure.invalid_width, c.failure);
    try std.testing.expectEqual(@as(usize, 0), f.pm_reads);
    f.pm_available = false; c = f.counter();
    try std.testing.expectEqual(Failure.pm_unavailable, c.failure);
    f.pm_available = true; f.tsc_available = false; c = f.counter();
    try std.testing.expectEqual(Failure.tsc_unavailable, c.failure);
}
test "PM stalled reversed and implausible jumps have bounded calibration failure" {
    var f: Fake = .{ .pm_step = 0 };
    var c = Counter.init(.{ .tsc = true }, f.sources(), 0, .{ .max_samples = 4 });
    try std.testing.expectEqual(Failure.calibration_timeout, c.failure);
    try std.testing.expectEqual(@as(usize, 5), f.pm_reads);
    try std.testing.expectEqual(@as(usize, 1), f.tsc_reads);
    f = .{ .pm_step = 0xffffffff }; c = f.counter();
    try std.testing.expectEqual(Failure.pm_jump, c.failure);
    f = .{ .pm_step = pm_frequency }; c = f.counter();
    try std.testing.expectEqual(Failure.pm_jump, c.failure);
    f = .{};
    c = Counter.init(.{ .tsc = true }, f.sources(), 0, .{ .max_samples = 0 });
    try std.testing.expectEqual(Failure.invalid_options, c.failure);
    try std.testing.expectEqual(@as(usize, 0), f.pm_reads);
}
test "stalled reversed and implausible TSC calibration fail without fake frequency" {
    var f: Fake = .{ .tsc_step = 0 };
    var c = f.counter();
    try std.testing.expectEqual(Failure.tsc_stalled, c.failure);
    f = .{ .tsc_value = std.math.maxInt(u64) - 1, .tsc_step = 100 }; c = f.counter();
    try std.testing.expectEqual(Failure.tsc_reversed, c.failure);
    f = .{ .tsc_step = 1 }; c = f.counter();
    try std.testing.expectEqual(Failure.invalid_frequency, c.failure);
    f = .{ .tsc_step = 1000000000000 }; c = f.counter();
    try std.testing.expectEqual(Failure.invalid_frequency, c.failure);
}
test "TSC read invalidates reversal disappearance and large jumps permanently" {
    var f: Fake = .{};
    var c = f.counter();
    f.tsc_value = c.origin - 1;
    try std.testing.expectEqual(@as(?u64, null), c.read());
    try std.testing.expectEqual(Failure.tsc_reversed, c.failure);
    f.tsc_value = c.origin + 1;
    try std.testing.expectEqual(@as(?u64, null), c.read());
    f = .{}; c = f.counter(); f.tsc_available = false;
    try std.testing.expectEqual(@as(?u64, null), c.read());
    try std.testing.expectEqual(Failure.tsc_unavailable, c.failure);
    f = .{}; c = f.counter(); f.tsc_value = c.origin + c.max_gap_ticks + 1;
    try std.testing.expectEqual(@as(?u64, null), c.read());
    try std.testing.expectEqual(Failure.tsc_jump, c.failure);
}
test "coarse validation catches cumulative and step drift reversal stall and missing clock" {
    var f: Fake = .{};
    var c = f.counter(); f.tsc_step = 0;
    f.tsc_value = c.origin + 10 * c.frequency_hz; c.validate(110);
    try std.testing.expect(c.valid);
    f.tsc_value = c.origin + 15 * c.frequency_hz; c.validate(111);
    try std.testing.expectEqual(Failure.drift, c.failure);
    f = .{}; c = f.counter(); c.validate(99);
    try std.testing.expectEqual(Failure.coarse_reversed, c.failure);
    f = .{}; c = f.counter(); c.validate(null);
    try std.testing.expectEqual(Failure.coarse_unavailable, c.failure);
    f = .{}; c = f.counter(); f.tsc_value = c.origin; f.tsc_step = 0; c.validate(103);
    try std.testing.expectEqual(Failure.tsc_stalled, c.failure);
    f = .{}; c = f.counter(); f.tsc_value = c.origin + 110 * c.frequency_hz; f.tsc_step = 0; c.validate(200);
    try std.testing.expectEqual(Failure.drift, c.failure);
}
test "mulDiv checks overflow and uses quotient remainder at full u64 range" {
    try std.testing.expectEqual(@as(?u64, null), mulDiv(1, 1, 0));
    try std.testing.expectEqual(@as(?u64, null), mulDiv(std.math.maxInt(u64), 2, 1));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), mulDiv(std.math.maxInt(u64), 7, 7));
    try std.testing.expectEqual(@as(?u64, 1789772500), mulDiv(100000000, pm_frequency, 200000));
    try std.testing.expectEqual(@as(?u64, 16), mulDiv(10, 5, 3));
}
