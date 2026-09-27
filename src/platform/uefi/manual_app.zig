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
const manual_secure_boot = @import("manual_secure_boot.zig");
const boot_timing = @import("boot_timing.zig");
const splash = @import("splash.zig");

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
    boot_timing.mark("GOP and memory map");
    const root = filesystem.openBootVolume() orelse return;
    defer root.close() catch {};
    boot_timing.mark("ESP volume open");
    // The splash goes up before any slow I/O; only the tiny settings file
    // (boot_logo=) is read first.
    const settings = manual_view.readSettings(root);
    boot_timing.mark("usos-settings.ini read");
    splash.setTheme(@import("theme_loader.zig").splashTheme(settings));
    splash.begin(info.framebuffer, splash.logoSetting(settings), "");
    manual_view.init(root, info, settings);
    manual_secure_boot.init(root);
    @import("windows_native_iso.zig").setEspRoot(root);
    if (e2e_flow.resumePersistent(root, showResumeStatus)) return;
    boot_timing.mark("persistent state checked");
    splash.status(manual_view.t(.splash_images));

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
    boot_timing.mark("DATA catalog open (BlockIo, GPT, NTFS mount)");
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
        // A WinPE / rescue ISO is not a Windows installer: it can only be
        // started as it is (no method choice, no answer file, no Setup).
        if (image.media) |info| if (info.content == .winpe) {
            manual_summary.showWinPe(root, entry, image, firmware);
            continue;
        };
        while (manual_methods.select(entry, image, firmware)) |method| {
            answerAndSummary(root, discovery, entry, image, method, firmware);
            // Back from the first screen after the method: with a single
            // method taken without asking there is no method screen, and
            // selecting it again would reopen the same screen (Back looked
            // dead on the XP answer-file screen), so return to the images.
            if (manual_methods.automatic) break;
        }
    }
}

/// Answer-file screen (when it applies) and summary; returns on Back from
/// the first of them that was shown. Back from the summary goes to the
/// answer-file screen when that was shown.
fn answerAndSummary(root: *std.os.uefi.protocol.File, discovery: *usos.catalog.media_discovery.Discovery, entry: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem, method: usos.catalog.BootMethod, firmware: usos.firmware.Firmware) void {
    if (entry.unattended_directory == null or !(image.kind == .iso or image.kind == .wim)) {
        return manual_summary.show(root, entry, image, method, .{}, 0, firmware);
    }
    // Vista without firmware CSM (vista-x64-sp2-uefi-csmwrap) hands profiles and
    // answer files on; with CSM Vista keeps its servicing answer only.
    const vista_csmwrap = usos.flow.answer_screen.vistaCsmwrap(entry, image.kind, method, firmware, @import("secure_boot.zig").csm().likelyOn());
    const profiles_allowed = usos.flow.answer_screen.profileCapable(entry, image.kind, method, firmware) or vista_csmwrap;
    const answers_unsupported = usos.flow.answer_screen.answersUnsupported(entry, firmware) and !vista_csmwrap;
    while (true) {
        const unattended = manual_unattended.select(discovery, .{ .root = root, .system = entry, .profiles_allowed = profiles_allowed, .image = image, .answers_unsupported = answers_unsupported });
        if (unattended.back) return;
        manual_summary.show(root, entry, image, method, unattended.choice, unattended.available, firmware);
        if (!unattended.shown) return;
    }
}

fn showResumeStatus(stage: e2e_flow.ResumeStage) void {
    switch (stage) {
        .starting_windows_setup => showWindowsHandoffStatus(.handoff_setup),
        .loading_ntfs_driver => showWindowsHandoffStatus(.handoff_ntfs),
        .locating_work_partition => showWindowsHandoffStatus(.handoff_work),
        .verifying_windows_media => showWindowsHandoffStatus(.handoff_verify),
        .loading_windows_boot_manager => showWindowsHandoffStatus(.handoff_bootmgr),
        .committing_windows_handoff => showWindowsHandoffStatus(.handoff_commit),
        .transferring_to_windows => showWindowsHandoffStatus(.handoff_transfer),
        .starting_chainload => {
            const lines = [_][]const u8{ manual_view.t(.chainload_line1), manual_view.t(.chainload_line2) };
            manual_view.status(manual_view.t(.chainload_title), "", &lines);
        },
    }
}

fn showDataCatalogError(err: anyerror) void {
    const lines = [_][]const u8{ manual_view.t(.error_catalog_line1), @errorName(err), manual_view.t(.error_catalog_line2) };
    manual_view.status(manual_view.t(.error_catalog_title), "", &lines);
}

fn showWindowsHandoffStatus(key: manual_view.Key) void {
    const lines = [_][]const u8{ manual_view.t(.handoff_line1), manual_view.t(key), manual_view.t(.handoff_line2) };
    manual_view.status(manual_view.t(.handoff_title), "", &lines);
}
