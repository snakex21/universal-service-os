//! Writes the firmware's ACPI tables to EFI\USOS\Logs\acpi\<machine>\ once
//! per machine (keyed by the SMBIOS system UUID): DSDT.aml, SSDT-NN-*.aml
//! (raw, as the firmware publishes them at USOS time) and index.txt listing
//! every XSDT/RSDT table. index.txt is written last; when it exists the
//! machine is skipped, so later boots do not write anything. Naming and
//! parsing rules: src/flow/acpi_dump.zig.
//! raw\ (own marker raw\summary.txt, so machines dumped by older builds get
//! it once too): RSDP20/RSDP10/RSDT/XSDT/FACS and every table as .bin plus
//! summary.txt with the ACPI 1.0 view (RsdtAddress, 32-bit FADT fields,
//! MADT entries, HPET registers at USOS time), src/flow/acpi_raw.zig.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const rules = usos.flow.acpi_dump;
const text_input = @import("text_input.zig");
const serial = @import("serial.zig");

const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const max_tables = 64;

pub const Result = enum { not_run, no_acpi, already_dumped, written, failed };

var result: Result = .not_run;
var written_tables: usize = 0;
var folder_name: [48]u8 = undefined;
var folder_len: usize = 0;

pub fn lastResult() Result {
    return result;
}

pub fn folder() []const u8 {
    return folder_name[0..folder_len];
}

pub fn tablesWritten() usize {
    return written_tables;
}

const Table = struct { address: usize, header: rules.Header };

