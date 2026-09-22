const std = @import("std");
const usos = @import("usos");
const random_reader = usos.storage.random_reader;
const gpt = usos.storage.gpt;
const fat32 = usos.storage.fat32;

const HostFileReader = usos.image_probe.random_access.FileReader;

fn fileRead(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
    const ctx: *HostFileReader = @ptrCast(@alignCast(context));
    const count = ctx.readAt(offset, output) catch return error.Io;
    if (count != output.len) return error.Io;
}

const efi = [_]u16{ 'E', 'F', 'I' };
const usos_dir = [_]u16{ 'U', 'S', 'O', 'S' };
const menu = [_]u16{ 'u', 's', 'o', 's', '-', 'm', 'e', 'n', 'u', '.', 'i', 'n', 'i' };
const path = [_][]const u16{ &efi, &usos_dir, &menu };

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const image_path = args.next() orelse return error.MissingImagePath;
    const expected_error = args.next();

    var context = try HostFileReader.open(init.io, std.Io.Dir.cwd(), image_path);
    defer context.close();
    const reader = random_reader.Reader{ .context = &context, .read_fn = fileRead };

    probe(reader) catch |err| {
        if (expected_error) |name| {
            if (std.mem.eql(u8, @errorName(err), name)) {
                std.debug.print("EXPECTED_FAIL={s}\n", .{@errorName(err)});
                return 0;
            }
        }
        return err;
    };
    if (expected_error != null) return error.ExpectedFailureDidNotOccur;
    return 0;
}

fn probe(reader: random_reader.Reader) !void {
    const esp = try gpt.findUsosEsp(reader);
    const start = std.math.mul(u64, esp.start_lba, 512) catch return error.PartitionBounds;
    const sectors = esp.sectorCount();
    const size = std.math.mul(u64, sectors, 512) catch return error.PartitionBounds;
    const fs = try fat32.mount(reader, .{ .start_bytes = start, .size_bytes = size });

    var gpt_name: [36]u8 = undefined;
    const gpt_name_len = esp.copyNameAscii(&gpt_name);
    var volume_label: [11]u8 = undefined;
    const volume_label_len = fs.copyVolumeLabel(&volume_label);
    var root_items: [16]fat32.DirectoryItem = undefined;
    const root_count = try fat32.listDirectory(fs, reader, &.{}, &root_items);
    if (!containsAsciiName(root_items[0..root_count], "EFI", true)) return error.RootEfiDirectoryMissing;
    const efi_path = [_][]const u16{&efi};
    var efi_items: [16]fat32.DirectoryItem = undefined;
    const efi_count = try fat32.listDirectory(fs, reader, &efi_path, &efi_items);
    if (!containsAsciiName(efi_items[0..efi_count], "USOS", true)) return error.EfiUsosDirectoryMissing;

    var contents: [131072]u8 = undefined;
    const read = try fat32.readFile(fs, reader, &path, &contents);
    if (std.mem.indexOf(u8, contents[0..read], "USOS FAT32 FIXTURE") == null) return error.MenuMarkerMissing;

    std.debug.print("GPT_NAME={s}\n", .{gpt_name[0..gpt_name_len]});
    std.debug.print("FAT32_LABEL={s}\n", .{volume_label[0..volume_label_len]});
    std.debug.print("ROOT_DIRECTORY_OK entries={d}\n", .{root_count});
    std.debug.print("EFI_DIRECTORY_OK entries={d}\n", .{efi_count});
    std.debug.print("USOS_MENU_INI_READ_OK bytes={d}\n", .{read});
}

fn containsAsciiName(items: []const fat32.DirectoryItem, wanted: []const u8, directory: bool) bool {
    for (items) |item| {
        if (item.isDirectory() != directory) continue;
        var name: [260]u8 = undefined;
        const len = item.copyNameAscii(&name);
        if (std.ascii.eqlIgnoreCase(name[0..len], wanted)) return true;
    }
    return false;
}
