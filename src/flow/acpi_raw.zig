//! Text summary for the raw ACPI dump (EFI\USOS\Logs\acpi\<machine>\raw\).
//! Written for the Windows 2000 ACPI HAL work on the X470
//! (docs/windows-2000-acpi-x470-2026-10-12.md): an ACPI 1.0b OS only sees
//! the RSDP's 32-bit RsdtAddress, the RSDT and the 32-bit FADT fields, so the
//! summary prints exactly that view next to the ACPI 2.0+ one and flags where
//! they differ.  Own code, from the ACPI specification only.
const std = @import("std");

pub const Writer = struct {
    buffer: []u8,
    used: usize = 0,

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buffer[self.used..], fmt, args) catch return;
        self.used += written.len;
    }

    pub fn text(self: *const Writer) []const u8 {
        return self.buffer[0..self.used];
    }
};

fn sum(bytes: []const u8) u8 {
    var s: u8 = 0;
    for (bytes) |c| s +%= c;
    return s;
}

fn r32(bytes: []const u8, at: usize) u32 {
    if (at + 4 > bytes.len) return 0;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn r64(bytes: []const u8, at: usize) u64 {
    if (at + 8 > bytes.len) return 0;
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn r16(bytes: []const u8, at: usize) u16 {
    if (at + 2 > bytes.len) return 0;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn r8(bytes: []const u8, at: usize) u8 {
    return if (at < bytes.len) bytes[at] else 0;
}

pub const Rsdp = struct { revision: u8, rsdt: u32, xsdt: u64, length: u32, sum20_ok: bool, sum_ext_ok: bool };

/// `bytes` = 20 bytes (ACPI 1.0) or 36 (2.0+).
pub fn parseRsdp(bytes: []const u8) ?Rsdp {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..8], "RSD PTR ")) return null;
    const revision = bytes[15];
    const length: u32 = if (revision >= 2 and bytes.len >= 36) r32(bytes, 20) else 20;
    const ext_len: usize = if (revision >= 2 and bytes.len >= 36) @min(@as(usize, length), bytes.len) else 0;
    return .{
        .revision = revision,
        .rsdt = r32(bytes, 16),
        .xsdt = if (revision >= 2) r64(bytes, 24) else 0,
        .length = length,
        .sum20_ok = sum(bytes[0..20]) == 0,
        .sum_ext_ok = ext_len == 0 or sum(bytes[0..ext_len]) == 0,
    };
}

pub fn writeRsdp(w: *Writer, label: []const u8, address: usize, bytes: []const u8) void {
    const rsdp = parseRsdp(bytes) orelse {
        w.print("{s} at 0x{x}: no RSD PTR signature\r\n", .{ label, address });
        return;
    };
    w.print("{s} at 0x{x}: revision {d} RsdtAddress=0x{x:0>8} XsdtAddress=0x{x} checksum20={s} extended={s}\r\n", .{
        label,                                address,                              rsdp.revision, rsdp.rsdt, rsdp.xsdt,
        if (rsdp.sum20_ok) "ok" else "BAD", if (rsdp.sum_ext_ok) "ok" else "BAD",
    });
    if (rsdp.rsdt == 0) w.print("  !! RsdtAddress is 0: an ACPI 1.0 OS (Windows 2000, 98, ME) finds no tables\r\n", .{});
}

/// Verdict on the ACPI 1.0 table list: `rsdt_address` from the RSDP the OS
/// uses, `signatures` = the tables the RSDT lists. Flags with "!!" what an
/// ACPI 1.0 OS (Windows 2000's ACPI HAL, XP) cannot find.
pub fn writeRsdtVerdict(w: *Writer, rsdt_address: u32, rsdt_valid: bool, signatures: []const [4]u8) void {
    if (rsdt_address == 0) {
        w.print("!! ACPI 1.0 view: RsdtAddress is 0, no RSDT (CSMWrap 3.1.2-usos5 builds one from the XSDT)\r\n", .{});
        return;
    }
    if (!rsdt_valid) {
        w.print("!! ACPI 1.0 view: RSDT at 0x{x:0>8} invalid (CSMWrap 3.1.2-usos5 builds one from the XSDT)\r\n", .{rsdt_address});
        return;
    }
    var missing = false;
    for ([_]*const [4]u8{ "FACP", "APIC" }) |want| {
        var found = false;
        for (signatures) |sig| {
            if (std.mem.eql(u8, &sig, want)) found = true;
        }
        if (!found) {
            missing = true;
            w.print("!! ACPI 1.0 view: {s} missing from the RSDT\r\n", .{want});
        }
    }
    if (!missing) w.print("ACPI 1.0 view: RSDT at 0x{x:0>8} lists FACP and APIC\r\n", .{rsdt_address});
}

