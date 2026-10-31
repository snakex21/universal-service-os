//! The disk facts of the MiniOS disk question (src/platform/uefi/minios_disk.zig),
//! in the form the Alpine route's picker shows them (tools/target_disk_identity.sh,
//! tools/xp_disk_overview.sh, tools/vista_csmwrap_prepare.sh): the model and
//! serial number from the controller's IDENTIFY data (EFI_DISK_INFO), the
//! bus and media chip tokens, the partition count and the erase-confirmation
//! overview with the CSMWrap layout (tools/xp_disk_overview.sh: the
//! partition list with file system, label, size, used / free space and the
//! detected system). Pure: host-tested.
const std = @import("std");
pub const fs_probe = @import("minios_fs_probe.zig");
test {
    _ = fs_probe;
}

/// EFI_DISK_INFO interface GUIDs (MdePkg/Include/Protocol/DiskInfo.h).
pub const Interface = enum { ide, ahci, nvme, scsi, usb, sd, other };

fn guidBytes(comptime a: u32, comptime b: u16, comptime c: u16, comptime d: [8]u8) [16]u8 {
    var out: [16]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], a, .little);
    std.mem.writeInt(u16, out[4..6], b, .little);
    std.mem.writeInt(u16, out[6..8], c, .little);
    @memcpy(out[8..16], &d);
    return out;
}

const interfaces = [_]struct { kind: Interface, guid: [16]u8 }{
    .{ .kind = .ide, .guid = guidBytes(0x5e948fe3, 0x26d3, 0x42b5, .{ 0xaf, 0x17, 0x61, 0x02, 0x87, 0x18, 0x8d, 0xec }) },
    .{ .kind = .ahci, .guid = guidBytes(0x9e498932, 0x4abc, 0x45af, .{ 0xa3, 0x4d, 0x02, 0x47, 0x78, 0x7b, 0xe7, 0xc4 }) },
    .{ .kind = .nvme, .guid = guidBytes(0x3ab14680, 0x5d3f, 0x4a4d, .{ 0xbc, 0xdc, 0xcc, 0x38, 0x00, 0x18, 0xc7, 0xf7 }) },
    .{ .kind = .scsi, .guid = guidBytes(0x08f74baa, 0xea36, 0x41d9, .{ 0x95, 0x21, 0x21, 0xa7, 0x0f, 0x87, 0x80, 0xbc }) },
    .{ .kind = .usb, .guid = guidBytes(0xcb871572, 0xc11a, 0x47b5, .{ 0xb4, 0x92, 0x67, 0x5e, 0xaf, 0xa7, 0x77, 0x27 }) },
    .{ .kind = .sd, .guid = guidBytes(0x8deec992, 0xd39c, 0x4a5c, .{ 0xab, 0x6b, 0x98, 0x6e, 0x14, 0x24, 0x2b, 0x9d }) },
};

pub fn interfaceKind(guid: [16]u8) Interface {
    for (interfaces) |entry| if (std.mem.eql(u8, &entry.guid, &guid)) return entry.kind;
    return .other;
}

pub const Identity = struct {
    interface: Interface = .other,
    model: [40]u8 = undefined,
    model_len: usize = 0,
    serial: [20]u8 = undefined,
    serial_len: usize = 0,
    /// Chip tokens as tools/target_disk_identity.sh prints them.
    bus: ?[]const u8 = null,
    media: ?[]const u8 = null,

    pub fn modelText(self: *const Identity) []const u8 {
        return self.model[0..self.model_len];
    }
    pub fn serialText(self: *const Identity) []const u8 {
        return self.serial[0..self.serial_len];
    }
};

/// Printable ASCII, trimmed of the padding spaces / NULs (as Linux's sysfs
/// model and serial attributes).
fn clean(out: []u8, raw: []const u8) usize {
    var n: usize = 0;
    for (raw) |c| {
        out[n] = if (c >= 0x20 and c < 0x7f) c else ' ';
        n += 1;
    }
    const trimmed = std.mem.trim(u8, out[0..n], " ");
    std.mem.copyForwards(u8, out[0..trimmed.len], trimmed);
    return trimmed.len;
}

/// ATA strings are byte-swapped 16-bit words.
fn cleanAta(out: []u8, raw: []const u8) usize {
    var swapped: [64]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        swapped[i] = raw[i + 1];
        swapped[i + 1] = raw[i];
    }
    return clean(out, swapped[0..i]);
}

