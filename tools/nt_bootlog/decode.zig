// USOS NT pre-boot logger: pure decoding and formatting (no UEFI calls), so
// `zig test tools/nt_bootlog/decode.zig` checks it on the host.
// Own code, GPL-3.0-or-later (repository LICENSE). Register meanings are
// taken from public sources: AMD FCH PMxC0 S5/Reset Status as decoded and
// cleared by Linux (arch/x86/kernel/cpu/amd.c, print_s5_reset_status_mmio:
// FCH_PM_BASE 0xFED80300, offset 0xC0, write-1-to-clear), NVMe 1.4 and
// xHCI 1.2 register layouts, Intel I211 datasheet (CTRL/STATUS/RCTL/TCTL).
const std = @import("std");

// ---------------------------------------------------------------- reset cause
pub const fch_s5_reset_status: u64 = 0xFED80300 + 0xC0;

pub const reset_bits = [_]struct { bit: u5, name: []const u8 }{
    .{ .bit = 0, .name = "THERMTRIP_L-pin" },
    .{ .bit = 1, .name = "power-button-4s" },
    .{ .bit = 2, .name = "SHUTDOWN_L-pin" },
    .{ .bit = 4, .name = "ASF-remote-power-off" },
    .{ .bit = 9, .name = "CPU-thermal-limit" },
    .{ .bit = 16, .name = "SYS_RST_L-pin(reset-button)" },
    .{ .bit = 17, .name = "software-PCI-reset" },
    .{ .bit = 18, .name = "CF9=04(INIT)" },
    .{ .bit = 19, .name = "CF9=06(warm/hard-reset)" },
    .{ .bit = 20, .name = "CF9=0E(full-reset)" },
    .{ .bit = 21, .name = "ACPI-sleep-state-transition(S3/S4/S5-wake)" },
    .{ .bit = 22, .name = "KB_RST_L-pin(8042)" },
    .{ .bit = 23, .name = "CPU-shutdown-event(triple-fault)" },
    .{ .bit = 24, .name = "failed-boot-timer" },
    .{ .bit = 25, .name = "hardware-watchdog" },
    .{ .bit = 26, .name = "ASF-remote-reset" },
    .{ .bit = 27, .name = "DF-sync-flood(uncorrected-error)" },
    .{ .bit = 29, .name = "FCH/MP1-warm-reset-handshake-failed" },
    .{ .bit = 30, .name = "parity-error" },
    .{ .bit = 31, .name = "software-sync-flood" },
};

/// Writes the decoded bit names (space separated) of a PMxC0 value.
pub fn decodeReset(out: *Out, value: u32) void {
    if (value == 0xFFFF_FFFF) {
        out.put("(all-ones: no FCH response)");
        return;
    }
    if (value == 0) {
        out.put("(none: zero, cleared by firmware or cold power-on)");
        return;
    }
    var known: u32 = 0;
    for (reset_bits) |entry| {
        const mask = @as(u32, 1) << entry.bit;
        known |= mask;
        if (value & mask != 0) {
            out.put(" ");
            out.put(entry.name);
        }
    }
    if (value & ~known != 0) out.print(" other-bits=0x{x:0>8}", .{value & ~known});
}

// ---------------------------------------------------------------- RAM marker
// One 4 KiB page above the NT 3.51 /MAXMEM=1024 limit (the 3.51 osloader
// BlpTruncateMemory drops every descriptor above it, so neither NTLDR nor
// the kernel ever uses the page), far below the firmware's top-down
// allocations near the top of low RAM. The logger claims it (EfiLoaderData,
// so CSMWrap's E820 still reports it as RAM) and writes the PRE part; NT's
// usosrst (1.8-nt351) writes the NT part only when the PRE part is valid.
pub const marker_address: u64 = 0x5000_0000;
pub const pre_signature = "USOSPRE1";
pub const nt_signature = "USOSNT35";
pub const off_pre_boot = 8;
pub const off_pre_check = 12;
pub const off_pre_tsc = 16;
pub const off_nt = 64;
pub const off_nt_boot = 72;
pub const off_nt_count = 76;
pub const off_nt_stages = 80;
pub const nt_stages_max = 64;
pub const off_nt_bugchecks = 144;
pub const off_nt_bugcheck_data = 148; // 5 x u32
pub const off_nt_seconds = 168; // seconds since usosrst load at the last stage

