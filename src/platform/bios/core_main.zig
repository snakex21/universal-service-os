const storage = @import("storage");
const catalog = @import("catalog");
const catalog_mode = @import("catalog_mode");
const test_mode = @import("test_mode");
const catalog_directory_source = @import("catalog_directory_source.zig");
const catalog_ntfs_directory_source = @import("catalog_ntfs_directory_source.zig");
const console = @import("console.zig");
const diagnostics = @import("diagnostics.zig");
const hardware_state = @import("hardware_state.zig");
const linux_load_probe = @import("linux_load_probe.zig");
const legacy_boot_actions = @import("legacy_boot_actions.zig");
const ntfs_diagnostics = @import("ntfs_diagnostics.zig");
const text_menu = @import("text_menu.zig");
const vbe_probe = @import("vbe_probe.zig");
const xp_target_chainload = @import("xp_target_chainload.zig");

const random_reader = storage.random_reader;
const gpt = storage.gpt;
const fat32 = storage.fat32;
const ntfs = storage.ntfs;

const context_magic: u32 = 0x43425355;
const context_version: u16 = 1;
const context_bytes: u16 = 24;

const systems_component = [_]u16{ 'S', 'y', 's', 't', 'e', 'm', 's' };
const windows_component = [_]u16{ 'W', 'i', 'n', 'd', 'o', 'w', 's' };
const windows_path = [_][]const u16{ &systems_component, &windows_component };

const BootContext = extern struct {
    magic: u32,
    version: u16,
    size: u16,
    bios_drive: u8,
    reserved: [3]u8,
    sector_bytes: u32,
    core_slot_lba: u64,
};

extern fn bios_read_sector(lba: u64, destination: [*]u8) callconv(.c) u32;
extern fn bios_read_sectors(lba: u64, count: u32, destination: [*]u8) callconv(.c) u32;

const BiosReaderContext = struct {
    sector_reads: u32 = 0,
};

fn biosRead(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
    const self: *BiosReaderContext = @ptrCast(@alignCast(context));
    var sector: [512]u8 = undefined;
    var cursor = offset;
    var written: usize = 0;
    while (written < output.len) {
        const lba = cursor / 512;
        const within: usize = @intCast(cursor % 512);
        self.sector_reads +|= 1;
        if (bios_read_sector(lba, &sector) != 0) return error.Io;
        const available = 512 - within;
        const remaining = output.len - written;
        const amount = if (available < remaining) available else remaining;
        var i: usize = 0;
        while (i < amount) : (i += 1) output[written + i] = sector[within + i];
        cursor += amount;
        written += amount;
    }
}

fn biosReadBulk(context: *anyopaque, offset: u64, output: []u8) random_reader.Error!void {
    const self: *BiosReaderContext = @ptrCast(@alignCast(context));
    var sector: [512]u8 = undefined;
    var cursor = offset;
    var written: usize = 0;
    while (written < output.len) {
        const within: usize = @intCast(cursor % 512);
        const remaining = output.len - written;
        if (within == 0 and remaining >= 512) {
            const count: u32 = @intCast(@min(@as(usize, 127), remaining / 512));
            if (bios_read_sectors(cursor / 512, count, output[written..].ptr) != 0) return error.Io;
            self.sector_reads +|= count;
            const amount = @as(usize, count) * 512;
            cursor += amount;
            written += amount;
            continue;
        }

        self.sector_reads +|= 1;
        if (bios_read_sector(cursor / 512, &sector) != 0) return error.Io;
        const available = 512 - within;
        const amount = @min(available, remaining);
        var i: usize = 0;
        while (i < amount) : (i += 1) output[written + i] = sector[within + i];
        cursor += amount;
        written += amount;
    }
}

export fn core_main(context: *const BootContext) callconv(.c) void {
    console.screen_output = false;
    console.line("USOS LEGACY CORE PM32");
    if (!validContext(context)) {
        console.screen_output = true;
        console.line("BOOT CONTEXT FAIL");
        return;
    }
    console.print("BOOT CONTEXT OK drive=0x");
    console.printHex8(context.bios_drive);
    console.line("");

    runFrontend(context);
    console.screen_output = true;
    console.line("USOS startup stopped. Check the diagnostic output.");
}

