const std = @import("std");
const graphics = @import("graphics");
const vbe = @import("vbe_probe.zig");
const console = @import("console.zig");
const partition = @import("dos_partition.zig");
const formatter = @import("dos_fat32_format.zig");
const formatter16 = @import("dos_fat16_format.zig");
const seeder16 = @import("dos_fat16_seed.zig");
const Canvas = graphics.menu_canvas.Canvas;
const Raw = extern struct { sectors_low: u32 = 0, sectors_high: u32 = 0, bytes_per_sector: u16 = 0, cylinders: u16 = 0, heads: u16 = 0, sectors_per_track: u16 = 0 };
extern fn bios_drive_info(drive: u32, output: *Raw) callconv(.c) u32;
extern fn bios_read_sector_drive(drive: u32, lba: u64, out: [*]u8) callconv(.c) u32;
extern fn bios_write_sector_drive(drive: u32, lba: u64, out: [*]const u8) callconv(.c) u32;
extern fn bios_write_sectors_drive(drive: u32, lba: u64, out: [*]const u8, count: u32) callconv(.c) u32;
extern const dos_mbr_start: [512]u8;
const Disk = struct { drive: u8, sectors: u32, before: [512]u8, label: [100]u8, len: usize, cylinders: u16, heads: u16, spt: u16 };
pub const Action = enum { repair, install, dos_install };
pub const Selection = struct { drive: u8, format_plan: ?partition.Plan = null };
const Writer = struct {
    drive: u8,
    pub fn read(self: *Writer, lba: u32, out: *[512]u8) !void { if (bios_read_sector_drive(self.drive, lba, out) != 0) return error.DosTargetReadFailed; }
    pub fn write(self: *Writer, lba: u32, bytes: *const [512]u8) !void { if (bios_write_sector_drive(self.drive, lba, bytes) != 0) return error.DosTargetWriteFailed; }
    pub fn zero(self: *Writer, lba: u32, sectors: u32) !void {
        const scratch: [*]u8 = @ptrFromInt(0x300000);
        @memset(scratch[0..127*512], 0);
        var done: u32 = 0;
        while (done < sectors) {
            const batch = @min(127, sectors - done);
            if (bios_write_sectors_drive(self.drive, lba + done, scratch, batch) != 0) return error.DosTargetWriteFailed;
            done += batch;
        }
    }
};

pub fn action(session: vbe.Session) ?Action {
    const canvas = Canvas.init(session.surface, graphics.Theme{});
    var selected: usize = 0;
    while (true) {
        canvas.beginList("Windows 98 SE", "Instalacja i naprawa obslugi wiekszej pamieci RAM", "BIOS", "");
        canvas.listRow(0, .{ .value = "Napraw RAM w zainstalowanym Windows 98", .selected = selected == 0 });
        canvas.listRow(1, .{ .value = "Nowa instalacja Windows 98 SE", .selected = selected == 1 });
        canvas.footer("STRZALKI - WYBIERZ    ENTER - DALEJ    ESC - WROC");
        const key = console.readKey();
        if (key.ascii == 27) return null;
        if (key.scan == 0x48) selected = 0;
        if (key.scan == 0x50) selected = 1;
        if (key.ascii == 13) return if (selected == 0) .repair else .install;
    }
}

pub fn dosAction(session: vbe.Session) ?bool {
    const canvas = Canvas.init(session.surface, graphics.Theme{});
    var install = false;
    while (true) {
        canvas.beginList("MS-DOS", "Uruchom programy z USB albo zainstaluj DOS na dysku", "BIOS", "");
        canvas.listRow(0, .{ .value = "Uruchom DOS i programy z USB", .selected = !install });
        canvas.listRow(1, .{ .value = "Zainstaluj MS-DOS na dysku", .selected = install });
        canvas.listRow(3, .{ .value = "Uruchomienie z USB: C: jest dyskiem w RAM." });
        canvas.listRow(4, .{ .value = "Zmiany w tej sesji znikna po wylaczeniu komputera." });
        canvas.footer("STRZALKI - WYBIERZ    ENTER - DALEJ    ESC - WROC");
        const key = console.readKey();
        if (key.ascii == 27) return null;
        if (key.scan == 0x48) install = false;
        if (key.scan == 0x50) install = true;
        if (key.ascii == 13) return install;
    }
}

