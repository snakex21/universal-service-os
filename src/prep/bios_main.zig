//! Standalone PM32 client of the unchanged Legacy Core firmware thunks.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const partitions = @import("partitions.zig");
const ntfs = @import("ntfs.zig");
const app = @import("app.zig");
const scale = @import("scale.zig");
const wim = @import("wim.zig");
const wim_app = @import("wim_app.zig");
const identity = @import("identity.zig");
const entropy = @import("entropy.zig");
const FixedHeap = @import("fixed_heap.zig");
const bios_heap = @import("bios_heap.zig");
const wim_only = if (@hasDecl(@import("root"), "prep_wim_only")) @import("root").prep_wim_only else false;

const Context = extern struct { magic: u32, version: u16, size: u16, drive: u8, reserved: [3]u8, sector_bytes: u32, core_lba: u64 };
const E820 = bios_heap.Region;
const DriveInfo = extern struct { low: u32, high: u32, sector_bytes: u16, cylinders: u16, heads: u16, spt: u16 };
extern fn bios_read_sector_drive(u32, u64, [*]u8) callconv(.c) u32;
extern fn bios_read_sectors(u64, u32, [*]u8) callconv(.c) u32;
extern fn bios_write_sectors_drive(u32, u64, [*]const u8, u32) callconv(.c) u32;
extern fn bios_drive_info(u32, *DriveInfo) callconv(.c) u32;
extern fn bios_e820_probe([*]E820) callconv(.c) u32;
extern fn core_putc(u8) callconv(.c) void;
extern var __prep_bss_start: u8;
extern var __prep_bss_end: u8;

const Block = struct {
    drive: u32,
    boot: bool = false,
    sectors: u64,
    fn disk(self: *Block) platform.Disk {
        return .{ .context = self, .sectors = self.sectors, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *Block = @ptrCast(@alignCast(ctx));
        var sector: [512]u8 = undefined;
        var done: usize = 0;
        while (done < out.len) {
            const cursor = offset + done;
            const within: usize = @intCast(cursor % 512);
            if (self.boot and within == 0 and out.len - done >= 512) {
                const count: u32 = @intCast(@min(127, (out.len - done) / 512));
                if (bios_read_sectors(cursor / 512, count, out[done..].ptr) != 0) return error.Io;
                done += @as(usize, count) * 512;
            } else {
                if (bios_read_sector_drive(self.drive, cursor / 512, &sector) != 0) return error.Io;
                const n = @min(out.len - done, 512 - within);
                @memcpy(out[done..][0..n], sector[within..][0..n]);
                done += n;
            }
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) platform.Error!void {
        const self: *Block = @ptrCast(@alignCast(ctx));
        var sector: [512]u8 = undefined;
        var done: usize = 0;
        while (done < input.len) {
            const cursor = offset + done;
            const within: usize = @intCast(cursor % 512);
            if (within == 0 and input.len - done >= 512) {
                const count: u32 = @intCast(@min(127, (input.len - done) / 512));
                if (bios_write_sectors_drive(self.drive, cursor / 512, input[done..].ptr, count) != 0) return error.Io;
                done += @as(usize, count) * 512;
            } else {
                if (bios_read_sector_drive(self.drive, cursor / 512, &sector) != 0) return error.Io;
                const n = @min(input.len - done, 512 - within);
                @memcpy(sector[within..][0..n], input[done..][0..n]);
                if (bios_write_sectors_drive(self.drive, cursor / 512, &sector, 1) != 0) return error.Io;
                done += n;
            }
        }
    }
    fn flush(_: *anyopaque) platform.Error!void {
        // AH=43 synchronous completion; this thin PoC has no extra write cache.
    }
};

const Output = struct {
    boot_drive: u32,
    qemu: bool = false,
    persist: bool = false,
    cursor: usize = 0,
    buffer: [512]u8 = @splat(0),
    failed: bool = false,
    fn write(ctx: *anyopaque, text: []const u8) void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        for (text) |c| {
            core_putc(c);
            if (self.qemu) asm volatile ("outb %[value], %[port]"
                :
                : [value] "{al}" (c),
                  [port] "{dx}" (@as(u16, 0xe9)),
            );
            if (!self.persist) continue;
            if (self.cursor >= 1023 * 512) {
                self.failed = true;
                continue;
            }
            self.buffer[self.cursor % 512] = c;
            self.cursor += 1;
            if (self.cursor % 512 == 0) {
                if (bios_write_sectors_drive(self.boot_drive, 1025 + (self.cursor - 1) / 512, &self.buffer, 1) != 0) self.failed = true;
                @memset(&self.buffer, 0);
            }
        }
        if (self.persist and self.cursor % 512 != 0 and bios_write_sectors_drive(self.boot_drive, 1025 + self.cursor / 512, &self.buffer, 1) != 0) self.failed = true;
    }
    fn clock(_: *anyopaque) u64 {
        const ticks: *const volatile u32 = @ptrFromInt(0x46c);
        return @as(u64, ticks.*) * 10 / 182;
    }
    fn logger(self: *Output) app.Logger {
        return .{ .context = self, .write_fn = write, .clock_fn = clock };
    }
};

const Source = struct {
    disk: platform.Disk,
    offset: u64,
    size: u64,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *Source = @ptrCast(@alignCast(ctx));
        if (offset > self.size or out.len > self.size - offset) return error.Bounds;
        try self.disk.read(self.offset + offset, out);
    }
    fn source(self: *Source) ntfs.Source {
        return .{ .context = self, .size = self.size, .read_fn = read };
    }
    fn input(self: *Source) wim.Input {
        return .{ .context = self, .size = self.size, .read_fn = read };
    }
};

