//! BIOS entry to the selected MS-DOS ISO and Windows 3.x installers.
const std = @import("std");
const storage = @import("storage");
const dos = @import("dos_fat.zig");
const Seed = @import("dos_fat16_seed.zig").Seed;
const Source = @import("dos_iso_source.zig").Source;
const programs = @import("dos_programs.zig");
const memdisk = @import("dos_memdisk.zig");
const target_ui = @import("dos_target_ui.zig");
const console = @import("console.zig");
const seabios = @import("seabios.zig");
const csmwrap_esp = @import("dos_csmwrap_esp.zig");
const vbe = @import("vbe_probe.zig");
const fat = storage.fat32;
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
extern const dos_mbr_start: [512]u8;
extern const dos_source_mbr_start: [512]u8;

/// noinline: its locals must not add to legacy_boot_actions.execute's frame (the PM32
/// stack below 0x9E000 ends at the Core .data; docs/design/bios-via-csmwrap.md).
pub noinline fn run(esp: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session, system_id: []const u8, image_name: []const u8) !void {
    const session = graphics orelse return error.DosPartitionScreenNeedsGraphics;
    const windows = !std.mem.eql(u8, system_id, "ms-dos");
    const install = if (windows) true else target_ui.dosAction(session) orelse return;
    try @import("windows_iso_config.zig").validateName(image_name);
    @import("graphics_menu.zig").busy(&session, if (windows) "Windows 3.x" else "MS-DOS");
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var name: [255]u16 = undefined;
    for (image_name, 0..) |ch, i| name[i] = ch;
    const dos_path = [_][]const u16{ wide("Systems"), wide("DOS"), wide("MS-DOS"), wide("Images"), if (windows) wide("MS-DOS 6.22.iso") else name[0..image_name.len] };
    var source = Source.open(fs, reader, bulk, &dos_path) catch |err| {
        if (err == error.NotFound and windows) return error.MissingMsDos622IsoInDosImages;
        return err;
    };
    _ = try source.require("SYS.COM"); _ = try source.require("EXPAND.EXE");
    const ram = try memdisk.allocateMode(esp, reader, bulk, if (install) .second_disk else .first_disk);
    const scratch: [*]u8 = @ptrFromInt(0x300000);
    const floppy = try source.bootFloppy(scratch[0..1474560]);
    var builder = try dos.Builder.initDisk(ram, floppy.bytes[0..512], if (install) &dos_source_mbr_start else &dos_mbr_start, if (install) 0x81 else 0x80);
    var seed = Seed{ .boot = floppy.bytes[0..512].*, .files = undefined };
    for ([_][]const u8{ "IO.SYS", "MSDOS.SYS", "COMMAND.COM" }, 0..) |filename, index| {
        const entry = try floppy.lookup(filename);
        const bytes = try builder.reserve(filename, dos.get32(entry, 28), false);
        try floppy.read(entry, bytes);
        seed.files[index] = bytes;
    }
    var dos_files = try builder.makeDirectory("DOSFILES", null);
    try source.copyRoot(&builder, &dos_files, true);
    if (windows) {
        const folder = if (std.mem.eql(u8, system_id, "windows-3-1")) wide("Windows 3.1") else wide("Windows 3.11");
        const path = [_][]const u16{ wide("Systems"), wide("Windows"), folder, wide("Images"), name[0..image_name.len] };
        var win = try Source.open(fs, reader, bulk, &path);
        const setup = try win.require("SETUP.EXE");
        var signature: [2]u8 = undefined;
        _ = try win.readAt(@as(u64, setup.extent_lba) * 2048, &signature);
        if (!std.mem.eql(u8, &signature, "MZ")) return error.InvalidWindows3Setup;
        var directory = try builder.makeDirectory("WINSETUP", null);
        try win.copyRoot(&builder, &directory, false);
    }
    try programs.copy(fs, reader, bulk, &builder);
    // VBMOUSE/VBADOS and the *.CSM start-menu variants are always in the RAM
    // disk (small); INSTALL.BAT uses them only when CSMWRAP.TAG is there.
    for ([_][]const u8{ "HIMEMX.EXE", "INSTALL.BAT", "LIVE.BAT", "PREPDOS.BAT", "COPYDOS.BAT", "UNPACK.BAT", "HIMEMX.TXT", "HIMEMSRC.ZIP", "LICENSE.TXT", "REBOOT.COM", "VBMOUSE.EXE", "VBADOS.TXT", "USOSKEY.COM" }) |filename|
        try helper(esp, reader, bulk, &builder, filename);
    if (windows) {
        for ([_][]const u8{ "W3START.BAT", "WINMENU.BAT", "W3CONFIG.SYS", "W3AUTO.BAT", "VBMOUSE.DRV", "USOSKEY.DRV", "W3CONFIG.CSM", "W3AUTO.CSM", "W3INI.BAS" }) |filename|
            try helper(esp, reader, bulk, &builder, filename);
    }
    // Installed under CSMWrap (no firmware CSM; docs/design/bios-via-csmwrap.md):
    // INSTALL.BAT sees CSMWRAP.TAG and adds HIMEM /M:2, VBADOS (USB mouse
    // through SeaBIOS INT 15h C2) and the Windows 3.x start-menu variants.
    // Real BIOS PCs get none of it.
    const csmwrap = install and seabios.csmwrap;
    if (csmwrap) try builder.add("CSMWRAP.TAG", "1");
    var config: [256]u8 = undefined;
    const letter: u8 = if (install) 'D' else 'C';
    const config_text = try std.fmt.bufPrint(&config, "DEVICE={c}:\\HIMEMX.EXE /MAX=32768 /X2MAX32\r\nDOS=HIGH\r\nFILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nSHELL={c}:\\COMMAND.COM {c}:\\ /E:2048 /P\r\n", .{ letter, letter, letter });
    try builder.add("CONFIG.SYS", config_text);
    seed.files[3] = config_text;
    var startup: [128]u8 = undefined;
    const startup_text = try std.fmt.bufPrint(&startup, "@echo off\r\n{c}:\r\ncd \\\r\n{c}:\\{s}\r\n", .{ letter, letter, if (install) @as([]const u8, "INSTALL.BAT") else "LIVE.BAT" });
    try builder.add("AUTOEXEC.BAT", startup_text);
    seed.files[4] = startup_text;
    try seed.validate();
    console.line("[DOS16] ORIGINAL DOS, SOURCE FILES AND PROGRAMS READY IN RAM");
    if (install) {
        const selected = (try target_ui.choose(drive, session, .dos_install)) orelse return;
        const plan = selected.format_plan orelse return error.MissingDosPartitionPlan;
        try target_ui.commitDos(plan, seed);
        console.line("[DOS16] USER CONFIRMED FAT16 TARGET COMMITTED");
        if (csmwrap) {
            const image_path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("msdos"), wide(csmwrap_esp.image_name) };
            const info = try fat.fileInfo(esp, reader, &image_path);
            _ = try target_ui.addCsmwrapEsp(plan, EspImage{ .esp = esp, .bulk = bulk, .path = &image_path }, info.size);
            console.line("[DOS16] CSMWRAP ESP OK");
        }
        memdisk.start(selected.drive);
    }
    console.line("[DOS16] LIVE SESSION; PHYSICAL HARD DISKS HIDDEN");
    memdisk.start(0xff);
}

const EspImage = struct {
    esp: fat.FileSystem,
    bulk: Reader,
    path: []const []const u16,
    pub fn read(self: EspImage, offset: u32, out: []u8) !void {
        if (try fat.readFileRange(self.esp, self.bulk, self.path, offset, out) != out.len) return error.InvalidCsmwrapEspImage;
    }
};

fn helper(esp: fat.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder, filename: []const u8) !void {
    var name: [12]u16 = undefined;
    for (filename, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("msdos"), name[0..filename.len] };
    const info = try fat.fileInfo(esp, reader, &path);
    if (info.size == 0 or info.size > 1024 * 1024) return error.InvalidDosHelper;
    const output = try builder.reserve(filename, info.size, false);
    if (try fat.readFileRange(esp, bulk, &path, 0, output) != output.len) return error.ShortDosHelper;
}
