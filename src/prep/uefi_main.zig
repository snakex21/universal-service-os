//! SPDX-License-Identifier: GPL-3.0-or-later
//! Isolated QEMU-only prep executable. Never chooses the first writable disk.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const ntfs = @import("ntfs.zig");
const app = @import("app.zig");
const scale = @import("scale.zig");
const wim = @import("wim.zig");
const wim_app = @import("wim_app.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
const layout = @import("windows_layout.zig");
const install_app = @import("install_app.zig");
const optical = @import("optical.zig");
const optical_ntfs = @import("optical_ntfs.zig");
const perf_clock = @import("perf_clock.zig");
const tsc_clock = @import("tsc_clock.zig");
const profiling = @import("profiling.zig");
const writecombine = @import("writecombine.zig");
const W = std.unicode.utf8ToUtf16LeStringLiteral;
// Separate root client opts into provisioning at compile time. The default
// prep binary keeps its existing reachable code and config format.
const boot_only = if (@hasDecl(@import("root"), "prep_boot_only")) @import("root").prep_boot_only else false;
const reference_boot = if (@hasDecl(@import("root"), "prep_reference_boot")) @import("root").prep_reference_boot else false;
comptime {
    _ = @import("ia32_rt.zig");
}

const Workload = enum { stage1a, scale_firmware, scale_tree150k, wim, install };
const InstallSource = struct { bytes: u64, start: u64, size: u64, serial: u64, path: []const u8 };
const Config = struct { kind: partitions.Kind, sectors: u64, token: [64]u8, workload: Workload = .stage1a, wim_index: ?u32 = null, source: ?InstallSource = null, verify_scope: wim_app.VerifyScope = .selected, timing: bool = false, combine: bool = true, probe_items: ?u64 = null };

fn config(text: []const u8) !Config {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    if (!std.mem.eql(u8, lines.next() orelse return error.InvalidArgument, "USOSPREP_QEMU_ONLY")) return error.InvalidArgument;
    var kind: ?partitions.Kind = null;
    var sectors: ?u64 = null;
    var token: ?[64]u8 = null;
    var workload: ?Workload = null;
    var wim_index: ?u32 = null;
    var source_bytes: ?u64 = null;
    var source_start: ?u64 = null;
    var source_size: ?u64 = null;
    var source_serial: ?u64 = null;
    var source_path: ?[]const u8 = null;
    var verify_scope: ?wim_app.VerifyScope = null;
    var timing: ?bool = null;
    var combine: ?bool = null;
    var probe_items: ?u64 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "mode=")) {
            if (kind != null) return error.InvalidArgument;
            kind = std.meta.stringToEnum(partitions.Kind, line[5..]) orelse return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, line, "target_sectors=")) {
            if (sectors != null) return error.InvalidArgument;
            sectors = try std.fmt.parseInt(u64, line[15..], 10);
        } else if (std.mem.startsWith(u8, line, "token=")) {
            if (token != null or line.len != 70) return error.InvalidArgument;
            for (line[6..]) |c| if (!std.ascii.isHex(c)) return error.InvalidArgument;
            token = line[6..70].*;
        } else if (std.mem.startsWith(u8, line, "profile=")) {
            if (workload != null) return error.InvalidArgument;
            workload = if (std.mem.eql(u8, line[8..], "scale-firmware")) .scale_firmware else if (std.mem.eql(u8, line[8..], "scale-tree150k")) .scale_tree150k else if (std.mem.eql(u8, line[8..], "wim")) .wim else if (std.mem.eql(u8, line[8..], "install")) .install else return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, line, "wim_index=")) {
            if (wim_index != null) return error.InvalidArgument;
            wim_index = std.fmt.parseInt(u32, line[10..], 10) catch return error.InvalidArgument;
            if (wim_index.? == 0) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, line, "source_bytes=")) {
            if (source_bytes != null) return error.InvalidArgument;
            source_bytes = try std.fmt.parseInt(u64, line[13..], 10);
        } else if (std.mem.startsWith(u8, line, "source_start=")) {
            if (source_start != null) return error.InvalidArgument;
            source_start = try std.fmt.parseInt(u64, line[13..], 10);
        } else if (std.mem.startsWith(u8, line, "source_size=")) {
            if (source_size != null) return error.InvalidArgument;
            source_size = try std.fmt.parseInt(u64, line[12..], 10);
        } else if (std.mem.startsWith(u8, line, "source_serial=")) {
            if (source_serial != null) return error.InvalidArgument;
            source_serial = try std.fmt.parseInt(u64, line[14..], 16);
        } else if (std.mem.startsWith(u8, line, "verify_scope=")) {
            if (verify_scope != null) return error.InvalidArgument;
            verify_scope = std.meta.stringToEnum(wim_app.VerifyScope, line[13..]) orelse return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, line, "timing=")) {
            if (timing != null) return error.InvalidArgument;
            timing = try switchValue(line[7..]);
        } else if (std.mem.startsWith(u8, line, "combine=")) {
            if (combine != null) return error.InvalidArgument;
            combine = try switchValue(line[8..]);
        } else if (std.mem.startsWith(u8, line, "probe_items=")) {
            if (probe_items != null) return error.InvalidArgument;
            probe_items = std.fmt.parseInt(u64, line[12..], 10) catch return error.InvalidArgument;
            if (probe_items.? == 0 or probe_items.? > 1000000) return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, line, "source_iso=")) {
            if (source_path != null or line.len <= 11 or line.len > 1035) return error.InvalidArgument;
            source_path = line[11..];
        } else return error.InvalidArgument;
    }
    const selected = workload orelse .stage1a;
    if ((selected == .wim or selected == .install) != (wim_index != null)) return error.InvalidArgument;
    if (verify_scope != null and selected != .wim and selected != .install) return error.InvalidArgument;
    const any_source = source_bytes != null or source_start != null or source_size != null or source_serial != null or source_path != null;
    if ((selected == .install) != any_source) return error.InvalidArgument;
    const source: ?InstallSource = if (selected == .install) .{
        .bytes = source_bytes orelse return error.InvalidArgument,
        .start = source_start orelse return error.InvalidArgument,
        .size = source_size orelse return error.InvalidArgument,
        .serial = source_serial orelse return error.InvalidArgument,
        .path = source_path orelse return error.InvalidArgument,
    } else null;
    if (source) |src| {
        if (src.start < 512 or src.size < 4096 or src.serial == 0 or src.start > src.bytes or src.size > src.bytes - src.start) return error.InvalidArgument;
    }
    if ((timing != null or combine != null or probe_items != null) and selected != .install) return error.InvalidArgument;
    return .{ .kind = kind orelse return error.InvalidArgument, .sectors = sectors orelse return error.InvalidArgument, .token = token orelse return error.InvalidArgument, .workload = selected, .wim_index = wim_index, .source = source, .verify_scope = verify_scope orelse .selected, .timing = timing orelse false, .combine = combine orelse true, .probe_items = probe_items };
}
fn switchValue(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return error.InvalidArgument;
}