/// IDENTIFY strings are space-padded printable ASCII. Anything else is not
/// the expected structure: EDK2-style NVMe EFI_DISK_INFO.Identify returns
/// the Identify *Namespace* data (binary NSZE/NCAP at the same offsets),
/// which must not become a model text.
pub fn printableField(raw: []const u8) bool {
    var any = false;
    for (raw) |c| {
        if (c == 0 or c == ' ') continue;
        if (c < 0x21 or c > 0x7e) return false;
        any = true;
    }
    return any;
}

/// IDENTIFY data of `kind`: NVMe Identify Controller (SN bytes 4-23, MN
/// 24-63; NVMe is always SSD, as usos_disk_media) or ATA IDENTIFY DEVICE
/// (serial words 10-19, model 27-46, nominal media rotation rate word 217:
/// 1 = SSD, 0x0401-0xfffe = HDD). A model field that is not text (e.g.
/// Identify Namespace data) leaves the identity empty.
pub fn parse(kind: Interface, data: []const u8) Identity {
    var id: Identity = .{ .interface = kind };
    switch (kind) {
        .nvme => {
            if (data.len < 64) return id;
            id.media = "ssd";
            if (!printableField(data[24..64])) return id;
            id.serial_len = clean(&id.serial, data[4..24]);
            id.model_len = clean(&id.model, data[24..64]);
        },
        .ahci, .ide => {
            if (data.len < 94) return id;
            if (!printableField(data[54..94])) return id;
            id.serial_len = cleanAta(&id.serial, data[20..40]);
            id.model_len = cleanAta(&id.model, data[54..94]);
            if (data.len >= 436) {
                const rate = std.mem.readInt(u16, data[434..436], .little);
                if (rate == 1) id.media = "ssd" else if (rate >= 0x0401 and rate != 0xffff) id.media = "hdd";
            }
        },
        else => {},
    }
    return id;
}

/// SCSI INQUIRY standard data (SPC: vendor bytes 8-15, product 16-31): the
/// model Linux shows for a USB / SCSI disk (sysfs device/model = product).
pub fn setInquiryModel(id: *Identity, data: []const u8) void {
    if (data.len < 32) return;
    id.model_len = clean(&id.model, data[16..32]);
}

/// SCSI VPD page 0x80 (unit serial number: length at byte 3, text from 4),
/// as tools/target_disk_identity.sh reads vpd_pg80.
pub fn setVpdSerial(id: *Identity, page: []const u8) void {
    if (page.len < 4 or page[1] != 0x80) return;
    const len = @min(@as(usize, page[3]), page.len - 4);
    id.serial_len = clean(&id.serial, page[4..][0..@min(len, id.serial.len)]);
}

/// A USB string descriptor's text (UTF-16LE units, as EFI_USB_IO
/// UsbGetStringDescriptor returns it), ASCII only, trimmed: the USB
/// iSerialNumber is Linux's serial of a USB disk (udev ID_SERIAL_SHORT).
fn utf16Clean(out: []u8, units: []const u16) usize {
    var raw: [64]u8 = undefined;
    var n: usize = 0;
    for (units) |unit| {
        if (unit == 0 or n == raw.len) break;
        raw[n] = if (unit >= 0x20 and unit < 0x7f) @intCast(unit) else ' ';
        n += 1;
    }
    var cleaned: [64]u8 = undefined;
    const len = @min(clean(&cleaned, raw[0..n]), out.len);
    @memcpy(out[0..len], cleaned[0..len]);
    return len;
}
pub fn setSerialUtf16(id: *Identity, units: []const u16) void {
    id.serial_len = utf16Clean(&id.serial, units);
}
/// USB iProduct: the model when the disk gives no INQUIRY data.
pub fn setModelUtf16(id: *Identity, units: []const u16) void {
    id.model_len = utf16Clean(&id.model, units);
}

/// USB device descriptor (USB 2.0 9.6.1): iProduct and iSerialNumber
/// string indexes (0 = none).
pub const UsbStrings = struct { product: u8, serial: u8 };
pub fn usbStrings(descriptor: []const u8) ?UsbStrings {
    if (descriptor.len < 18 or descriptor[1] != 1) return null;
    return .{ .product = descriptor[15], .serial = descriptor[16] };
}

