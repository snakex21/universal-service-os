//! Writes the firmware's ACPI tables to EFI\USOS\Logs\acpi\<machine>\ once
//! per machine (keyed by the SMBIOS system UUID): DSDT.aml, SSDT-NN-*.aml
//! (raw, as the firmware publishes them at USOS time) and index.txt listing
//! every XSDT/RSDT table. index.txt is written last; when it exists the
//! machine is skipped, so later boots do not write anything. Naming and
//! parsing rules: src/flow/acpi_dump.zig.
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

fn run(root: *uefi.protocol.File) !Result {
    var tables: [max_tables]Table = undefined;
    var count: usize = 0;
    const rsdp = findRsdp() orelse return .no_acpi;
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
    if (root_address == 0) return .no_acpi;
    const root_table = headerAt(root_address) orelse return .no_acpi;

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

    const info = text_input.Report.smbios();
    const key = rules.machineKey(if (info) |system| system.uuid else null, crc.final(), &folder_name);
    folder_len = key.len;

    var path: [96]u16 = undefined;
    const logs = try root.open(wide("\\EFI\\USOS\\Logs"), .read_write_create, .{ .directory = true });
    defer logs.close() catch {};
    const acpi = try logs.open(wide("acpi"), .read_write_create, .{ .directory = true });
    defer acpi.close() catch {};
    const machine = try acpi.open(ascii(key, &path), .read_write_create, .{ .directory = true });
    defer machine.close() catch {};
    if (machine.open(wide("index.txt"), .read, .{})) |existing| {
        existing.close() catch {};
        return .already_dumped;
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