const Output = struct {
    qemu: bool = false,
    file: ?*uefi.protocol.File = null,
    serial: ?*uefi.protocol.SerialIo = null,
    failed: bool = false,
    tracker: ?*platform.TrackedAllocator = null,
    stack_bytes: usize = 0,
    stack: ?[]const u8 = null,
    profile: profiling.Profiler = profiling.Profiler.init(null),
    timer: ?tsc_clock.Counter = null,
    timer_config: ?perf_clock.Config = null,
    pm_reads: u64 = 0,
    timing: bool = false,
    probe_items: ?u64 = null,
    fn timerMemory(_: *anyopaque, at: u64, len: usize) ![]const u8 {
        // Only firmware-provided ACPI roots are passed here. Discovery bounds
        // every length, pointer, checksum and traversal before reading further.
        const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(at)));
        return ptr[0..len];
    }
    fn timerRaw(ctx: *anyopaque) ?u32 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        self.pm_reads +|= 1;
        return asm volatile ("inl %[port], %[value]" : [value] "={eax}" (-> u32) : [port] "{dx}" (self.timer_config.?.port));
    }
    fn timerRead(ctx: *anyopaque) ?u64 {
        const self: *Output = @ptrCast(@alignCast(ctx));
        return if (self.timer) |*timer| timer.read() else null;
    }
    fn initProfile(self: *Output) void {
        const caps = tsc_clock.nativeCapabilities();
        if (!caps.tsc) { self.logger().say("TIMING clock=unavailable reason=no_tsc pm_reads=0\n", .{}); return; }
        const coarse = checkedClock() orelse return;
        const system = uefi.system_table;
        if (system.number_of_table_entries > 256) return;
        for (system.configuration_table[0..system.number_of_table_entries]) |entry| {
            if (!entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid) and
                !entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) continue;
            const cfg = perf_clock.discover(.{ .context = self, .read_fn = timerMemory }, @intFromPtr(entry.vendor_table)) catch continue;
            self.timer_config = cfg;
            self.timer = tsc_clock.Counter.init(caps, .{.context = self, .tsc_fn = tsc_clock.nativeRead, .pm_fn = timerRaw, .pm_width = cfg.width}, coarse, .{});
            const timer = &self.timer.?;
            if (timer.valid and self.timing) self.profile = profiling.Profiler.init(.{ .context = self, .read_fn = timerRead, .frequency_hz = timer.frequency_hz, .name = "tsc-calibrated-approximate" });
            self.logger().say("TIMING clock=tsc-calibrated hz={d} valid={any} invariant={any} failure={s} pm_reads={d} profile_enabled={any} pm_after_calibration=forbidden\n", .{timer.frequency_hz, timer.valid, caps.invariant, @tagName(timer.failure), self.pm_reads, self.timing});
            return;
        }
    }
    fn emit(context: *anyopaque, text: []const u8) void {
        const self: *Output = @ptrCast(@alignCast(context));
        // E9 is a QEMU debug console, including firmware without SerialIo.
        if (self.qemu) for (text) |c| asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (c),
              [port] "{dx}" (@as(u16, 0xe9)),
        );
        if (self.serial) |serial| _ = serial.write(text) catch 0;
        if (uefi.system_table.con_out) |console| {
            var utf16: [2050:0]u16 = undefined;
            var n: usize = 0;
            for (text) |c| {
                if (n + 2 >= utf16.len) break;
                if (c == '\n') {
                    utf16[n] = '\r';
                    n += 1;
                }
                utf16[n] = c;
                n += 1;
            }
            utf16[n] = 0;
            _ = console.outputString(@ptrCast(&utf16)) catch false;
        }
        if (self.file) |file| {
            const n = file.write(text) catch {
                self.failed = true;
                return;
            };
            if (n != text.len) self.failed = true;
            file.flush() catch {
                self.failed = true;
            };
        }
    }
    fn clock(_: *anyopaque) u64 { return checkedClock() orelse 0; }
    fn checkedClock() ?u64 {
        const t = (uefi.system_table.runtime_services.getTime() catch return null)[0];
        if (t.year < 1970 or t.month < 1 or t.month > 12 or t.day < 1 or t.day > 31 or t.hour > 23 or t.minute > 59 or t.second > 60) return null;
        var days: u64 = 0;
        var year: u32 = 1970;
        while (year < t.year) : (year += 1) days += if (leap(year)) 366 else 365;
        const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: usize = 1;
        while (month < t.month and month <= 12) : (month += 1) days += month_days[month - 1] + @as(u64, if (month == 2 and leap(t.year)) 1 else 0);
        days += @as(u64, t.day) -| 1;
        return days * 86400 + @as(u64, t.hour) * 3600 + @as(u64, t.minute) * 60 + t.second;
    }
    fn leap(year: u32) bool {
        return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    }
    fn logger(self: *Output) app.Logger {
        return .{ .context = self, .write_fn = emit, .clock_fn = clock, .telemetry_fn = telemetry, .profiler = if (self.timing) &self.profile else null, .progress_fn = diagnosticBoundary };
    }
    fn diagnosticBoundary(ctx: *anyopaque, stage: []const u8, update: platform.ProgressUpdate) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        const limit = self.probe_items orelse return;
        if (!self.qemu or !std.mem.eql(u8, stage, "apply-selected") or update.current < limit) return;
        self.logger().say("TIMING_STOP pm_reads={d} clock_failure={s}\n", .{self.pm_reads, if (self.timer) |timer| @tagName(timer.failure) else "unavailable"});
        self.logger().say("DIAGNOSTIC_STOP current={d} incomplete=true not_installation_pass=true\n", .{update.current});
        asm volatile ("outl %[value], %[port]" :: [value] "{eax}" (@as(u32, 0x24)), [port] "{dx}" (@as(u16, 0xf4)));
    }
    fn telemetry(ctx: *anyopaque) platform.Telemetry {
        const self: *Output = @ptrCast(@alignCast(ctx));
        if (self.timer) |*timer| timer.validate(checkedClock());
        if (self.timing) _ = self.profile.now();
        var stats: platform.Telemetry = .{ .io = block_io_counts, .target_io = target_io_counts, .io_kind = .block_io, .alloc_peak = if (self.tracker) |t| t.peak else 0 };
        if (self.timer) |*timer| { if (timer.read()) |ticks| stats.monotonic_ms = profiling.milliseconds(ticks, timer.frequency_hz); }
        if (self.stack) |stack| {
            const painted: [*]const volatile u8 = stack.ptr;
            var untouched: usize = 0;
            while (untouched < stack.len and painted[untouched] == 0xa5) : (untouched += 1) {}
            stats.stack_available = true;
            stats.stack_high_water = stack.len - untouched;
        }
        return stats;
    }
};