/// Generic Address Structure (12 bytes): space id, width, offset, access, address.
fn gasAddress(bytes: []const u8, at: usize) u64 {
    return r64(bytes, at + 4);
}

fn gasSpace(bytes: []const u8, at: usize) u8 {
    return r8(bytes, at);
}

/// The FADT as an ACPI 1.0b OS reads it (32-bit fields) and the 2.0+ X_ fields.
pub fn writeFadt(w: *Writer, fadt: []const u8) void {
    const len = fadt.len;
    w.print("FACP revision {d} length {d}\r\n", .{ r8(fadt, 8), len });
    const firmware_ctrl = r32(fadt, 36);
    const dsdt = r32(fadt, 40);
    // Byte 44 is INT_MODEL in ACPI 1.0 (reserved from 2.0 on), byte 45 is
    // Preferred_PM_Profile (2.0+, reserved in 1.0).
    w.print("  1.0 view: FIRMWARE_CTRL(FACS)=0x{x:0>8} DSDT=0x{x:0>8} INT_MODEL(byte 44, reserved in 2.0+)={d} Preferred_PM_Profile={d} SCI_INT={d} SMI_CMD=0x{x} ACPI_ENABLE=0x{x:0>2} ACPI_DISABLE=0x{x:0>2}\r\n", .{
        firmware_ctrl, dsdt, r8(fadt, 44), r8(fadt, 45), r16(fadt, 46), r32(fadt, 48), r8(fadt, 52), r8(fadt, 53),
    });
    w.print("  PM1a_EVT=0x{x} PM1b_EVT=0x{x} PM1a_CNT=0x{x} PM1b_CNT=0x{x} PM2_CNT=0x{x} PM_TMR=0x{x} GPE0=0x{x} GPE1=0x{x}\r\n", .{
        r32(fadt, 56), r32(fadt, 60), r32(fadt, 64), r32(fadt, 68), r32(fadt, 72), r32(fadt, 76), r32(fadt, 80), r32(fadt, 84),
    });
    w.print("  lengths: PM1_EVT={d} PM1_CNT={d} PM2_CNT={d} PM_TMR={d} GPE0={d} GPE1={d} GPE1_BASE={d}\r\n", .{
        r8(fadt, 88), r8(fadt, 89), r8(fadt, 90), r8(fadt, 91), r8(fadt, 92), r8(fadt, 93), r8(fadt, 94),
    });
    const flags = r32(fadt, 112);
    w.print("  P_LVL2_LAT={d} P_LVL3_LAT={d} DUTY_OFFSET={d} DUTY_WIDTH={d} DAY_ALRM=0x{x} MON_ALRM=0x{x} CENTURY=0x{x} IAPC_BOOT_ARCH=0x{x:0>4} Flags=0x{x:0>8}\r\n", .{
        r16(fadt, 96), r16(fadt, 98), r8(fadt, 104), r8(fadt, 105), r8(fadt, 106), r8(fadt, 107), r8(fadt, 108), r16(fadt, 109), flags,
    });
    w.print("  flags: WBINVD={d} PROC_C1={d} SLP_BUTTON={d} PWR_BUTTON={d} FIX_RTC={d} TMR_VAL_EXT(32-bit PM timer)={d} RESET_REG_SUP={d} HW_REDUCED={d} APIC_PHYS_DEST={d}\r\n", .{
        flags & 1, (flags >> 2) & 1, (flags >> 5) & 1, (flags >> 4) & 1, (flags >> 6) & 1, (flags >> 8) & 1, (flags >> 10) & 1, (flags >> 20) & 1, (flags >> 19) & 1,
    });
    if (len >= 148) {
        const x_fw = r64(fadt, 132);
        const x_dsdt = r64(fadt, 140);
        w.print("  2.0 view: X_FIRMWARE_CTRL=0x{x} X_DSDT=0x{x} X_PM1a_EVT=0x{x} X_PM1a_CNT=0x{x} X_PM_TMR=0x{x}(space {d}) X_GPE0=0x{x}\r\n", .{
            x_fw, x_dsdt, gasAddress(fadt, 148), gasAddress(fadt, 172), gasAddress(fadt, 208), gasSpace(fadt, 208), gasAddress(fadt, 220),
        });
        if (len >= 128) w.print("  RESET_REG=0x{x}(space {d}) RESET_VALUE=0x{x:0>2}\r\n", .{ gasAddress(fadt, 116), gasSpace(fadt, 116), r8(fadt, 128) });
        if (firmware_ctrl == 0 and x_fw != 0) w.print("  !! FIRMWARE_CTRL is 0, only X_FIRMWARE_CTRL is set: an ACPI 1.0 OS finds no FACS\r\n", .{});
        if (firmware_ctrl != 0 and x_fw != 0 and firmware_ctrl != x_fw) w.print("  !! FIRMWARE_CTRL and X_FIRMWARE_CTRL differ\r\n", .{});
        if (dsdt == 0 and x_dsdt != 0) w.print("  !! DSDT is 0, only X_DSDT is set: an ACPI 1.0 OS finds no DSDT\r\n", .{});
        if (dsdt != 0 and x_dsdt != 0 and dsdt != x_dsdt) w.print("  !! DSDT and X_DSDT differ\r\n", .{});
    }
    if (r32(fadt, 64) == 0) w.print("  !! PM1a_CNT_BLK is 0 (32-bit field)\r\n", .{});
    if (r32(fadt, 76) == 0) w.print("  !! PM_TMR_BLK is 0 (32-bit field): an ACPI 1.0 HAL has no PM timer\r\n", .{});
    if (r8(fadt, 91) != 4) w.print("  !! PM_TMR_LEN is not 4\r\n", .{});
}