/// The NVMe Identify Controller admin command (opcode 06h, CNS 01h in
/// CDW10, NSID 0) as EFI_NVM_EXPRESS_COMMAND fields.
pub const nvme_identify = struct {
    pub const opcode: u32 = 0x06;
    pub const cdw10: u32 = 0x01;
    pub const flags: u8 = 0x04; // CDW10_VALID
    pub const bytes: u32 = 4096;
};
/// ATA IDENTIFY DEVICE (ECh, PIO data-in, 512 bytes).
pub const ata_identify = struct {
    pub const command: u8 = 0xec;
    pub const protocol_pio_in: u8 = 0x04;
    pub const length: u8 = 0x80 | 0x20; // LENGTH_BYTES | LENGTH_SECTOR_COUNT
    pub fn deviceHead(port_multiplier: u16) u8 {
        return 0xe0 | (if (port_multiplier == 0xffff) 0 else @as(u8, @truncate(port_multiplier << 4)));
    }
};

/// Bus chip token from the device path bus (minios_plan.busName) and the
/// DISK_INFO interface (null: unknown, no chip).
pub fn busToken(bus: []const u8, kind: Interface) ?[]const u8 {
    const by_path = [_][2][]const u8{ .{ "NVMe", "nvme" }, .{ "SATA", "sata" }, .{ "SAS", "sas" }, .{ "SCSI", "scsi" }, .{ "USB", "usb" }, .{ "ATAPI", "ide" } };
    for (by_path) |entry| if (std.mem.eql(u8, bus, entry[0])) return entry[1];
    return switch (kind) {
        .nvme => "nvme",
        .ahci => "sata",
        .ide => "ide",
        .scsi => "scsi",
        .usb => "usb",
        .sd => "mmc",
        .other => null,
    };
}

/// usos_disk_type: "NVMe SSD", "SATA HDD", "SAS", ...
pub fn typeText(buffer: []u8, id: *const Identity) ?[]const u8 {
    const bus = id.bus orelse return null;
    const labels = [_][2][]const u8{ .{ "nvme", "NVMe" }, .{ "sata", "SATA" }, .{ "ide", "IDE" }, .{ "scsi", "SCSI" }, .{ "sas", "SAS" }, .{ "usb", "USB" }, .{ "mmc", "SD/MMC" } };
    const label = for (labels) |entry| {
        if (std.mem.eql(u8, bus, entry[0])) break entry[1];
    } else return null;
    var media: [8]u8 = undefined;
    const m = id.media orelse return std.fmt.bufPrint(buffer, "{s}", .{label}) catch null;
    const upper = std.ascii.upperString(media[0..@min(m.len, media.len)], m[0..@min(m.len, media.len)]);
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ label, upper }) catch null;
}

/// The picker name (usos_disk_picker_name): the model, else the bus.
pub fn displayName(id: *const Identity) []const u8 {
    if (id.model_len > 0) return id.modelText();
    if (id.bus) |bus| {
        const names = [_][2][]const u8{ .{ "nvme", "NVMe disk" }, .{ "sata", "SATA disk" }, .{ "ide", "IDE disk" }, .{ "scsi", "SCSI disk" }, .{ "sas", "SAS disk" }, .{ "usb", "USB disk" }, .{ "mmc", "SD/MMC disk" } };
        for (names) |entry| if (std.mem.eql(u8, bus, entry[0])) return entry[1];
    }
    return "Disk";
}

/// "<model> (<n> GiB)", n = bytes / 2^30 rounded down (usos_xp_choose_disk).
pub fn pickerTitle(buffer: []u8, id: *const Identity, bytes: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} ({d} GiB)", .{ displayName(id), bytes / 1073741824 });
}

pub const GptHeader = struct {
    entries_lba: u64,
    count: u32,
    entry_size: u32,

    pub fn parse(sector: []const u8) ?GptHeader {
        if (sector.len < 92 or !std.mem.eql(u8, sector[0..8], "EFI PART")) return null;
        const size = std.mem.readInt(u32, sector[84..88], .little);
        if (size < 128 or size > 512 or 512 % size != 0) return null;
        return .{ .entries_lba = std.mem.readInt(u64, sector[72..80], .little), .count = @min(std.mem.readInt(u32, sector[80..84], .little), 256), .entry_size = size };
    }
};