// Counts actual source/target BlockIo calls, including bounce read-modify-write.
// File-protocol writes to the diagnostic log are outside this storage counter.
var block_io_counts: platform.IoCounters = .{};
var target_io_counts: platform.IoCounters = .{};
var storage_profiler: ?*profiling.Profiler = null;
fn blockRead(io: *uefi.protocol.BlockIo, lba: u64, bytes: []u8, category: profiling.Category) platform.Error!void {
    const timing = platform.measure(storage_profiler, category);
    defer platform.measured(storage_profiler, timing);
    block_io_counts.read(bytes.len);
    if (category == .target_io) target_io_counts.read(bytes.len);
    io.readBlocks(io.media.media_id, lba, bytes) catch { block_io_counts.failed(); return error.Io; };
}
fn blockWrite(io: *uefi.protocol.BlockIo, lba: u64, bytes: []const u8, category: profiling.Category) platform.Error!void {
    const timing = platform.measure(storage_profiler, category);
    defer platform.measured(storage_profiler, timing);
    block_io_counts.write(bytes.len);
    if (category == .target_io) target_io_counts.write(bytes.len);
    io.writeBlocks(io.media.media_id, lba, bytes) catch { block_io_counts.failed(); return error.Io; };
}

const Device = struct {
    io: *uefi.protocol.BlockIo,
    bounce: [64 * 1024]u8 align(4096) = undefined,
    category: profiling.Category = .target_io,
    fn disk(self: *Device) platform.Disk {
        return .{ .context = self, .sector_bytes = self.io.media.block_size, .sectors = self.io.media.last_block + 1, .read_fn = read, .write_fn = write, .flush_fn = flush, .profiler = storage_profiler };
    }
    fn read(ctx: *anyopaque, offset: u64, output: []u8) platform.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        var done: usize = 0;
        while (done < output.len) {
            const cursor = offset + done;
            const within: usize = @intCast(cursor % self.io.media.block_size);
            const n = @min(output.len - done, self.bounce.len - within);
            const read_size = std.mem.alignForward(usize, within + n, self.io.media.block_size);
            try blockRead(self.io, cursor / self.io.media.block_size, self.bounce[0..read_size], self.category);
            @memcpy(output[done..][0..n], self.bounce[within..][0..n]);
            done += n;
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) platform.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        // The combiner supplies a4096-aligned buffer. Preserve large aligned
        // requests all the way to BlockIo instead of splitting them at64KiB.
        const io_align = @max(@as(usize, 1), self.io.media.io_align);
        if (offset % self.io.media.block_size == 0 and input.len % self.io.media.block_size == 0 and @intFromPtr(input.ptr) % io_align == 0) {
            try blockWrite(self.io, offset / self.io.media.block_size, input, self.category);
            return;
        }
        var done: usize = 0;
        while (done < input.len) {
            const cursor = offset + done;
            const within: usize = @intCast(cursor % self.io.media.block_size);
            const n = @min(input.len - done, self.bounce.len - within);
            const write_size = std.mem.alignForward(usize, within + n, self.io.media.block_size);
            if (within != 0 or (within + n) % self.io.media.block_size != 0) try blockRead(self.io, cursor / self.io.media.block_size, self.bounce[0..write_size], self.category);
            @memcpy(self.bounce[within..][0..n], input[done..][0..n]);
            try blockWrite(self.io, cursor / self.io.media.block_size, self.bounce[0..write_size], self.category);
            done += n;
        }
    }
    fn flush(ctx: *anyopaque) platform.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        const timing = platform.measure(storage_profiler, self.category);
        defer platform.measured(storage_profiler, timing);
        block_io_counts.flush();
        if (self.category == .target_io) target_io_counts.flush();
        self.io.flushBlocks() catch { block_io_counts.failed(); return error.Io; };
    }
};

test "aligned oneMiB target write reaches BlockIo once and unaligned IO keeps bounce semantics" {
    const Media = std.meta.Child(@FieldType(uefi.protocol.BlockIo, "media"));
    const Fixture = struct {
        io: uefi.protocol.BlockIo = undefined,
        media: Media = std.mem.zeroes(Media),
        reads: usize = 0, writes: usize = 0, largest: usize = 0, fail: bool = false,
        fn reset(_: *uefi.protocol.BlockIo, _: bool) callconv(uefi.cc) uefi.Status { return .success; }
        fn read(io: *uefi.protocol.BlockIo, _: u32, _: u64, n: usize, ptr: [*]u8) callconv(uefi.cc) uefi.Status {
            const self: *@This() = @fieldParentPtr("io", io);
            self.reads += 1; @memset(ptr[0..n], 0); return .success;
        }
        fn write(io: *uefi.protocol.BlockIo, _: u32, _: u64, n: usize, _: [*]const u8) callconv(uefi.cc) uefi.Status {
            const self: *@This() = @fieldParentPtr("io", io);
            self.writes += 1; self.largest = @max(self.largest, n);
            return if (self.fail) .device_error else .success;
        }
        fn flush(_: *uefi.protocol.BlockIo) callconv(uefi.cc) uefi.Status { return .success; }
    };
    var f: Fixture = .{};
    f.media.block_size = 512; f.media.last_block = 4095; f.media.io_align = 4096;
    f.io = .{ .revision = 0, .media = &f.media, ._reset = Fixture.reset, ._read_blocks = Fixture.read, ._write_blocks = Fixture.write, ._flush_blocks = Fixture.flush };
    const bytes = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 1024 * 1024);
    defer std.testing.allocator.free(bytes); @memset(bytes, 0x3c);
    var device: Device = .{ .io = &f.io };
    try device.disk().write(0, bytes);
    try std.testing.expectEqual(@as(usize, 1), f.writes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), f.largest);
    try std.testing.expectEqual(@as(usize, 0), f.reads);
    try device.disk().write(1, bytes[0..37]);
    try std.testing.expectEqual(@as(usize, 2), f.writes);
    try std.testing.expectEqual(@as(usize, 1), f.reads);
    f.fail = true;
    try std.testing.expectError(error.Io, device.disk().write(0, bytes));
}

// Bounded device-path traversal. A whole disk's path must not prefix the boot
// volume path. Missing/malformed paths fail closed rather than guessing.
fn pathBody(path: *const uefi.protocol.DevicePath) ![]const u8 {
    const bytes: [*]const u8 = @ptrCast(path);
    var offset: usize = 0;
    while (offset <= 4092) {
        const len = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        if (len < 4 or len > 4096 - offset) return error.Corrupt;
        if (bytes[offset] == 0x7f) {
            if (bytes[offset + 1] != 0xff or len != 4) return error.Unsupported;
            return bytes[0..offset];
        }
        offset += len;
    }
    return error.Corrupt;
}

