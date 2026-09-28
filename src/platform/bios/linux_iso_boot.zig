//! Linux ISO from DATA in Legacy BIOS (docs/design/linux-iso-boot.md section 6):
//! the same recipe as the UEFI menu (src/flow/linux_iso), the kernel entered
//! through the 32-bit boot protocol, initrd = distro initrds + the ESP's
//! \EFI\USOS\linux\usos-linux.cpio + a generated cpio with /usos/iso.map.
//! No BSS in the Core: scratch memory is taken at fixed physical addresses
//! that are only reused after planning (the kernel load area).
const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const linux_iso = catalog.linux_iso;
const iso9660 = catalog.iso9660;
const header_module = @import("linux_boot_header.zig");
const params = @import("linux_boot_params.zig");
const memory = @import("linux_memory.zig");
const e820 = @import("e820.zig");
const vbe = @import("vbe_probe.zig");
const menu = @import("graphics_menu.zig");
const console = @import("console.zig");
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;
extern fn core_linux_jump(entry: u32, boot_params: u32) callconv(.c) noreturn;

/// grub.cfg scratch (64 KiB) at the kernel load address: free until the kernel
/// is copied there, after planning.
const grub_scratch_phys: usize = memory.kernel_load_start;
const grub_scratch_bytes: usize = 64 * 1024;
const helper_max_bytes: usize = 1024 * 1024;
const per_boot_max_bytes: usize = 16 * 1024;

const Iso = struct {
    fs: ntfs.FileSystem,
    disk: Reader,
    file: ntfs.File,
    label_buf: [32]u8 = undefined,
    label_len: usize = 0,

    pub fn size(self: *const Iso) u64 {
        return self.file.size();
    }
    pub fn readAt(self: *const Iso, offset: u64, output: []u8) !usize {
        try self.file.readAt(self.fs, self.disk, offset, output);
        return output.len;
    }
    pub fn volumeLabel(self: *const Iso) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    pub fn exists(self: *const Iso, path: []const u8) bool {
        return (iso9660.findRecord(self, path) catch null) != null;
    }
    pub fn read(self: *const Iso, path: []const u8, buffer: []u8) ?[]const u8 {
        const record = (iso9660.findRecord(self, path) catch return null) orelse return null;
        if (record.is_directory or record.size > buffer.len) return null;
        const n: usize = @intCast(record.size);
        _ = self.readAt(@as(u64, record.extent_lba) * 2048, buffer[0..n]) catch return null;
        return buffer[0..n];
    }
};