fn get64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

const WimConfig = struct { offset: u64, size: u64, index: u32 };
fn validateWorkload(comptime only_wim: bool, workload: u32) !void {
    if (only_wim) {
        if (workload != 3) return error.InvalidArgument;
    } else if (workload > 2) return error.InvalidArgument;
}
fn wimConfig(cfg: *const [512]u8, boot_bytes: u64) !WimConfig {
    const result: WimConfig = .{
        .offset = get64(cfg, 96),
        .size = get64(cfg, 104),
        .index = std.mem.readInt(u32, cfg[136..140], .little),
    };
    // LBA0..2047 contains only Core/config/log data. WIM is a read-only,
    // sector-aligned extent outside that area, within the explicit boot disk.
    if (result.index == 0 or result.size < 208 or result.offset < 2048 * 512 or result.offset % 512 != 0) return error.InvalidArgument;
    if (result.offset > boot_bytes or result.size > boot_bytes - result.offset) return error.Bounds;
    return result;
}

fn run(ctx: *const Context, output: *Output) !void {
    // Before persistence is enabled, missing entropy cannot modify boot log
    // sectors either. BIOS CPU486 requires no modern RNG instruction.
    var rng_context: u8 = 0;
    const qemu = output.qemu;
    const random = try entropy.collect(.{ .context = &rng_context, .rdrand = entropy.rdrand, .fw_cfg = entropy.qemuEntropy, .qemu_detected = qemu });
    const ids = try identity.Identifiers.fromEntropy(random.bytes);
    if (ctx.magic != 0x43425355 or ctx.version != 1 or ctx.size != 24 or ctx.sector_bytes != 512 or ctx.drive != 0x80) return error.Unsupported;
    var entries: [128]E820 = undefined;
    const count = bios_e820_probe(&entries);
    if (count == 0 or count > entries.len) return error.Unsupported;
    var boot_info: DriveInfo = undefined;
    if (bios_drive_info(ctx.drive, &boot_info) != 0 or boot_info.sector_bytes != 512) return error.Unsupported;
    var boot: Block = .{ .drive = ctx.drive, .boot = true, .sectors = (@as(u64, boot_info.high) << 32) | boot_info.low };
    var cfg: [512]u8 = undefined;
    try boot.disk().read(1024 * 512, &cfg);
    if (!std.mem.eql(u8, cfg[0..16], "USOSPREP BIOS v1") or cfg[128] != 0x81 or cfg[129] != ctx.drive) return error.InvalidArgument;
    output.persist = true;
    if (std.mem.readInt(u32, cfg[20..24], .little) != 512) return error.Unsupported;
    const mode = std.mem.readInt(u32, cfg[16..20], .little);
    const kind: partitions.Kind = switch (mode) {
        0 => .gpt,
        1 => .mbr,
        else => return error.InvalidArgument,
    };
    const workload = std.mem.readInt(u32, cfg[132..136], .little);
    try validateWorkload(wim_only, workload);
    const arena = if (comptime wim_only)
        try bios_heap.selectLimit(entries[0..count], 12 * 1024 * 1024)
    else
        try bios_heap.select(entries[0..count], workload != 0);
    var target_info: DriveInfo = undefined;
    if (bios_drive_info(0x81, &target_info) != 0 or target_info.sector_bytes != 512) return error.Unsupported;
    var target: Block = .{ .drive = 0x81, .sectors = (@as(u64, target_info.high) << 32) | target_info.low };
    if (target.sectors != get64(&cfg, 24)) return error.InvalidArgument;
    var marker: [512]u8 = undefined;
    try target.disk().read(0, &marker);
    const prefix = "USOSPREP TARGET v1\n";
    if (!std.mem.eql(u8, marker[0..prefix.len], prefix) or !std.mem.eql(u8, marker[prefix.len..][0..64], cfg[32..96])) return error.InvalidArgument;
    const heap: [*]u8 = @ptrFromInt(arena.start);
    var fixed = FixedHeap.init(heap[0..arena.bytes]);
    var tracker: platform.TrackedAllocator = .{ .backing = fixed.allocator(), .limit = arena.bytes };
    defer output.logger().say("HEAP physical_current={d} physical_peak={d} extent_peak={d} reserved={d}\n", .{ fixed.current_bytes, fixed.peak_bytes, fixed.extent_peak_bytes, fixed.buffer.len });
    output.logger().say("USOSPREP BIOS PM32 cpu_baseline=i486; boot=0x80 target=0x81 exact-token; E820 heap_start={d} heap_bytes={d}; logLBA1025..2047\n", .{ arena.start, arena.bytes });
    output.logger().say("ENTROPY source={s} bytes=64 qemu_detected={any} no-weak-fallback\n", .{ @tagName(random.source), qemu });
    if (comptime wim_only) {
        const archive_cfg = try wimConfig(&cfg, try boot.disk().bytes());
        output.logger().say("MEM WIM program_heap_limit={d}; fixed_core_stack_and_static_separate; firmware_excluded\n", .{arena.bytes});
        var archive: Source = .{ .disk = boot.disk(), .offset = archive_cfg.offset, .size = archive_cfg.size };
        // No format occurs here: shared WIM preflight validates before writes.
        try wim_app.run(target.disk(), kind, ids, &tracker, archive.input(), archive_cfg.index, output.logger());
    } else if (workload == 0) {
        var small: Source = .{ .disk = boot.disk(), .offset = get64(&cfg, 112), .size = get64(&cfg, 120) };
        var large: Source = .{ .disk = boot.disk(), .offset = get64(&cfg, 96), .size = get64(&cfg, 104) };
        if (small.offset != 2048 * 512 or small.size != 64 or large.offset != 2056 * 512) return error.InvalidArgument;
        try app.run(target.disk(), kind, ids, &tracker, .{ .small = small.source(), .large = large.source() }, output.logger());
    } else {
        output.logger().say("MEM program_heap_limit={d}; coalescing_physical_peak_and_span_reported; fixed_core_stack_and_static_separate; firmware_excluded\n", .{arena.bytes});
        try scale.run(target.disk(), kind, ids, &tracker, if (workload == 2) .tree150k else .firmware, output.logger());
    }
    output.logger().say("USOSPREP FINAL current={d} peak={d}\n", .{ tracker.current, tracker.peak });
    if (output.failed or tracker.current != 0 or fixed.current_bytes != 0) return error.Io;
}