pub fn write(root: *uefi.protocol.File) void {
    result = run(root) catch |err| blk: {
        serial.writeAscii("[ACPI_DUMP] failed: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
        break :blk .failed;
    };
}

const Walk = struct { count: usize, root_address: usize, entry_bytes: usize, crc: u32 };

/// Every XSDT/RSDT table plus the FADT's DSDT (at most max_tables).
fn collect(tables: *[max_tables]Table) ?Walk {
    var count: usize = 0;
    const rsdp = findRsdp() orelse return null;
    const revision = rsdp[15];
    var root_address: usize = 0;
    var entry_bytes: usize = 4;
    if (revision >= 2) {
        const xsdt = std.mem.readInt(u64, rsdp[24..32], .little);
        if (xsdt != 0 and xsdt <= std.math.maxInt(usize)) {
            root_address = @intCast(xsdt);
            entry_bytes = 8;
        }
    }
    if (root_address == 0) root_address = std.mem.readInt(u32, rsdp[16..20], .little);
    if (root_address == 0) return null;
    const root_table = headerAt(root_address) orelse return null;

    var crc = std.hash.Crc32.init();
    var offset: usize = rules.header_size;
    while (offset + entry_bytes <= root_table.length and count < max_tables) : (offset += entry_bytes) {
        const at: [*]const u8 = @ptrFromInt(root_address + offset);
        const address: u64 = if (entry_bytes == 8) std.mem.readInt(u64, at[0..8], .little) else std.mem.readInt(u32, at[0..4], .little);
        if (address == 0 or address > std.math.maxInt(usize)) continue;
        const header = headerAt(@intCast(address)) orelse continue;
        tables[count] = .{ .address = @intCast(address), .header = header };
        count += 1;
        crc.update(bytesAt(@intCast(address), rules.header_size));
        if (std.mem.eql(u8, &header.signature, "FACP") and count < max_tables) {
            const dsdt = rules.dsdtAddress(bytesAt(@intCast(address), header.length));
            if (dsdt != 0 and dsdt <= std.math.maxInt(usize)) {
                if (headerAt(@intCast(dsdt))) |dsdt_header| {
                    tables[count] = .{ .address = @intCast(dsdt), .header = dsdt_header };
                    count += 1;
                    crc.update(bytesAt(@intCast(dsdt), rules.header_size));
                }
            }
        }
    }
    return .{ .count = count, .root_address = root_address, .entry_bytes = entry_bytes, .crc = crc.final() };
}

/// True when an ACPI ID (e.g. PNP0C50, NVTK0603) appears as a _HID/_CID
/// value in the DSDT or an SSDT (byte-pattern scan, driver_manifest rules).
pub fn amlContainsId(id: []const u8) bool {
    var tables: [max_tables]Table = undefined;
    const walk = collect(&tables) orelse return false;
    for (tables[0..walk.count]) |table| {
        const signature = &table.header.signature;
        if (!std.mem.eql(u8, signature, "DSDT") and !std.mem.eql(u8, signature, "SSDT")) continue;
        if (@import("usos").flow.driver_manifest.amlContainsId(bytesAt(table.address, table.header.length), id)) return true;
    }
    return false;
}

fn run(root: *uefi.protocol.File) !Result {
    var tables: [max_tables]Table = undefined;
    const walk = collect(&tables) orelse return .no_acpi;
    const count = walk.count;
    const root_address = walk.root_address;
    const entry_bytes = walk.entry_bytes;

    const info = text_input.Report.smbios();
    const key = rules.machineKey(if (info) |system| system.uuid else null, walk.crc, &folder_name);
    folder_len = key.len;

    var path: [96]u16 = undefined;
    const logs = try root.open(wide("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true });
    defer logs.close() catch {};
    const acpi = try logs.open(wide("acpi"), .read_write_create, .{ .directory = true });
    defer acpi.close() catch {};
    const machine = try acpi.open(ascii(key, &path), .read_write_create, .{ .directory = true });
    defer machine.close() catch {};
    // raw\ (every table + RSDP/RSDT/XSDT as .bin and summary.txt, the
    // ACPI 1.0 view for the Windows 2000 HAL work) has its own marker, so a
    // machine dumped by an older build gets it once as well.
    const raw_written = writeRaw(machine) catch |err| blk: {
        serial.writeAscii("[ACPI_DUMP] raw failed: ");
        serial.writeAscii(@errorName(err));
        serial.writeAscii("\n");
        break :blk false;
    };
    if (machine.open(wide("index.txt"), .read, .{})) |existing| {
        existing.close() catch {};
        return if (raw_written) .written else .already_dumped;
    } else |_| {}

    var index_text: [8192]u8 = undefined;
    var used: usize = 0;
    emit(&index_text, &used, "USOS ACPI dump\r\nbuild={s}\r\nmachine={s}\r\nroot={s} at 0x{x}\r\n", .{ usos.build_info.id, key, if (entry_bytes == 8) "XSDT" else "RSDT", root_address });
    if (info) |system| emit(&index_text, &used, "smbios: product=\"{s}\" board=\"{s}\" version=\"{s}\"\r\n", .{ system.product, system.board_product, system.version });
    emit(&index_text, &used, "\r\nsignature oem_id table_id revision oem_revision length checksum address file\r\n", .{});

    written_tables = 0;
    var ssdt_index: usize = 0;
    for (tables[0..count]) |table| {
        const h = table.header;
        const bytes = bytesAt(table.address, h.length);
        const checked = rules.parseHeader(bytes, bytes) orelse continue;
        var name_buffer: [64]u8 = undefined;
        var name: []const u8 = "-";
        if (rules.dumped(h.signature)) {
            if (std.mem.eql(u8, &h.signature, "SSDT")) ssdt_index += 1;
            name = rules.fileName(h, ssdt_index, &name_buffer);
            try writeFile(machine, ascii(name, &path), bytes);
            written_tables += 1;
        }
        var oem: [8]u8 = undefined;
        var table_id: [8]u8 = undefined;
        emit(&index_text, &used, "{s} {s} {s} {d} 0x{x:0>8} {d} {s} 0x{x} {s}\r\n", .{ h.signature, printable(&h.oem_id, &oem), printable(&h.oem_table_id, &table_id), h.revision, h.oem_revision, h.length, if (checked.checksum_ok) "ok" else "BAD", table.address, name });
    }
    try writeFile(machine, wide("index.txt"), index_text[0..used]);
    serial.writeAscii("[ACPI_DUMP] written\n");
    return .written;
}

const raw = usos.flow.acpi_raw;

/// The ACPI config-table RSDP for one GUID (null when absent).
fn rsdpFor(guid: uefi.Guid) ?[*]const u8 {
    const system = uefi.system_table;
    for (system.configuration_table[0..system.number_of_table_entries]) |entry| {
        if (!entry.vendor_guid.eql(guid)) continue;
        const rsdp: [*]const u8 = @ptrCast(entry.vendor_table);
        if (std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) return rsdp;
    }
    return null;
}

fn signatureAt(address: u64) [4]u8 {
    if (address == 0) return "NULL".*;
    if (address > std.math.maxInt(u32)) return "HIGH".*;
    return if (headerAt(@intCast(address))) |h| h.signature else "????".*;
}

/// Writes raw\ once per machine (summary.txt last = complete). True when
/// it wrote anything.
fn writeRaw(machine: *uefi.protocol.File) !bool {
    const dir = try machine.open(wide("raw"), .read_write_create, .{ .directory = true });
    defer dir.close() catch {};
    if (dir.open(wide("summary.txt"), .read, .{})) |existing| {
        existing.close() catch {};
        return false;
    } else |_| {}

    var summary_buffer: [32768]u8 = undefined;
    var w = raw.Writer{ .buffer = &summary_buffer };
    var path: [64]u16 = undefined;
    w.print("USOS ACPI raw dump (ACPI 1.0 view for Windows 2000/9x)\r\nbuild={s}\r\n\r\n", .{usos.build_info.id});

    const r20 = rsdpFor(uefi.tables.ConfigurationTable.acpi_20_table_guid);
    const r10 = rsdpFor(uefi.tables.ConfigurationTable.acpi_10_table_guid);
    if (r20) |p| {
        raw.writeRsdp(&w, "RSDP (ACPI 2.0 GUID)", @intFromPtr(p), p[0..36]);
        try writeFile(dir, wide("RSDP20.bin"), p[0..36]);
    } else w.print("RSDP (ACPI 2.0 GUID): none\r\n", .{});
    if (r10) |p| {
        raw.writeRsdp(&w, "RSDP (ACPI 1.0 GUID)", @intFromPtr(p), p[0..20]);
        try writeFile(dir, wide("RSDP10.bin"), p[0..20]);
    } else w.print("RSDP (ACPI 1.0 GUID): none\r\n", .{});

    const main = r20 orelse r10 orelse {
        try writeFile(dir, wide("summary.txt"), w.text());
        return true;
    };
    const parsed = raw.parseRsdp(main[0..if (main[15] >= 2) 36 else 20]) orelse {
        try writeFile(dir, wide("summary.txt"), w.text());
        return true;
    };

    var rsdt_count: usize = 0;
    var rsdt_entries: [max_tables]u32 = undefined;
    if (parsed.rsdt != 0) {
        if (headerAt(parsed.rsdt)) |h| {
            const bytes = bytesAt(parsed.rsdt, h.length);
            try writeFile(dir, wide("RSDT.bin"), bytes);
            const ok = if (rules.parseHeader(bytes, bytes)) |c| c.checksum_ok else false;
            w.print("\r\nRSDT at 0x{x} length {d} checksum {s}\r\n", .{ parsed.rsdt, h.length, if (ok) "ok" else "BAD" });
            var offset: usize = rules.header_size;
            while (offset + 4 <= h.length and rsdt_count < max_tables) : (offset += 4) {
                const address = std.mem.readInt(u32, bytes[offset..][0..4], .little);
                rsdt_entries[rsdt_count] = address;
                rsdt_count += 1;
                const sig = signatureAt(address);
                w.print("  RSDT[{d}] 0x{x:0>8} {s}\r\n", .{ rsdt_count - 1, address, &sig });
            }
        } else w.print("\r\n!! RSDT at 0x{x}: no valid table header\r\n", .{parsed.rsdt});
    }
    if (parsed.xsdt != 0 and parsed.xsdt <= std.math.maxInt(u32)) {
        const xsdt: usize = @intCast(parsed.xsdt);
        if (headerAt(xsdt)) |h| {
            const bytes = bytesAt(xsdt, h.length);
            try writeFile(dir, wide("XSDT.bin"), bytes);
            w.print("\r\nXSDT at 0x{x} length {d}\r\n", .{ xsdt, h.length });
            var offset: usize = rules.header_size;
            while (offset + 8 <= h.length) : (offset += 8) {
                const address = std.mem.readInt(u64, bytes[offset..][0..8], .little);
                var in_rsdt = false;
                for (rsdt_entries[0..rsdt_count]) |e| {
                    if (e == address) in_rsdt = true;
                }
                const sig = signatureAt(address);
                w.print("  XSDT 0x{x} {s}{s}\r\n", .{ address, &sig, if (parsed.rsdt != 0 and !in_rsdt) "  !! not in RSDT" else "" });
            }
        }
    }

    // Every table as raw .bin (the collect() walk: XSDT, else RSDT, + DSDT).
    var tables: [max_tables]Table = undefined;
    const walk = collect(&tables) orelse {
        try writeFile(dir, wide("summary.txt"), w.text());
        return true;
    };
    w.print("\r\n", .{});
    var name_buffer: [32]u8 = undefined;
    for (tables[0..walk.count], 0..) |table, index| {
        const bytes = bytesAt(table.address, table.header.length);
        const name = raw.rawName(table.header.signature, index, &name_buffer);
        try writeFile(dir, ascii(name, &path), bytes);
        w.print("{s} 0x{x} {d} bytes\r\n", .{ name, table.address, table.header.length });
        const sig = &table.header.signature;
        if (std.mem.eql(u8, sig, "FACP")) {
            raw.writeFadt(&w, bytes);
            // FACS has no standard header: signature + length.
            const fw32: u64 = if (bytes.len >= 40) std.mem.readInt(u32, bytes[36..40], .little) else 0;
            const fw64: u64 = if (bytes.len >= 140) std.mem.readInt(u64, bytes[132..140], .little) else 0;
            const facs: u64 = if (fw32 != 0) fw32 else fw64;
            if (facs != 0 and facs <= std.math.maxInt(u32)) {
                const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(facs)));
                const len = std.mem.readInt(u32, p[4..8], .little);
                w.print("  FACS at 0x{x}: signature {s} length {d}\r\n", .{ facs, p[0..4], len });
                if (std.mem.eql(u8, p[0..4], "FACS") and len >= 64 and len <= 4096) try writeFile(dir, wide("FACS.bin"), p[0..len]);
            }
        } else if (std.mem.eql(u8, sig, "APIC")) {
            raw.writeMadt(&w, bytes);
        } else if (std.mem.eql(u8, sig, "HPET")) {
            raw.writeHpet(&w, bytes);
            const base: u64 = if (bytes.len >= 52) std.mem.readInt(u64, bytes[44..52], .little) else 0;
            if (base != 0 and base <= std.math.maxInt(u32)) {
                const regs: [*]const volatile u32 = @ptrFromInt(@as(usize, @intCast(base)));
                w.print("  HPET registers now: caps 0x{x:0>8} period {d} fs, general config 0x{x:0>8} (bit 1 = LegacyReplacement), timer0 config 0x{x:0>8}\r\n", .{ regs[0], regs[1], regs[4], regs[0x40] });
            }
        }
    }
    try writeFile(dir, wide("summary.txt"), w.text());
    serial.writeAscii("[ACPI_DUMP] raw written\n");
    return true;
}

fn findRsdp() ?[*]const u8 {
    const system = uefi.system_table;
    const entries = system.configuration_table[0..system.number_of_table_entries];
    for ([_]uefi.Guid{ uefi.tables.ConfigurationTable.acpi_20_table_guid, uefi.tables.ConfigurationTable.acpi_10_table_guid }) |guid| {
        for (entries) |entry| {
            if (!entry.vendor_guid.eql(guid)) continue;
            const rsdp: [*]const u8 = @ptrCast(entry.vendor_table);
            if (std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) return rsdp;
        }
    }
    return null;
}

fn bytesAt(address: usize, length: usize) []const u8 {
    const pointer: [*]const u8 = @ptrFromInt(address);
    return pointer[0..length];
}

fn headerAt(address: usize) ?rules.Header {
    return rules.parseHeader(bytesAt(address, rules.header_size), null);
}

fn printable(bytes: []const u8, out: *[8]u8) []const u8 {
    const n = @min(bytes.len, out.len);
    for (bytes[0..n], 0..) |c, i| out[i] = if (c > 0x20 and c < 0x7f) c else '_';
    return out[0..n];
}

fn ascii(text: []const u8, out: []u16) [*:0]const u16 {
    const n = @min(text.len, out.len - 1);
    for (text[0..n], 0..) |c, i| out[i] = c;
    out[n] = 0;
    return @ptrCast(out.ptr);
}

fn writeFile(directory: *uefi.protocol.File, name: [*:0]const u16, bytes: []const u8) !void {
    if (directory.open(name, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
    const file = try directory.open(name, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try file.write(bytes[written..]);
        if (n == 0) return error.ShortWrite;
        written += n;
    }
    try file.flush();
}

fn emit(buffer: []u8, used: *usize, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buffer[used.*..], fmt, args) catch return;
    used.* += written.len;
}