pub fn run(esp_fs: storage.fat32.FileSystem, reader: Reader, bulk: Reader, image_directory: []const u8, image_name: []const u8, graphics: ?vbe.Session) !void {
    try @import("windows_iso_config.zig").validateName(image_name);
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var names: [12][]const u16 = undefined;
    var wide: [512]u16 = undefined;
    const path = try components(image_directory, image_name, &names, &wide);
    var iso = Iso{ .fs = fs, .disk = bulk, .file = undefined };
    try ntfs.openFile(fs, reader, path, &iso.file);

    // Where the ISO lies on the disk, and the PVD checksum /usos/init looks for.
    var map = linux_iso.iso_map.Map{ .size = iso.file.size() };
    try isoMap(&iso.file, fs.cluster_bytes, data.start_lba, &map);
    var pvd: [linux_iso.iso_map.pvd_bytes]u8 = undefined;
    _ = try iso.readAt(linux_iso.iso_map.pvd_offset, &pvd);
    if (!std.mem.eql(u8, pvd[1..6], "CD001")) return error.NotIso9660;
    map.crc = storage.gpt.crc32(&pvd);
    const label = std.mem.trimEnd(u8, pvd[40..72], " \x00");
    iso.label_len = @min(label.len, iso.label_buf.len);
    @memcpy(iso.label_buf[0..iso.label_len], label[0..iso.label_len]);

    var recipe: linux_iso.recipe.Recipe = undefined;
    const scratch: [*]u8 = @ptrFromInt(grub_scratch_phys);
    try linux_iso.recipe.plan(&iso, &recipe, scratch[0..grub_scratch_bytes]);
    console.line("[LINUX-ISO] recipe ready");

    // Kernel header.
    const kernel = (try iso9660.findRecord(&iso, recipe.kernel())) orelse return error.FileNotFound;
    var setup: [header_module.minimum_header_bytes]u8 = undefined;
    _ = try iso.readAt(@as(u64, kernel.extent_lba) * 2048, &setup);
    const header = try header_module.parse(&setup);
    if (header.protocol < 0x020a or !header.isLoadedHigh() or header.init_size == 0 or header.initrd_addr_max == 0)
        return error.UnsupportedLinuxKernel;

    // Initrd size: distro initrds (4-byte padded) + helper + generated cpio.
    var records: [linux_iso.grub_cfg.max_initrds]iso9660.Record = undefined;
    var total: u64 = 0;
    for (0..recipe.initrdCount()) |i| {
        records[i] = (try iso9660.findRecord(&iso, recipe.initrd(i))) orelse return error.FileNotFound;
        total += records[i].size + linux_iso.cpio.padding(records[i].size);
    }
    const helper_components = [_][]const u16{ w("EFI"), w("USOS"), w("linux"), w("usos-linux.cpio") };
    const helper_info = storage.fat32.fileInfo(esp_fs, reader, &helper_components) catch return error.LinuxHelperMissing;
    if (helper_info.size == 0 or helper_info.size > helper_max_bytes) return error.LinuxHelperMissing;
    total += helper_info.size + per_boot_max_bytes;

    var entries: [e820.max_entries]e820.Entry = undefined;
    const e820_map = entries[0..try e820.probe(&entries)];
    const layout = try memory.plan(e820_map, header, kernel.size, total);
    if (!memory.rangeIsUsable(e820_map, .{ .start = params.boot_params_phys, .end = params.cmdline_phys + params.cmdline_capacity }))
        return error.LiveBootParametersMemoryUnavailable;
    if (graphics) |session| menu.environmentStart(&session, "STARTING LINUX");

    // Initrd first (the grub.cfg scratch sits where the kernel goes).
    var cursor: usize = @intCast(layout.initramfs.start);
    for (records[0..recipe.initrdCount()], 0..) |record, index| {
        const output: [*]u8 = @ptrFromInt(cursor);
        const n: usize = @intCast(record.size);
        _ = try iso.readAt(@as(u64, record.extent_lba) * 2048, output[0..n]);
        cursor += n;
        const pad: usize = @intCast(linux_iso.cpio.padding(n));
        @memset(output[n..][0..pad], 0);
        cursor += pad;
        if (graphics) |session| menu.preparationProgress(&session, @intCast(10 + index * 60 / recipe.initrdCount()));
    }
    const helper_out: [*]u8 = @ptrFromInt(cursor);
    const helper_len = try storage.fat32.readFile(esp_fs, reader, &helper_components, helper_out[0..@intCast(helper_info.size)]);
    cursor += helper_len;
    const per_boot_out: [*]u8 = @ptrFromInt(cursor);
    var map_text: [2048]u8 = undefined;
    var writer = linux_iso.cpio.Writer{ .out = per_boot_out[0..per_boot_max_bytes] };
    try writer.directory("usos");
    try writer.file("usos/iso.map", 0o644, try map.write(&map_text));
    // Debian installer: the ISO appears as a USB partition (BLKPG fallback).
    if (recipe.family == .debian_installer) try writer.file("preseed.cfg", 0o644, "d-i cdrom-detect/try-usb boolean true\n");
    cursor += (try writer.finish()).len;
    const initrd_size: u64 = cursor - @as(usize, @intCast(layout.initramfs.start));

    // Kernel (protected-mode part) at 1 MiB.
    const dest: [*]u8 = @ptrFromInt(memory.kernel_load_start);
    _ = try iso.readAt(@as(u64, kernel.extent_lba) * 2048 + header.protected_file_offset, dest[0..@intCast(layout.kernel_protected.size())]);
    if (graphics) |session| menu.preparationProgress(&session, 90);

    const boot_params: *[params.boot_params_bytes]u8 = @ptrFromInt(params.boot_params_phys);
    const cmdline: *[params.cmdline_capacity]u8 = @ptrFromInt(params.cmdline_phys);
    try params.buildLive(boot_params, cmdline, &setup, layout.initramfs.start, initrd_size, e820_map, graphics, recipe.cmdline());
    console.line("[LINUX-ISO] kernel and initrd loaded; starting");
    core_linux_jump(@intCast(memory.kernel_load_start), params.boot_params_phys);
}

fn w(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

/// "\Systems\Linux\Ubuntu\Images" + name -> NTFS path components.
fn components(directory: []const u8, name: []const u8, out: *[12][]const u16, wide: *[512]u16) ![]const []const u16 {
    var count: usize = 0;
    var at: usize = 0;
    var parts = std.mem.tokenizeScalar(u8, directory, '\\');
    while (true) {
        const part = parts.next() orelse name;
        if (count == out.len or at + part.len > wide.len) return error.InvalidImageName;
        for (part, 0..) |c, i| wide[at + i] = c;
        out[count] = wide[at .. at + part.len];
        at += part.len;
        count += 1;
        if (part.ptr == name.ptr) break;
    }
    return out[0..count];
}

fn isoMap(file: *const ntfs.File, cluster_bytes: u32, partition_lba: u64, map: *linux_iso.iso_map.Map) !void {
    if (file.resident_len != null) return error.IsoResidentOrSparse;
    const size = file.size();
    var covered: u64 = 0;
    for (file.stream.runs[0..file.stream.len]) |extent| {
        if (extent.sparse or extent.lcn < 0) return error.IsoResidentOrSparse;
        if (covered >= size) break;
        var bytes = extent.clusters * cluster_bytes;
        if (covered + bytes > size) bytes = size - covered;
        const lba = partition_lba + @as(u64, @intCast(extent.lcn)) * (cluster_bytes / 512);
        map.append(lba, (bytes + 511) / 512) catch return error.IsoNotContiguousEnough;
        covered += bytes;
    }
    if (covered < size) return error.IsoResidentOrSparse;
}
