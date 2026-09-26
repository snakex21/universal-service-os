// Legacy VGA routing for Windows 7 on UEFI without CSM (UefiSeven path only).
// Windows 7's vga/vgapnp miniport probes 0x3CE/0x3CF and 0x3C4/0x3C5 before it
// uses the VBE modes UefiSeven provides. With CSM off, some firmware (X470 +
// RX 560) leaves the root port's VGA Enable or the GPU's I/O decode off, the
// probe reads 0xFF and the driver fails with Code 10 ("Starting Windows" freeze).
// Order: log -> PciIo.Attributes(Enable, VGA...) -> raw bridge/command bits only
// where still missing and provably safe -> log again. Never used with CSM.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const cc = uefi.cc;
const Status = uefi.Status;
const trace = @import("windows7_uefi_trace.zig");
const probe = @import("windows7_uefi_memory_probe.zig");
const DevicePath = uefi.protocol.DevicePath;

pub const attr = struct {
    pub const vga_palette_io: u64 = 0x0004;
    pub const vga_memory: u64 = 0x0008;
    pub const vga_io: u64 = 0x0010;
    pub const io: u64 = 0x0100;
    pub const memory: u64 = 0x0200;
    pub const bus_master: u64 = 0x0400;
    pub const vga_palette_io_16: u64 = 0x20000;
    pub const vga_io_16: u64 = 0x40000;
};
const Width = enum(u32) { u8 = 0, u16 = 1, u32 = 2, u64 = 3 };
pub const Operation = enum(u32) { get = 0, set = 1, enable = 2, disable = 3, supported = 4 };
const ConfigFn = *const fn (*PciIo, Width, u32, usize, *anyopaque) callconv(cc) Status;
pub const PciIo = extern struct {
    poll_mem: *const anyopaque,
    poll_io: *const anyopaque,
    mem_read: *const anyopaque,
    mem_write: *const anyopaque,
    io_read: *const anyopaque,
    io_write: *const anyopaque,
    pci_read: ConfigFn,
    pci_write: ConfigFn,
    copy_mem: *const anyopaque,
    map: *const anyopaque,
    unmap: *const anyopaque,
    allocate_buffer: *const anyopaque,
    free_buffer: *const anyopaque,
    flush: *const anyopaque,
    get_location: *const fn (*PciIo, *usize, *usize, *usize, *usize) callconv(cc) Status,
    attributes: *const fn (*PciIo, Operation, u64, ?*u64) callconv(cc) Status,
    get_bar_attributes: *const fn (*PciIo, u8, ?*u64, ?*?*anyopaque) callconv(cc) Status,
    set_bar_attributes: *const anyopaque,
    rom_size: u64,
    rom_image: ?*anyopaque,
    pub const guid = uefi.Guid{ .time_low = 0x4cf5b200, .time_mid = 0x68b8, .time_high_and_version = 0x4ca5, .clock_seq_high_and_reserved = 0x9e, .clock_seq_low = 0xec, .node = .{ 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a } };

    fn read(self: *PciIo, comptime T: type, offset: u32) T {
        var value: T = if (T == u8) 0xff else if (T == u16) 0xffff else 0xffffffff;
        const w: Width = switch (T) {
            u8 => .u8,
            u16 => .u16,
            u32 => .u32,
            else => @compileError("width"),
        };
        _ = self.pci_read(self, w, offset, 1, @ptrCast(&value));
        return value;
    }
    fn write(self: *PciIo, comptime T: type, offset: u32, value: T) Status {
        var v = value;
        const w: Width = if (T == u8) .u8 else if (T == u16) .u16 else .u32;
        return self.pci_write(self, w, offset, 1, @ptrCast(&v));
    }
    fn attribute(self: *PciIo, op: Operation, value: u64) struct { Status, u64 } {
        var result: u64 = 0;
        const status = self.attributes(self, op, value, if (op == .get or op == .supported) &result else null);
        return .{ status, result };
    }
};

// ---- pure decisions (unit tested) ----

