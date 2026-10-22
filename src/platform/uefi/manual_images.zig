const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const probe = @import("windows_media_probe.zig");
const media = usos.image_probe.windows_media;

var list_storage: usos.catalog.ImageList = .{};
/// Row detail text that is formatted (the "belongs in" folder hint).
var detail_storage: [usos.catalog.image_list_max_items][96]u8 = undefined;

pub fn select(discovery: *usos.catalog.media_discovery.Discovery, system: *const usos.catalog.SystemEntry) ?usos.catalog.ImageItem {
    list_storage = discovery.images(system.image_directory);
    const images = &list_storage;
    if (images.len == 0) {
        const lines = [_][]const u8{ view.t(.images_none_line1), view.t(.images_none_line2) };
        view.notice(view.tr(system.name), .warning, .warning, view.t(.notice_no_image_title), &lines);
        view.waitForDismiss();
        return null;
    }
    // Architecture and Setup/WinPE content of each Windows ISO (read from DATA).
    probe.probeList(system, images);

    var rows: [usos.catalog.image_list_max_items]usos.gui.ui.Row = undefined;
    var two_line = false;
    for (images.items[0..images.len], 0..) |*image, index| {
        rows[index] = row(system, image, &detail_storage[index]);
        if (rows[index].detail.len > 0) two_line = true;
    }

    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.tr(system.name), view.t(.images_subtitle), rows[0..images.len], selected, two_line, null);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, images.len, &list)) {
            .activate => {
                const image = images.items[selected];
                // Selectable but blocked: explain why and stay in the list.
                if (blockReason(system, image)) |reason| {
                    showBlocked(image.name.slice(), reason);
                    list.open(view.tr(system.name), view.t(.images_subtitle), rows[0..images.len], selected, two_line, null);
                    continue;
                }
                return image;
            },
            .back => return null,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

/// Why this image cannot start on this firmware (null: no objection).
/// Windows 7/Vista (and Server 2008/2008 R2) start through the PE donor, so
/// their media need no own UEFI loader (os_profiles.mediaBlock).
pub fn blockReason(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) ?media.Block {
    const info = image.media orelse return null;
    const reason = usos.catalog.os_profiles.mediaBlock(system.id, info, probe.firmware());
    // 32-bit Windows 8.1 / 10 without firmware CSM: win-x86-uefi-csmwrap
    // (the ISO's own WinPE through CSMWrap). With a CSM the block stays.
    if (reason == .needs_32bit_uefi_or_bios and x86Csmwrap(system, image)) return null;
    return reason;
}

/// 32-bit media of Windows 8.1 / 10 (native modern systems) on 64-bit UEFI
/// without a firmware CSM: started through CSMWrap (micro-Linux step 610).
pub fn x86Csmwrap(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) bool {
    const info = image.media orelse return false;
    if (info.arch != .x86 or image.kind != .iso or probe.firmware() != .uefi_x64) return false;
    // Windows 7 / Vista and Server 2008 (route_as) as well: their 32-bit media
    // go through an x86 PE10 donor (win-nt6-x86-uefi-csmwrap).
    // Windows 8 RTM (x86_csmwrap): only its 32-bit media, routing unchanged.
    if (!usos.flow.preparation_capability.nativeModernNt(system.id) and !nt6Legacy(system) and
        !usos.catalog.os_profiles.traits(system.id).x86_csmwrap) return false;
    return !@import("secure_boot.zig").csm().likelyOn();
}

/// The backend of this selection: the routing's, except that 32-bit Windows 8
/// RTM media (x86_csmwrap, no native route) under Automatic on 64-bit UEFI
/// without CSM take the windows_iso x86 CSMWrap start (manual_summary).
pub fn backendFor(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem, method: usos.catalog.BootMethod, firmware: usos.firmware.Firmware) ?usos.flow.preparation_capability.Backend {
    const routed = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return null;
    if (method == .automatic and usos.catalog.os_profiles.traits(system.id).x86_csmwrap and x86Csmwrap(system, image)) return .windows_iso;
    return routed;
}

/// Windows 7 / Vista routes (Server 2008 / 2008 R2 via route_as).
pub fn nt6Legacy(system: *const usos.catalog.SystemEntry) bool {
    return usos.catalog.os_profiles.traits(system.id).native_uefi.legacyPe();
}

pub fn blockText(reason: media.Block) []const u8 {
    return switch (reason) {
        .needs_32bit_uefi_or_bios => view.t(.media_blocked_32bit),
        .arm64_media => view.t(.media_blocked_arm64),
        .no_uefi_loader => view.t(.media_blocked_no_uefi),
        .ia64_media => view.t(.server_blocked_ia64),
    };
}

/// The image's install media and its folder disagree (Server media in a
/// client folder or the reverse): where it belongs. A hint, never a block.
pub fn folderHint(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) media.FolderHint {
    const info = image.media orelse return .none;
    if (!probe.applies(system)) return .none;
    return media.folderHint(info.install, system.server);
}

/// Folder name for the folder hint ("Windows Server 2022"), or a generic
/// "Windows Server ..." / "Windows ..." when the version names none.
pub fn suggestedFolder(image: usos.catalog.ImageItem) []const u8 {
    const info = image.media orelse return "";
    return media.suggestedFolder(info.install) orelse if (info.install.server) "Windows Server ..." else "Windows ...";
}

fn showBlocked(name: []const u8, reason: media.Block) void {
    const lines = [_][]const u8{ blockText(reason), view.t(.media_blocked_line2) };
    view.notice(name, .warning, .warning, view.t(.media_blocked_title), &lines);
    view.waitForDismiss();
}

/// Badge: the architecture (warning when blocked); detail line: what the
/// ISO is (Windows Setup, Windows Server Setup, WinPE / rescue media), the
/// folder it belongs in (Server/client mismatch) or why it cannot start.
fn row(system: *const usos.catalog.SystemEntry, image: *const usos.catalog.ImageItem, detail: *[96]u8) usos.gui.ui.Row {
    var result = usos.gui.ui.Row{ .title = image.name.slice(), .icon = .{ .label = kindLabel(image.kind) } };
    const info = image.media orelse return result;
    if (info.unreadable) {
        result.detail = view.t(.media_unreadable);
        return result;
    }
    const arch: ?[]const u8 = if (info.arch == .unknown) null else info.arch.label();
    if (blockReason(system, image.*)) |reason| {
        result.detail = blockText(reason);
        result.badge = .{ .text = arch orelse view.t(.badge_unavailable), .tone = .warning };
        return result;
    }
    result.detail = switch (info.content) {
        .setup => if (info.install.serverOnly()) view.t(.server_setup) else view.t(.media_setup),
        .winpe => view.t(.media_winpe),
        .not_windows => view.t(.media_not_windows),
        .unknown => "",
    };
    const hint = folderHint(system, image.*);
    if (hint != .none) result.detail = view.format(detail, .server_belongs_in, &.{suggestedFolder(image.*)});
    // a solid chip per architecture (x86 and x64 in their own colours,
    // src/gui/arch_badge.zig); the folder hint is in the detail line
    if (usos.gui.arch_badge.badge(info.arch)) |chip| result.badge = chip;
    if (info.content == .winpe and arch == null) result.badge = .{ .text = view.t(.media_winpe_badge), .tone = .accent };
    return result;
}

pub fn kindLabel(kind: usos.catalog.ImageKind) []const u8 {
    return switch (kind) {
        .iso => "ISO",
        .wim => "WIM",
        .img => "IMG",
        .vhd => "VHD",
        .vhdx => "VHDX",
        .efi => "EFI",
    };
}
