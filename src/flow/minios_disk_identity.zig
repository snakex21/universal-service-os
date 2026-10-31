//! The disk facts of the MiniOS disk question (src/platform/uefi/minios_disk.zig),
//! in the form the Alpine route's picker shows them (tools/target_disk_identity.sh,
//! tools/xp_disk_overview.sh, tools/vista_csmwrap_prepare.sh): the model and
//! serial number from the controller's IDENTIFY data (EFI_DISK_INFO), the
//! bus and media chip tokens, the partition count and the erase-confirmation
//! overview with the CSMWrap layout. Pure: host-tested.
const std = @import("std");

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

/// IDENTIFY data of `kind`: NVMe Identify Controller (SN bytes 4-23, MN
/// 24-63; NVMe is always SSD, as usos_disk_media) or ATA IDENTIFY DEVICE
/// (serial words 10-19, model 27-46, nominal media rotation rate word 217:
/// 1 = SSD, 0x0401-0xfffe = HDD).
pub fn parse(kind: Interface, data: []const u8) Identity {
    var id: Identity = .{ .interface = kind };
    switch (kind) {
        .nvme => {
            if (data.len < 64) return id;
            id.serial_len = clean(&id.serial, data[4..24]);
            id.model_len = clean(&id.model, data[24..64]);
            id.media = "ssd";
        },
        .ahci, .ide => {
            if (data.len < 94) return id;
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

pub const Partitions = struct {
    table: enum { none, mbr, gpt } = .none,
    count: u32 = 0,
    allocated: u64 = 0,

    pub fn addGpt(self: *Partitions, entry: []const u8) void {
        if (entry.len < 48 or std.mem.allEqual(u8, entry[0..16], 0)) return;
        const first = std.mem.readInt(u64, entry[32..40], .little);
        const last = std.mem.readInt(u64, entry[40..48], .little);
        self.count += 1;
        if (last >= first) self.allocated +|= last - first + 1;
    }

    /// Primary MBR entries (a GPT disk is read through its GPT instead).
    pub fn fromMbr(sector: []const u8) Partitions {
        if (sector.len < 512 or sector[510] != 0x55 or sector[511] != 0xaa) return .{};
        var result: Partitions = .{ .table = .mbr };
        for (0..4) |i| {
            const e = sector[446 + i * 16 ..][0..16];
            if (e[4] == 0) continue;
            result.count += 1;
            result.allocated +|= std.mem.readInt(u32, e[12..16], .little);
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
    storage: [12][224]u8 = undefined,
    texts: [12][]const u8 = undefined,
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
    const p = Partitions.fromMbr(&mbr);
    try std.testing.expectEqual(@as(u32, 2), p.count);
    try std.testing.expectEqual(@as(u64, 206848), p.allocated);
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
    gpt.addGpt(&entry);
    entry[0] = 1;
    std.mem.writeInt(u64, entry[32..40], 2048, .little);
    std.mem.writeInt(u64, entry[40..48], 4095, .little);
    gpt.addGpt(&entry);
    try std.testing.expectEqual(@as(u32, 1), gpt.count);
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
    const parts: Partitions = .{ .table = .mbr, .count = 3, .allocated = 1000083456 - 2048 };
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
        "",
        "All partitions, systems and files on this disk will be erased.",
        "New layout (MBR): 475 GiB NTFS (drive C:) for Windows 10, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.",
    };
    try std.testing.expectEqual(want.len, o.lines().len);
    for (want, o.lines()) |a, b| try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqual(@as(u64, 0), csmwrapFreeGib(1000));
}