/// MADT entries: every local APIC / x2APIC, I/O APIC, override and NMI.
pub fn writeMadt(w: *Writer, madt: []const u8) void {
    if (madt.len < 44) return;
    w.print("APIC (MADT) revision {d} length {d} LocalApicAddress=0x{x:0>8} flags=0x{x} (PCAT_COMPAT={d})\r\n", .{
        r8(madt, 8), madt.len, r32(madt, 36), r32(madt, 40), r32(madt, 40) & 1,
    });
    var lapic_total: usize = 0;
    var lapic_enabled: usize = 0;
    var lapic_online_capable: usize = 0;
    var max_id: u32 = 0;
    var x2apic: usize = 0;
    var ioapics: usize = 0;
    var at: usize = 44;
    while (at + 2 <= madt.len) {
        const kind = madt[at];
        const len = madt[at + 1];
        if (len < 2 or at + len > madt.len) {
            w.print("  !! malformed entry at offset {d} (type {d} length {d})\r\n", .{ at, kind, len });
            break;
        }
        const e = madt[at .. at + len];
        switch (kind) {
            0 => {
                lapic_total += 1;
                const flags = r32(e, 4);
                if (flags & 1 != 0) lapic_enabled += 1;
                if (flags & 2 != 0) lapic_online_capable += 1;
                if (flags & 1 != 0 and e[3] > max_id) max_id = e[3];
                w.print("  LAPIC uid {d} apic_id {d} flags 0x{x}\r\n", .{ e[2], e[3], flags });
            },
            1 => {
                ioapics += 1;
                w.print("  IOAPIC id {d} address 0x{x:0>8} gsi_base {d}\r\n", .{ e[2], r32(e, 4), r32(e, 8) });
            },
            2 => w.print("  INT_SRC_OVR bus {d} irq {d} -> gsi {d} flags 0x{x:0>4}\r\n", .{ e[2], e[3], r32(e, 4), r16(e, 8) }),
            3 => w.print("  NMI_SRC flags 0x{x:0>4} gsi {d}\r\n", .{ r16(e, 2), r32(e, 4) }),
            4 => w.print("  LAPIC_NMI uid {d} flags 0x{x:0>4} lint {d}\r\n", .{ e[2], r16(e, 3), r8(e, 5) }),
            5 => w.print("  LAPIC_ADDR_OVR 0x{x}\r\n", .{r64(e, 4)}),
            9 => {
                x2apic += 1;
                w.print("  X2APIC id {d} flags 0x{x} uid {d}\r\n", .{ r32(e, 4), r32(e, 8), r32(e, 12) });
            },
            0x0A => w.print("  X2APIC_NMI uid {d} flags 0x{x:0>4} lint {d}\r\n", .{ r32(e, 4), r16(e, 2), r8(e, 8) }),
            else => w.print("  entry type {d} length {d}\r\n", .{ kind, len }),
        }
        at += len;
    }
    w.print("  total: LAPIC {d} (enabled {d}, online-capable {d}, highest enabled id {d}), X2APIC {d}, IOAPIC {d}\r\n", .{
        lapic_total, lapic_enabled, lapic_online_capable, max_id, x2apic, ioapics,
    });
}

