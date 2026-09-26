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
        view.notice(system.name, .warning, .warning, view.t(.notice_no_image_title), &lines);
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
    list.open(system.name, view.t(.images_subtitle), rows[0..images.len], selected, two_line, null);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, images.len, &list)) {
            .activate => {
                const image = images.items[selected];
                // Selectable but blocked: explain why and stay in the list.
                if (blockReason(system, image)) |reason| {
                    showBlocked(image.name.slice(), reason);
                    list.open(system.name, view.t(.images_subtitle), rows[0..images.len], selected, two_line, null);
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
    return usos.catalog.os_profiles.mediaBlock(system.id, info, probe.firmware());
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
    if (usos.catalog.os_profiles.mediaBlock(system.id, info, probe.firmware())) |reason| {
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
    if (arch) |text| result.badge = .{ .text = text, .tone = if (hint != .none) .warning else if (info.content == .setup) .success else .accent };
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