/// I/O window of a type-1 header. `null` when the window is disabled (base > limit).
pub fn ioWindow(base_reg: u8, limit_reg: u8, base_upper: u16, limit_upper: u16) ?[2]u32 {
    const wide = base_reg & 0x0f == 0x01;
    const base: u32 = (@as(u32, base_reg & 0xf0) << 8) | (if (wide) @as(u32, base_upper) << 16 else 0);
    const limit: u32 = (@as(u32, limit_reg & 0xf0) << 8) | 0xfff | (if (wide) @as(u32, limit_upper) << 16 else 0);
    if (base > limit) return null;
    return .{ base, limit };
}
/// Setting a bridge's I/O Space Enable must never make it claim the legacy
/// motherboard ports (0x0000-0x0FFF) through a zero or low I/O window.
pub fn bridgeIoEnableSafe(window: ?[2]u32) bool {
    const w = window orelse return true;
    return w[0] >= 0x1000;
}
/// Attributes to request on the GPU, limited to its Supported mask.
pub fn gpuAttributes(supported: u64, include_io: bool, use_16: bool) u64 {
    var want: u64 = attr.memory | attr.vga_memory;
    if (include_io) want |= attr.io;
    if (!use_16 and supported & attr.vga_io != 0) want |= attr.vga_io else if (supported & attr.vga_io_16 != 0) want |= attr.vga_io_16;
    if (!use_16 and supported & attr.vga_palette_io != 0) want |= attr.vga_palette_io else if (supported & attr.vga_palette_io_16 != 0) want |= attr.vga_palette_io_16;
    return want & supported;
}

pub const Probe = struct {
    misc: u8 = 0,
    gc_index: u8 = 0,
    gc_set_reset: u8 = 0,
    gc_bit_mask: u8 = 0,
    gc_read_map: u8 = 0,
    seq_memory_mode: u8 = 0,
    seq_toggled: u8 = 0,
    a0000: [8]u8 = .{0} ** 8,
    pub fn gcOk(p: Probe) bool {
        return p.gc_index & 0x0f == 0x08 and p.gc_set_reset & 0x0f == 0x05 and p.gc_bit_mask == 0xbb and p.gc_read_map & 0x03 == 0x03;
    }
    pub fn seqOk(p: Probe) bool {
        return (p.seq_memory_mode ^ p.seq_toggled) & 0x08 == 0x08;
    }
    pub fn ok(p: Probe) bool {
        return p.gcOk() and p.seqOk();
    }
};

// ---- hardware access ----

fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "{dx}" (port),
    );
}
fn in8(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}
fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "{dx}" (port),
    );
}
fn in32(port: u16) u32 {
    return asm volatile ("inl %[p], %[v]"
        : [v] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}
fn gcReadback(index: u8, value: u8) u8 {
    out8(0x3ce, index);
    const old = in8(0x3cf);
    out8(0x3cf, value);
    const got = in8(0x3cf);
    out8(0x3cf, old);
    return got;
}
/// The register test vga.sys performs, with every register restored.
pub fn vgaProbe() Probe {
    var p = Probe{};
    p.misc = in8(0x3cc);
    const gc_saved = in8(0x3ce);
    p.gc_set_reset = gcReadback(0x00, 0x05);
    p.gc_read_map = gcReadback(0x04, 0x03);
    p.gc_bit_mask = gcReadback(0x08, 0xbb);
    out8(0x3ce, 0x08);
    p.gc_index = in8(0x3ce);
    out8(0x3ce, gc_saved);
    const seq_saved = in8(0x3c4);
    out8(0x3c4, 0x04);
    p.seq_memory_mode = in8(0x3c5);
    out8(0x3c5, p.seq_memory_mode ^ 0x08);
    p.seq_toggled = in8(0x3c5);
    out8(0x3c5, p.seq_memory_mode);
    out8(0x3c4, seq_saved);
    for (&p.a0000, 0..) |*b, i| b.* = @as(*volatile u8, @ptrFromInt(0xa0000 + i)).*;
    return p;
}
fn logProbe(log: *trace.Session, stage: []const u8, p: Probe) void {
    log.print("VGA probe {s}: {s} GC(idx08={x:0>2} SR05={x:0>2} BMbb={x:0>2} RM03={x:0>2}) {s} SEQ(MM={x:0>2} toggled={x:0>2}) {s} MISC3CC={x:0>2} A0000={x}", .{
        stage, if (p.ok()) "PASS" else "FAIL", p.gc_index, p.gc_set_reset, p.gc_bit_mask, p.gc_read_map, if (p.gcOk()) "ok" else "bad", p.seq_memory_mode, p.seq_toggled, if (p.seqOk()) "ok" else "bad", p.misc, p.a0000,
    });
}

const Device = struct {
    io: *PciIo,
    handle: uefi.Handle,
    seg: usize = 0,
    bus: usize = 0,
    dev: usize = 0,
    func: usize = 0,
    fn locate(self: *Device) void {
        _ = self.io.get_location(self.io, &self.seg, &self.bus, &self.dev, &self.func);
    }
    fn isBridge(self: Device) bool {
        return self.io.read(u8, 0x0e) & 0x7f == 1;
    }
    fn window(self: Device) ?[2]u32 {
        return ioWindow(self.io.read(u8, 0x1c), self.io.read(u8, 0x1d), self.io.read(u16, 0x30), self.io.read(u16, 0x32));
    }
};
fn logDevice(log: *trace.Session, stage: []const u8, d: Device) void {
    const id = d.io.read(u32, 0x00);
    const class = d.io.read(u32, 0x08) >> 8;
    const cmd = d.io.read(u16, 0x04);
    const cur = d.io.attribute(.get, 0);
    const sup = d.io.attribute(.supported, 0);
    if (d.isBridge()) {
        const bc = d.io.read(u16, 0x3e);
        const w = d.window();
        log.print("PCI {s} bridge {x:0>4}:{x:0>2}:{x:0>2}.{x} id={x:0>8} class={x:0>6} CMD={x:0>4}(io={d} mem={d}) BRIDGE_CTL={x:0>4}(vga={d} vga16={d}) IOwin={s}{x}-{x} attrs={x}/{x} sup={x}", .{
            stage, d.seg, d.bus, d.dev, d.func, id, class, cmd, cmd & 1, (cmd >> 1) & 1, bc, (bc >> 3) & 1, (bc >> 4) & 1, if (w == null) "off " else "", if (w) |x| x[0] else 0, if (w) |x| x[1] else 0, cur[1], @intFromEnum(cur[0]), sup[1],
        });
    } else {
        var bars: [6]u32 = undefined;
        for (&bars, 0..) |*b, i| b.* = d.io.read(u32, 0x10 + @as(u32, @intCast(i)) * 4);
        log.print("PCI {s} gpu {x:0>4}:{x:0>2}:{x:0>2}.{x} id={x:0>8} class={x:0>6} CMD={x:0>4}(io={d} mem={d} bm={d}) BAR={x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8} attrs={x}/{x} sup={x}", .{
            stage, d.seg, d.bus, d.dev, d.func, id, class, cmd, cmd & 1, (cmd >> 1) & 1, (cmd >> 2) & 1, bars[0], bars[1], bars[2], bars[3], bars[4], bars[5], cur[1], @intFromEnum(cur[0]), sup[1],
        });
    }
}
/// I/O BARs of a type-0 header (0 = unassigned); the GPU may take I/O decode
/// only when none of them could alias the legacy motherboard ports.
fn gpuIoBarsSafe(d: Device, behind_safe_bridge: bool) bool {
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const bar = d.io.read(u32, 0x10 + i * 4);
        if (bar & 1 == 1) {
            if (bar & 0xfffffffc < 0x1000 and !behind_safe_bridge) return false;
        } else if (bar & 0x6 == 0x4) i += 1; // 64-bit memory BAR
    }
    return true;
}

fn formatPath(dp: *const DevicePath, out: []u8) []const u8 {
    var w: usize = 0;
    var node = dp;
    var count: usize = 0;
    while (count < 16) : (count += 1) {
        const bytes: [*]const u8 = @ptrCast(node);
        const t = @intFromEnum(node.type);
        if (t == 0x7f) break;
        const piece = (if (t == 1 and node.subtype == 1)
            std.fmt.bufPrint(out[w..], "/Pci({x},{x})", .{ bytes[5], bytes[4] })
        else if (t == 2 and node.subtype == 1)
            std.fmt.bufPrint(out[w..], "/PciRoot({x})", .{std.mem.readInt(u32, bytes[8..12], .little)})
        else if (t == 2 and node.subtype == 3)
            std.fmt.bufPrint(out[w..], "/AcpiAdr({x})", .{std.mem.readInt(u32, bytes[4..8], .little)})
        else
            std.fmt.bufPrint(out[w..], "/Node({x},{x})", .{ t, node.subtype })) catch break;
        w += piece.len;
        if (node.length < 4) break;
        node = @ptrCast(bytes + node.length);
    }
    return out[0..w];
}