/// One partition as lsblk lists it (number = the Linux partition number:
/// GPT entry index + 1, MBR slot 1-4, logical partitions from 5).
pub const Entry = struct {
    number: u16,
    start: u64,
    sectors: u64,
    /// An MBR extended partition (lsblk: 1 KiB, no file system).
    container: bool = false,
    probe: fs_probe.Probe = .{},

    /// lsblk SIZE of the node in MiB (sysfs size / 2048).
    pub fn mib(self: *const Entry) u64 {
        return (if (self.container) 2 else self.sectors) / 2048;
    }
};

pub fn isExtended(kind: u8) bool {
    return kind == 0x05 or kind == 0x0f or kind == 0x85;
}

pub const Partitions = struct {
    table: enum { none, mbr, gpt } = .none,
    count: u32 = 0,
    allocated: u64 = 0,
    /// The first max_entries partitions in lsblk order.
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    /// The MBR extended partition (EBR chain start), if any.
    extended_start: ?u64 = null,
    /// The next logical partition number (Linux: 5, 6, ...).
    next_logical: u16 = 5,

    pub const max_entries = 16;

    pub fn shown(self: *const Partitions) []const Entry {
        return self.entries[0..self.entry_count];
    }

    fn add(self: *Partitions, entry: Entry) void {
        self.count += 1;
        // Linux sizes an extended partition node at 2 sectors (1 KiB).
        self.allocated +|= if (entry.container) 2 else entry.sectors;
        if (self.entry_count < max_entries) {
            self.entries[self.entry_count] = entry;
            self.entry_count += 1;
        }
    }

    pub fn addGpt(self: *Partitions, entry: []const u8, index: u32) void {
        if (entry.len < 48 or std.mem.allEqual(u8, entry[0..16], 0)) return;
        const first = std.mem.readInt(u64, entry[32..40], .little);
        const last = std.mem.readInt(u64, entry[40..48], .little);
        self.add(.{ .number = @intCast(@min(index + 1, 0xffff)), .start = first, .sectors = if (last >= first) last - first + 1 else 0 });
    }

    /// Primary MBR entries (a GPT disk is read through its GPT instead);
    /// the logical partitions follow with addLogical.
    pub fn fromMbr(sector: []const u8) Partitions {
        if (sector.len < 512 or sector[510] != 0x55 or sector[511] != 0xaa) return .{};
        var result: Partitions = .{ .table = .mbr };
        for (0..4) |i| {
            const e = sector[446 + i * 16 ..][0..16];
            if (e[4] == 0) continue;
            const start: u64 = std.mem.readInt(u32, e[8..12], .little);
            const container = isExtended(e[4]);
            if (container and result.extended_start == null) result.extended_start = start;
            result.add(.{ .number = @intCast(i + 1), .start = start, .sectors = std.mem.readInt(u32, e[12..16], .little), .container = container });
        }
        return result;
    }

    pub fn addLogical(self: *Partitions, start: u64, sectors: u64) void {
        self.add(.{ .number = self.next_logical, .start = start, .sectors = sectors });
        self.next_logical +|= 1;
    }
};

/// One EBR of the logical partition chain: the logical partition (start
/// relative to this EBR) and the next EBR (relative to the extended
/// partition's start).
pub const Ebr = struct {
    logical: ?Logical = null,
    next: ?u64 = null,

    pub const Logical = struct { start: u64, sectors: u64 };

    pub fn parse(sector: []const u8, extended_start: u64, this_lba: u64) ?Ebr {
        if (sector.len < 512 or sector[510] != 0x55 or sector[511] != 0xaa) return null;
        var result: Ebr = .{};
        const first = sector[446..][0..16];
        const second = sector[462..][0..16];
        if (first[4] != 0 and !isExtended(first[4])) {
            const rel = std.mem.readInt(u32, first[8..12], .little);
            result.logical = .{ .start = this_lba + rel, .sectors = std.mem.readInt(u32, first[12..16], .little) };
        }
        if (isExtended(second[4])) {
            const rel = std.mem.readInt(u32, second[8..12], .little);
            if (rel != 0) result.next = extended_start + rel;
        }
        return result;
    }
};

