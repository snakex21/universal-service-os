const storage = @import("storage");
const console = @import("console.zig");
const vbe_probe = @import("vbe_probe.zig");

const fat32 = storage.fat32;
const random_reader = storage.random_reader;

const p_efi = [_]u16{ 'E', 'F', 'I' };
const p_usos = [_]u16{ 'U', 'S', 'O', 'S' };
const p_ready = [_]u16{ 'x', 'p', '-', 't', 'a', 'r', 'g', 'e', 't', '-', 'r', 'e', 'a', 'd', 'y', '.', 'i', 'n', 'i' };
const ready_path = [_][]const u16{ &p_efi, &p_usos, &p_ready };

const Error = fat32.Error || error{
    ReadyFileTooLarge,
    ShortReadyRead,
    MissingVersion,
    UnsupportedVersion,
    MissingDiskId,
    MissingPartitionStart,
    MissingBiosPartition,
    BadNumber,
    TargetNotFound,
    MultipleTargets,
    InvalidMbr,
    InvalidXpSetupPartition,
    InvalidVbr,
    VgaTextModeFailed,
};

const Ready = struct {
    disk_id: u32,
    partition_start_lba: u32,
    bios_partition: u32,
};

extern fn bios_read_sector_drive(drive: u32, lba: u64, destination: [*]u8) callconv(.c) u32;
extern fn bios_vbe_text_mode() callconv(.c) u32;
extern fn core_chainload_vbr(drive: u32) callconv(.c) noreturn;

pub fn runIfReady(fs: fat32.FileSystem, reader: random_reader.Reader, graphics: ?vbe_probe.Session) void {
    _ = fat32.fileInfo(fs, reader, &ready_path) catch return;
    run(fs, reader, graphics) catch |err| {
        console.print("XP CHAINLOAD FAIL error=");
        console.print(@errorName(err));
        console.line("");
    };
}

fn run(fs: fat32.FileSystem, reader: random_reader.Reader, graphics: ?vbe_probe.Session) Error!void {
    const info = try fat32.fileInfo(fs, reader, &ready_path);
    if (info.size == 0 or info.size > 512) return error.ReadyFileTooLarge;
    var buffer: [512]u8 = undefined;
    const amount = try fat32.readFileRange(fs, reader, &ready_path, 0, buffer[0..info.size]);
    if (amount != info.size) return error.ShortReadyRead;
    const ready = try parseReady(buffer[0..info.size]);

    console.print("XP CHAINLOAD READY mbr=0x");
    console.printHex32(ready.disk_id);
    console.print(" xpsetup_lba=");
    console.printU32(ready.partition_start_lba);
    console.line("");

    var found_drive: ?u8 = null;
    var found_mbr: [512]u8 = undefined;
    var drive: u32 = 0x80;
    while (drive <= 0x8F) : (drive += 1) {
        var sector: [512]u8 = undefined;
        if (bios_read_sector_drive(drive, 0, &sector) != 0) continue;
        if (sector[510] != 0x55 or sector[511] != 0xAA) continue;
        const disk_id = readU32Le(sector[440..444]);
        if (disk_id != ready.disk_id) continue;
        if (found_drive != null) return error.MultipleTargets;
        found_drive = @intCast(drive);
        found_mbr = sector;
    }
    const target_drive = found_drive orelse return error.TargetNotFound;

    try validateMbr(&found_mbr, ready);
    console.print("XP CHAINLOAD TARGET drive=0x");
    console.printHex8(target_drive);
    console.print(" mbr=0x");
    console.printHex32(ready.disk_id);
    console.print(" partition=");
    console.printU32(ready.bios_partition);
    console.line("");

    if (graphics != null) {
        if (bios_vbe_text_mode() != 0) return error.VgaTextModeFailed;
        console.line("XP CHAINLOAD VGA TEXT PASS");
    }

    const vbr_ptr: [*]u8 = @ptrFromInt(0x00007C00);
    if (bios_read_sector_drive(target_drive, ready.partition_start_lba, vbr_ptr) != 0) return error.InvalidVbr;
    const vbr = vbr_ptr[0..512];
    if (vbr[510] != 0x55 or vbr[511] != 0xAA) return error.InvalidVbr;
    if (readU32Le(vbr[28..32]) != ready.partition_start_lba) return error.InvalidVbr;

    // NT52 FAT32 boot code keeps BP=7C00 and obtains the boot drive from the
    // FAT32 extended BPB at offset 0x40. mkfs.fat initializes that byte to
    // 0x80, but XPSETUP can be 0x81+ while the Kingston remains BIOS disk 0.
    // Patch only the in-memory VBR so SETUPLDR sees the actual runtime drive.
    const old_bpb_drive = vbr[64];
    vbr[64] = target_drive;
    console.print("XP CHAINLOAD BPB DRIVE old=0x");
    console.printHex8(old_bpb_drive);
    console.print(" runtime=0x");
    console.printHex8(target_drive);
    console.line("");

    var stage2_probe: [512]u8 = undefined;
    if (bios_read_sector_drive(target_drive, @as(u64, ready.partition_start_lba) + 12, &stage2_probe) != 0) return error.InvalidVbr;
    console.print("XP CHAINLOAD NT52 STAGE2 PROBE first=0x");
    console.printHex32(readU32Le(stage2_probe[0..4]));
    console.line("");

    console.print("XP CHAINLOAD VBR PASS drive=0x");
    console.printHex8(target_drive);
    console.print(" lba=");
    console.printU32(ready.partition_start_lba);
    console.line(" -> 0000:7C00");
    core_chainload_vbr(target_drive);
}