// ABI prefix of EFI_PCI_IO_PROTOCOL, as also used by the repository's
// uefi_drivers.zig. Only the PCI configuration read slot is called here.
const PciIo = extern struct {
    poll_mem: *const anyopaque,
    poll_io: *const anyopaque,
    mem_read: *const anyopaque,
    mem_write: *const anyopaque,
    io_read: *const anyopaque,
    io_write: *const anyopaque,
    pci_read: *const fn (*PciIo, u32, u32, usize, *anyopaque) callconv(uefi.cc) uefi.Status,
    pub const guid align(8) = uefi.Guid{ .time_low = 0x4cf5b200, .time_mid = 0x68b8, .time_high_and_version = 0x4ca5, .clock_seq_high_and_reserved = 0x9e, .clock_seq_low = 0xec, .node = .{ 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a } };
};

fn connectStorage(log: app.Logger) !void {
    const bs = uefi.system_table.boot_services orelse return error.Io;
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &PciIo.guid })) orelse return error.Unsupported;
    defer bs.freePool(@ptrCast(@alignCast(handles.ptr))) catch {};
    if (handles.len > 128) return error.TooManyEntries;
    var count: usize = 0;
    for (handles) |handle| {
        const io = (try bs.handleProtocol(PciIo, handle)) orelse continue;
        var class: u32 = 0;
        if (io.pci_read(io, 2, 8, 1, @ptrCast(&class)) != .success) continue;
        if (class >> 24 != 1) continue;
        count += 1;
        if (count > 32) return error.TooManyEntries;
        if (bs.connectController(handle, null, null, true)) |_| {
            log.say("STORAGE connect class={x} recursive OK\n", .{class >> 8});
        } else |err| {
            log.say("STORAGE connect class={x} result={s}\n", .{ class >> 8, @errorName(err) });
        }
    }
    log.say("STORAGE controllers={d}; explicit target selection follows\n", .{count});
}

fn choose(cfg: Config, boot_handle: uefi.Handle, log: app.Logger) !*uefi.protocol.BlockIo {
    const bs = uefi.system_table.boot_services orelse return error.Io;
    const boot_path = (try bs.handleProtocol(uefi.protocol.DevicePath, boot_handle)) orelse return error.Unsupported;
    const boot_body = try pathBody(boot_path);
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.Io;
    defer bs.freePool(@ptrCast(@alignCast(handles.ptr))) catch {};
    log.say("SELECT handles={d} wanted_sectors={d} boot_path_bytes={d}\n", .{ handles.len, cfg.sectors, boot_body.len });
    var result: ?*uefi.protocol.BlockIo = null;
    if (handles.len > 32) return error.TooManyEntries;
    for (handles, 0..) |handle, index| {
        if (handle == boot_handle) {
            log.say("CANDIDATE {d} boot-handle excluded\n", .{index});
            continue;
        }
        const io = (try bs.handleProtocol(uefi.protocol.BlockIo, handle)) orelse continue;
        const media = io.media;
        log.say("CANDIDATE {d} present={any} logical={any} readonly={any} block={d} align={d} last_lba={d}\n", .{ index, media.media_present, media.logical_partition, media.read_only, media.block_size, media.io_align, media.last_block });
        if (!media.media_present or media.logical_partition or media.read_only or (media.block_size != 512 and media.block_size != 4096) or media.io_align > 4096 or media.last_block == std.math.maxInt(u64)) {
            log.say("CANDIDATE {d} media-filter excluded\n", .{index});
            continue;
        }
        if (media.last_block + 1 != cfg.sectors) {
            log.say("CANDIDATE {d} size mismatch\n", .{index});
            continue;
        }
        const path = (try bs.handleProtocol(uefi.protocol.DevicePath, handle)) orelse return error.Unsupported;
        const body = try pathBody(path);
        if (body.len == 0 or std.mem.startsWith(u8, boot_body, body)) {
            log.say("CANDIDATE {d} boot-parent/empty-path excluded\n", .{index});
            continue;
        }
        var sector: [4096]u8 align(4096) = undefined;
        try blockRead(io, 0, sector[0..media.block_size], .source_io);
        const prefix = "USOSPREP TARGET v1\n";
        if (!std.mem.eql(u8, sector[0..prefix.len], prefix)) {
            log.say("CANDIDATE {d} marker-prefix mismatch\n", .{index});
            continue;
        }
        if (!std.mem.eql(u8, sector[prefix.len..][0..64], &cfg.token) or sector[prefix.len + 64] != '\n') {
            log.say("CANDIDATE {d} marker-token mismatch\n", .{index});
            continue;
        }
        if (result != null) return error.InvalidArgument;
        result = io;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        log.say("TARGET exact-token-match sectors={d} device_path_sha256={s}; boot-device excluded\n", .{ cfg.sectors, std.fmt.bytesToHex(digest, .lower) });
    }
    return result orelse error.InvalidArgument;
}

