const std = @import("std");
const usos = @import("usos");
const collect_boot_info = @import("collect_boot_info.zig");
const catalog_ntfs_directory_source = @import("catalog_ntfs_directory_source.zig");
const data_volume = @import("data_volume.zig");
const filesystem = @import("filesystem.zig");
const e2e_flow = @import("e2e_flow.zig");
const manual_categories = @import("manual_categories.zig");
const manual_images = @import("manual_images.zig");
const manual_methods = @import("manual_methods.zig");
const manual_summary = @import("manual_summary.zig");
const manual_systems = @import("manual_systems.zig");
const manual_unattended = @import("manual_unattended.zig");
const manual_utilities = @import("manual_utilities.zig");
const manual_view = @import("manual_view.zig");

const CatalogState = struct {
    catalog: data_volume.Catalog,
    adapter: catalog_ntfs_directory_source.Adapter,
    discovery: usos.catalog.media_discovery.Discovery,
};

noinline fn initCatalogState(state: *CatalogState) !void {
    state.catalog = try data_volume.openCatalog();
    state.adapter = catalog_ntfs_directory_source.Adapter.init(state.catalog.fs, state.catalog.reader());
    state.discovery = usos.catalog.media_discovery.Discovery.init(state.adapter.source());
}

pub fn run() void {
    const info = collect_boot_info.collect() catch return;
    const root = filesystem.openBootVolume() orelse return;
    defer root.close() catch {};
    manual_view.init(root, info);
    if (e2e_flow.resumePersistent(root, showResumeStatus)) return;

    const bs = std.os.uefi.system_table.boot_services orelse return;
    const pages = bs.allocatePages(.any, .loader_data, (@sizeOf(CatalogState) + 4095) / 4096) catch |err| {
        showDataCatalogError(err);
        return;
    };
    defer bs.freePages(pages) catch {};
    const state: *CatalogState = @ptrCast(pages.ptr);
    initCatalogState(state) catch |err| {
        showDataCatalogError(err);
        return;
    };
    const discovery = &state.discovery;
    while (true) {
        const category = manual_categories.select();
        if (category == .utilities) {
            while (manual_utilities.select(root, discovery, info.firmware)) |utility| runEntry(root, discovery, utility, info.firmware);
            continue;
        }
        while (manual_systems.select(root, discovery, category, info.firmware)) |system| runEntry(root, discovery, system, info.firmware);
    }
}

fn runEntry(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, entry: *const usos.catalog.SystemEntry, firmware: usos.firmware.Firmware) void {
    while (manual_images.select(discovery, entry)) |image| {
        while (manual_methods.select(entry, image, firmware)) |method| {
            if (entry.unattended_directory != null and (image.kind == .iso or image.kind == .wim)) {
                const unattended = manual_unattended.select(discovery, entry);
                if (unattended.back) continue;
                manual_summary.show(root, entry, image, method, unattended.path, firmware);
            } else {
                manual_summary.show(root, entry, image, method, null, firmware);
            }
        }
    }
}

fn showResumeStatus(stage: e2e_flow.ResumeStage) void {
    switch (stage) {
        .starting_windows_setup => showWindowsHandoffStatus("Preparing Windows Setup handoff..."),
        .loading_ntfs_driver => showWindowsHandoffStatus("Loading NTFS driver..."),
        .locating_work_partition => showWindowsHandoffStatus("Locating prepared WORK partition..."),
        .verifying_windows_media => showWindowsHandoffStatus("Verifying install.wim and EFI boot files..."),
        .loading_windows_boot_manager => showWindowsHandoffStatus("Loading Windows Boot Manager..."),
        .committing_windows_handoff => showWindowsHandoffStatus("Saving one-shot handoff state..."),
        .transferring_to_windows => showWindowsHandoffStatus("Transferring control to Windows Setup..."),
        .starting_chainload => {
            manual_view.begin("windows-handoff", "Starting chained bootloader");
            manual_view.row(false, "Boot media preparation is complete.");
            manual_view.row(false, "Starting EFI/BOOT from the prepared WORK partition...");
            manual_view.passiveFooter();
        },
    }
}

fn showDataCatalogError(err: anyerror) void {
    manual_view.begin("data-catalog", "DATA CATALOG UNAVAILABLE");
    manual_view.row(false, "USOS could not open the NTFS USOS_DATA volume.");
    manual_view.row(false, @errorName(err));
    manual_view.row(false, "Images are discovered directly from DATA; ESP marker files are not used.");
    manual_view.passiveFooter();
}

fn showWindowsHandoffStatus(status: []const u8) void {
    manual_view.begin("windows-handoff", "STARTING WINDOWS SETUP");
    manual_view.row(false, "Windows installer preparation is complete.");
    manual_view.row(false, status);
    manual_view.row(false, "Please wait. The Windows logo will appear shortly.");
    manual_view.passiveFooter();
}
