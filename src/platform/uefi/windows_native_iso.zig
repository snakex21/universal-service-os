const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const udf = usos.image_probe.udf;
const ntfs = usos.storage.ntfs;
const data_volume = @import("data_volume.zig");
const files = @import("wimboot_files.zig");
const source_config = usos.windows_iso_config;
const esp_image = @import("esp_image_start.zig");
const serial = @import("serial.zig");
const scanner = usos.windows7_iso;
const directory_source = @import("catalog_ntfs_directory_source.zig");
const driver_files = @import("windows_driver_files.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const BootState = struct {
    catalog: data_volume.Catalog,
    source: ntfs.File,
    donor: ntfs.File,
    answer: ntfs.File,
    volume: files.Volume,
};
noinline fn initBootState(state: *BootState) !void {
    // Store the catalog before creating any reader: reader.context points into
    // catalog.block. Keep state stationary through donor probing and StartImage.
    state.catalog = try data_volume.openCatalog();
    state.volume = .{};
}
const Iso = struct {
    catalog: *data_volume.Catalog,
    file: *ntfs.File,
    pub fn size(self: *const Iso) u64 { return self.file.size(); }
    pub fn readAt(self: *const Iso, offset: u64, output: []u8) !usize {
        try self.file.readAt(self.catalog.fs, self.catalog.reader(), offset, output);
        return output.len;
    }
};
fn widen(name: []const u8, buffer: []u16) []const u16 {
    for (name, 0..) |ch, i| buffer[i] = ch;
    return buffer[0..name.len];
}
fn openIso(catalog: *data_volume.Catalog, folder: []const u16, name: []const u8, file: *ntfs.File) !void {
    try source_config.validateName(name);
    var name_buffer: [255]u16 = undefined;
    const path = [_][]const u16{ wide("Systems"), wide("Windows"), folder, wide("Images"), widen(name, &name_buffer) };
    try ntfs.openFile(catalog.fs, catalog.reader(), &path, file);
}
const DonorContext = struct {
    state: *BootState,
    pub fn probeDonor(self: *DonorContext, name: []const u8) !usos.wim_setup.Setup {
        try openIso(&self.state.catalog, wide("Windows 10"), name, &self.state.donor);
        var iso = Iso{ .catalog = &self.state.catalog, .file = &self.state.donor };
        return scanner.inspectDonor(uefi.pool_allocator, &iso);
    }
};
fn inspectState(state: *BootState, name: []const u8, vista: bool) !scanner.Inspection {
    try openIso(&state.catalog, if (vista) wide("Windows Vista") else wide("Windows 7"), name, &state.source);
    var iso = Iso{ .catalog = &state.catalog, .file = &state.source };
    const selected = if (vista) try scanner.inspectVista(uefi.pool_allocator, &iso) else try scanner.inspectSelected(uefi.pool_allocator, &iso);
    var adapter = directory_source.Adapter.init(state.catalog.fs, state.catalog.reader());
    var context = DonorContext{ .state = state };
    return scanner.resolveDonor(selected, adapter.source(), &context);
}
pub noinline fn inspect(name: []const u8, vista: bool) !scanner.Inspection {
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    // BootState inherits the BlockIo bounce buffer's 4096-byte alignment;
    // raw AllocatePool guarantees only 8 bytes. The typed allocator aligns it.
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    return inspectState(state, name, vista);
}
pub fn externalDriverCount() !usize {
    var catalog = try data_volume.openCatalog();
    return driver_files.infCount(&catalog);
}
const IsoStage = @import("usos").flow.preparation_boot_progress.DirectIsoStage;
pub noinline fn start(root: *uefi.protocol.File, name: []const u8, answer_name: ?[]const u8, vista: bool, progress: *const fn (IsoStage, []const u8) void) !void {
    if (@import("builtin").cpu.arch != .x86_64) return error.WindowsSetupRequiresX64;
    try source_config.validateName(name);
    if (answer_name) |answer| try source_config.validateName(answer);
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const state = try uefi.pool_allocator.create(BootState);
    defer uefi.pool_allocator.destroy(state);
    try initBootState(state);
    const catalog = &state.catalog;
    if (vista and answer_name != null) return error.VistaUnattendedNotSupported;
    progress(.validating, "Validating installation ISO and resolving boot source");
    const inspection = try inspectState(state, name, vista);
    const source = &state.source;
    const external_pe10 = inspection.mode == .original;
    if (external_pe10) {
        // Reopen the chosen donor: enumeration may have probed other candidates.
        var context = DonorContext{ .state = state };
        const current = try context.probeDonor(inspection.donor_name.slice());
        if (!std.meta.eql(current, inspection.boot_setup)) return error.Windows10PeDonorChanged;
    }
    var boot_iso = Iso{ .catalog = catalog, .file = if (external_pe10) &state.donor else source };
    const setup = inspection.boot_setup;
    var node: udf.Node = undefined;
    var boot_message: [384]u8 = undefined;
    serial.writeAscii(try std.fmt.bufPrint(&boot_message, "[WIN7_NATIVE] {s}; boot ISO={s}; PE={d}.{d}.{d} x64 index={d}\r\n", .{
        if (vista) "Vista SP2 x64 -> external PE10" else inspection.mode.label(), inspection.bootName(name), setup.major, setup.minor, setup.build, setup.index,
    }));
    progress(.validating, inspection.bootName(name));
    const volume = &state.volume;
    var owned: [10][]align(8) u8 = undefined;
    var count: usize = 0;
    defer for (owned[0..count]) |allocation| bs.freePool(allocation.ptr) catch {};
    const support_file = try root.open(wide("\\EFI\\USOS\\windows-native\\support.cpio"), .read, .{});
    defer support_file.close() catch {};
    const support = try bs.allocatePool(.loader_data, 8 * 1024 * 1024);
    owned[count] = support; count += 1;
    const support_len = try support_file.read(support);
    if (support_len == support.len) return error.SupportArchiveTooLarge;
    try volume.addCpio(support[0..support_len]);
    {
        const stock_file = try root.open(if (vista) wide("\\EFI\\USOS\\windows-native\\vista-support.cpio") else wide("\\EFI\\USOS\\windows-native\\win7-support.cpio"), .read, .{});
        defer stock_file.close() catch {};
        const stock = try bs.allocatePool(.loader_data, 64 * 1024 * 1024);
        owned[count] = stock; count += 1;
        const stock_len = try stock_file.read(stock);
        if (stock_len == stock.len) return error.SupportArchiveTooLarge;
        try volume.addCpio(stock[0..stock_len]);
    }
    try volume.add(if (vista) "usos-modern-vista.flag" else "usos-modern-win7.flag", "1\r\n");
    if (external_pe10) try volume.add("usos-external-pe10.flag", "1\r\n");
    if (inspection.nvme_packages) try volume.add("usos-nvme-packages.flag", "1\r\n");
    if (!vista) {
        progress(.loading, "Reading optional Windows 7 x64 driver packages");
        const drivers = try driver_files.load(catalog);
        owned[count] = drivers.bytes; count += 1;
        try volume.add("usos-drivers.bin", drivers.bytes);
        var driver_message: [128]u8 = undefined;
        serial.writeAscii(try std.fmt.bufPrint(&driver_message, "[WIN7_NATIVE] external driver INF files={d}; Windows validates hardware match\r\n", .{drivers.inf_count}));
    }
    const paths = scanner.boot_paths;
    const names = [_][]const u8{ "BCD", "boot.sdi", "boot.wim" };
    for (paths, names) |boot_path, boot_name| {
        if (!try udf.openPath(&boot_iso, boot_path, &node) or node.is_directory or node.size == 0 or node.size > scanner.max_boot_file_size) return error.InvalidWindowsBootFile;
        const bytes = try bs.allocatePool(.loader_data, @intCast(node.size));
        owned[count] = bytes; count += 1;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = @min(bytes.len - offset, 1024 * 1024);
            try udf.readNodeAt(&boot_iso, &node, offset, bytes[offset..][0..amount]);
            offset += amount;
            if (std.mem.eql(u8, boot_name, "boot.wim") and (offset % (8 * 1024 * 1024) == 0 or offset == bytes.len)) {
                var message: [100]u8 = undefined;
                progress(.loading, try std.fmt.bufPrint(&message, "Loading boot-source boot.wim: {d}%", .{offset * 100 / bytes.len}));
            }
        }
        try volume.add(boot_name, bytes);
    }
    var config: [544]u8 = undefined;
    try volume.add("usos-source.ini", try source_config.sourceConfigForFolder(&config, catalog.partition.part_guid, source.size(), if (vista) "Windows Vista" else "Windows 7", name));
    if (answer_name) |answer| {
        var answer_wide: [255]u16 = undefined;
        const answer_path = [_][]const u16{ wide("Systems"), wide("Windows"), wide("Windows 7"), wide("Unattended"), widen(answer, &answer_wide) };
        const answer_file = &state.answer;
        try ntfs.openFile(catalog.fs, catalog.reader(), &answer_path, answer_file);
        if (answer_file.size() == 0 or answer_file.size() > 1024 * 1024) return error.InvalidAnswerFileSize;
        const bytes = try bs.allocatePool(.loader_data, @intCast(answer_file.size()));
        owned[count] = bytes; count += 1;
        try answer_file.readAt(catalog.fs, catalog.reader(), 0, bytes);
        try volume.add("usos-unattend.xml", bytes);
    }
    const image = try esp_image.load(root, "\\EFI\\USOS\\windows-native\\wimboot");
    defer _ = bs._unloadImage(image);
    const handle = try files.install(volume);
    defer files.uninstall(handle, volume);
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, image)) orelse return error.NoLoadedImage;
    loaded.device_handle = handle;
    var option_text: [32]u8 = undefined;
    const option_ascii = try @import("diagnostic_boot.zig").wimbootOptions(&option_text, setup.index, @import("diagnostic_boot.zig").requested(root));
    var options: [32:0]u16 = undefined;
    for (option_ascii, 0..) |ch, i| options[i] = ch;
    options[option_ascii.len] = 0;
    loaded.load_options = &options;
    loaded.load_options_size = @intCast((option_ascii.len + 1) * 2);
    progress(.starting, if (external_pe10) "Starting external PE10; install source remains selected Windows ISO" else "Starting hybrid ISO's own WinPE and Setup");
    serial.writeAscii("[WIN7_NATIVE] CORE -> WIMBOOT UEFI\r\n");
    const result = try bs.startImage(image);
    if (result.code != .success) return error.WimbootReturnedError;
    return error.WimbootReturned;
}
