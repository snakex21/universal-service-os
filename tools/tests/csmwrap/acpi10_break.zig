// QEMU test helper only (tools/tests/csmwrap/run_csmwrap_acpi10_qemu.py), never
// shipped: breaks the firmware's ACPI 1.0 view the way some UEFI boards
// publish it, then starts CSMWrap (\EFI\BOOT\CSMWRAP.EFI on the same volume).
//  - RSDP (ACPI 2.0 GUID): RsdtAddress = 0, both checksums fixed;
//  - FADT (through the XSDT): FIRMWARE_CTRL, DSDT, PM1a_EVT, PM1a_CNT,
//    PM_TMR, GPE0 = 0 where the X_ field is set, checksum fixed.
// Prints "ACPI10-BREAK ..." on the console (serial in QEMU).
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

fn breakTables() void {
    const system = uefi.system_table;
    var rsdp: ?[*]u8 = null;
    for (system.configuration_table[0..system.number_of_table_entries]) |entry| {
        if (!entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) continue;
        rsdp = @ptrCast(entry.vendor_table);
    }
    const r = rsdp orelse {
        say("ACPI10-BREAK no ACPI 2.0 RSDP\n", .{});
        return;
    };
    const xsdt_addr = r64(r, 24);
    say("ACPI10-BREAK RSDP rsdt={x} xsdt={x}\n", .{ r32(r, 16), xsdt_addr });
    std.mem.writeInt(u32, r[16..20], 0, .little);
    r[8] = 0;
    r[8] = 0 -% sum(r[0..20]);
    r[32] = 0;
    r[32] = 0 -% sum(r[0..36]);

    const x: [*]u8 = @ptrFromInt(@as(usize, @intCast(xsdt_addr)));
    const xlen = r32(x, 4);
    var off: usize = 36;
    while (off + 8 <= xlen) : (off += 8) {
        const t: [*]u8 = @ptrFromInt(@as(usize, @intCast(r64(x, off))));
        if (!std.mem.eql(u8, t[0..4], "FACP")) continue;
        const len = r32(t, 4);
        if (len < 232) break;
        const pairs = [_][2]usize{ .{ 36, 132 }, .{ 40, 140 } };
        for (pairs) |p| {
            if (r64(t, p[1]) != 0) std.mem.writeInt(u32, t[p[0]..][0..4], 0, .little);
        }
        const blocks = [_][2]usize{ .{ 56, 148 }, .{ 64, 172 }, .{ 76, 208 }, .{ 80, 220 } };
        for (blocks) |b| {
            if (r64(t, b[1] + 4) != 0) std.mem.writeInt(u32, t[b[0]..][0..4], 0, .little);
        }
        t[9] = 0;
        t[9] = 0 -% sum(t[0..len]);
        say("ACPI10-BREAK FADT rev {d} len {d}: FIRMWARE_CTRL={x} DSDT={x} PM1a_EVT={x} PM_TMR={x} (X_FIRMWARE_CTRL={x} X_DSDT={x})\n", .{ t[8], len, r32(t, 36), r32(t, 40), r32(t, 56), r32(t, 76), r64(t, 132), r64(t, 140) });
        break;
    }
}

fn run() !uefi.Status {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    breakTables();
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NoLoadedImage;
    const device = loaded.device_handle orelse return error.NoDevice;
    const dp = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.NoDevicePath;
    var storage: [4096]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const path = try dp.createFileDevicePath(arena.allocator(), wide("\\EFI\\BOOT\\CSMWRAP.EFI"));
    const image = try bs.loadImage(false, uefi.handle, .{ .device_path = path });
    say("ACPI10-BREAK starting CSMWrap\n", .{});
    const result = try bs.startImage(image);
    return result.code;
}

pub fn main() uefi.Status {
    return run() catch |err| {
        say("ACPI10-BREAK error {s}\n", .{@errorName(err)});
        return .load_error;
    };
}