fn runFrontend(context: *const BootContext) void {
    var bios_context = BiosReaderContext{};
    const reader = random_reader.Reader{ .context = &bios_context, .read_fn = biosRead };
    const bulk_reader = random_reader.Reader{ .context = &bios_context, .read_fn = biosReadBulk };

    const esp = gpt.findUsosEsp(reader) catch |err| {
        printError("GPT/ESP FAIL", err);
        return;
    };
    var gpt_name: [36]u8 = undefined;
    const gpt_name_len = esp.copyNameAscii(&gpt_name);
    console.line("GPT OK");
    console.print("GPT NAME: ");
    console.print(gpt_name[0..gpt_name_len]);
    console.line("");

    const start_bytes = checkedMul(esp.start_lba, 512) orelse {
        console.screen_output = true;
        console.line("ESP BOUNDS FAIL");
        return;
    };
    const size_bytes = checkedMul(esp.sectorCount(), 512) orelse {
        console.screen_output = true;
        console.line("ESP BOUNDS FAIL");
        return;
    };
    const fs = fat32.mount(reader, .{ .start_bytes = start_bytes, .size_bytes = size_bytes }) catch |err| {
        printError("FAT32 FAIL", err);
        return;
    };
    var label: [11]u8 = undefined;
    const label_len = fs.copyVolumeLabel(&label);
    console.line("FAT32 OK");
    console.print("FAT32 BPB LABEL: ");
    console.print(label[0..label_len]);
    console.line("");

    var esp_directory_adapter = catalog_directory_source.Adapter.init(fs, reader);
    var ntfs_diag = ntfs_diagnostics.State{};
    var data_directory_adapter: catalog_ntfs_directory_source.Adapter = undefined;
    var data_source: ?catalog.directory_source.Source = null;
    var windows_index_offset: u64 = 0;
    const discovery_source = if (catalog_mode.force_esp_catalog) esp_directory_adapter.source() else blk: {
        const data_partition = gpt.findUsosData(reader) catch |err| {
            ntfs_diag.recordError("GPT:USOS_DATA", err);
            printError("DATA GPT FAIL - USING ESP FALLBACK", err);
            break :blk esp_directory_adapter.source();
        };
        ntfs_diag.data_gpt_found = true;
        ntfs_diag.data_start_lba = data_partition.start_lba;
        ntfs_diag.data_sector_count = data_partition.sectorCount();

        const data_start_bytes = checkedMul(data_partition.start_lba, 512) orelse {
            ntfs_diag.recordError("GPT:USOS_DATA", error.PartitionBounds);
            console.line("DATA BOUNDS FAIL - USING ESP FALLBACK");
            break :blk esp_directory_adapter.source();
        };
        const data_size_bytes = checkedMul(data_partition.sectorCount(), 512) orelse {
            ntfs_diag.recordError("GPT:USOS_DATA", error.PartitionBounds);
            console.line("DATA BOUNDS FAIL - USING ESP FALLBACK");
            break :blk esp_directory_adapter.source();
        };
        const data_partition_bytes = ntfs.Partition{ .start_bytes = data_start_bytes, .size_bytes = data_size_bytes };

        const boot_probe = ntfs.probeBootSector(reader, data_partition_bytes) catch |err| {
            ntfs_diag.recordError("VBR:USOS_DATA", err);
            printError("NTFS VBR FAIL - USING ESP FALLBACK", err);
            break :blk esp_directory_adapter.source();
        };
        ntfs_diag.vbr_read = true;
        ntfs_diag.vbr_oem_ntfs = boot_probe.oem_ntfs;
        ntfs_diag.vbr_signature_valid = boot_probe.boot_signature_valid;
        ntfs_diag.bytes_per_sector = boot_probe.bytes_per_sector;
        ntfs_diag.sectors_per_cluster = boot_probe.sectors_per_cluster;
        ntfs_diag.mft_lcn = boot_probe.mft_lcn;

        const data_fs = ntfs.mount(reader, data_partition_bytes) catch |err| {
            ntfs_diag.recordError("NTFS:MOUNT", err);
            printError("NTFS DATA FAIL - USING ESP FALLBACK", err);
            break :blk esp_directory_adapter.source();
        };
        ntfs_diag.mount_ok = true;
        ntfs_diag.mft_runs = data_fs.mftRunCount();
        console.print("NTFS DATA OK MFT_RUNS=");
        console.printU32(@intCast(data_fs.mftRunCount()));
        console.line("");

        data_directory_adapter = catalog_ntfs_directory_source.Adapter.init(data_fs, reader, &ntfs_diag);
        const source = data_directory_adapter.source();
        data_source = source;
        ntfs_diag.systems_probe_attempted = true;
        var systems_entries: [catalog.directory_source.max_directory_entries]catalog.directory_source.Entry = undefined;
        const systems_page = source.listPage("\\Systems", 0, &systems_entries) catch |err| {
            ntfs_diag.recordError("\\Systems", err);
            printError("NTFS SYSTEMS FAIL", err);
            break :blk source;
        };
        ntfs_diag.systems_open_ok = true;
        ntfs_diag.systems_entry_count = systems_page.count;

        const windows_info = ntfs.directoryInfo(data_fs, reader, &windows_path) catch |err| {
            ntfs_diag.recordError("\\Systems\\Windows", err);
            break :blk source;
        };
        if (windows_info.first_index_lcn) |index_lcn| {
            const relative = checkedMul(index_lcn, data_fs.cluster_bytes) orelse 0;
            windows_index_offset = checkedAdd(data_start_bytes, relative) orelse 0;
            const single_hash = probeIndexHash(reader, windows_index_offset, data_fs.cluster_bytes);
            ntfs_diag.pre_vbe_index_single_ok = single_hash.ok;
            ntfs_diag.pre_vbe_index_single_hash = single_hash.hash;
            diagnostics.printIndexHash("INDEX PRE-VBE single", single_hash.ok, single_hash.hash);
            const bulk_hash = probeIndexHash(bulk_reader, windows_index_offset, data_fs.cluster_bytes);
            ntfs_diag.pre_vbe_index_bulk_ok = bulk_hash.ok;
            ntfs_diag.pre_vbe_index_bulk_hash = bulk_hash.hash;
            diagnostics.printIndexHash("INDEX PRE-VBE bulk", bulk_hash.ok, bulk_hash.hash);
        }
        ntfs_diag.clearError();
        break :blk source;
    };
    var discovery = catalog.media_discovery.Discovery.init(discovery_source);
    var hardware_runtime = diagnostics.RuntimeState{
        .before_discovery = hardware_state.capture(),
    };
    const diag = diagnostics.Info{
        .bios_drive = context.bios_drive,
        .gpt_name = gpt_name[0..gpt_name_len],
        .fat32_label = label[0..label_len],
        .source = esp_directory_adapter.source(),
        .data_source = data_source,
        .ntfs = &ntfs_diag,
        .sector_reads = &bios_context.sector_reads,
        .cache_hits = &discovery.cache_hits,
        .cache_misses = &discovery.cache_misses,
        .hardware = &hardware_runtime,
    };
    var graphics = vbe_probe.init();
    if (graphics != null) @import("boot_ui.zig").init(&fs, reader);
    console.screen_output = true;
    if (windows_index_offset != 0) {
        const cluster_bytes = data_directory_adapter.fs.cluster_bytes;
        const single_hash = probeIndexHash(reader, windows_index_offset, cluster_bytes);
        ntfs_diag.post_vbe_index_single_ok = single_hash.ok;
        ntfs_diag.post_vbe_index_single_hash = single_hash.hash;
        diagnostics.printIndexHash("INDEX POST-VBE single", single_hash.ok, single_hash.hash);
        const bulk_hash = probeIndexHash(bulk_reader, windows_index_offset, cluster_bytes);
        ntfs_diag.post_vbe_index_bulk_ok = bulk_hash.ok;
        ntfs_diag.post_vbe_index_bulk_hash = bulk_hash.hash;
        diagnostics.printIndexHash("INDEX POST-VBE bulk", bulk_hash.ok, bulk_hash.hash);
    }
    ntfs_diag.clearError();
    // A completed XP target preparation takes precedence over the persistent
    // micro-Linux boot marker: after preparation/reboot we must chainload the
    // freshly created XPSETUP partition instead of entering preparation again.
    linux_load_probe.offerXpResume(fs, reader, bulk_reader, esp.part_guid, graphics);
    @import("windows_work_chainload.zig").runIfReady(fs, reader, bulk_reader, @intCast(context.bios_drive), graphics);
    xp_target_chainload.runIfReady(fs, reader, graphics);
    linux_load_probe.runIfRequested(fs, reader, bulk_reader, esp.part_guid, graphics);
    const actions = legacy_boot_actions.Context{
        .esp_fs = fs,
        .reader = reader,
        .bulk_reader = bulk_reader,
        .esp_part_guid_disk = esp.part_guid,
        .bios_boot_drive = context.bios_drive,
    };
    if (test_mode.xp_menu_auto) {
        text_menu.runXpMenuAutoTest(&discovery, diag, actions, &graphics, test_mode.xp_menu_auto_none);
        console.line("[LEGACY_MENU_TEST] FAIL auto test returned unexpectedly");
        while (true) {}
    }
    text_menu.run(&discovery, diag, actions, graphics);
}