/// PCI controller behind the first GOP handle whose device path contains one.
fn gpuFromGop(bs: *uefi.tables.BootServices, log: *trace.Session) ?Device {
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.GraphicsOutput.guid }) catch null) orelse {
        log.line("VGA: no GOP handle");
        return null;
    };
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    for (handles, 0..) |h, i| {
        const dp = (bs.handleProtocol(DevicePath, h) catch null) orelse continue;
        var text: [256]u8 = undefined;
        const gop = (bs.handleProtocol(uefi.protocol.GraphicsOutput, h) catch null) orelse continue;
        log.print("VGA: GOP[{d}/{d}] fb={x:0>16} path={s}", .{ i, handles.len, gop.mode.frame_buffer_base, formatPath(dp, &text) });
        const found = (bs.locateDevicePath(dp, PciIo) catch null) orelse continue;
        const io = (bs.handleProtocol(PciIo, found[1]) catch null) orelse continue;
        var d = Device{ .io = io, .handle = found[1] };
        d.locate();
        return d;
    }
    return null;
}
/// Fallback: a display-class PciIo device whose BAR resources contain the GOP framebuffer.
fn gpuFromFramebuffer(bs: *uefi.tables.BootServices, log: *trace.Session) ?Device {
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null) orelse return null;
    const fb = gop.mode.frame_buffer_base;
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &PciIo.guid }) catch null) orelse return null;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    for (handles) |h| {
        const io = (bs.handleProtocol(PciIo, h) catch null) orelse continue;
        if (io.read(u8, 0x0b) != 0x03) continue;
        var bar: u8 = 0;
        while (bar < 6) : (bar += 1) {
            var res: ?*anyopaque = null;
            if (io.get_bar_attributes(io, bar, null, &res) != .success) continue;
            const p = res orelse continue;
            defer bs.freePool(@ptrCast(@alignCast(p))) catch {};
            const b: [*]const u8 = @ptrCast(p);
            if (b[0] != 0x8a) continue;
            const min = std.mem.readInt(u64, b[14..22], .little);
            const len = std.mem.readInt(u64, b[38..46], .little);
            if (fb >= min and fb - min < len) {
                var d = Device{ .io = io, .handle = h };
                d.locate();
                log.print("VGA: GPU matched by framebuffer {x} in BAR{d}", .{ fb, bar });
                return d;
            }
        }
    }
    return null;
}
/// Upstream bridges of `gpu`, root first, via its device path prefixes.
fn bridges(bs: *uefi.tables.BootServices, gpu: Device, out: []Device) usize {
    const dp = (bs.handleProtocol(DevicePath, gpu.handle) catch null) orelse return 0;
    var buf: [256]u8 align(8) = undefined;
    const src: [*]const u8 = @ptrCast(dp);
    var offset: usize = 0;
    var pci_ends: [8]usize = undefined;
    var n: usize = 0;
    var node: *const DevicePath = dp;
    var guard: usize = 0;
    while (@intFromEnum(node.type) != 0x7f and guard < 16) : (guard += 1) {
        if (node.length < 4) return 0;
        offset += node.length;
        if (@intFromEnum(node.type) == 1 and node.subtype == 1 and n < pci_ends.len) {
            pci_ends[n] = offset;
            n += 1;
        }
        node = @ptrCast(src + offset);
    }
    var count: usize = 0;
    if (n < 2) return 0;
    for (pci_ends[0 .. n - 1]) |end| {
        if (end + 4 > buf.len or count >= out.len) break;
        @memcpy(buf[0..end], src[0..end]);
        buf[end..][0..4].* = .{ 0x7f, 0xff, 4, 0 };
        const found = (bs.locateDevicePath(@ptrCast(&buf), PciIo) catch null) orelse continue;
        if (@intFromEnum(found[0].type) != 0x7f) continue;
        const io = (bs.handleProtocol(PciIo, found[1]) catch null) orelse continue;
        out[count] = .{ .io = io, .handle = found[1] };
        out[count].locate();
        count += 1;
    }
    return count;
}
fn logAmdDataFabric(log: *trace.Session) void {
    if (builtin.cpu.arch != .x86_64) return;
    const features = probe.cpuid(1);
    if (!probe.amdSyscfgSupported(probe.cpuid(0), features)) return;
    out32(0xcf8, 0x80000000 | (0x18 << 11) | 0x80);
    const vgaen = in32(0xcfc);
    out32(0xcf8, 0x80000000 | (0x18 << 11));
    const id = in32(0xcfc);
    log.print("AMD DF D18F0 id={x:0>8} VGAEn(0x80)={x:0>8} (read-only; VE=bit0)", .{ id, vgaen });
}
/// Bridges outside the GPU chain that already have VGA Enable (routing conflicts).
fn foreignVgaBridges(bs: *uefi.tables.BootServices, chain: []const Device, log: *trace.Session) usize {
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &PciIo.guid }) catch null) orelse return 0;
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    var conflicts: usize = 0;
    outer: for (handles) |h| {
        for (chain) |c| if (c.handle == h) continue :outer;
        const io = (bs.handleProtocol(PciIo, h) catch null) orelse continue;
        var d = Device{ .io = io, .handle = h };
        if (!d.isBridge() or io.read(u16, 0x3e) & 0x08 == 0) continue;
        d.locate();
        log.print("VGA: other bridge {x:0>2}:{x:0>2}.{x} already has VGA Enable", .{ d.bus, d.dev, d.func });
        conflicts += 1;
    }
    return conflicts;
}

