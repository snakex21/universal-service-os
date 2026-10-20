const std = @import("std");
const storage = @import("storage");
const iso9660 = @import("catalog").iso9660;
const fat = storage.fat32;
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;
const dos = @import("dos_fat.zig");
const config = @import("catalog").windows_iso_config;
const memdisk = @import("dos_memdisk.zig");
const target_ui = @import("dos_target_ui.zig");
const wimboot = @import("windows_wimboot.zig");
const graphics_menu = @import("graphics_menu.zig");
const console = @import("console.zig");
const vbe = @import("vbe_probe.zig");
const seabios = @import("seabios.zig");
const csmwrap_esp = @import("dos_csmwrap_esp.zig");
const EspImage = @import("dos6_native_iso.zig").EspImage;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

/// Windows 95/98/Me from the ISO's own DOS boot floppy
/// (docs/win9x-modern-2026-09-30.md). `tag` goes to U9ENV.BAT (INSTALL.BAT
/// picks the patches and Setup switches by it).
/// The DATA folder is the name (Systems\Windows\<name>).
const Release = struct { id: []const u8, name: []const u8, tag: []const u8 };
const releases = [_]Release{
    .{ .id = "windows-98-se", .name = "Windows 98 SE", .tag = "98SE" },
    .{ .id = "windows-98", .name = "Windows 98", .tag = "98" },
    .{ .id = "windows-me", .name = "Windows Me", .tag = "ME" },
    .{ .id = "windows-95", .name = "Windows 95", .tag = "95" },
};
/// The Setup folder of the CD: 98 and 98 SE, Me, 95 OSR2.
const setup_folders = [_][]const u8{ "win98", "win9x", "win95" };
const max_answer_bytes = 256 * 1024;
const win9x_folder = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("win9x") };
/// Copied from EFI\USOS\dos-native\win9x to the RAM disk root; the list
/// matches tools/build_win9x_support.py FILES.
const win9x_helpers = [_][]const u8{ "U9FIX.COM", "U9FIX.TXT", "USOSVESA.INF", "VESAMINI.DRV", "VESAMINI.VXD", "VMHAL9X.DLL", "VMHAL486.DLL", "VMDISP9X.DLL", "VMDISP9X.TXT", "USOSKEY.COM", "USOSKEY.DRV", "USOSMOUS.DRV", "VBMOUSE.EXE", "VBMOUSE.DRV", "VBADOS.TXT", "DOSMOUSE.BAT", "INWIN.COM", "CREGFIX.SYS", "USOSLAN.EXE" };

const Iso = struct {
    fs: ntfs.FileSystem,
    disk: Reader,
    file: *const ntfs.File,
    pub fn size(self: *const Iso) u64 {
        return self.file.size();
    }
    pub fn readAt(self: *const Iso, offset: u64, out: []u8) !usize {
        try self.file.readAt(self.fs, self.disk, offset, out);
        return out.len;
    }
};