fn validContext(context: *const BootContext) bool {
    if (context.magic != context_magic or context.version != context_version or context.size != context_bytes) return false;
    if (context.sector_bytes != 512 or context.core_slot_lba != 64) return false;
    for (context.reserved) |value| if (value != 0) return false;
    return true;
}

fn printError(prefix: []const u8, err: anyerror) void {
    console.screen_output = true;
    console.print(prefix);
    console.print(" error=");
    console.print(@errorName(err));
    console.line("");
}

const SectorHashProbe = struct { ok: bool, hash: u32 };

fn probeIndexHash(reader: random_reader.Reader, absolute_offset: u64, cluster_bytes: u32) SectorHashProbe {
    var cluster: [4096]u8 = undefined;
    if (cluster_bytes != cluster.len) return .{ .ok = false, .hash = 0 };
    reader.readAt(absolute_offset, &cluster) catch return .{ .ok = false, .hash = 0 };
    var hash: u32 = 0x811c9dc5;
    for (cluster) |byte| {
        hash ^= byte;
        hash *%= 0x01000193;
    }
    return .{ .ok = true, .hash = hash };
}

fn checkedAdd(a: u64, b: u64) ?u64 {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

fn checkedMul(a: u64, b: u64) ?u64 {
    const result = @mulWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

pub const panic = struct {
    pub fn call(_: []const u8, _: ?*anyopaque, _: ?usize) noreturn {
        console.line("CORE PANIC");
        while (true) {}
    }
};