fn sourceRead(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
    const device: *Device = @ptrCast(@alignCast(ctx));
    try device.disk().read(offset, out);
}
fn chooseSource(cfg: InstallSource, target: *uefi.protocol.BlockIo, log: app.Logger) !*uefi.protocol.BlockIo {
    const bs = uefi.system_table.boot_services orelse return error.Io;
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.Io;
    defer bs.freePool(@ptrCast(@alignCast(handles.ptr))) catch {};
    if (handles.len > 128) return error.TooManyEntries;
    var result: ?*uefi.protocol.BlockIo = null;
    for (handles) |handle| {
        const io = (try bs.handleProtocol(uefi.protocol.BlockIo, handle)) orelse continue;
        if (io == target or !io.media.media_present or io.media.logical_partition or io.media.io_align > 4096 or
            (io.media.block_size != 512 and io.media.block_size != 4096)) continue;
        if ((std.math.mul(u64, std.math.add(u64, io.media.last_block, 1) catch continue, io.media.block_size) catch continue) != cfg.bytes) continue;
        var block: [4096]u8 align(4096) = undefined;
        if (cfg.start % io.media.block_size != 0) continue;
        blockRead(io, cfg.start / io.media.block_size, block[0..io.media.block_size], .source_io) catch continue;
        if (!std.mem.eql(u8, block[3..11], "NTFS    ") or std.mem.readInt(u64, block[72..80], .little) != cfg.serial) continue;
        if (result != null) return error.AmbiguousSource;
        result = io;
    }
    log.say("SOURCE explicit_ntfs_bytes={d} start={d} size={d} serial={x}; never writable API\n", .{ cfg.bytes, cfg.start, cfg.size, cfg.serial });
    return result orelse error.SourceNotFound;
}
fn runInstall(cfg: Config, boot: uefi.Handle, target: *Device, tracker: *platform.TrackedAllocator, seed: [64]u8, log: app.Logger) !void {
    const allocator = tracker.allocator();
    const src_cfg = cfg.source orelse return error.InvalidArgument;
    const source = try allocator.create(Device);
    defer allocator.destroy(source);
    source.* = .{ .io = try chooseSource(src_cfg, target.io, log), .category = .source_io };
    const output: *Output = @ptrCast(@alignCast(log.context));
    output.timing = cfg.timing;
    output.probe_items = cfg.probe_items;
    output.initProfile();
    storage_profiler = if (cfg.timing) &output.profile else null;
    defer storage_profiler = null;
    const install_log = output.logger();
    install_log.say("DIAGNOSTIC_OPTIONS timing={any} combine={any} probe_items={?d}\n", .{cfg.timing, cfg.combine, cfg.probe_items});
    // The host runner pins this virtual target's QCOW2 backend and token.
    var combined: ?writecombine.Cache = if (cfg.combine) try writecombine.Cache.init(allocator, target.disk(), .qcow2_file) else null;
    defer if (combined) |*cache| cache.deinit();
    const target_disk = if (combined) |*cache| cache.disk() else target.disk();
    var wide: [1024]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&wide, src_cfg.path);
    var components: [32][]const u16 = undefined;
    var count: usize = 0;
    var iter = std.mem.tokenizeAny(u16, wide[0..n], &.{ '/', '\\' });
    while (iter.next()) |part| {
        if (count == components.len or std.mem.eql(u16, part, &.{'.'}) or std.mem.eql(u16, part, &.{ '.', '.' })) return error.InvalidArgument;
        components[count] = part;
        count += 1;
    }
    if (count == 0) return error.InvalidArgument;
    const iso = try allocator.create(optical_ntfs.Source);
    defer allocator.destroy(iso);
    try optical_ntfs.Source.openInto(.{ .context = source, .size = src_cfg.bytes, .read_fn = sourceRead }, src_cfg.start, src_cfg.size, components[0..count], allocator, iso);
    defer iso.deinit();
    errdefer if (iso.last_error) |err| log.say("SOURCE original_error={s}\n", .{@errorName(err)});
    const ids = try layout.Ids.fromSeed64(seed);
    var marker: [84]u8 = undefined;
    const marker_text = try std.fmt.bufPrint(&marker, "USOSPREP TARGET v1\n{s}\n", .{cfg.token});
    const result = try install_app.run(target_disk, if (cfg.kind == .gpt) .uefi else .bios, ids, .{ .explicit = true, .source_identity = @intFromPtr(source.io), .target_identity = @intFromPtr(target.io), .boot_identity = @intFromPtr(boot), .marker = marker_text }, tracker, .{ .context = iso, .size = iso.file.size(), .read_fn = iso.reader().read_fn }, cfg.wim_index.?, .{ .verify_scope = cfg.verify_scope }, install_log);
    install_log.say("TIMING_FINAL pm_reads={d} clock_failure={s} profile_enabled={any}\n", .{output.pm_reads, if (output.timer) |timer| @tagName(timer.failure) else "unavailable", cfg.timing});
    // wim_app performs the final combiner flush inside its dirty-recovery
    // lifetime. No fallible target IO is allowed after that protected barrier.
    if (combined) |cache| install_log.say("TARGET_COMBINE capacity={d} logical_writes={d} upstream_writes={d} logical_bytes={d} upstream_bytes={d} drains={d} failures={d}\n", .{ writecombine.capacity, cache.stats.logical_writes, cache.stats.upstream_writes, cache.stats.logical_bytes, cache.stats.upstream_bytes, cache.stats.drains, cache.stats.failures });
    log.say("INSTALL layout_mode={s} disk_guid={s} windows_guid={s} esp_guid={s} mbr_signature={x} windows_start={d} windows_size={d} system_start={d} system_size={d}\n", .{ @tagName(result.mode), std.fmt.bytesToHex(ids.base.disk_guid, .lower), std.fmt.bytesToHex(ids.base.partition_guid, .lower), std.fmt.bytesToHex(ids.esp, .lower), ids.base.mbr_signature, result.windows.start_bytes, result.windows.size_bytes, result.system.start_bytes, result.system.size_bytes });
}

const FileSource = struct {
    file: *uefi.protocol.File,
    fn source(self: *FileSource) !ntfs.Source {
        var info_buf: [1024]u8 align(8) = undefined;
        const info = try self.file.getInfo(.file, &info_buf);
        if (info.attribute.directory) return error.InvalidArgument;
        return .{ .context = self, .size = info.file_size, .read_fn = read };
    }
    fn input(self: *FileSource) !wim.Input {
        const file = try self.source();
        return .{ .context = file.context, .size = file.size, .read_fn = file.read_fn };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        self.file.setPosition(offset) catch return error.Io;
        var done: usize = 0;
        while (done < out.len) {
            const n = self.file.read(out[done..]) catch return error.Io;
            if (n == 0) return error.Io;
            done += n;
        }
    }
};