pub fn writeHpet(w: *Writer, hpet: []const u8) void {
    if (hpet.len < 56) return;
    w.print("HPET table: event_timer_block_id=0x{x:0>8} base=0x{x}(space {d}) number {d} min_tick {d} page_protection 0x{x}\r\n", .{
        r32(hpet, 36), gasAddress(hpet, 40), gasSpace(hpet, 40), r8(hpet, 52), r16(hpet, 53), r8(hpet, 55),
    });
}

/// Raw file name for the n-th table of a root table: "FACP-03.bin".
pub fn rawName(signature: [4]u8, index: usize, out: []u8) []const u8 {
    var sig: [4]u8 = undefined;
    for (signature, 0..) |c, i| sig[i] = if (std.ascii.isAlphanumeric(c)) c else '_';
    return std.fmt.bufPrint(out, "{s}-{d:0>2}.bin", .{ sig, index }) catch "";
}

fn fixSum(bytes: []u8, at: usize) void {
    bytes[at] = 0;
    bytes[at] = 0 -% sum(bytes);
}

test "RSDP 1.0 view and the RsdtAddress 0 warning" {
    var rsdp = [_]u8{0} ** 36;
    @memcpy(rsdp[0..8], "RSD PTR ");
    rsdp[15] = 2;
    std.mem.writeInt(u32, rsdp[16..20], 0xBD068600, .little);
    std.mem.writeInt(u32, rsdp[20..24], 36, .little);
    std.mem.writeInt(u64, rsdp[24..32], 0xBD068728, .little);
    rsdp[8] = 0;
    rsdp[8] = 0 -% sum(rsdp[0..20]);
    fixSum(&rsdp, 32);
    const p = parseRsdp(&rsdp).?;
    try std.testing.expect(p.sum20_ok and p.sum_ext_ok);
    try std.testing.expectEqual(@as(u32, 0xBD068600), p.rsdt);
    var buf: [512]u8 = undefined;
    var w = Writer{ .buffer = &buf };
    writeRsdp(&w, "rsdp20", 0x1000, &rsdp);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "RsdtAddress=0xbd068600") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!!") == null);
    std.mem.writeInt(u32, rsdp[16..20], 0, .little);
    w.used = 0;
    writeRsdp(&w, "rsdp20", 0x1000, &rsdp);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "RsdtAddress is 0") != null);
    try std.testing.expect(parseRsdp("not an rsdp at all.") == null);
}