pub const Marker = struct {
    pre_valid: bool,
    pre_boot: u32,
    pre_tsc: u64,
    nt_valid: bool,
    nt_boot: u32,
    stages: []const u8,
    bugchecks: u32,
    bugcheck: [5]u32,
    seconds: u32,
};

fn le32(page: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, page[off..][0..4], .little);
}

pub fn parseMarker(page: []const u8) Marker {
    var m: Marker = .{
        .pre_valid = false,
        .pre_boot = 0,
        .pre_tsc = 0,
        .nt_valid = false,
        .nt_boot = 0,
        .stages = "",
        .bugchecks = 0,
        .bugcheck = .{ 0, 0, 0, 0, 0 },
        .seconds = 0,
    };
    if (page.len < 4096) return m;
    m.pre_boot = le32(page, off_pre_boot);
    m.pre_valid = std.mem.eql(u8, page[0..8], pre_signature) and le32(page, off_pre_check) == ~m.pre_boot;
    m.pre_tsc = std.mem.readInt(u64, page[off_pre_tsc..][0..8], .little);
    m.nt_valid = std.mem.eql(u8, page[off_nt..][0..8], nt_signature);
    if (!m.nt_valid) return m;
    m.nt_boot = le32(page, off_nt_boot);
    const count = @min(le32(page, off_nt_count), nt_stages_max);
    m.stages = page[off_nt_stages..][0..count];
    m.bugchecks = le32(page, off_nt_bugchecks);
    for (&m.bugcheck, 0..) |*v, i| v.* = le32(page, off_nt_bugcheck_data + 4 * i);
    m.seconds = le32(page, off_nt_seconds);
    return m;
}

/// Fresh page for this boot: PRE header, NT part empty.
pub fn initMarker(page: []u8, boot: u32, tsc: u64) void {
    @memset(page[0..4096], 0);
    @memcpy(page[0..8], pre_signature);
    std.mem.writeInt(u32, page[off_pre_boot..][0..4], boot, .little);
    std.mem.writeInt(u32, page[off_pre_check..][0..4], ~boot, .little);
    std.mem.writeInt(u64, page[off_pre_tsc..][0..8], tsc, .little);
}