/// The layout tools/vista_csmwrap_target.sh writes (the prepare script's
/// arithmetic): the free space for Setup's Windows partition in GiB.
pub fn csmwrapFreeGib(sectors: u64) u64 {
    if (sectors < 133120 + 2097152 + 4096) return 0;
    const esp_start = (sectors - 133120 + 2047) / 2048 * 2048;
    const staging_start = (esp_start - 2097152) / 2048 * 2048;
    return (staging_start -| 2048) / 2097152;
}

/// The erase confirmation details (vista_csmwrap_prepare.sh screen file):
/// "ERASE ALL DATA ON THIS DISK", the disk overview, the erase line and the
/// new MBR layout.
pub const Overview = struct {
    storage: [32][224]u8 = undefined,
    texts: [32][]const u8 = undefined,
    count: usize = 0,

    fn add(self: *Overview, comptime fmt: []const u8, args: anytype) void {
        if (self.count == self.texts.len) return;
        self.texts[self.count] = std.fmt.bufPrint(&self.storage[self.count], fmt, args) catch "";
        self.count += 1;
    }

    pub fn lines(self: *const Overview) []const []const u8 {
        return self.texts[0..self.count];
    }

    pub fn build(self: *Overview, id: *const Identity, parts: *const Partitions, sectors: u64, system: []const u8, csmwrap: bool) void {
        self.count = 0;
        self.add("ERASE ALL DATA ON THIS DISK", .{});
        self.add("", .{});
        self.add("Disk: {s}", .{displayName(id)});
        var type_buffer: [32]u8 = undefined;
        if (typeText(&type_buffer, id)) |text| self.add("Type: {s}", .{text});
        self.add("S/N: {s}", .{id.serialText()});
        self.add("Size: {d} GiB", .{sectors * 512 / 1073741824});
        self.add("Status: not currently in use.", .{});
        self.add("Partitions: {d}; unallocated: approx. {d} MiB", .{ parts.count, (sectors -| parts.allocated) / 2048 });
        // xp_disk_overview.sh: the mounted file systems' df totals, the
        // first four partitions, the rest as a count, the detection note.
        var known: usize = 0;
        var used: u64 = 0;
        var free: u64 = 0;
        for (parts.shown()) |*e| {
            if (e.probe.used == null or e.probe.free == null) continue;
            known += 1;
            used += e.probe.used.? / 1024;
            free += e.probe.free.? / 1024;
        }
        if (known > 0) {
            self.add("Readable file systems: {d}; used {d} MiB, free {d} MiB", .{ known, used / 1024, free / 1024 });
        } else self.add("Used/free space in file systems: unknown.", .{});
        for (parts.shown()[0..@min(parts.entry_count, 4)]) |*e| {
            const p = &e.probe;
            if (p.label_len > 0) {
                self.add("Partition {d}: {s} {s} ({d} MiB)", .{ e.number, p.fs.name(), p.labelText(), e.mib() });
            } else self.add("Partition {d}: {s} ({d} MiB)", .{ e.number, p.fs.name(), e.mib() });
            const found = p.system orelse "System unknown";
            if (p.used != null and p.free != null) {
                self.add("  Used: {d} MiB, free: {d} MiB; {s}", .{ p.used.? / 1048576, p.free.? / 1048576, found });
            } else self.add("  Used/free: unknown; {s}", .{found});
        }
        if (parts.count > 4) self.add("(Other partitions: {d})", .{parts.count - 4});
        self.add("File detection does not verify whether a system works.", .{});
        self.add("", .{});
        self.add("All partitions, systems and files on this disk will be erased.", .{});
        if (csmwrap) self.add("New layout (MBR): {d} GiB NTFS (drive C:) for {s}, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.", .{ csmwrapFreeGib(sectors), system });
    }
};