fn firmwareRandom(_: *anyopaque, out: *[64]u8) bool {
    const bs = uefi.system_table.boot_services orelse return false;
    const rng = (bs.locateProtocol(uefi.protocol.Rng, null) catch null) orelse return false;
    rng.getRNG(null, out) catch return false;
    return true;
}
fn qemuDetected() bool {
    if (entropy.qemuCpu()) return true;
    const table = uefi.system_table;
    if (table.number_of_table_entries > 4096) return false;
    for (table.configuration_table[0..table.number_of_table_entries]) |entry| {
        if (!entry.vendor_guid.eql(uefi.tables.ConfigurationTable.smbios_table_guid) and !entry.vendor_guid.eql(uefi.tables.ConfigurationTable.smbios3_table_guid)) continue;
        const bytes: [*]const u8 = @ptrCast(entry.vendor_table);
        const location = entropy.smbiosEntry(bytes[0..32]) orelse continue;
        if (location.address == 0 or location.address > std.math.maxInt(usize) or location.length == 0 or location.length > 65536) continue;
        const address = std.math.cast(usize, location.address) orelse continue;
        _ = std.math.add(usize, address, location.length) catch continue;
        const data: [*]const u8 = @ptrFromInt(address);
        if (entropy.qemuSmbios(data[0..location.length])) return true;
    }
    return false;
}
fn run(output: *Output) anyerror!void {
    // Fail before opening/deleting the ESP log or writing any disk sector.
    var rng_context: u8 = 0;
    const random = try entropy.collect(.{ .context = &rng_context, .efi_rng = firmwareRandom, .rdseed = entropy.rdseed, .rdrand = entropy.rdrand, .fw_cfg = entropy.qemuEntropy, .qemu_detected = output.qemu });
    const ids = try identity.Identifiers.fromEntropy(random.bytes);
    const bs = uefi.system_table.boot_services orelse return error.Io;
    try bs.setWatchdogTimer(0, 0, null);
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.Io;
    const boot_handle = loaded.device_handle orelse return error.Io;
    const filesystem = (try bs.handleProtocol(uefi.protocol.SimpleFileSystem, boot_handle)) orelse return error.Io;
    const root = try filesystem.openVolume();
    defer root.close() catch {};
    if (root.open(W("\\USOSPREP.LOG"), .read_write, .{})) |old| {
        _ = try old.delete();
    } else |err| {
        if (err != error.NotFound) return err;
    }
    output.file = try root.open(W("\\USOSPREP.LOG"), .read_write_create, .{});
    const log = output.logger();
    errdefer |err| log.say("USOSPREP UEFI FAIL {s}\n", .{@errorName(err)});
    log.say("USOSPREP UEFI {s} BEGIN; QEMU-only explicit token target\n", .{@tagName(builtin.cpu.arch)});
    log.say("CPU application_baseline={s}; firmware_cpu_requirement_measured_separately\n", .{builtin.cpu.model.name});
    log.say("ENTROPY source={s} bytes=64 qemu_detected={any} no-weak-fallback\n", .{ @tagName(random.source), output.qemu });
    const cfg_file = try root.open(W("\\USOSPREP.CFG"), .read, .{});
    var cfg_buf: [4096]u8 = undefined;
    const cfg_size = try cfg_file.read(&cfg_buf);
    log.say("CONFIG bytes={d}\n", .{cfg_size});
    var extra: [1]u8 = undefined;
    if (try cfg_file.read(&extra) != 0) return error.InvalidArgument;
    try cfg_file.close();
    const cfg = try config(cfg_buf[0..cfg_size]);
    log.say("CONFIG parsed mode={s} sectors={d} token_bytes=64 workload={s}\n", .{ @tagName(cfg.kind), cfg.sectors, @tagName(cfg.workload) });
    try connectStorage(log);
    var device: Device = .{ .io = try choose(cfg, boot_handle, log) };
    const tracker = output.tracker orelse return error.InvalidArgument;
    errdefer log.say("MEM failure alloc_current={d} alloc_peak={d}\n", .{ tracker.current, tracker.peak });
    switch (cfg.workload) {
        .install => {
            tracker.limit = 14 * 1024 * 1024;
            try runInstall(cfg, boot_handle, &device, tracker, random.bytes, log);
        },
        .stage1a => {
            var small: FileSource = .{ .file = try root.open(W("\\FIXTURES\\small.bin"), .read, .{}) };
            defer small.file.close() catch {};
            var large: FileSource = .{ .file = try root.open(W("\\FIXTURES\\large.bin"), .read, .{}) };
            defer large.file.close() catch {};
            try app.run(device.disk(), cfg.kind, ids, tracker, .{ .small = try small.source(), .large = try large.source() }, log);
        },
        .scale_firmware, .scale_tree150k => {
            tracker.limit = 16 * 1024 * 1024;
            log.say("MEM program_limit=16777216 includes_own_stack=1048576 fixed_block_bounce=65536; firmware_excluded\n", .{});
            try scale.run(device.disk(), cfg.kind, ids, tracker, if (cfg.workload == .scale_tree150k) .tree150k else .firmware, log);
        },
        .wim => {
            tracker.limit = 14 * 1024 * 1024;
            log.say("MEM WIM allocator_limit=14680064 includes_own_stack=1048576 fixed_block_bounce=65536; firmware_excluded\n", .{});
            var archive: FileSource = .{ .file = try root.open(W("\\FIXTURES\\install.wim"), .read, .{}) };
            defer archive.file.close() catch {};
            // The shared entry point validates the selected image and all
            // resource hashes before writing the first format sector.
            try wim_app.runWithOptions(device.disk(), cfg.kind, ids, tracker, try archive.input(), cfg.wim_index.?, .{ .verify_scope = cfg.verify_scope }, log);
        },
    }
    log.say("USOSPREP FINAL alloc_current={d} alloc_peak={d} fixed_block_bounce=65536\n", .{ tracker.current, tracker.peak });
    if (tracker.current != output.stack_bytes or output.failed) return error.Io;
}