pub fn formatMarker(out: *Out, m: Marker, previous_boot: u32) void {
    if (!m.pre_valid) {
        out.put("RAM marker: ABSENT (page did not survive the reset, or first boot with the logger)\r\n");
        return;
    }
    out.print("RAM marker: PRESENT (pre-boot record of boot {d}", .{m.pre_boot});
    if (m.pre_boot != previous_boot) out.print(", expected {d}", .{previous_boot});
    out.print(", tsc {d})\r\n", .{m.pre_tsc});
    if (!m.nt_valid) {
        out.put("  NT part: none (usosrst 1.8 never reached its load in that boot)\r\n");
        return;
    }
    out.print("  NT part: boot {d} stages \"", .{m.nt_boot});
    for (m.stages) |c| out.putByte(if (c >= 0x20 and c < 0x7F) c else '?');
    out.print("\" last-stage-at {d}s bugchecks {d}", .{ m.seconds, m.bugchecks });
    if (m.bugchecks != 0) out.print(" data {x:0>8} {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ m.bugcheck[0], m.bugcheck[1], m.bugcheck[2], m.bugcheck[3], m.bugcheck[4] });
    out.put("\r\n");
}

// ---------------------------------------------------------------- ring file
// \USOS\BOOTLOG.TXT: a 128-byte header line, then `slots` fixed 4 KiB text
// slots (space padded, CRLF at the end); boot n goes to slot (n-1) % slots.
// Fixed size 128 + 50 * 4096 = 204928 bytes.
pub const slots: u32 = 50;
pub const slot_bytes: usize = 4096;
pub const header_bytes: usize = 128;
pub const file_bytes: usize = header_bytes + slots * slot_bytes;
const header_prefix = "USOS NT pre-boot log v1 slots=50 slot=4096 last_boot=";

pub fn parseHeader(header: []const u8) u32 {
    if (header.len < header_prefix.len + 8 or !std.mem.startsWith(u8, header, header_prefix)) return 0;
    return std.fmt.parseInt(u32, header[header_prefix.len..][0..8], 10) catch 0;
}

pub fn formatHeader(out: *[header_bytes]u8, boot: u32) void {
    @memset(out, ' ');
    _ = std.fmt.bufPrint(out, header_prefix ++ "{d:0>8} (newest slot = (last_boot-1) % 50)", .{boot % 100_000_000}) catch {};
    out[header_bytes - 2] = '\r';
    out[header_bytes - 1] = '\n';
}

pub fn slotOffset(boot: u32) u64 {
    return header_bytes + @as(u64, (boot -% 1) % slots) * slot_bytes;
}

/// Pads a record to exactly one slot (truncation marked, CRLF at the end).
pub fn finishSlot(slot: *[slot_bytes]u8, used: usize, truncated: bool) void {
    var n = @min(used, slot_bytes - 2);
    if (truncated and n >= 12) {
        n -= 12;
        @memcpy(slot[n..][0..12], "[truncated]\n");
        n += 12;
    }
    @memset(slot[n .. slot_bytes - 2], ' ');
    slot[slot_bytes - 2] = '\r';
    slot[slot_bytes - 1] = '\n';
}

// ---------------------------------------------------------------- devices
pub fn className(class: u32) []const u8 {
    if (class == 0x010802) return "NVMe";
    if (class == 0x0C0330) return "xHCI";
    if (class >> 16 == 0x02) return "NIC";
    return "";
}

pub fn formatCommand(out: *Out, command: u16, status: u16) void {
    out.print(" cmd={x:0>4}(IO{d} MEM{d} BME{d}) sts={x:0>4}", .{ command, command & 1, (command >> 1) & 1, (command >> 2) & 1, status });
    // Sticky error bits: detected parity, signalled system error, received
    // master abort, received target abort, signalled target abort.
    if (status & 0x8000 != 0) out.put(" DPE");
    if (status & 0x4000 != 0) out.put(" SSE");
    if (status & 0x2000 != 0) out.put(" RMA");
    if (status & 0x1000 != 0) out.put(" RTA");
    if (status & 0x0800 != 0) out.put(" STA");
}

pub fn formatNvme(out: *Out, cc: u32, csts: u32, aqa: u32, asq: u64, acq: u64) void {
    out.print("  nvme CC={x:0>8} EN={d} SHN={d} CSTS={x:0>8} RDY={d} CFS={d} SHST={d} AQA={x:0>8} ASQ={x} ACQ={x}\r\n", .{
        cc, cc & 1, (cc >> 14) & 3, csts, csts & 1, (csts >> 1) & 1, (csts >> 2) & 3, aqa, asq, acq,
    });
}

pub fn formatXhci(out: *Out, caplength: u8, usbcmd: u32, usbsts: u32, crcr_nonzero: bool, dcbaap: u64) void {
    out.print("  xhci CAPLEN={x:0>2} USBCMD={x:0>8} R/S={d} USBSTS={x:0>8} HCH={d} HSE={d} HCE={d} CRCR={s} DCBAAP={x}\r\n", .{
        caplength, usbcmd, usbcmd & 1, usbsts, usbsts & 1, (usbsts >> 2) & 1, (usbsts >> 12) & 1, if (crcr_nonzero) "nonzero" else "zero", dcbaap,
    });
}

pub fn formatNic(out: *Out, ctrl: u32, status: u32, rctl: u32, tctl: u32) void {
    out.print("  nic CTRL={x:0>8} STATUS={x:0>8} RCTL={x:0>8} RCTL.EN={d} TCTL={x:0>8} TCTL.EN={d}\r\n", .{
        ctrl, status, rctl, (rctl >> 1) & 1, tctl, (tctl >> 1) & 1,
    });
}

pub fn memoryTypeName(t: u32) []const u8 {
    const names = [_][]const u8{ "reserved", "loader_code", "loader_data", "bs_code", "bs_data", "rt_code", "rt_data", "conventional", "unusable", "acpi_reclaim", "acpi_nvs", "mmio", "mmio_port", "pal", "persistent", "unaccepted" };
    return if (t < names.len) names[t] else "other";
}

// ---------------------------------------------------------------- text out
pub const Out = struct {
    buf: []u8,
    len: usize = 0,
    truncated: bool = false,

    pub fn put(self: *Out, text: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(room, text.len);
        @memcpy(self.buf[self.len..][0..n], text[0..n]);
        self.len += n;
        if (n < text.len) self.truncated = true;
    }
    pub fn putByte(self: *Out, c: u8) void {
        self.put(&[1]u8{c});
    }
    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch {
            self.truncated = true;
            self.len = self.buf.len;
            return;
        };
        self.len += written.len;
    }
    pub fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------- tests
test "reset cause decode" {
    var storage: [256]u8 = undefined;
    var out = Out{ .buf = &storage };
    decodeReset(&out, (1 << 20) | (1 << 27) | (1 << 3));
    try std.testing.expectEqualStrings(" CF9=0E(full-reset) DF-sync-flood(uncorrected-error) other-bits=0x00000008", out.slice());
    out = Out{ .buf = &storage };
    decodeReset(&out, 0);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "none") != null);
    out = Out{ .buf = &storage };
    decodeReset(&out, 0xFFFF_FFFF);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "all-ones") != null);
    try std.testing.expectEqual(@as(u64, 0xFED803C0), fch_s5_reset_status);
}

