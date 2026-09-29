//! SliTaz Live: read the kernel and all four initramfs layers from the selected ISO.
const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const source_module = @import("dos_iso_source.zig");
const header_module = @import("linux_boot_header.zig");
const params = @import("linux_boot_params.zig");
const memory = @import("linux_memory.zig");
const e820 = @import("e820.zig");
const vbe = @import("vbe_probe.zig");
const menu = @import("graphics_menu.zig");
const Reader = storage.random_reader.Reader;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
extern fn core_linux_jump(entry: u32, boot_params: u32) callconv(.c) noreturn;

/// noinline: its locals must not add to legacy_boot_actions.execute's frame (the PM32
/// stack below 0x9E000 ends at the Core .data; docs/design/bios-via-csmwrap.md).
pub noinline fn run(reader: Reader, bulk: Reader, image_name: []const u8, graphics: ?vbe.Session) !void {
    try @import("windows_iso_config.zig").validateName(image_name);
    var name: [255]u16 = undefined;
    for (image_name, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("Systems"), wide("Linux"), wide("Other Linux"), wide("Images"), name[0..image_name.len] };
    const data = try storage.gpt.findUsosData(reader);
    const fs = try storage.ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var source = try source_module.Source.open(fs, reader, bulk, &path);
    const kernel = try require(&source, "BOOT/BZIMAGE");
    var layers: [4]catalog.iso9660.Record = undefined;
    var total: u64 = 0;
    for ([_][]const u8{ "BOOT/ROOTFS4.GZ", "BOOT/ROOTFS3.GZ", "BOOT/ROOTFS2.GZ", "BOOT/ROOTFS1.GZ" }, 0..) |p, i| {
        layers[i] = try require(&source, p);
        total += layers[i].size;
    }
    var setup: [header_module.minimum_header_bytes]u8 = undefined;
    _ = try source.readAt(@as(u64, kernel.extent_lba) * 2048, &setup);
    const header = try header_module.parse(&setup);
    if (header.protocol < 0x020a or !header.isLoadedHigh() or header.isX86_64() or header.init_size == 0 or
        header.cmdline_size < command.len or header.initrd_addr_max == 0)
        return error.UnsupportedLiveKernel;
    var entries: [e820.max_entries]e820.Entry = undefined;
    const map = entries[0..try e820.probe(&entries)];
    const layout = try memory.plan(map, header, kernel.size, total);
    if (!memory.rangeIsUsable(map, .{ .start = params.boot_params_phys, .end = params.cmdline_phys + params.cmdline_capacity }))
        return error.LiveBootParametersMemoryUnavailable;
    if (graphics) |session| menu.environmentStart(&session, "STARTING LINUX LIVE");
    const dest: [*]u8 = @ptrFromInt(memory.kernel_load_start);
    _ = try source.readAt(@as(u64, kernel.extent_lba) * 2048 + header.protected_file_offset, dest[0..@intCast(layout.kernel_protected.size())]);
    if (graphics) |session| menu.preparationProgress(&session, 20);
    var cursor: usize = @intCast(layout.initramfs.start);
    for (layers, 0..) |layer, index| {
        const output: [*]u8 = @ptrFromInt(cursor);
        _ = try source.readAt(@as(u64, layer.extent_lba) * 2048, output[0..@intCast(layer.size)]);
        cursor += @intCast(layer.size);
        if (graphics) |session| menu.preparationProgress(&session, @intCast((index + 2) * 20));
    }
    const boot_params: *[params.boot_params_bytes]u8 = @ptrFromInt(params.boot_params_phys);
    const cmdline: *[params.cmdline_capacity]u8 = @ptrFromInt(params.cmdline_phys);
    try params.buildLive(boot_params, cmdline, &setup, layout.initramfs.start, total, map, graphics, command);
    @import("console.zig").line("[LINUX LIVE] SliTaz kernel and four RAM layers loaded; starting");
    core_linux_jump(@intCast(memory.kernel_load_start), params.boot_params_phys);
}

const command = "root=/dev/null rw lang=en_US kmap=us autologin noswap";

fn require(source: *source_module.Source, path: []const u8) !catalog.iso9660.Record {
    const record = (try catalog.iso9660.findRecord(source, path)) orelse return error.SliTazCookingIsoRequired;
    const offset = @as(u64, record.extent_lba) * 2048;
    if (record.is_directory or record.size == 0 or offset > source.size() or record.size > source.size() - offset)
        return error.InvalidLiveIsoExtent;
    return record;
}