fn verifyBootReceipt(root: *uefi.protocol.File, name: [:0]const u16, expected: [32]u8, allocator: std.mem.Allocator, log: app.Logger) !void {
    const file = try root.open(name, .read, .{});
    defer file.close() catch {};
    var info_buf: [1024]u8 align(8) = undefined;
    const info = try file.getInfo(.file, &info_buf);
    if (info.attribute.directory or info.file_size == 0 or info.file_size > 1024 * 1024) return error.InvalidBootReceipt;
    const expected_size = info.file_size;
    const buffer = try allocator.alloc(u8, 65536);
    defer allocator.free(buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining = expected_size;
    while (remaining != 0) {
        const count: usize = @intCast(@min(buffer.len, remaining));
        const actual = try file.read(buffer[0..count]);
        if (actual == 0) return error.InvalidBootReceipt;
        hash.update(buffer[0..actual]);
        remaining -= actual;
    }
    var extra: [1]u8 = undefined;
    if (try file.read(&extra) != 0) return error.InvalidBootReceipt;
    const digest = hash.finalResult();
    if (!std.mem.eql(u8, &digest, &expected)) return error.BootReceiptHashMismatch;
    log.say("BOOT RECEIPT bytes={d} sha256={s} matched_host_pin; gate_semantics_checked_by_host\n", .{ expected_size, std.fmt.bytesToHex(digest, .lower) });
}

fn chooseBoot(cfg: @import("uefi_boot_config.zig").Config, boot_handle: uefi.Handle, device: *Device, allocator: std.mem.Allocator, log: app.Logger) !void {
    const bs = uefi.system_table.boot_services orelse return error.Io;
    const boot_path = (try bs.handleProtocol(uefi.protocol.DevicePath, boot_handle)) orelse return error.Unsupported;
    const boot_body = try pathBody(boot_path);
    if (boot_body.len == 0) return error.Unsupported;
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.Io;
    defer bs.freePool(@ptrCast(@alignCast(handles.ptr))) catch {};
    if (handles.len > 128) return error.TooManyEntries;
    var selected: ?*uefi.protocol.BlockIo = null;
    var sector: [512]u8 = undefined;
    for (handles, 0..) |handle, index| {
        if (handle == boot_handle) continue;
        const io = (try bs.handleProtocol(uefi.protocol.BlockIo, handle)) orelse continue;
        const media = io.media;
        if (!media.media_present or media.logical_partition or media.read_only or media.block_size != 512 or media.io_align > 4096 or media.last_block == std.math.maxInt(u64)) continue;
        const bytes = std.math.mul(u64, media.last_block + 1, 512) catch continue;
        if (bytes != cfg.target_bytes) continue;
        const path = (try bs.handleProtocol(uefi.protocol.DevicePath, handle)) orelse return error.Unsupported;
        const body = try pathBody(path);
        if (body.len == 0 or std.mem.startsWith(u8, boot_body, body)) continue;
        device.io = io;
        const disk = device.disk();
        try disk.read(512, &sector);
        if (!std.mem.eql(u8, sector[0..8], "EFI PART") or !std.mem.eql(u8, sector[56..72], &cfg.ids.base.disk_guid)) continue;
        // A matching disk GUID with damaged/different layout is an error,
        // never a reason to silently fall through to another candidate.
        if(comptime reference_boot) {
            try @import("diagnostic_boot_disk.zig").validate(disk,allocator);
        } else {
            const prepared = try layout.plan(disk, .uefi);
            try @import("boot_files.zig").validateDisk(disk, prepared, cfg.ids, allocator);
        }
        if (selected != null) return error.AmbiguousBootTarget;
        selected = io;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        log.say("BOOT TARGET candidate={d} bytes={d} full_GPT_and_NTFS_identity=matched device_path_sha256={s}; boot-device excluded\n", .{ index, bytes, std.fmt.bytesToHex(digest, .lower) });
    }
    device.io = selected orelse return error.BootTargetNotFound;
}

fn runBoot(output: *Output) anyerror!void {
    if (!output.qemu) return error.QemuBootClientOnly;
    var rng_context: u8 = 0;
    const random = try entropy.collect(.{ .context = &rng_context, .efi_rng = firmwareRandom, .rdseed = entropy.rdseed, .rdrand = entropy.rdrand, .fw_cfg = entropy.qemuEntropy, .qemu_detected = output.qemu });
    const bs = uefi.system_table.boot_services orelse return error.Io;
    try bs.setWatchdogTimer(0, 0, null);
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.Io;
    const boot_handle = loaded.device_handle orelse return error.Io;
    const filesystem = (try bs.handleProtocol(uefi.protocol.SimpleFileSystem, boot_handle)) orelse return error.Io;
    const root = try filesystem.openVolume();
    defer root.close() catch {};
    const cfg_file = try root.open(W("\\USOSBOOT.CFG"), .read, .{});
    defer cfg_file.close() catch {};
    var cfg_buf: [4096]u8 = undefined;
    const cfg_size = try cfg_file.read(&cfg_buf);
    var extra: [1]u8 = undefined;
    if (try cfg_file.read(&extra) != 0) return error.InvalidBootConfig;
    const cfg = if(comptime reference_boot) try @import("uefi_boot_config.zig").parseReferenceDiagnostic(cfg_buf[0..cfg_size]) else try @import("uefi_boot_config.zig").parse(cfg_buf[0..cfg_size]);
    if (cfg.arch != (if (builtin.cpu.arch == .x86_64) .x64 else .ia32)) return error.BootArchitectureMismatch;
    if (root.open(W("\\USOSBOOT.LOG"), .read_write, .{})) |old| {
        _ = try old.delete();
    } else |err| {
        if (err != error.NotFound) return err;
    }
    output.file = try root.open(W("\\USOSBOOT.LOG"), .read_write_create, .{});
    const log = output.logger();
    errdefer |err| log.say("USOSBOOT UEFI FAIL {s}\n", .{@errorName(err)});
    log.say("USOSBOOT UEFI {s} BEGIN; separate provisioning client; no Windows NTFS writes\n", .{@tagName(builtin.cpu.arch)});
    log.say("ENTROPY source={s} bytes=64 qemu_detected={any}; loader_GUID_explicit_from_host_entropy\n", .{ @tagName(random.source), output.qemu });
    const tracker = output.tracker orelse return error.InvalidArgument;
    tracker.limit = 16 * 1024 * 1024;
    const allocator = tracker.allocator();
    errdefer log.say("MEM failure alloc_current={d} alloc_peak={d}\n", .{ tracker.current, tracker.peak });
    try verifyBootReceipt(root, W("\\USOSLAY.RCP"), cfg.layout_receipt_sha256, allocator, log);
    try verifyBootReceipt(root, W("\\USOSBCD.RCP"), cfg.bcd_receipt_sha256, allocator, log);
    try connectStorage(log);
    {
        const device = try allocator.create(Device);
        defer allocator.destroy(device);
        try chooseBoot(cfg, boot_handle, device, allocator, log);
        const disk = device.disk();
        const prepared = if(comptime reference_boot) @import("diagnostic_boot_disk.zig").layout() else try layout.plan(disk, .uefi);
        var wide_locale: [32]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wide_locale, cfg.locale);
        const options: @import("boot_files.zig").Options = .{
            .arch = if (cfg.arch == .x64) .x64 else .ia32,
            .loader_guid = cfg.loader_guid,
            .timestamp = std.math.mul(u64, std.math.add(u64, Output.clock(output), 11644473600) catch return error.InvalidBootTime, 10000000) catch return error.InvalidBootTime,
            .locale = wide_locale[0..n],
            .gates = if(comptime reference_boot) .{ .layout_apply = true, .diagnostic_deferred = true } else .{ .layout_apply = true, .bcd_reference = true },
        };
        const stats = if(comptime reference_boot) blk: {
            log.say("BOOT_REFERENCE_DIAGNOSTIC bcd_reference_comparison=deferred; guarded overlay only\n", .{});
            const fat_serial=std.mem.readInt(u32,random.bytes[0..4],.little);
            if(fat_serial==0 or fat_serial==std.math.maxInt(u32))return error.EntropyUnavailable;
            break :blk try @import("boot_files.zig").provisionReference(disk,prepared,cfg.ids,tracker,options,fat_serial,log);
        } else blk: {
            var guarded = try @import("boot_target.zig").EspOnly.init(disk, prepared);
            break :blk try @import("boot_files.zig").provisionUefi(guarded.disk(), prepared, cfg.ids, tracker, options, log);
        };
        log.say("USOSBOOT copied files={d} bytes={d} bootmgfw_sha256={s} bcd_sha256={s}\n", .{ stats.files, stats.bytes, std.fmt.bytesToHex(stats.main_sha256, .lower), std.fmt.bytesToHex(stats.bcd_sha256, .lower) });
    }
    log.say("USOSBOOT FINAL alloc_current={d} alloc_peak={d}; no NVRAM changes; first Windows start is a separate gate\n", .{ tracker.current, tracker.peak });
    if (tracker.current != output.stack_bytes or output.failed) return error.Io;
}