test "NVMe and ATA identify data give the Linux model, serial and media" {
    var nvme: [4096]u8 = @splat(0);
    @memcpy(nvme[4..24], "  2205E5A1B2C3      ");
    @memcpy(nvme[24..64], "Micron 3400 MTFDKBA512TFH               ");
    const n = parse(.nvme, &nvme);
    try std.testing.expectEqualStrings("Micron 3400 MTFDKBA512TFH", n.modelText());
    try std.testing.expectEqualStrings("2205E5A1B2C3", n.serialText());
    try std.testing.expectEqualStrings("ssd", n.media.?);

    var ata: [512]u8 = @splat(0);
    const model = "Samsung SSD 860 EVO 250GB               ";
    const serial = "S3YJNX0K864125B     ";
    for (0..20) |w| {
        ata[54 + 2 * w] = model[2 * w + 1];
        ata[54 + 2 * w + 1] = model[2 * w];
    }
    for (0..10) |w| {
        ata[20 + 2 * w] = serial[2 * w + 1];
        ata[20 + 2 * w + 1] = serial[2 * w];
    }
    std.mem.writeInt(u16, ata[434..436], 1, .little);
    var s = parse(.ahci, &ata);
    try std.testing.expectEqualStrings("Samsung SSD 860 EVO 250GB", s.modelText());
    try std.testing.expectEqualStrings("S3YJNX0K864125B", s.serialText());
    try std.testing.expectEqualStrings("ssd", s.media.?);
    std.mem.writeInt(u16, ata[434..436], 7200, .little);
    try std.testing.expectEqualStrings("hdd", parse(.ahci, &ata).media.?);
    std.mem.writeInt(u16, ata[434..436], 0, .little);
    try std.testing.expect(parse(.ahci, &ata).media == null);
    try std.testing.expectEqual(@as(usize, 0), parse(.nvme, ata[0..10]).model_len);

    s.bus = busToken("SATA", .ahci);
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("SATA SSD", typeText(&buffer, &s).?);
    try std.testing.expectEqualStrings("Samsung SSD 860 EVO 250GB (232 GiB)", try pickerTitle(&buffer, &s, 250059350016));
}

test "USB disk: INQUIRY product, VPD 80h / iSerialNumber serial, device descriptor indexes" {
    var inquiry: [36]u8 = @splat(' ');
    inquiry[0] = 0;
    @memcpy(inquiry[8..16], "Kingston");
    @memcpy(inquiry[16..32], "DataTraveler 3.0");
    @memcpy(inquiry[32..36], "PMAP");
    var id: Identity = .{ .interface = .usb };
    setInquiryModel(&id, &inquiry);
    try std.testing.expectEqualStrings("DataTraveler 3.0", id.modelText());
    setInquiryModel(&id, inquiry[0..20]); // too short: unchanged
    try std.testing.expectEqualStrings("DataTraveler 3.0", id.modelText());

    const vpd = [_]u8{ 0, 0x80, 0, 8 } ++ "AB12CD34".*;
    setVpdSerial(&id, &vpd);
    try std.testing.expectEqualStrings("AB12CD34", id.serialText());
    setVpdSerial(&id, &[_]u8{ 0, 0x83, 0, 0 }); // other page: unchanged
    try std.testing.expectEqualStrings("AB12CD34", id.serialText());

    const units = std.unicode.utf8ToUtf16LeStringLiteral(" 0123456789ABCDEF0123456789 ");
    setSerialUtf16(&id, units);
    // Longer than Identity.serial (20): cut like the picker's S/N field.
    try std.testing.expectEqualStrings("0123456789ABCDEF0123", id.serialText());
    setModelUtf16(&id, std.unicode.utf8ToUtf16LeStringLiteral("USB DISK 3.0\x00junk"));
    try std.testing.expectEqualStrings("USB DISK 3.0", id.modelText());

    var device: [18]u8 = @splat(0);
    device[0] = 18;
    device[1] = 1;
    device[15] = 2;
    device[16] = 3;
    try std.testing.expectEqual(UsbStrings{ .product = 2, .serial = 3 }, usbStrings(&device).?);
    device[1] = 2;
    try std.testing.expect(usbStrings(&device) == null);
}

test "pass-thru IDENTIFY commands: NVMe CNS 1 admin, ATA ECh PIO in" {
    try std.testing.expectEqual(@as(u32, 6), nvme_identify.opcode);
    try std.testing.expectEqual(@as(u32, 1), nvme_identify.cdw10);
    try std.testing.expectEqual(@as(u8, 0x04), nvme_identify.flags);
    try std.testing.expectEqual(@as(u8, 0xec), ata_identify.command);
    try std.testing.expectEqual(@as(u8, 0xa0), ata_identify.length);
    try std.testing.expectEqual(@as(u8, 0xe0), ata_identify.deviceHead(0xffff));
    try std.testing.expectEqual(@as(u8, 0xf0), ata_identify.deviceHead(1));
}