test "RSDT verdict flags RsdtAddress 0 and missing FACP/APIC" {
    var buf: [1024]u8 = undefined;
    var w = Writer{ .buffer = &buf };
    writeRsdtVerdict(&w, 0, false, &.{});
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!! ACPI 1.0 view: RsdtAddress is 0") != null);
    w.used = 0;
    writeRsdtVerdict(&w, 0xBD068600, false, &.{});
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!! ACPI 1.0 view: RSDT at 0xbd068600 invalid") != null);
    w.used = 0;
    writeRsdtVerdict(&w, 0xBD068600, true, &.{ "FACP".*, "HPET".* });
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!! ACPI 1.0 view: APIC missing from the RSDT") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "FACP missing") == null);
    w.used = 0;
    writeRsdtVerdict(&w, 0xBD068600, true, &.{ "HPET".*, "APIC".*, "FACP".* });
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!!") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "lists FACP and APIC") != null);
}

test "FADT INT_MODEL is byte 44, Preferred_PM_Profile byte 45" {
    var fadt = [_]u8{0} ** 276;
    @memcpy(fadt[0..4], "FACP");
    fadt[44] = 1;
    fadt[45] = 3;
    var buf: [4096]u8 = undefined;
    var w = Writer{ .buffer = &buf };
    writeFadt(&w, &fadt);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "INT_MODEL(byte 44, reserved in 2.0+)=1 Preferred_PM_Profile=3") != null);
}

test "FADT 32-bit fields missing are flagged" {
    var fadt = [_]u8{0} ** 276;
    @memcpy(fadt[0..4], "FACP");
    fadt[8] = 6;
    std.mem.writeInt(u64, fadt[132..140], 0xBD063000, .little);
    std.mem.writeInt(u32, fadt[40..44], 0xBC98A000, .little);
    std.mem.writeInt(u64, fadt[140..148], 0xBC98A000, .little);
    std.mem.writeInt(u32, fadt[76..80], 0x808, .little);
    fadt[91] = 4;
    std.mem.writeInt(u32, fadt[64..68], 0x804, .little);
    var buf: [4096]u8 = undefined;
    var w = Writer{ .buffer = &buf };
    writeFadt(&w, &fadt);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "only X_FIRMWARE_CTRL is set") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "DSDT is 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "PM_TMR=0x808") != null);
    std.mem.writeInt(u32, fadt[36..40], 0xBD063000, .little);
    w.used = 0;
    writeFadt(&w, &fadt);
    try std.testing.expect(std.mem.indexOf(u8, w.text(), "!!") == null);
}

test "MADT summary counts LAPICs, IOAPICs and overrides" {
    var madt = [_]u8{0} ** (44 + 8 * 3 + 12 + 10 + 6);
    @memcpy(madt[0..4], "APIC");
    std.mem.writeInt(u32, madt[36..40], 0xFEE00000, .little);
    var at: usize = 44;
    for ([_]u8{ 0, 1, 2 }, 0..) |id, i| {
        madt[at] = 0;
        madt[at + 1] = 8;
        madt[at + 2] = @intCast(i);
        madt[at + 3] = id;
        std.mem.writeInt(u32, madt[at + 4 ..][0..4], if (i == 2) 0 else 1, .little);
        at += 8;
    }
    madt[at] = 1;
    madt[at + 1] = 12;
    madt[at + 2] = 17;
    std.mem.writeInt(u32, madt[at + 4 ..][0..4], 0xFEC00000, .little);
    at += 12;
    madt[at] = 2;
    madt[at + 1] = 10;
    madt[at + 3] = 0;
    std.mem.writeInt(u32, madt[at + 4 ..][0..4], 2, .little);
    at += 10;
    madt[at] = 4;
    madt[at + 1] = 6;
    madt[at + 2] = 0xFF;
    madt[at + 5] = 1;
    var buf: [4096]u8 = undefined;
    var w = Writer{ .buffer = &buf };
    writeMadt(&w, &madt);
    const t = w.text();
    try std.testing.expect(std.mem.indexOf(u8, t, "LAPIC 3 (enabled 2, online-capable 0, highest enabled id 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "IOAPIC id 17 address 0xfec00000 gsi_base 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "INT_SRC_OVR bus 0 irq 0 -> gsi 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "LAPIC_NMI uid 255") != null);
    var name: [16]u8 = undefined;
    try std.testing.expectEqualStrings("FACP-03.bin", rawName("FACP".*, 3, &name));
}