fn validateMbr(mbr: *const [512]u8, ready: Ready) Error!void {
    if (mbr[510] != 0x55 or mbr[511] != 0xAA) return error.InvalidMbr;
    if (readU32Le(mbr[440..444]) != ready.disk_id) return error.InvalidMbr;
    if (ready.bios_partition < 1 or ready.bios_partition > 4) return error.InvalidMbr;

    const entry = 446 + (ready.bios_partition - 1) * 16;
    if (mbr[entry] != 0x00 or mbr[entry + 4] != 0x0C) return error.InvalidXpSetupPartition;
    if (readU32Le(mbr[entry + 8 .. entry + 12]) != ready.partition_start_lba) return error.InvalidXpSetupPartition;
}

fn parseReady(input: []const u8) Error!Ready {
    var version: ?u32 = null;
    var disk_id: ?u32 = null;
    var start: ?u32 = null;
    var bios_partition: ?u32 = null;

    var cursor: usize = 0;
    while (cursor < input.len) {
        const line_start = cursor;
        while (cursor < input.len and input[cursor] != '\n') : (cursor += 1) {}
        var line = input[line_start..cursor];
        if (cursor < input.len) cursor += 1;
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const eq = indexOf(line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (eql(key, "version")) version = try parseNumber(value);
        if (eql(key, "mbr_disk_id")) disk_id = try parseNumber(value);
        if (eql(key, "partition_start_lba")) start = try parseNumber(value);
        if (eql(key, "bios_partition")) bios_partition = try parseNumber(value);
    }

    const parsed_version = version orelse return error.MissingVersion;
    if (parsed_version != 2) return error.UnsupportedVersion;
    return .{
        .disk_id = disk_id orelse return error.MissingDiskId,
        .partition_start_lba = start orelse return error.MissingPartitionStart,
        .bios_partition = bios_partition orelse return error.MissingBiosPartition,
    };
}

fn parseNumber(text: []const u8) Error!u32 {
    if (text.len == 0) return error.BadNumber;
    var base: u32 = 10;
    var cursor: usize = 0;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        cursor = 2;
        if (cursor == text.len) return error.BadNumber;
    }
    var value: u32 = 0;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        const digit: u32 = if (c >= '0' and c <= '9') c - '0' else if (base == 16 and c >= 'a' and c <= 'f') c - 'a' + 10 else if (base == 16 and c >= 'A' and c <= 'F') c - 'A' + 10 else return error.BadNumber;
        if (digit >= base) return error.BadNumber;
        const mul = @mulWithOverflow(value, base);
        if (mul[1] != 0) return error.BadNumber;
        const add = @addWithOverflow(mul[0], digit);
        if (add[1] != 0) return error.BadNumber;
        value = add[0];
    }
    return value;
}

fn readU32Le(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn indexOf(text: []const u8, needle: u8) ?usize {
    for (text, 0..) |c, i| if (c == needle) return i;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

test "XP ready marker parser accepts deterministic target metadata" {
    const ready = try parseReady(
        "version=2\r\n" ++
            "mbr_disk_id=0x1234abcd\r\n" ++
            "bios_partition=2\r\n" ++
            "partition_start_lba=1050624\r\n",
    );
    try @import("std").testing.expectEqual(@as(u32, 0x1234ABCD), ready.disk_id);
    try @import("std").testing.expectEqual(@as(u32, 1050624), ready.partition_start_lba);
    try @import("std").testing.expectEqual(@as(u32, 2), ready.bios_partition);
}