test "interface GUIDs and bus tokens follow DiskInfo.h and target_disk_identity.sh" {
    try std.testing.expectEqual(Interface.nvme, interfaceKind(guidBytes(0x3ab14680, 0x5d3f, 0x4a4d, .{ 0xbc, 0xdc, 0xcc, 0x38, 0x00, 0x18, 0xc7, 0xf7 })));
    try std.testing.expectEqual(Interface.other, interfaceKind(@splat(0)));
    try std.testing.expectEqualStrings("nvme", busToken("NVMe", .other).?);
    try std.testing.expectEqualStrings("sata", busToken("disk", .ahci).?);
    try std.testing.expect(busToken("disk", .other) == null);
    var id: Identity = .{};
    try std.testing.expectEqualStrings("Disk", displayName(&id));
    id.bus = "nvme";
    try std.testing.expectEqualStrings("NVMe disk", displayName(&id));
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("NVMe", typeText(&buffer, &id).?);
}

test "partition count from MBR and GPT entries" {
    var mbr: [512]u8 = @splat(0);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;
    mbr[446 + 4] = 0x07;
    std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], 204800, .little);
    mbr[462 + 4] = 0x0c;
    std.mem.writeInt(u32, mbr[462 + 12 ..][0..4], 2048, .little);
    var p = Partitions.fromMbr(&mbr);
    try std.testing.expectEqual(@as(u32, 2), p.count);
    try std.testing.expectEqual(@as(u64, 206848), p.allocated);
    try std.testing.expectEqual(@as(u16, 2), p.shown()[1].number);
    // An extended partition: lsblk lists it at 1 KiB, then its logicals.
    mbr[478 + 4] = 0x0f;
    std.mem.writeInt(u32, mbr[478 + 8 ..][0..4], 1000000, .little);
    std.mem.writeInt(u32, mbr[478 + 12 ..][0..4], 500000, .little);
    p = Partitions.fromMbr(&mbr);
    try std.testing.expectEqual(@as(?u64, 1000000), p.extended_start);
    try std.testing.expect(p.shown()[2].container);
    try std.testing.expectEqual(@as(u64, 0), p.shown()[2].mib());
    var ebr: [512]u8 = @splat(0);
    ebr[510] = 0x55;
    ebr[511] = 0xaa;
    ebr[446 + 4] = 0x07;
    std.mem.writeInt(u32, ebr[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, ebr[446 + 12 ..][0..4], 100000, .little);
    ebr[462 + 4] = 0x05;
    std.mem.writeInt(u32, ebr[462 + 8 ..][0..4], 102048, .little);
    const link = Ebr.parse(&ebr, 1000000, 1000000).?;
    try std.testing.expectEqual(@as(u64, 1002048), link.logical.?.start);
    try std.testing.expectEqual(@as(?u64, 1102048), link.next);
    p.addLogical(link.logical.?.start, link.logical.?.sectors);
    try std.testing.expectEqual(@as(u32, 4), p.count);
    try std.testing.expectEqual(@as(u16, 5), p.shown()[3].number);
    try std.testing.expectEqual(@as(u64, 206848 + 2 + 100000), p.allocated);
    ebr[462 + 4] = 0;
    try std.testing.expect(Ebr.parse(&ebr, 1000000, 1000000).?.next == null);
    mbr[511] = 0;
    try std.testing.expectEqual(@as(u32, 0), Partitions.fromMbr(&mbr).count);

    var header: [512]u8 = @splat(0);
    @memcpy(header[0..8], "EFI PART");
    std.mem.writeInt(u64, header[72..80], 2, .little);
    std.mem.writeInt(u32, header[80..84], 128, .little);
    std.mem.writeInt(u32, header[84..88], 128, .little);
    const h = GptHeader.parse(&header).?;
    try std.testing.expectEqual(@as(u64, 2), h.entries_lba);
    var gpt: Partitions = .{ .table = .gpt };
    var entry: [128]u8 = @splat(0);
    gpt.addGpt(&entry, 0);
    entry[0] = 1;
    std.mem.writeInt(u64, entry[32..40], 2048, .little);
    std.mem.writeInt(u64, entry[40..48], 4095, .little);
    gpt.addGpt(&entry, 2);
    try std.testing.expectEqual(@as(u32, 1), gpt.count);
    try std.testing.expectEqual(@as(u16, 3), gpt.shown()[0].number);
    try std.testing.expectEqual(@as(u64, 2048), gpt.allocated);
    std.mem.writeInt(u32, header[84..88], 100, .little);
    try std.testing.expect(GptHeader.parse(&header) == null);
}

