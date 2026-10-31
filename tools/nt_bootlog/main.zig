// USOS NT pre-boot logger (diagnostic, X470 native NT 3.51 restart study).
// Runs as \EFI\BOOT\BOOTX64.EFI of the target disk's CSMWrap ESP, silently,
// on every boot: records why the previous boot ended (AMD FCH S5/Reset
// Status, then cleared), whether the RAM marker page survived (and what
// usosrst wrote into it), and the state the firmware hands over of every
// NVMe / xHCI / network PCI function; appends one 4 KiB record to the ring
// \USOS\BOOTLOG.TXT and chainloads CSMWrap from \EFI\BOOT\CSMWRAPX.EFI (same
// folder, so CSMWrap still finds csmwrap.ini next to itself). No screen
// output, no key presses; every logging error is ignored, the chainload is
// always attempted. Read-only MMIO except the PMxC0 write-1-to-clear.
// Version 2 (2026-10-31, Win10 x86 CSMWrap first-boot reset study): also the
// bus-0 PCI-to-PCI bridges (bus numbers, VGA enable, PCIe link state), the
// display controllers and a function count, so a GPU port the firmware hid
// or left without a link shows in the record of that boot.
// Own code, GPL-3.0-or-later (repository LICENSE).
const std = @import("std");
const uefi = std.os.uefi;
const d = @import("decode.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const version = "nt-bootlog 2";

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[v]"
        : [v] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

fn cfg(bus: u32, dev: u32, func: u32, reg: u32) u32 {
    outl(0xCF8, 0x8000_0000 | (bus << 16) | (dev << 11) | (func << 8) | (reg & 0xFC));
    return inl(0xCFC);
}

fn mmio32(address: u64) u32 {
    const p: *volatile u32 = @ptrFromInt(address);
    return p.*;
}

fn mmio8(address: u64) u8 {
    const p: *volatile u8 = @ptrFromInt(address);
    return p.*;
}

fn mmio64(address: u64) u64 {
    return @as(u64, mmio32(address)) | (@as(u64, mmio32(address + 4)) << 32);
}

// ------------------------------------------------------------------ file
fn openLog(root: *uefi.protocol.File) ?*uefi.protocol.File {
    const dir = root.open(wide("\\USOS"), .read_write_create, .{ .directory = true }) catch return null;
    dir.close() catch {};
    return root.open(wide("\\USOS\\BOOTLOG.TXT"), .read_write_create, .{}) catch null;
}

/// Boot number of this boot (header + 1); creates the fixed-size file the
/// first time.
fn nextBoot(file: *uefi.protocol.File) u32 {
    var header: [d.header_bytes]u8 = undefined;
    file.setPosition(0) catch return 0;
    const got = file.read(&header) catch 0;
    var last: u32 = 0;
    if (got == header.len) last = d.parseHeader(&header);
    if (last == 0) {
        // New (or foreign) file: write it out to full size once.
        var blank: [d.slot_bytes]u8 = undefined;
        d.finishSlot(&blank, 0, false);
        file.setPosition(d.header_bytes) catch return 0;
        var i: u32 = 0;
        while (i < d.slots) : (i += 1) _ = file.write(&blank) catch return 0;
    }
    return last +% 1;
}

fn store(file: *uefi.protocol.File, boot: u32, slot: *[d.slot_bytes]u8) void {
    file.setPosition(d.slotOffset(boot)) catch return;
    _ = file.write(slot) catch return;
    var header: [d.header_bytes]u8 = undefined;
    d.formatHeader(&header, boot);
    file.setPosition(0) catch return;
    _ = file.write(&header) catch return;
    file.flush() catch {};
}

// ------------------------------------------------------------------ probes
fn logTime(out: *d.Out) void {
    if (uefi.system_table.runtime_services.getTime()) |result| {
        const t = result[0];
        out.print(" rtc {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second });
    } else |_| out.put(" rtc ?");
}

fn logReset(out: *d.Out) void {
    const raw = mmio32(d.fch_s5_reset_status);
    out.print("reset cause PMxC0=0x{x:0>8}:", .{raw});
    d.decodeReset(out, raw);
    if (raw != 0 and raw != 0xFFFF_FFFF) {
        // Write-1-to-clear (Linux print_s5_reset_status_mmio does the same),
        // so the next boot shows only the next reset's cause.
        const p: *volatile u32 = @ptrFromInt(d.fch_s5_reset_status);
        p.* = raw;
        out.print(" | after clear 0x{x:0>8}", .{mmio32(d.fch_s5_reset_status)});
    }
    out.put("\r\n");
}

const PageState = struct { type: u32, found: bool };

fn markerPageType(bs: *uefi.tables.BootServices) PageState {
    var storage: [16384]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const map = bs.getMemoryMap(&storage) catch return .{ .type = 0, .found = false };
    var it = map.iterator();
    while (it.next()) |desc| {
        const end = desc.physical_start + desc.number_of_pages * 4096;
        if (d.marker_address >= desc.physical_start and d.marker_address < end)
            return .{ .type = @intFromEnum(desc.type), .found = true };
    }
    return .{ .type = 0, .found = false };
}

fn logMarker(out: *d.Out, bs: *uefi.tables.BootServices, boot: u32, tsc: u64) void {
    const state = markerPageType(bs);
    out.print("marker page 0x{x} uefi-type ", .{d.marker_address});
    if (!state.found) {
        out.put("NOT-IN-MAP (marker off)\r\n");
        return;
    }
    out.print("{s}", .{d.memoryTypeName(state.type)});
    // RAM types only: conventional, loader / boot-services code and data.
    const ram = state.type == 7 or (state.type >= 1 and state.type <= 4);
    if (!ram) {
        out.put(" (not RAM: marker off)\r\n");
        return;
    }
    const page: *[4096]u8 = @ptrFromInt(d.marker_address);
    var copy: [4096]u8 = undefined;
    for (&copy, 0..) |*b, i| b.* = @as(*volatile u8, &page[i]).*;
    out.put("\r\n");
    d.formatMarker(out, d.parseMarker(&copy), boot -% 1);
    d.formatNvmeRing(out, &copy);
    if (state.type != 7) {
        // Owned by the firmware (or another loader): never write it; usosrst
        // then finds no valid header and leaves the page alone too.
        out.put("  (page in use by firmware: not prepared this boot)\r\n");
        return;
    }
    // Claim it so neither the firmware nor CSMWrap allocates it before
    // ExitBootServices; loader data is still RAM in CSMWrap's E820.
    const at: [*]align(4096) uefi.Page = @ptrFromInt(d.marker_address);
    _ = bs.allocatePages(.{ .address = at }, .loader_data, 1) catch {
        out.put("  (allocatePages failed: not prepared this boot)\r\n");
        return;
    };
    d.initMarker(page, boot, tsc);
    out.put("  prepared for this boot\r\n");
}

fn logDevices(out: *d.Out) void {
    var functions: u32 = 0;
    var bridges: u32 = 0;
    var displays: u32 = 0;
    var bus: u32 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u32 = 0;
        while (dev < 32) : (dev += 1) {
            var func: u32 = 0;
            while (func < 8) : (func += 1) {
                const id = cfg(bus, dev, func, 0);
                if (id == 0xFFFF_FFFF or id & 0xFFFF == 0xFFFF or id == 0) {
                    if (func == 0) break;
                    continue;
                }
                functions += 1;
                const header = (cfg(bus, dev, func, 0x0C) >> 16) & 0xFF;
                const class = cfg(bus, dev, func, 8) >> 8;
                const kind = d.className(class);
                if (header & 0x7F == 0 and kind.len != 0) logDevice(out, bus, dev, func, id, class, kind);
                if (header & 0x7F == 0 and class >> 16 == 0x03) displays += 1;
                if (header & 0x7F == 1 and bus == 0) {
                    logBridge(out, dev, func, id);
                    bridges += 1;
                }
                if (func == 0 and header & 0x80 == 0) break;
            }
        }
    }
    outl(0xCF8, 0);
    d.formatSummary(out, functions, bridges, displays);
}

/// Link Capabilities / Link Status of the function's PCI Express
/// capability, null without one (bounded walk of the capability list).
fn pcieLink(bus: u32, dev: u32, func: u32) ?d.Link {
    if ((cfg(bus, dev, func, 4) >> 16) & 0x10 == 0) return null;
    var ptr = cfg(bus, dev, func, 0x34) & 0xFC;
    var hops: u32 = 0;
    while (ptr >= 0x40 and hops < 48) : (hops += 1) {
        const head = cfg(bus, dev, func, ptr);
        if (head & 0xFF == 0x10) return .{ .cap = cfg(bus, dev, func, ptr + 0x0C), .status = @truncate(cfg(bus, dev, func, ptr + 0x10) >> 16) };
        ptr = (head >> 8) & 0xFC;
    }
    return null;
}

fn logBridge(out: *d.Out, dev: u32, func: u32, id: u32) void {
    const cmdsts = cfg(0, dev, func, 4);
    const bctl: u16 = @truncate(cfg(0, dev, func, 0x3C) >> 16);
    d.formatBridge(out, dev, func, id, cfg(0, dev, func, 0x18), @truncate(cmdsts), @truncate(cmdsts >> 16), bctl, pcieLink(0, dev, func));
}

fn logDevice(out: *d.Out, bus: u32, dev: u32, func: u32, id: u32, class: u32, kind: []const u8) void {
    const cmdsts = cfg(bus, dev, func, 4);
    const command: u16 = @truncate(cmdsts);
    out.print("{s} {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} class {x:0>6}", .{ kind, bus, dev, func, id & 0xFFFF, id >> 16, class });
    d.formatCommand(out, command, @truncate(cmdsts >> 16));
    const bar_lo = cfg(bus, dev, func, 0x10);
    var bar: u64 = bar_lo & ~@as(u32, 0xF);
    if (bar_lo & 6 == 4) bar |= @as(u64, cfg(bus, dev, func, 0x14)) << 32;
    out.print(" bar0={x}\r\n", .{bar});
    if (bar_lo & 1 != 0 or bar == 0 or command & 2 == 0) {
        out.put("  (no memory decode: registers not read)\r\n");
        return;
    }
    if (std.mem.eql(u8, kind, "NVMe")) {
        d.formatNvme(out, mmio32(bar + 0x14), mmio32(bar + 0x1C), mmio32(bar + 0x24), mmio64(bar + 0x28), mmio64(bar + 0x30));
    } else if (std.mem.eql(u8, kind, "xHCI")) {
        const caplength = mmio8(bar);
        const op = bar + caplength;
        d.formatXhci(out, caplength, mmio32(op), mmio32(op + 4), (mmio32(op + 0x18) | mmio32(op + 0x1C)) != 0, mmio64(op + 0x30));
    } else if (id & 0xFFFF == 0x8086 and class == 0x020000) {
        // Intel Ethernet (I211 and the rest of the e1000/igb families):
        // CTRL, STATUS, RCTL, TCTL have no read side effects.
        d.formatNic(out, mmio32(bar), mmio32(bar + 8), mmio32(bar + 0x100), mmio32(bar + 0x400));
    }
}

// ------------------------------------------------------------------ main
fn record(device: uefi.Handle, bs: *uefi.tables.BootServices, tsc0: u64) void {
    const fs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device) catch return) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};
    const file = openLog(root) orelse return;
    defer file.close() catch {};
    const boot = nextBoot(file);
    if (boot == 0) return;

    var slot: [d.slot_bytes]u8 = undefined;
    var out = d.Out{ .buf = slot[0 .. d.slot_bytes - 2] };
    out.print("=== boot {d} {s} tsc {d}", .{ boot, version, tsc0 });
    logTime(&out);
    out.put("\r\n");
    logReset(&out);
    logMarker(&out, bs, boot, tsc0);
    logDevices(&out);
    out.print("logger took {d} tsc ticks; chainload \\EFI\\BOOT\\CSMWRAPX.EFI\r\n", .{rdtsc() -% tsc0});
    d.finishSlot(&slot, out.len, out.truncated);
    store(file, boot, &slot);
}

fn chainload(device: uefi.Handle, bs: *uefi.tables.BootServices) uefi.Status {
    const dp = (bs.handleProtocol(uefi.protocol.DevicePath, device) catch return .load_error) orelse return .load_error;
    var storage: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const path = dp.createFileDevicePath(arena.allocator(), wide("\\EFI\\BOOT\\CSMWRAPX.EFI")) catch return .load_error;
    const image = bs.loadImage(false, uefi.handle, .{ .device_path = path }) catch return .load_error;
    const result = bs.startImage(image) catch return .load_error;
    return result.code;
}

pub fn main() uefi.Status {
    const tsc0 = rdtsc();
    const bs = uefi.system_table.boot_services orelse return .load_error;
    const loaded = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return .load_error) orelse return .load_error;
    const device = loaded.device_handle orelse return .load_error;
    record(device, bs, tsc0);
    return chainload(device, bs);
}