pub fn statusName(s: Status) []const u8 {
    return std.enums.tagName(Status, s) orelse "vendor status";
}

pub const Outcome = enum { passed_before, passed_after, failed };

/// Routes legacy VGA to the GOP controller and logs everything to `log`.
pub fn prepare(log: *trace.Session) Outcome {
    if (builtin.cpu.arch != .x86_64) return .failed;
    const bs = uefi.system_table.boot_services orelse return .failed;
    const before = vgaProbe();
    logProbe(log, "before", before);
    logAmdDataFabric(log);
    var gpu = gpuFromGop(bs, log) orelse gpuFromFramebuffer(bs, log) orelse {
        log.line("VGA: GOP controller has no PciIo; routing unchanged");
        return if (before.ok()) .passed_before else .failed;
    };
    var chain_buf: [8]Device = undefined;
    const nb = bridges(bs, gpu, chain_buf[0 .. chain_buf.len - 1]);
    chain_buf[nb] = gpu;
    const chain = chain_buf[0 .. nb + 1];
    for (chain) |d| logDevice(log, "before", d);
    const conflicts = foreignVgaBridges(bs, chain, log);

    const upstream_safe = nb == 0 or bridgeIoEnableSafe(chain[nb - 1].window());
    const io_ok = gpuIoBarsSafe(gpu, nb > 0 and upstream_safe);
    const sup = gpu.io.attribute(.supported, 0);
    var want = gpuAttributes(sup[1], io_ok, false);
    var st = gpu.io.attributes(gpu.io, .enable, want, null);
    log.print("VGA: GPU Attributes(Enable, {x}) = {s} (supported {x}, io {s})", .{ want, statusName(st), sup[1], if (io_ok) "requested" else "withheld: I/O BAR could alias legacy ports" });
    if (st != .success) {
        want = gpuAttributes(sup[1], io_ok, true);
        st = gpu.io.attributes(gpu.io, .enable, want, null);
        log.print("VGA: GPU Attributes(Enable, {x}) _16 variants = {s}", .{ want, statusName(st) });
    }

    // Raw fallback: whatever the firmware left out, on each bridge root first.
    for (chain[0..nb]) |d| {
        const cmd = d.io.read(u16, 0x04);
        const bc = d.io.read(u16, 0x3e);
        const io_safe = bridgeIoEnableSafe(d.window());
        const want_cmd: u16 = cmd | 0x0002 | (if (io_safe) @as(u16, 1) else 0);
        if (bc & 0x08 == 0) {
            if (conflicts != 0) {
                log.print("VGA: bridge {x:0>2}:{x:0>2}.{x} VGA Enable left off: another bridge owns VGA", .{ d.bus, d.dev, d.func });
            } else {
                const s = d.io.write(u16, 0x3e, bc | 0x08);
                log.print("VGA: bridge {x:0>2}:{x:0>2}.{x} BRIDGE_CTL {x:0>4} -> {x:0>4} ({s})", .{ d.bus, d.dev, d.func, bc, d.io.read(u16, 0x3e), statusName(s) });
            }
        }
        if (want_cmd != cmd) {
            const s = d.io.write(u16, 0x04, want_cmd);
            log.print("VGA: bridge {x:0>2}:{x:0>2}.{x} CMD {x:0>4} -> {x:0>4} ({s})", .{ d.bus, d.dev, d.func, cmd, d.io.read(u16, 0x04), statusName(s) });
        }
        if (!io_safe) log.print("VGA: bridge {x:0>2}:{x:0>2}.{x} I/O enable withheld: I/O window below 0x1000", .{ d.bus, d.dev, d.func });
    }
    const gcmd = gpu.io.read(u16, 0x04);
    const want_gcmd: u16 = gcmd | 0x0002 | (if (io_ok) @as(u16, 1) else 0);
    if (want_gcmd != gcmd) {
        const s = gpu.io.write(u16, 0x04, want_gcmd);
        log.print("VGA: gpu CMD {x:0>4} -> {x:0>4} ({s})", .{ gcmd, gpu.io.read(u16, 0x04), statusName(s) });
    }
    gpu.locate();
    for (chain) |d| logDevice(log, "after", d);
    const after = vgaProbe();
    logProbe(log, "after", after);
    if (before.ok()) return .passed_before;
    return if (after.ok()) .passed_after else .failed;
}