test "erase confirmation overview: the X470 Micron 3400 (1000215216 sectors)" {
    var id = parse(.nvme, &[_]u8{0} ** 64);
    @memcpy(id.model[0..11], "Micron 3400");
    id.model_len = 11;
    @memcpy(id.serial[0..4], "SN01");
    id.serial_len = 4;
    id.bus = "nvme";
    var parts: Partitions = .{ .table = .mbr };
    // The X470 Micron after a Win10 x86 CSMWrap run: C:, the 1 GiB helper,
    // the 64 MiB CSMWrap ESP.
    parts.add(.{ .number = 1, .start = 2048, .sectors = 1000083456 - 2048 - 2097152 - 133120, .probe = .{ .fs = .ntfs, .used = 20 * 1073741824, .free = 450 * 1073741824, .system = "Windows (system files)" } });
    parts.entries[0].probe.setLabel("");
    parts.add(.{ .number = 2, .start = 0, .sectors = 2097152, .probe = .{ .fs = .ntfs } });
    parts.entries[1].probe.setLabel("USOSPE");
    parts.add(.{ .number = 3, .start = 0, .sectors = 133120, .probe = .{ .fs = .vfat, .used = 5 * 1048576, .free = 59 * 1048576, .system = "No system detected" } });
    parts.entries[2].probe.setLabel("CSMWRAP");
    try std.testing.expectEqual(@as(u64, 1000083456 - 2048), parts.allocated);
    var o: Overview = .{};
    o.build(&id, &parts, 1000215216, "Windows 10", true);
    const want = [_][]const u8{
        "ERASE ALL DATA ON THIS DISK",
        "",
        "Disk: Micron 3400",
        "Type: NVMe SSD",
        "S/N: SN01",
        "Size: 476 GiB",
        "Status: not currently in use.",
        "Partitions: 3; unallocated: approx. 65 MiB",
        "Readable file systems: 2; used 20485 MiB, free 460859 MiB",
        "Partition 1: ntfs (487232 MiB)",
        "  Used: 20480 MiB, free: 460800 MiB; Windows (system files)",
        "Partition 2: ntfs USOSPE (1024 MiB)",
        "  Used/free: unknown; System unknown",
        "Partition 3: vfat CSMWRAP (65 MiB)",
        "  Used: 5 MiB, free: 59 MiB; No system detected",
        "File detection does not verify whether a system works.",
        "",
        "All partitions, systems and files on this disk will be erased.",
        "New layout (MBR): 475 GiB NTFS (drive C:) for Windows 10, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.",
    };
    try std.testing.expectEqual(want.len, o.lines().len);
    for (want, o.lines()) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(u64, 0), csmwrapFreeGib(1000));

    // Nothing readable, five partitions: the script's unknown line and count.
    var many: Partitions = .{ .table = .gpt };
    for (0..5) |i| many.add(.{ .number = @intCast(i + 1), .start = 0, .sectors = 2048 });
    o.build(&id, &many, 1000215216, "Windows 10", false);
    try std.testing.expectEqualStrings("Used/free space in file systems: unknown.", o.lines()[8]);
    try std.testing.expectEqualStrings("Partition 1: unknown (1 MiB)", o.lines()[9]);
    try std.testing.expectEqualStrings("(Other partitions: 1)", o.lines()[17]);
}

test "NVMe Identify Namespace data from EFI_DISK_INFO is not a model" {
    var ns: [4096]u8 = @splat(0);
    std.mem.writeInt(u64, ns[0..8], 1000215216, .little); // NSZE
    std.mem.writeInt(u64, ns[8..16], 1000215216, .little); // NCAP
    std.mem.writeInt(u64, ns[16..24], 30000000, .little); // NUSE
    ns[25] = 0x01;
    ns[26] = 0x1f;
    const id = parse(.nvme, &ns);
    try std.testing.expectEqual(@as(usize, 0), id.model_len);
    try std.testing.expectEqualStrings("ssd", id.media.?);
    try std.testing.expect(!printableField(&[_]u8{0} ** 8));
    try std.testing.expect(printableField("  X  "));
    var ata: [512]u8 = @splat(0xff);
    try std.testing.expectEqual(@as(usize, 0), parse(.ahci, &ata).model_len);
}
