// AMD APM vol.2, Extended Fixed-Range MTRR Type-Field Encodings:
// SYS_CFG bit19 exposes RdMem/WrMem; byte bits4/3 route accesses to DRAM.
// Scoped workaround for the measured bare-metal Vermeer CPUID 00a20f12.
// Never alter cache types, other legacy ranges, BIOS flash or NVRAM.
const std = @import("std");
const uefi = std.os.uefi;
const probe = @import("windows7_uefi_memory_probe.zig");
const trace = @import("windows7_uefi_trace.zig");
const cc = uefi.cc;
const syscfg_msr = 0xc0010010;
const modify: u64 = 1 << 19;
const ram_route: u64 = 0x1818181818181818;
const CpuInfo = extern struct {
    id: u64,
    flags: u32,
    package: u32,
    core: u32,
    thread: u32,
    extended: [6]u32 = .{0} ** 6,
};
const Procedure = *const fn (?*anyopaque) callconv(cc) void;
const Mp = extern struct {
    getNumber: *const fn (*Mp, *usize, *usize) callconv(cc) uefi.Status,
    getInfo: *const fn (*Mp, usize, *CpuInfo) callconv(cc) uefi.Status,
    startupAll: *const anyopaque,
    startupThis: *const fn (*Mp, Procedure, usize, ?uefi.Event, usize, ?*anyopaque, ?*bool) callconv(cc) uefi.Status,
    switchBsp: *const anyopaque,
    enableDisable: *const anyopaque,
    whoAmI: *const fn (*Mp, *usize) callconv(cc) uefi.Status,
    pub const guid = uefi.Guid{ .time_low = 0x3fdda605, .time_mid = 0xa76e, .time_high_and_version = 0x4f46, .clock_seq_high_and_reserved = 0xad, .clock_seq_low = 0x29, .node = .{ 0x12, 0xf4, 0x53, 0x1b, 0x3d, 0x08 } };
};
const State = struct { syscfg: u64 = 0, def: u64 = 0, c0: u64 = 0, c8: u64 = 0 };
const Action = enum { capture, apply, restore };
const Work = struct { state: State = .{}, action: Action = .capture, ok: bool = false };
var map_buffer: [65536]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