/// noinline: its locals must not add to legacy_boot_actions.execute's frame (the PM32
/// stack below 0x9E000 ends at the Core .data; docs/design/bios-via-csmwrap.md).
pub noinline fn run(esp: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session, system_id: []const u8, image_name: []const u8, unattended_name: ?[]const u8) !void {
    const session = graphics orelse return error.DosPartitionScreenNeedsGraphics;
    const release = for (&releases) |*entry| {
        if (std.mem.eql(u8, entry.id, system_id)) break entry;
    } else return error.UnsupportedWin9xRelease;
    const action = target_ui.action(session, release.name) orelse return;
    var folder_name: [16]u16 = undefined;
    for (release.name, 0..) |ch, i| folder_name[i] = ch;
    const folder = folder_name[0..release.name.len];
    try config.validateName(image_name);
    if (unattended_name) |answer| try config.validateName(answer);
    graphics_menu.windowsSetupStart(&session);
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var name: [255]u16 = undefined;
    for (image_name, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("Systems"), wide("Windows"), folder, wide("Images"), name[0..image_name.len] };
    var file: ntfs.File = undefined;
    try ntfs.openFile(fs, reader, &path, &file);
    var iso = Iso{ .fs = fs, .disk = bulk, .file = &file };
    var setup_folder: []const u8 = undefined;
    const setup = for (setup_folders) |candidate| {
        if (try iso9660.findRecord(&iso, candidate)) |record| {
            setup_folder = candidate;
            break record;
        }
    } else return error.DosSetupDirectoryMissing;
    if (!setup.is_directory or setup.size > 1024 * 1024) return error.InvalidDosSetupDirectory;
    var setup_path: [16]u8 = undefined;
    const executable = (try iso9660.findRecord(&iso, try std.fmt.bufPrint(&setup_path, "{s}/setup.exe", .{setup_folder}))) orelse return error.DosSetupMissing;
    if (executable.is_directory or executable.size == 0) return error.DosSetupMissing;
    var descriptor: [2048]u8 = undefined;
    _ = try iso.readAt(17 * 2048, &descriptor);
    const bootable = descriptor[0] == 0 and std.mem.eql(u8, descriptor[1..6], "CD001") and std.mem.startsWith(u8, descriptor[7..], "EL TORITO SPECIFICATION");
    var floppy_offset: u64 = 0;
    if (bootable) {
        const catalog_offset = @as(u64, dos.get32(&descriptor, 71)) * 2048;
        _ = try iso.readAt(catalog_offset, &descriptor);
        if (descriptor[0] != 1 or descriptor[1] != 0 or dos.get16(&descriptor, 30) != 0xaa55 or descriptor[32] != 0x88 or descriptor[33] != 2) return error.UnsupportedDosBootImage;
        floppy_offset = @as(u64, dos.get32(&descriptor, 40)) * 2048;
    }
    const ram = try memdisk.allocate(esp, reader, bulk, drive);
    const scratch: [*]u8 = @ptrFromInt(0x300000);
    const floppy_bytes = scratch[0..1474560];
    if (bootable) {
        _ = try iso.readAt(floppy_offset, floppy_bytes);
    } else {
        // Windows 95 CDs do not boot: a 1.44 MB startup disk image of 95 OSR2
        // or 98 in <system>\Boot\BOOTDISK.IMG (docs/win9x-modern-2026-09-30.md).
        const boot_path = [_][]const u16{ wide("Systems"), wide("Windows"), folder, wide("Boot"), wide("BOOTDISK.IMG") };
        var boot_file: ntfs.File = undefined;
        ntfs.openFile(fs, reader, &boot_path, &boot_file) catch return error.Win9xBootDiskMissing;
        if (boot_file.size() != floppy_bytes.len) return error.InvalidDosFloppy;
        try boot_file.readAt(fs, bulk, 0, floppy_bytes);
    }
    const floppy = try dos.Floppy.init(floppy_bytes);
    var builder = try dos.Builder.init(ram, floppy_bytes[0..512]);
    // Only the DOS kernel files are required. The Me floppy has no HIMEM.SYS
    // (its IO.SYS brings the XMS driver along); a Windows 95 startup disk has
    // SYS/ATTRIB loose instead of EBD.CAB (INSTALL.BAT handles both).
    var himem = true;
    for ([_][]const u8{ "IO.SYS", "MSDOS.SYS", "COMMAND.COM", "HIMEM.SYS", "FDISK.EXE", "EXTRACT.EXE", "EBD.CAB", "SYS.COM", "ATTRIB.EXE" }, 0..) |filename, index| {
        const entry = floppy.lookup(filename) catch |err| {
            if (err == error.MissingDosFile and index >= 3) {
                if (index == 3) himem = false;
                continue;
            }
            return err;
        };
        try floppy.read(entry, try builder.reserve(filename, dos.get32(entry, 28), false));
    }
    const ram_patch = &[_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("ram-patch") };
    try espFile(esp, reader, bulk, &builder, ram_patch, "PATCH9X.EXE", "PATCH9X.EXE");
    try espFile(esp, reader, bulk, &builder, ram_patch, "CWSDPMI.EXE", "CWSDPMI.EXE");
    try espFile(esp, reader, bulk, &builder, ram_patch, if (action == .repair) "REPAIR.BAT" else "INSTALL.BAT", "AUTOEXEC.BAT");
    // EFI\USOS\dos-native\win9x (tools/build_win9x_support.py): the
    // SYSTEM.INI helper and the VESA display driver (vmdisp9x, MIT).
    for (win9x_helpers) |filename| try espFile(esp, reader, bulk, &builder, &win9x_folder, filename, filename);
    // MSBATCH.INF: the answer file chosen from DATA Unattended (copied 1:1),
    // else the one the UEFI menu rendered from a profile, else the USOS default.
    const answer_kind = try answerFile(esp, reader, bulk, fs, release, folder, unattended_name, &builder);
    const csmwrap = action == .install and seabios.csmwrap;
    var env: [96]u8 = undefined;
    try builder.add("U9ENV.BAT", try std.fmt.bufPrint(&env, "SET U9SYS={s}\r\nSET U9SRC={s}\r\nSET U9ANS={s}\r\nSET U9CSM={s}\r\n", .{ release.tag, setup_folder, answer_kind, if (csmwrap) "1" else "0" }));
    const config_tail = "FILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\n";
    // Under CSMWrap HIMEM picks an A20 handler that leaves A20 off and DOS=HIGH
    // hangs; port 92h (/M:2) works (docs/design/bios-via-csmwrap.md 4.3).
    const himem_line = "DEVICE=A:\\HIMEM.SYS /TESTMEM:OFF\r\n";
    const himem_csmwrap = "DEVICE=A:\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n";
    // CREGFIX (mintsuki, 0BSD) first under CSMWrap: CR0/CR2/CR3/CR4/EFER as a
    // legacy BIOS leaves them, before Setup's mini-Windows.
    const cregfix = "DEVICE=A:\\CREGFIX.SYS\r\n";
    try builder.add("CONFIG.SYS", if (seabios.csmwrap)
        (if (himem) cregfix ++ himem_csmwrap ++ config_tail else cregfix ++ config_tail)
    else if (himem) himem_line ++ config_tail else config_tail);
    try builder.makeNamedSetupDirectory(setup_folder);
    var position: u64 = 0;
    var copied: usize = 0;
    var progress = wimboot.Progress{ .session = graphics, .total = dos.image_size };
    while (action == .install and position < setup.size) {
        const block_size: usize = @intCast(@min(2048, setup.size - position));
        _ = try iso.readAt(@as(u64, setup.extent_lba) * 2048 + position, descriptor[0..block_size]);
        var p: usize = 0;
        while (p < block_size and descriptor[p] != 0) {
            const length = descriptor[p];
            if (length > block_size - p) return error.InvalidDosSetupDirectory;
            const record = iso9660.recordInfo(descriptor[p..][0..length]) orelse return error.InvalidDosSetupDirectory;
            const raw = descriptor[p + record.name_offset ..][0..record.name_len];
            if (!record.is_directory) {
                if (descriptor[p + 25] & 0x80 != 0) return error.UnsupportedDosMultiExtent;
                const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
                const output = try builder.reserve(raw[0..end], @intCast(record.size), true);
                var done: usize = 0;
                while (done < output.len) {
                    const count = @min(1024 * 1024, output.len - done);
                    _ = try iso.readAt(@as(u64, record.extent_lba) * 2048 + done, output[done..][0..count]);
                    done += count;
                    copied += count;
                    wimboot.Progress.update(&progress, copied);
                }
            }
            // Subdirectories (TOUR, 98 FE CHANNELS: optional extras) are not copied.
            p += length;
        }
        position += block_size;
    }
    wimboot.Progress.update(&progress, dos.image_size);
    console.line("[WIN9X] ORIGINAL DOS AND SETUP FILES IN RAM; NO PREPARATION REBOOT");
    const selected = (try target_ui.choose(drive, session, action, release.name)) orelse return;
    if (selected.format_plan) |plan| {
        try target_ui.commit(plan);
        console.line("[WIN9X] USER CONFIRMED TARGET PARTITION COMMITTED");
        // No firmware CSM: the disk boots through its own CSMWrap ESP at the
        // tail (docs/design/bios-via-csmwrap.md section 4), like MS-DOS.
        if (csmwrap) {
            const image_path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("msdos"), wide(csmwrap_esp.image_name) };
            const info = try fat.fileInfo(esp, reader, &image_path);
            _ = try target_ui.addCsmwrapEsp(plan, EspImage{ .esp = esp, .bulk = bulk, .path = &image_path }, info.size);
            console.line("[WIN9X] CSMWRAP ESP OK");
        }
    } else console.line("[WIN9X] USER CONFIRMED RAM REPAIR; NO PARTITION WRITES");
    memdisk.start(selected.drive);
}

