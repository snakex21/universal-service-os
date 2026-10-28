// QEMU test helper only (tools/tests/csmwrap/run_csmwrap_acpi10_qemu.py
// --sci-off), never shipped: puts the machine back into legacy mode the way
// an AMI board hands it over (PM1a_CNT.SCI_EN = 0; OVMF leaves it 1), then
// starts CSMWrap (\EFI\BOOT\CSMWRAP.EFI on the same volume), so CSMWrap
// 3.1.2-usos6 patch 0007 sends the ACPI_ENABLE SMI_CMD write itself. QEMU's
// PIIX4/ICH9 model sets SCI_EN again on that write.
// Prints "ACPIEN-LEGACY ..." on the console (serial in QEMU).
// SPDX-License-Identifier: GPL-2.0-or-later
const std = @import("std");
const uefi = std.os.uefi;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var out: [260]u16 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (n + 2 >= out.len) break;
        if (c == '\n') {
            out[n] = '\r';
            n += 1;
        }
        out[n] = c;
        n += 1;
    }
    out[n] = 0;
    if (uefi.system_table.con_out) |con| _ = con.outputString(out[0..n :0]) catch false;
}

fn sum(bytes: []const u8) u8 {
    var s: u8 = 0;
    for (bytes) |c| s +%= c;
    return s;
}

fn r32(p: [*]u8, at: usize) u32 {
    return std.mem.readInt(u32, p[at..][0..4], .little);
}

fn r64(p: [*]u8, at: usize) u64 {
    return std.mem.readInt(u64, p[at..][0..8], .little);
}

fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

fn sciOff() void {
    const system = uefi.system_table;
    var rsdp: ?[*]u8 = null;
    for (system.configuration_table[0..system.number_of_table_entries]) |entry| {
        if (!entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) continue;
        rsdp = @ptrCast(entry.vendor_table);
    }
    const r = rsdp orelse {
        say("ACPIEN-LEGACY no ACPI 2.0 RSDP\n", .{});
        return;
    };
    const x: [*]u8 = @ptrFromInt(@as(usize, @intCast(r64(r, 24))));
    const xlen = r32(x, 4);
    var off: usize = 36;
    while (off + 8 <= xlen) : (off += 8) {
        const t: [*]u8 = @ptrFromInt(@as(usize, @intCast(r64(x, off))));
        if (!std.mem.eql(u8, t[0..4], "FACP")) continue;
        const port: u16 = @intCast(r32(t, 64) & 0xFFFF);
        if (port == 0) break;
        const before = inw(port);
        outw(port, before & ~@as(u16, 1));
        say("ACPIEN-LEGACY PM1a_CNT {x}: {x} -> {x}\n", .{ port, before, inw(port) });
        return;
    }
    say("ACPIEN-LEGACY no FADT PM1a_CNT\n", .{});
}

fn run() !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    sciOff();
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var storage: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const path = try dp.createFileDevicePath(arena.allocator(), wide("\\EFI\\BOOT\\CSMWRAP.EFI"));
    const image = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    say("ACPIEN-LEGACY starting CSMWrap\n", .{});
    const result = try bs.startImage(image);
    return result.code;
}

pub fn main() uefi.Status {
    return run() catch |err| {
        say("ACPIEN-LEGACY error {s}\n", .{@errorName(err)});
        return .load_error;
    };
}
