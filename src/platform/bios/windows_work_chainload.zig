const std = @import("std");
const storage = @import("storage");
const console = @import("console.zig");
const vbe = @import("vbe_probe.zig");
const graphics_menu = @import("graphics_menu.zig");
const params = @import("linux_boot_params.zig");
const contract = @import("windows_boot_contract.zig");
const fat32 = storage.fat32;
const Reader = storage.random_reader.Reader;
const path = [_][]const u16{ &std.unicode.utf8ToUtf16LeStringLiteral("EFI").*, &std.unicode.utf8ToUtf16LeStringLiteral("USOS").*, &std.unicode.utf8ToUtf16LeStringLiteral("windows-bios-ready.ini").* };

extern fn bios_read_sector_drive(drive: u32, lba: u64, destination: [*]u8) callconv(.c) u32;
extern fn bios_write_sector_drive(drive: u32, lba: u64, source: [*]const u8) callconv(.c) u32;
const wimboot = @import("windows_wimboot.zig");

pub fn runIfReady(fs: fat32.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session) void {
    run(fs, reader, bulk, drive, graphics) catch |err| {
        console.screen_output = true;
        console.print("WINDOWS BIOS HANDOFF STOP: ");
        console.line(@errorName(err));
        if (graphics) |session| graphics_menu.windowsSetupFailure(&session, @errorName(err));
        console.line("Press ESC to return to the USOS menu.");
        while (console.readKey().ascii != 27) {}
    };
}

fn run(fs: fat32.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session) !void {
    const info = fat32.fileInfo(fs, reader, &path) catch |err| {
        if (err == error.NotFound) return;
        return err;
    };
    if (info.size != 512) return error.InvalidReadySize;
    var marker: [512]u8 = undefined;
    if (try fat32.readFileRange(fs, reader, &path, 0, &marker) != 512) return error.ShortReadyRead;
    if (std.mem.startsWith(u8, &marker, "ready=0\n")) return;
    const work = try storage.gpt.findUsosWork(reader);
    var guid: [36]u8 = undefined;
    params.formatGuidDisk(work.part_guid, &guid);
    try contract.validateMarker(&marker, &guid);
    try wimboot.prepare(fs, reader, bulk, drive, graphics);

    // A 512-byte file occupies one complete sector even when FAT is fragmented.
    // Consume only that sector; never alter allocation tables or directory data.
    if (info.first_cluster < 2 or info.first_cluster - 2 >= fs.cluster_count) return error.InvalidReadyCluster;
    const relative = @as(u64, fs.first_data_sector) + @as(u64, info.first_cluster - 2) * fs.sectors_per_cluster;
    if (relative >= fs.total_sectors or relative * 512 + 512 > fs.partition.size_bytes or fs.partition.start_bytes % 512 != 0) return error.ReadyOutsideEsp;
    const lba = fs.partition.start_bytes / 512 + relative;
    var readback: [512]u8 = undefined;
    if (bios_read_sector_drive(drive, lba, &readback) != 0 or !std.mem.eql(u8, &marker, &readback)) return error.ReadySectorChanged;
    marker[6] = '0';
    if (bios_write_sector_drive(drive, lba, &marker) != 0) return error.ReadyConsumeFailed;
    if (bios_read_sector_drive(drive, lba, &readback) != 0 or !std.mem.eql(u8, &marker, &readback)) return error.ReadyConsumeReadbackFailed;
    console.line("[WINDOWS_BIOS] ONE-SHOT CONSUMED PASS");
    wimboot.start();
}