test "BIOS artifacts accept only their own workload family" {
    for (0..3) |workload| {
        try validateWorkload(false, @intCast(workload));
        try std.testing.expectError(error.InvalidArgument, validateWorkload(true, @intCast(workload)));
    }
    try validateWorkload(true, 3);
    try std.testing.expectError(error.InvalidArgument, validateWorkload(false, 3));
    try std.testing.expectError(error.InvalidArgument, validateWorkload(true, 4));
    try std.testing.expectError(error.InvalidArgument, validateWorkload(false, std.math.maxInt(u32)));
}

fn core_main(ctx: *const Context) callconv(.c) void {
    // Only this new target owns this BSS range. Existing Core startup and
    // thunks are unchanged. Zig compiler_rt uses a small global BSS region.
    const bss: [*]u8 = @ptrCast(&__prep_bss_start);
    @memset(bss[0 .. @intFromPtr(&__prep_bss_end) - @intFromPtr(bss)], 0);
    var output: Output = .{ .boot_drive = ctx.drive, .qemu = entropy.qemuBios() };
    const passed = if (run(ctx, &output)) |_| true else |err| result: {
        output.logger().say("USOSPREP TERMINAL FAIL {s}\n", .{@errorName(err)});
        break :result false;
    };
    const value: u32 = if (passed) 0x10 else 0x11;
    if (output.qemu) asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (@as(u16, 0xf4)),
    );
}
comptime {
    // The real firmware symbol and ABI are unchanged. Host config tests do
    // not instantiate the BIOS thunks or issue hardware instructions.
    if (!builtin.is_test) @export(&core_main, .{ .name = "core_main" });
}

test "BIOS WIM extent and image selection reject ambiguity before target writes" {
    var cfg: [512]u8 = @splat(0);
    std.mem.writeInt(u64, cfg[96..104], 2048 * 512, .little);
    std.mem.writeInt(u64, cfg[104..112], 4096, .little);
    std.mem.writeInt(u32, cfg[136..140], 2, .little);
    const selected = try wimConfig(&cfg, 2056 * 512);
    try std.testing.expectEqual(@as(u32, 2), selected.index);
    try std.testing.expectEqual(@as(u64, 4096), selected.size);
    std.mem.writeInt(u32, cfg[136..140], 0, .little);
    try std.testing.expectError(error.InvalidArgument, wimConfig(&cfg, 2056 * 512));
    std.mem.writeInt(u32, cfg[136..140], 1, .little);
    std.mem.writeInt(u64, cfg[96..104], 1024 * 512, .little);
    try std.testing.expectError(error.InvalidArgument, wimConfig(&cfg, 2056 * 512));
    std.mem.writeInt(u64, cfg[96..104], 2048 * 512 + 1, .little);
    try std.testing.expectError(error.InvalidArgument, wimConfig(&cfg, 2056 * 512));
    std.mem.writeInt(u64, cfg[96..104], 2048 * 512, .little);
    try std.testing.expectError(error.Bounds, wimConfig(&cfg, 2056 * 512 - 1));
    std.mem.writeInt(u64, cfg[104..112], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.Bounds, wimConfig(&cfg, std.math.maxInt(u64)));
}