/// Short console note when the display will probably stay frozen (PL + EN;
/// the firmware font may lack Polish diacritics, so ASCII only).
pub fn warnFrozenDisplay() void {
    const con = uefi.system_table.con_out orelse return;
    const text = std.unicode.utf8ToUtf16LeStringLiteral("\r\n" ++
        "USOS: brak zgodnej grafiki VGA - ekran moze sie zatrzymac na \"Uruchamianie systemu Windows\",\r\n" ++
        "      a instalacja trwa w tle. Nie wylaczaj komputera.\r\n" ++
        "USOS: no compatible VGA graphics - the screen may stop at \"Starting Windows\"\r\n" ++
        "      while setup continues in the background. Do not power off.\r\n");
    _ = con.outputString(text) catch {};
    if (uefi.system_table.boot_services) |bs| bs.stall(5 * std.time.us_per_s) catch {};
}

test "I/O window decoding" {
    try std.testing.expect(ioWindow(0xf0, 0x00, 0, 0) == null);
    try std.testing.expectEqual([2]u32{ 0, 0xfff }, ioWindow(0x00, 0x00, 0, 0).?);
    try std.testing.expectEqual([2]u32{ 0xe000, 0xefff }, ioWindow(0xe1, 0xe1, 0, 0).?);
    try std.testing.expectEqual([2]u32{ 0x1e000, 0x1efff }, ioWindow(0xe1, 0xe1, 1, 1).?);
    try std.testing.expect(bridgeIoEnableSafe(null));
    try std.testing.expect(!bridgeIoEnableSafe(ioWindow(0x00, 0x00, 0, 0)));
    try std.testing.expect(bridgeIoEnableSafe(ioWindow(0xe0, 0xe0, 0, 0)));
}
test "GPU attribute request prefers full VGA decode, falls back to 16-bit" {
    const full = attr.vga_io | attr.vga_palette_io | attr.vga_memory | attr.vga_io_16 | attr.vga_palette_io_16 | attr.io | attr.memory;
    try std.testing.expectEqual(attr.memory | attr.vga_memory | attr.io | attr.vga_io | attr.vga_palette_io, gpuAttributes(full, true, false));
    try std.testing.expectEqual(attr.memory | attr.vga_memory | attr.vga_io_16 | attr.vga_palette_io_16, gpuAttributes(full, false, true));
    const only16 = attr.vga_memory | attr.vga_io_16 | attr.io | attr.memory;
    try std.testing.expectEqual(attr.memory | attr.vga_memory | attr.io | attr.vga_io_16, gpuAttributes(only16, true, false));
    try std.testing.expectEqual(@as(u64, 0), gpuAttributes(0, true, false));
}
test "VGA probe verdict" {
    const good = Probe{ .gc_index = 0x08, .gc_set_reset = 0x05, .gc_bit_mask = 0xbb, .gc_read_map = 0x03, .seq_memory_mode = 0x06, .seq_toggled = 0x0e };
    try std.testing.expect(good.ok());
    const floating = Probe{ .gc_index = 0xff, .gc_set_reset = 0xff, .gc_bit_mask = 0xff, .gc_read_map = 0xff, .seq_memory_mode = 0xff, .seq_toggled = 0xff };
    try std.testing.expect(!floating.ok());
    var no_seq = good;
    no_seq.seq_toggled = no_seq.seq_memory_mode;
    try std.testing.expect(!no_seq.ok());
}