test "marker round trip and NT part layout" {
    var page: [4096]u8 = undefined;
    @memset(&page, 0xAA);
    try std.testing.expect(!parseMarker(&page).pre_valid);
    initMarker(&page, 7, 12345);
    var m = parseMarker(&page);
    try std.testing.expect(m.pre_valid and !m.nt_valid);
    try std.testing.expectEqual(@as(u32, 7), m.pre_boot);
    // What usosrst writes (tools/w2k/usosrst/src/usosrst.c, USOSRST_RAMLOG).
    @memcpy(page[off_nt..][0..8], nt_signature);
    std.mem.writeInt(u32, page[off_nt_boot..][0..4], 7, .little);
    @memcpy(page[off_nt_stages..][0..5], "LRPSK");
    std.mem.writeInt(u32, page[off_nt_count..][0..4], 5, .little);
    std.mem.writeInt(u32, page[off_nt_bugchecks..][0..4], 1, .little);
    std.mem.writeInt(u32, page[off_nt_bugcheck_data..][0..4], 0x0A, .little);
    m = parseMarker(&page);
    try std.testing.expect(m.nt_valid);
    try std.testing.expectEqualStrings("LRPSK", m.stages);
    try std.testing.expectEqual(@as(u32, 0x0A), m.bugcheck[0]);
    var storage: [512]u8 = undefined;
    var out = Out{ .buf = &storage };
    formatMarker(&out, m, 7);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "stages \"LRPSK\"") != null);
    // A wrong check word makes the PRE part invalid.
    page[off_pre_check] ^= 1;
    try std.testing.expect(!parseMarker(&page).pre_valid);
    // Stage count is bounded.
    std.mem.writeInt(u32, page[off_nt_count..][0..4], 0xFFFF, .little);
    try std.testing.expectEqual(@as(usize, nt_stages_max), parseMarker(&page).stages.len);
}

test "ring header and slots" {
    var header: [header_bytes]u8 = undefined;
    formatHeader(&header, 42);
    try std.testing.expectEqual(@as(u32, 42), parseHeader(&header));
    try std.testing.expectEqual(@as(u32, 0), parseHeader("garbage"));
    try std.testing.expectEqual(@as(u64, header_bytes), slotOffset(1));
    try std.testing.expectEqual(@as(u64, header_bytes + 49 * slot_bytes), slotOffset(50));
    try std.testing.expectEqual(@as(u64, header_bytes), slotOffset(51));
    try std.testing.expectEqual(@as(usize, 204928), file_bytes);
    var slot: [slot_bytes]u8 = undefined;
    @memcpy(slot[0..3], "abc");
    finishSlot(&slot, 3, false);
    try std.testing.expectEqualStrings("abc ", slot[0..4]);
    try std.testing.expectEqualStrings("\r\n", slot[slot_bytes - 2 ..]);
}

test "device formatting" {
    var storage: [512]u8 = undefined;
    var out = Out{ .buf = &storage };
    formatCommand(&out, 0x0406, 0x2010);
    try std.testing.expectEqualStrings(" cmd=0406(IO0 MEM1 BME1) sts=2010 RMA", out.slice());
    out = Out{ .buf = &storage };
    formatNvme(&out, 0x00460001 | (1 << 14), 0x9, 0x001f001f, 0x1000, 0x2000);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "EN=1 SHN=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "RDY=1 CFS=0 SHST=2") != null);
    out = Out{ .buf = &storage };
    formatNic(&out, 0, 0, 0x2, 0x2);
    try std.testing.expect(std.mem.indexOf(u8, out.slice(), "RCTL.EN=1") != null);
    try std.testing.expectEqualStrings("NVMe", className(0x010802));
    try std.testing.expectEqualStrings("NIC", className(0x020000));
    try std.testing.expectEqualStrings("conventional", memoryTypeName(7));
    var small: [4]u8 = undefined;
    out = Out{ .buf = &small };
    out.put("abcdef");
    try std.testing.expect(out.truncated and out.len == 4);
}