fn supported() bool {
    const f = probe.cpuid(1);
    return probe.amdSyscfgSupported(probe.cpuid(0), f) and f.a == 0x00a20f12 and (f.d & (1 << 12)) != 0;
}
fn acceptable(s: State) bool {
    // Only the measured UC/non-DRAM legacy window. No global enable changes.
    return s.syscfg & (modify | (1 << 18)) == (1 << 18) and s.def == 0xc00 and s.c0 == 0 and s.c8 == 0;
}
fn wrmsr(index: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [index] "{ecx}" (index),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{ .memory = true });
}
fn flagsAndCli() usize {
    return asm volatile ("pushfq; popq %[flags]; cli"
        : [flags] "=r" (-> usize),
        :
        : .{ .memory = true });
}
fn restoreInterrupts(flags: usize) void {
    if (flags & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
}
fn capture() State {
    const flags = flagsAndCli();
    defer restoreInterrupts(flags);
    const sys = probe.rdmsr(syscfg_msr);
    wrmsr(syscfg_msr, sys | modify);
    const result = State{ .syscfg = sys, .def = probe.rdmsr(0x2ff), .c0 = probe.rdmsr(0x268), .c8 = probe.rdmsr(0x269) };
    wrmsr(syscfg_msr, sys);
    return result;
}
fn setRouting(s: State, c0: u64, c8: u64) bool {
    const flags = flagsAndCli();
    defer restoreInterrupts(flags);
    const cr0 = asm volatile ("movq %%cr0, %[v]"
        : [v] "=r" (-> usize),
    );
    const cr4 = asm volatile ("movq %%cr4, %[v]"
        : [v] "=r" (-> usize),
    );
    const cr3 = asm volatile ("movq %%cr3, %[v]"
        : [v] "=r" (-> usize),
    );
    // Quiesce local caches and translations while changing the routing of UC pages.
    // MP callbacks run serially; nobody accesses C0000 until all CPUs are done.
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" ((cr0 | (1 << 30)) & ~@as(usize, 1 << 29)),
        : .{ .memory = true });
    asm volatile ("wbinvd" ::: .{ .memory = true });
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (cr4 & ~@as(usize, 1 << 7)),
        : .{ .memory = true });
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (cr3),
        : .{ .memory = true });
    wrmsr(0x2ff, s.def & ~@as(u64, 1 << 11));
    wrmsr(syscfg_msr, s.syscfg | modify);
    wrmsr(0x268, c0);
    wrmsr(0x269, c8);
    const ok = probe.rdmsr(0x268) == c0 and probe.rdmsr(0x269) == c8;
    wrmsr(syscfg_msr, s.syscfg);
    wrmsr(0x2ff, s.def);
    asm volatile ("wbinvd" ::: .{ .memory = true });
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (cr3),
        : .{ .memory = true });
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (cr4),
        : .{ .memory = true });
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (cr0),
        : .{ .memory = true });
    return ok and probe.rdmsr(syscfg_msr) == s.syscfg and probe.rdmsr(0x2ff) == s.def;
}
fn worker(argument: ?*anyopaque) callconv(cc) void {
    const work: *Work = @ptrCast(@alignCast(argument.?));
    work.ok = false;
    if (!supported() or probe.rdmsr(0xfe) & (1 << 8) == 0) return;
    switch (work.action) {
        .capture => {
            work.state = capture();
            work.ok = acceptable(work.state);
        },
        .apply => {
            const current = capture();
            if (current.syscfg != work.state.syscfg or current.def != work.state.def) return;
            // SMT siblings may share fixed MTRRs. Accept the already-applied state.
            if (current.c0 == ram_route and current.c8 == ram_route) {
                work.ok = true;
                return;
            }
            if (current.c0 != work.state.c0 or current.c8 != work.state.c8) return;
            work.ok = setRouting(work.state, ram_route, ram_route);
        },
        .restore => {
            work.ok = setRouting(work.state, work.state.c0, work.state.c8);
        },
    }
}
fn dispatch(mp: *Mp, index: usize, bsp: usize, work: *Work) bool {
    if (index == bsp) worker(work) else if (mp.startupThis(mp, worker, index, null, 0, work, null) != .success) return false;
    return work.ok;
}
fn reservedRegion() bool {
    const bs = uefi.system_table.boot_services orelse return false;
    const map = bs.getMemoryMap(&map_buffer) catch return false;
    // Every page must be reserved, non-runtime, not live firmware allocation.
    for (0..16) |page| {
        const addr: u64 = 0xc0000 + page * 4096;
        var it = map.iterator();
        var found = false;
        while (it.next()) |entry| {
            if (entry.physical_start <= addr and (addr - entry.physical_start) / 4096 < entry.number_of_pages) {
                if (@intFromEnum(entry.type) != 0 or entry.attribute.memory_runtime) return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    for (0..0x10000) |i| if (@as(*volatile u8, @ptrFromInt(0xc0000 + i)).* != 0xff) return false;
    return true;
}
fn writableRegion() bool {
    for (0..16) |page| {
        const p: *volatile u8 = @ptrFromInt(0xc0000 + page * 4096);
        const old = p.*;
        const wanted = old ^ 0xa5;
        p.* = wanted;
        const written = p.* == wanted;
        p.* = old;
        if (!written or p.* != old) return false;
    }
    return true;
}
const Transition = enum { passed, failed_restored, failed_rollback };
fn transition(backend: anytype, active: []const bool) Transition {
    var success = true;
    for (active, 0..) |enabled, i| {
        if (enabled and !backend.apply(i)) {
            success = false;
            break;
        }
    }
    if (success) success = backend.verify();
    if (success) return .passed;
    var restored = true;
    for (active, 0..) |enabled, i| {
        if (enabled and !backend.restore(i)) restored = false;
    }
    return if (restored) .failed_restored else .failed_rollback;
}
const Hardware = struct {
    mp: *Mp,
    bsp: usize,
    states: []Work,
    fn apply(self: *@This(), index: usize) bool {
        self.states[index].action = .apply;
        return dispatch(self.mp, index, self.bsp, &self.states[index]);
    }
    fn restore(self: *@This(), index: usize) bool {
        self.states[index].action = .restore;
        return dispatch(self.mp, index, self.bsp, &self.states[index]);
    }
    fn verify(_: *@This()) bool {
        return writableRegion();
    }
};
pub fn prepare(device: uefi.Handle, directory: []const u16) !void {
    if (!supported()) return;
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const filename = std.unicode.utf8ToUtf16LeStringLiteral("usos-amd-shadow.log");
    if ((try bs.locateProtocol(probe.LegacyRegion, null)) != null or (try bs.locateProtocol(probe.LegacyRegion2, null)) != null) {
        trace.recordNamed(device, directory, filename, "SKIPPED: firmware provides a LegacyRegion protocol; use standard UefiSeven path");
        return;
    }
    if (@as(*volatile u32, @ptrFromInt(0x40)).* != 0 or !reservedRegion()) {
        trace.recordNamed(device, directory, filename, "SKIPPED: legacy region not empty/reserved, or Int10 already present");
        return;
    }
    const mp = (try bs.locateProtocol(Mp, null)) orelse {
        trace.recordNamed(device, directory, filename, "STOP: AMD workaround requires MP Services");
        return error.NoMpServices;
    };
    var count: usize = 0;
    var enabled: usize = 0;
    var bsp: usize = 0;
    if (mp.getNumber(mp, &count, &enabled) != .success or mp.whoAmI(mp, &bsp) != .success or count > 64 or count == 0 or bsp >= count) return error.InvalidCpuTopology;
    var active = [_]bool{false} ** 64;
    var state = [_]Work{.{}} ** 64;
    var seen: usize = 0;
    for (0..count) |i| {
        var info: CpuInfo = undefined;
        if (mp.getInfo(mp, i, &info) != .success) return error.CpuInfoFailed;
        active[i] = info.flags & 2 != 0;
        if (!active[i]) continue;
        seen += 1;
        if (!dispatch(mp, i, bsp, &state[i])) {
            var buf: [400]u8 = undefined;
            const s = state[i].state;
            const msg = try std.fmt.bufPrint(&buf, "STOP: unsupported CPU state cpu={d} SYS_CFG={x} DEF={x} C0={x:0>16} C8={x:0>16}; routing unchanged", .{ i, s.syscfg, s.def, s.c0, s.c8 });
            trace.recordNamed(device, directory, filename, msg);
            return error.UnsupportedAmdMemoryState;
        }
    }
    if (seen != enabled or !active[bsp]) return error.InvalidCpuTopology;
    trace.recordNamed(device, directory, filename, "BEGIN: captured all enabled CPUs; enabling DRAM read/write only at C0000-CFFFF");
    var hardware = Hardware{ .mp = mp, .bsp = bsp, .states = state[0..count] };
    const outcome = transition(&hardware, active[0..count]);
    if (outcome != .passed) {
        trace.recordNamed(device, directory, filename, if (outcome == .failed_restored) "FAIL: DRAM routing/write verification failed; all CPU registers restored; Windows not started" else "FAIL: CPU register rollback incomplete; reboot required; Windows not started");
        return error.AmdShadowFailed;
    }
    var buf: [400]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "PASS: enabled DRAM routing on {d} CPUs; C0/C8=1818181818181818; SYS_CFG restored; all 16 pages write/read/restore verified; continuing to UefiSeven", .{enabled});
    trace.recordNamed(device, directory, filename, msg);
}
const Fake = struct {
    fail_cpu: ?usize = null,
    writable: bool = true,
    rollback_ok: bool = true,
    applied: u8 = 0,
    restored: u8 = 0,
    verified: bool = false,
    fn apply(self: *@This(), index: usize) bool {
        self.applied |= @as(u8, 1) << @intCast(index);
        return self.fail_cpu != index;
    }
    fn restore(self: *@This(), index: usize) bool {
        self.restored |= @as(u8, 1) << @intCast(index);
        return self.rollback_ok;
    }
    fn verify(self: *@This()) bool {
        self.verified = true;
        return self.writable;
    }
};
test "partial CPU update failure restores every enabled CPU and skips write probe" {
    var backend = Fake{ .fail_cpu = 2 };
    try std.testing.expectEqual(Transition.failed_restored, transition(&backend, &.{ true, false, true, true }));
    try std.testing.expectEqual(@as(u8, 5), backend.applied);
    try std.testing.expectEqual(@as(u8, 13), backend.restored);
    try std.testing.expect(!backend.verified);
}
test "failed memory verification restores all CPUs and reports rollback failure" {
    var backend = Fake{ .writable = false };
    try std.testing.expectEqual(Transition.failed_restored, transition(&backend, &.{ true, true }));
    try std.testing.expectEqual(@as(u8, 3), backend.restored);
    backend = .{ .writable = false, .rollback_ok = false };
    try std.testing.expectEqual(Transition.failed_rollback, transition(&backend, &.{ true, true }));
}
test "successful routing leaves disabled CPUs untouched and requires memory verification" {
    var backend = Fake{};
    try std.testing.expectEqual(Transition.passed, transition(&backend, &.{ true, false, true }));
    try std.testing.expectEqual(@as(u8, 5), backend.applied);
    try std.testing.expectEqual(@as(u8, 0), backend.restored);
    try std.testing.expect(backend.verified);
}
test "only measured non-DRAM UC mapping can be changed" {
    const measured = State{ .syscfg = 0x740000, .def = 0xc00, .c0 = 0, .c8 = 0 };
    try std.testing.expect(acceptable(measured));
    var s = measured;
    s.c0 = ram_route;
    try std.testing.expect(!acceptable(s));
    s = measured;
    s.c8 = 0x0505050505050505;
    try std.testing.expect(!acceptable(s));
    s = measured;
    s.syscfg &= ~@as(u64, 1 << 18);
    try std.testing.expect(!acceptable(s));
    s = measured;
    s.syscfg |= modify;
    try std.testing.expect(!acceptable(s));
    s = measured;
    s.def = 0x806;
    try std.testing.expect(!acceptable(s));
    for (0..8) |i| try std.testing.expectEqual(@as(u64, 0), (ram_route >> @as(u6, @intCast(i * 8))) & 7);
}