pub fn choose(source: u8, session: vbe.Session, selected_action: Action) !?Selection {
    const fat16 = selected_action == .dos_install;
    const title = if (fat16) "MS-DOS / Windows 3.x" else "Windows 98 SE";
    var disks: [16]Disk = undefined;
    var source_gpt: [512]u8 = undefined;
    if (bios_read_sector_drive(source, 1, &source_gpt) != 0) return error.DosSourceIdentityUnavailable;
    var count: usize = 0;
    for (0x80..0x90) |number| {
        if (number == source) continue;
        var raw = Raw{};
        if (bios_drive_info(@intCast(number), &raw) != 0 or raw.bytes_per_sector != 512 or raw.sectors_high != 0 or raw.sectors_low < (if (fat16) @as(u32, 264226) else 4_196_386)) continue;
        if (fat16) _ = partition.planFat16(@intCast(number), source, raw.sectors_low, 128, raw.cylinders, raw.heads, raw.sectors_per_track, [_]u8{0} ** 512) catch continue;
        var sector: [512]u8 = undefined;
        if (bios_read_sector_drive(@intCast(number), 1, &sector) != 0) continue;
        if (std.mem.eql(u8, sector[0..8], "EFI PART") and std.mem.eql(u8, sector[56..72], source_gpt[56..72])) continue;
        if (bios_read_sector_drive(@intCast(number), 0, &sector) != 0) continue;
        if (selected_action == .repair and !partition.repairLayout(&sector)) continue;
        var parts: u8 = 0;
        var style: []const u8 = "MBR";
        if (sector[510] == 0x55 and sector[511] == 0xaa) {
            for (0..4) |i| {
                const kind = sector[446 + i * 16 + 4];
                if (kind != 0) parts += 1;
                if (kind == 0xee) style = "GPT";
                if (kind == 7) style = "MBR / NTFS";
            }
        }
        var disk = &disks[count];
        disk.drive = @intCast(number); disk.sectors = raw.sectors_low; disk.before = sector;
        disk.cylinders = raw.cylinders; disk.heads = raw.heads; disk.spt = raw.sectors_per_track;
        const text = if (std.mem.eql(u8, style, "GPT"))
            try std.fmt.bufPrint(&disk.label, "Dysk {d} - {d} MiB - GPT", .{ count + 1, raw.sectors_low >> 11 })
        else
            try std.fmt.bufPrint(&disk.label, "Dysk {d} - {d} MiB - {s}, partycje: {d}", .{ count + 1, raw.sectors_low >> 11, style, parts });
        disk.len = text.len; count += 1;
    }
    if (count == 0) return error.NoCompatibleDosTargetDisk;
    console.releaseKeyAfterFirmwareIo();
    const canvas = Canvas.init(session.surface, graphics.Theme{});
    var selected: usize = 0;
    while (true) {
        canvas.beginList(title, if (selected_action == .repair) "Naprawa RAM: zachowuje system i partycje. Pendrive jest wykluczony." else if (fat16) "Wybierz dysk dla nowej partycji FAT16. Pendrive jest wykluczony." else "USOS przygotuje nowa partycje FAT32. Pendrive instalacyjny jest wykluczony.", "BIOS", "");
        const begin = graphics.menu_canvas.listStart(selected, count, canvas.visibleRows());
        for (begin..@min(count, begin + canvas.visibleRows())) |i| canvas.listRow(i - begin, .{ .value = disks[i].label[0..disks[i].len], .selected = selected == i });
        canvas.footer("STRZALKI - WYBIERZ    ENTER - DALEJ    ESC - ANULUJ");
        const key = console.readKey();
        if (key.ascii == 27) return null;
        if (key.scan == 0x48 and selected > 0) selected -= 1;
        if (key.scan == 0x50 and selected + 1 < count) selected += 1;
        if (key.ascii != 13) continue;
        const disk = &disks[selected];
        if (selected_action == .repair) {
            var confirmed = false;
            while (true) {
                canvas.beginList("Naprawa RAM Windows 98", disk.label[0..disk.len], "Patcher9x / poprawka RAM", "");
                canvas.listRow(0, .{ .value = "ANULUJ", .selected = !confirmed });
                canvas.listRow(1, .{ .value = "ZASTOSUJ POPRAWKE RAM", .selected = confirmed });
                canvas.listRow(3, .{ .value = "System i partycje pozostana. Pliki przed zmiana dostana kopie." });
                canvas.listRow(4, .{ .value = "Naprawa instalacji w C:\\WINDOWS, takze po pierwszym restarcie." });
                canvas.footer("STRZALKI - WYBIERZ    ENTER - ZATWIERDZ    ESC - WROC");
                const repair_key = console.readKey();
                if (repair_key.ascii == 27) break;
                if (repair_key.scan == 0x48) confirmed = false;
                if (repair_key.scan == 0x50) confirmed = true;
                if (repair_key.ascii == 13) {
                    if (confirmed) return .{ .drive = disk.drive };
                    break;
                }
            }
            continue;
        }
        var size_index: usize = 0;
        const sizes = if (fat16) [_]u32{ 256, 512, 128 } else [_]u32{ 8, 4, 2 };
        while (size_index < 2 and !sizeAvailable(disk, source, sizes[size_index], fat16)) size_index += 1;
        while (true) {
            canvas.beginList("Rozmiar nowej partycji", disk.label[0..disk.len], if (fat16) "MS-DOS / FAT16" else "Windows 98 SE / FAT32", "");
            const labels = if (fat16) [_][]const u8{ "256 MiB - zalecane", "512 MiB", "128 MiB" } else [_][]const u8{ "8 GiB - zalecane", "4 GiB", "2 GiB" };
            for (labels, 0..) |label, i| canvas.listRow(i, .{ .value = label, .selected = size_index == i, .unavailable = !sizeAvailable(disk, source, sizes[i], fat16) });
            canvas.listRow(4, .{ .value = "Pozostale miejsce zostanie nieprzydzielone." });
            canvas.listRow(5, .{ .value = "Dotychczasowe partycje na tym dysku zostana usuniete." });
            canvas.footer("STRZALKI - ROZMIAR    ENTER - PODSUMOWANIE    ESC - WROC");
            const size_key = console.readKey();
            if (size_key.ascii == 27) break;
            if (size_key.scan == 0x48 and size_index > 0) size_index -= 1;
            if (size_key.scan == 0x50 and size_index < 2) size_index += 1;
            if (size_key.ascii != 13 or !sizeAvailable(disk, source, sizes[size_index], fat16)) continue;
            const planned = if (fat16)
                try partition.planFat16(disk.drive, source, disk.sectors, sizes[size_index], disk.cylinders, disk.heads, disk.spt, disk.before)
            else try partition.plan(disk.drive, source, disk.sectors, sizes[size_index], disk.before);
            var size_text: [80]u8 = undefined;
            const detail = try std.fmt.bufPrint(&size_text, "Nowy uklad: jedna aktywna partycja {s} {d} {s}, litera C:", .{ if (fat16) @as([]const u8, "FAT16") else "FAT32", sizes[size_index], if (fat16) @as([]const u8, "MiB") else "GiB" });
            var confirm: usize = 0;
            while (true) {
                canvas.beginList("Potwierdz przygotowanie dysku", disk.label[0..disk.len], title, "");
                canvas.listRow(0, .{ .value = "ANULUJ", .selected = confirm == 0 });
                canvas.listRow(1, .{ .value = "USUN PARTYCJE I INSTALUJ", .selected = confirm == 1 });
                canvas.listRow(3, .{ .value = detail });
                canvas.listRow(4, .{ .value = "Wszystkie obecne dane na wybranym dysku zostana utracone." });
                canvas.listRow(5, .{ .value = "Nastepnie automatycznie ruszy formatowanie i instalator." });
                canvas.footer("STRZALKI - WYBIERZ    ENTER - ZATWIERDZ    ESC - WROC");
                const confirm_key = console.readKey();
                if (confirm_key.ascii == 27) break;
                if (confirm_key.scan == 0x48) confirm = 0;
                if (confirm_key.scan == 0x50) confirm = 1;
                if (confirm_key.ascii == 13) {
                    if (confirm == 1) return .{ .drive = disk.drive, .format_plan = planned };
                    break;
                }
            }
        }
    }
}
fn sizeAvailable(disk: *const Disk, source: u8, size: u32, fat16: bool) bool {
    if (fat16) {
        _ = partition.planFat16(disk.drive, source, disk.sectors, size, disk.cylinders, disk.heads, disk.spt, disk.before) catch return false;
        return true;
    }
    return disk.sectors >= size * 2 * 1024 * 1024 + 2082;
}
pub fn commit(plan: partition.Plan) !void {
    var current = Raw{};
    if (bios_drive_info(plan.drive, &current) != 0 or current.sectors_high != 0 or current.sectors_low != plan.disk_sectors or current.bytes_per_sector != 512) return error.DosTargetChanged;
    if (plan.fat16 and (current.cylinders != plan.cylinders or current.heads != plan.heads or current.sectors_per_track != plan.sectors_per_track)) return error.DosTargetChanged;
    var writer = Writer{ .drive = plan.drive };
    try partition.apply(&writer, plan, &dos_mbr_start);
    if (plan.fat16) try formatter16.format(&writer, plan) else try formatter.format(&writer, plan);
}
pub fn commitDos(plan: partition.Plan, seed: seeder16.Seed) !void {
    try seed.validate();
    if (!plan.fat16) return error.InvalidDosBootSeed;
    try commit(plan);
    var writer = Writer{ .drive = plan.drive };
    try seeder16.write(&writer, plan, seed);
}