/// Adds MSBATCH.INF to the RAM disk root; returns the U9ANS value.
fn answerFile(esp: fat.FileSystem, reader: Reader, bulk: Reader, fs: ntfs.FileSystem, release: *const Release, folder: []const u16, unattended_name: ?[]const u8, builder: *dos.Builder) ![]const u8 {
    if (unattended_name) |answer| {
        var name: [255]u16 = undefined;
        for (answer, 0..) |ch, i| name[i] = ch;
        const path = [_][]const u16{ wide("Systems"), wide("Windows"), folder, wide("Unattended"), name[0..answer.len] };
        var file: ntfs.File = undefined;
        try ntfs.openFile(fs, reader, &path, &file);
        if (file.size() == 0 or file.size() > max_answer_bytes) return error.InvalidWin9xAnswerFile;
        const output = try builder.reserve("MSBATCH.INF", @intCast(file.size()), false);
        try file.readAt(fs, bulk, 0, output);
        return "USER";
    }
    // \EFI\USOS\answer\<tag>.INF: rendered from a profile by the UEFI menu
    // before it started the BIOS mode (answer_profiles.stageWin9x).
    var staged_name: [12]u8 = undefined;
    const staged = try std.fmt.bufPrint(&staged_name, "{s}.INF", .{release.tag});
    var staged_wide: [12]u16 = undefined;
    for (staged, 0..) |ch, i| staged_wide[i] = ch;
    const answer_folder = [_][]const u16{ wide("EFI"), wide("USOS"), wide("answer") };
    const rendered = answer_folder ++ [_][]const u16{staged_wide[0..staged.len]};
    const from_profile = if (fat.fileInfo(esp, reader, &rendered)) |_| true else |_| false;
    if (from_profile) try espFile(esp, reader, bulk, builder, &answer_folder, staged, "MSBATCH.INF") else try espFile(esp, reader, bulk, builder, &win9x_folder, "MSBATCH.INF", "MSBATCH.INF");
    return if (from_profile) "PROFILE" else "USOS";
}

/// <folder>\<name> on the ESP to the RAM disk root as `ram_name`.
noinline fn espFile(esp: fat.FileSystem, reader: Reader, bulk: Reader, builder: *dos.Builder, folder: []const []const u16, name: []const u8, ram_name: []const u8) !void {
    var wide_name: [12]u16 = undefined;
    for (name, 0..) |ch, i| wide_name[i] = ch;
    var path: [5][]const u16 = undefined;
    @memcpy(path[0..folder.len], folder);
    path[folder.len] = wide_name[0..name.len];
    const full = path[0 .. folder.len + 1];
    const info = try fat.fileInfo(esp, reader, full);
    if (info.size == 0 or info.size > 1024 * 1024) return error.InvalidDosPatchHelper;
    const output = try builder.reserve(ram_name, info.size, false);
    if (try fat.readFileRange(esp, bulk, full, 0, output) != output.len) return error.ShortDosPatchHelper;
}