fn stackEntry(output: *Output) callconv(uefi.cc) usize {
    (if (comptime boot_only) runBoot(output) else run(output)) catch |err| {
        output.logger().say("USOSPREP TERMINAL FAIL {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
comptime {
    if (builtin.os.tag == .uefi) @export(&stackEntry, .{ .name = "\x01usosprep_stack_entry" });
}

// Firmware may supply a stack smaller than this formatter's bounded call
// depth. Switch only the stack, preserving the firmware ABI and returning to
// the original stack before freeing the pool allocation. The1MiB allocation
// is included in the same current/peak workload budget as core allocations.
fn stackSwitch() callconv(.naked) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\push %%rbp
            \\mov %%rsp, %%rbp
            \\mov %%rcx, %%rsp
            \\and $-16, %%rsp
            \\sub $32, %%rsp
            \\mov %%rdx, %%rcx
            \\call usosprep_stack_entry
            \\mov %%rbp, %%rsp
            \\pop %%rbp
            \\ret
        );
    } else {
        asm volatile (
            \\push %%ebp
            \\mov %%esp, %%ebp
            \\mov 8(%%ebp), %%eax
            \\mov 12(%%ebp), %%edx
            \\mov %%eax, %%esp
            \\and $-16, %%esp
            \\sub $12, %%esp
            \\push %%edx
            \\call usosprep_stack_entry
            \\mov %%ebp, %%esp
            \\pop %%ebp
            \\ret
        );
    }
}

pub fn main() uefi.Status {
    var output: Output = .{ .qemu = qemuDetected() };
    if (uefi.system_table.boot_services) |bs| {
        output.serial = bs.locateProtocol(uefi.protocol.SerialIo, null) catch null;
        if (output.serial) |serial| {
            serial.reset() catch {};
            serial.setAttribute(115200, 0, 0, .no_parity, 8, .one_stop_bit) catch {};
        }
    }
    var tracker: platform.TrackedAllocator = .{ .backing = uefi.pool_allocator };
    output.tracker = &tracker;
    const allocator = tracker.allocator();
    var passed = false;
    if (allocator.alloc(u8, 1024 * 1024)) |stack| {
        output.stack_bytes = stack.len;
        output.stack = stack;
        @memset(stack, 0xa5);
        const call: *const fn (usize, *Output) callconv(uefi.cc) usize = @ptrCast(&stackSwitch);
        passed = call(@intFromPtr(stack.ptr) + stack.len, &output) == 0;
        var stack_ok = true;
        for (stack[0..4096]) |c| if (c != 0xa5) {
            stack_ok = false;
            break;
        };
        var untouched: usize = 0;
        while (untouched < stack.len and stack[untouched] == 0xa5) : (untouched += 1) {}
        output.logger().say("STACK canary_ok={any} reserved_bytes={d} high_water_bytes={d}\n", .{ stack_ok, stack.len, stack.len - untouched });
        if (!stack_ok) passed = false;
        output.stack = null;
        allocator.free(stack);
        output.logger().say("USOSPREP PLATFORM stack_bytes=1048576 alloc_current={d} alloc_peak={d}\n", .{ tracker.current, tracker.peak });
        if (tracker.current != 0 or output.failed) passed = false;
    } else |_| output.logger().say("USOSPREP TERMINAL FAIL stack-allocation\n", .{});
    if (output.file) |file| {
        file.close() catch {
            passed = false;
        };
        output.file = null;
    }
    const value: u32 = if (passed) 0x10 else 0x11;
    if (output.qemu) asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (@as(u16, 0xf4)),
    );
    uefi.system_table.runtime_services.resetSystem(.shutdown, if (passed) .success else .device_error, null);
}

test "explicit target config rejects ambiguity and unknown keys" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const good = "USOSPREP_QEMU_ONLY\nmode=gpt\ntarget_sectors=4194304\ntoken=" ++ token ++ "\n";
    const result = try config(good);
    try std.testing.expectEqual(partitions.Kind.gpt, result.kind);
    try std.testing.expectEqual(@as(u64, 4194304), result.sectors);
    try std.testing.expectEqual(Workload.stage1a, result.workload);
    try std.testing.expectEqual(Workload.scale_firmware, (try config(good ++ "profile=scale-firmware\n")).workload);
    try std.testing.expectError(error.InvalidArgument, config(good ++ "profile=unknown\n"));
    try std.testing.expectError(error.InvalidArgument, config(good ++ "profile=scale-firmware\nprofile=scale-firmware\n"));
    try std.testing.expectError(error.InvalidArgument, config(good ++ "mode=mbr\n"));
    try std.testing.expectError(error.InvalidArgument, config(good ++ "first_disk=true\n"));
}

test "WIM profile requires an explicit positive unique image index" {
    const base = "USOSPREP_QEMU_ONLY\nmode=gpt\ntarget_sectors=4194304\ntoken=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n";
    const selected = try config(base ++ "profile=wim\nwim_index=2\n");
    try std.testing.expectEqual(Workload.wim, selected.workload);
    try std.testing.expectEqual(@as(?u32, 2), selected.wim_index);
    try std.testing.expectError(error.InvalidArgument, config(base ++ "profile=wim\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "profile=wim\nwim_index=0\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "profile=wim\nwim_index=4294967296\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "profile=wim\nwim_index=2\nwim_index=2\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "wim_index=1\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "profile=scale-firmware\nwim_index=1\n"));
}

test "install requires complete explicit read-only source identity" {
    const base = "USOSPREP_QEMU_ONLY\nmode=gpt\ntarget_sectors=67108864\ntoken=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nprofile=install\nwim_index=2\n";
    const source = "source_bytes=12884901888\nsource_start=1048576\nsource_size=12883836416\nsource_serial=12345678abcdef01\nsource_iso=INSTALL.ISO\n";
    try std.testing.expectError(error.InvalidArgument, config(base));
    const cfg = try config(base ++ source);
    try std.testing.expectEqual(Workload.install, cfg.workload);
    try std.testing.expectEqual(@as(u64, 12884901888), cfg.source.?.bytes);
    try std.testing.expectEqual(wim_app.VerifyScope.selected, cfg.verify_scope);
    try std.testing.expect(!cfg.timing and cfg.combine and cfg.probe_items == null);
    const diagnostic = try config(base ++ source ++ "timing=on\ncombine=off\nprobe_items=12613\n");
    try std.testing.expect(diagnostic.timing and !diagnostic.combine and diagnostic.probe_items.? == 12613);
    inline for (.{"timing=other\n", "timing=on\ntiming=off\n", "combine=off\ncombine=on\n", "probe_items=0\n", "probe_items=1000001\n", "probe_items=1\nprobe_items=2\n"}) |bad| {
        try std.testing.expectError(error.InvalidArgument, config(base ++ source ++ bad));
    }
    try std.testing.expectEqual(wim_app.VerifyScope.all, (try config(base ++ source ++ "verify_scope=all\n")).verify_scope);
    try std.testing.expectError(error.InvalidArgument, config(base ++ source ++ "verify_scope=unknown\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ source ++ "verify_scope=all\nverify_scope=selected\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ source ++ "source_bytes=12884901888\n"));
    try std.testing.expectError(error.InvalidArgument, config(base ++ "source_bytes=1024\nsource_start=512\nsource_size=4096\nsource_serial=1234\nsource_iso=INSTALL.ISO\n"));
}
