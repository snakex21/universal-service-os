//! Legacy BIOS graphical menu: the same screens as the UEFI menu
//! (src/gui/menu_screens.zig) drawn straight into the VBE framebuffer, with
//! the font, icons and language from boot_ui.zig.
const std = @import("std");
const catalog = @import("catalog");
const boot_method_model = catalog.boot_method_model;
const graphics = @import("graphics");
const vbe_probe = @import("vbe_probe.zig");
const boot_ui = @import("boot_ui.zig");
const menu_pointer = @import("menu_pointer.zig");
const image_rows = @import("image_rows.zig");

const Ui = graphics.ui.Ui;
const Row = graphics.ui.Row;
const Hint = graphics.ui.Hint;
const screens = graphics.ui_screens;
const lang_file = graphics.lang_file;

const max_rows: usize = 64;

/// Geometry of the screen on display, for pointer hit testing.
var current: struct {
    kind: enum(u8) { none, home, list } = .none,
    count: usize = 0,
    geometry: screens.ListGeometry = undefined,
    marker: u8 = 1,
} linksection(".data") = .{};

pub fn hit(surface: graphics.Surface, x: u32, y: u32) ?usize {
    switch (current.kind) {
        .home => {
            var ui = boot_ui.partial(surface);
            return screens.homeHit(&ui, current.count, x, y);
        },
        .list => return screens.listHit(current.geometry, current.count, x, y),
        .none => return null,
    }
}

fn listHints(buffer: *[4]Hint, ui: *const Ui, open: lang_file.Key) []const Hint {
    buffer.* = .{
        .{ .key = "\u{2191}\u{2193}", .label = ui.t(.key_select) },
        .{ .key = "Enter", .label = ui.t(open) },
        .{ .key = "Esc", .label = ui.t(.key_back) },
        .{ .key = "D", .label = ui.t(.key_diagnostics) },
    };
    return buffer;
}

fn noticeHints(buffer: *[2]Hint, ui: *const Ui) []const Hint {
    buffer.* = .{
        .{ .key = "Esc", .label = ui.t(.key_back) },
        .{ .key = "D", .label = ui.t(.key_diagnostics) },
    };
    return buffer;
}

pub fn refreshClock(session: *const vbe_probe.Session) void {
    if (current.kind == .none) return;
    var ui = boot_ui.partial(session.surface);
    var buffer: [48]u8 = undefined;
    const info = boot_ui.header(&ui, &buffer);
    ui.headerClockAt(ui.headerClockRight(info), info.clock);
}

// ------------------------------------------------------------------ home

fn homeItems(ui: *const Ui, items: *[catalog.categories.all.len + 1]screens.HomeItem) []const screens.HomeItem {
    for (catalog.categories.all, 0..) |category, index| {
        items[index] = .{
            .icon = switch (category) {
                .windows => .windows,
                .linux => .terminal,
                .beta => .flask,
                .dos => .floppy,
                .utilities => .gear,
            },
            .title = ui.strings.lookup(category.label()),
            .description = ui.t(switch (category) {
                .windows => .category_windows_desc,
                .linux => .category_linux_desc,
                .beta => .category_beta_desc,
                .dos => .category_dos_desc,
                .utilities => .category_utilities_desc,
            }),
        };
    }
    // Legacy BIOS offers restart and shut down only (no firmware setup).
    items[catalog.categories.all.len] = .{ .icon = .power, .title = ui.t(.category_power), .description = ui.t(.power_subtitle) };
    return items;
}

pub fn categories(session: *const vbe_probe.Session, selected: usize) void {
    menu_pointer.configure(session.surface, true, catalog.categories.all.len + 1, selected);
    var ui = boot_ui.menu(session.surface);
    var items: [catalog.categories.all.len + 1]screens.HomeItem = undefined;
    var clock: [48]u8 = undefined;
    const hints = [_]Hint{
        .{ .key = "\u{2191}\u{2193}\u{2190}\u{2192}", .label = ui.t(.key_select) },
        .{ .key = "Enter", .label = ui.t(.key_open) },
        .{ .key = "Esc", .label = ui.t(.key_power) },
        .{ .key = "D", .label = ui.t(.key_diagnostics) },
    };
    screens.home(&ui, boot_ui.header(&ui, &clock), homeItems(&ui, &items), selected, null, &hints);
    current.kind = .home;
    current.count = items.len;
}

pub fn categorySelection(session: *const vbe_probe.Session, previous: usize, now: usize) void {
    if (previous == now) return;
    menu_pointer.configure(session.surface, true, catalog.categories.all.len + 1, now);
    var ui = boot_ui.partial(session.surface);
    var items: [catalog.categories.all.len + 1]screens.HomeItem = undefined;
    const list = homeItems(&ui, &items);
    screens.homeItem(&ui, list, previous, .normal);
    screens.homeItem(&ui, list, now, .selected);
}

// ------------------------------------------------------------------ lists

const ListBuild = struct {
    rows: [max_rows]Row = undefined,
    details: [max_rows][48]u8 = undefined,
    count: usize = 0,
};

fn showList(session: *const vbe_probe.Session, ui: *const Ui, spec: screens.ListSpec) void {
    menu_pointer.configure(session.surface, false, spec.rows.len, spec.selected);
    var clock: [48]u8 = undefined;
    current.geometry = screens.listScreen(ui, boot_ui.header(ui, &clock), spec, 0);
    current.kind = .list;
    current.count = spec.rows.len;
}

fn updateList(session: *const vbe_probe.Session, ui: *const Ui, spec: screens.ListSpec, previous: usize) void {
    menu_pointer.configure(session.surface, false, spec.rows.len, spec.selected);
    if (current.kind != .list) return showList(session, ui, spec);
    const first = screens.firstVisible(spec.selected, spec.rows.len, current.geometry.list.visible, current.geometry.first);
    if (first != current.geometry.first) {
        current.geometry.first = first;
        screens.drawRows(ui, current.geometry, spec);
    } else {
        screens.drawRow(ui, current.geometry, spec, previous);
        screens.drawRow(ui, current.geometry, spec, spec.selected);
    }
    if (current.geometry.help) |rect| {
        if (spec.help) |help| screens.drawHelp(ui, rect, help);
    }
}

fn systemRows(ui: *const Ui, build: *ListBuild, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, count: usize) void {
    build.count = @min(count, max_rows);
    for (0..build.count) |index| {
        const entry = catalog.systems.byCategoryIndex(category, index) orelse {
            build.rows[index] = .{ .title = "", .enabled = false };
            continue;
        };
        build.rows[index] = systemRow(ui, index, entry.id, entry.name, entry.firmware, discovery.mediaStatus(entry.image_directory), &build.details[index]);
    }
}

fn systemRow(ui: *const Ui, slot: usize, id: []const u8, name: []const u8, firmware: catalog.FirmwareRequirement, media: catalog.SystemMediaStatus, detail: *[48]u8) Row {
    const icon: graphics.ui.RowIcon = if (boot_ui.icon(id, slot)) |rgba| .{ .rgba = rgba } else .{ .label = name[0..@min(name.len, 1)] };
    if (!firmware.accepts(.bios)) return .{
        .title = name,
        .detail = ui.t(.system_requires_uefi_detail),
        .icon = icon,
        .badge = .{ .text = ui.t(.system_requires_uefi), .tone = .warning },
        .enabled = false,
    };
    if (!media.hasImages()) return .{ .title = name, .detail = ui.t(.system_no_image), .icon = icon, .enabled = false };
    var number: [12]u8 = undefined;
    return .{
        .title = name,
        .detail = ui.format(detail, .system_image_count, &.{std.fmt.bufPrint(&number, "{d}", .{media.imageCount()}) catch "?"}),
        .icon = icon,
        .badge = .{ .text = ui.t(.system_ready), .tone = .success },
    };
}

/// A system that needs UEFI is selectable but blocked here: the side panel
/// says why and what to do, like the UEFI menu's blocked-entry help.
fn requiresUefi(category: catalog.Category, index: usize) bool {
    const entry = catalog.systems.byCategoryIndex(category, index) orelse return false;
    return !entry.firmware.accepts(.bios);
}

fn blockedHelp(ui: *const Ui, category: catalog.Category, index: usize, lines: *[2][]const u8) ?screens.Help {
    if (!requiresUefi(category, index)) return null;
    lines.* = .{ ui.t(.system_requires_uefi_detail), ui.t(.system_requires_uefi_hint) };
    return .{ .title = ui.t(.system_requires_uefi), .lines = lines };
}

pub fn systems(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, selected: usize, count: usize) void {
    var ui = boot_ui.menu(session.surface);
    var build: ListBuild = .{};
    systemRows(&ui, &build, discovery, category, count);
    var hints: [4]Hint = undefined;
    var lines: [2][]const u8 = undefined;
    showList(session, &ui, .{ .title = ui.strings.lookup(category.label()), .subtitle = ui.t(.systems_subtitle), .rows = build.rows[0..build.count], .selected = selected, .help = blockedHelp(&ui, category, selected, &lines), .hints = listHints(&hints, &ui, .key_open) });
}

pub fn systemSelection(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, previous: usize, now: usize, count: usize) void {
    if (previous == now) return;
    // The help panel takes list space: it appearing or disappearing needs a
    // full relayout (same text for every blocked row, so no redraw otherwise).
    if (requiresUefi(category, previous) != requiresUefi(category, now)) return systems(session, discovery, category, now, count);
    var ui = boot_ui.partial(session.surface);
    var build: ListBuild = .{};
    systemRows(&ui, &build, discovery, category, count);
    updateList(session, &ui, .{ .title = "", .rows = build.rows[0..build.count], .selected = now }, previous);
}

fn utilityRows(ui: *const Ui, build: *ListBuild, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List) void {
    build.count = @min(list.len, max_rows);
    for (0..build.count) |index| {
        const item = &list.items[index];
        build.rows[index] = switch (item.builtin) {
            .hardware => .{ .title = ui.t(.bios_hardware), .detail = ui.t(.utilities_hardware_desc), .icon = .{ .vector = .chip } },
            .freedos => .{ .title = item.name.slice(), .detail = ui.t(.utilities_freedos_desc), .icon = .{ .vector = .floppy } },
            .none => systemRow(ui, index, item.name.slice(), item.name.slice(), .any, discovery.mediaStatus(item.imageDirectory()), &build.details[index]),
        };
    }
}

pub fn utilities(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List, selected: usize) void {
    var ui = boot_ui.menu(session.surface);
    var build: ListBuild = .{};
    utilityRows(&ui, &build, discovery, list);
    var hints: [4]Hint = undefined;
    showList(session, &ui, .{ .title = ui.t(.category_utilities), .subtitle = ui.t(.category_utilities_desc), .rows = build.rows[0..build.count], .selected = selected, .hints = listHints(&hints, &ui, .key_open) });
}

pub fn utilitySelection(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List, previous: usize, now: usize) void {
    if (previous == now) return;
    var ui = boot_ui.partial(session.surface);
    var build: ListBuild = .{};
    utilityRows(&ui, &build, discovery, list);
    updateList(session, &ui, .{ .title = "", .rows = build.rows[0..build.count], .selected = now }, previous);
}

fn imageRows(build: *ListBuild, images_list: *const catalog.ImageList) void {
    build.count = image_rows.fill(&build.rows, images_list);
}

pub fn images(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize) void {
    renderImages(session, title, images_list, selected, false);
}

pub fn systemImages(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize) void {
    renderImages(session, title, images_list, selected, true);
}

fn renderImages(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize, methods_enabled: bool) void {
    var ui = boot_ui.menu(session.surface);
    var build: ListBuild = .{};
    imageRows(&build, images_list);
    var hints: [4]Hint = undefined;
    showList(session, &ui, .{ .title = title, .subtitle = ui.t(.images_subtitle), .rows = build.rows[0..build.count], .selected = selected, .two_line = false, .hints = listHints(&hints, &ui, if (methods_enabled) .key_boot_method else .key_run) });
}

pub fn imageSelection(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, previous: usize, now: usize, methods_enabled: bool) void {
    _ = title;
    _ = methods_enabled;
    if (previous == now) return;
    var ui = boot_ui.partial(session.surface);
    var build: ListBuild = .{};
    imageRows(&build, images_list);
    updateList(session, &ui, .{ .title = "", .rows = build.rows[0..build.count], .selected = now, .two_line = false }, previous);
}

// ------------------------------------------------------------------ methods

fn methodLabel(ui: *const Ui, item: *const boot_method_model.Item) []const u8 {
    var value = item.label.slice();
    if (item.validation_status) |status| {
        const suffix = status.badge();
        if (suffix.len > 0 and std.mem.endsWith(u8, value, suffix)) value = std.mem.trimEnd(u8, value[0 .. value.len - suffix.len], " ");
    }
    return ui.strings.lookup(value);
}

fn methodBadge(ui: *const Ui, item: *const boot_method_model.Item) ?graphics.ui.Badge {
    const status = item.validation_status orelse return null;
    return switch (status) {
        .validated_hardware => .{ .text = ui.t(.badge_ready), .tone = .success },
        .tested_in_vm => .{ .text = ui.t(.badge_tested_in_vm), .tone = .accent },
        .experimental => .{ .text = ui.t(.badge_experimental), .tone = .warning },
    };
}

fn methodRows(ui: *const Ui, build: *ListBuild, model: *const boot_method_model.List, runnable: []const usize) void {
    build.count = runnable.len;
    for (runnable, 0..) |index, row| {
        const item = &model.items[index];
        build.rows[row] = .{ .title = methodLabel(ui, item), .badge = methodBadge(ui, item) };
    }
}

fn methodHelp(ui: *const Ui, item: *const boot_method_model.Item, lines: *[2][]const u8) screens.Help {
    lines.* = .{ ui.strings.lookup(item.help.line1), ui.strings.lookup(item.help.line2) };
    return .{ .title = ui.strings.lookup(item.help.title), .lines = lines, .badge = methodBadge(ui, item) };
}

/// `runnable` lists the model indices of the methods that can run here;
/// `selected` indexes into it.
pub fn methods(session: *const vbe_probe.Session, image_name: []const u8, model: *const boot_method_model.List, runnable: []const usize, selected: usize) void {
    var ui = boot_ui.menu(session.surface);
    var build: ListBuild = .{};
    methodRows(&ui, &build, model, runnable);
    var lines: [2][]const u8 = undefined;
    var hints: [4]Hint = undefined;
    showList(session, &ui, .{
        .title = ui.t(.methods_title),
        .subtitle = image_name,
        .rows = build.rows[0..build.count],
        .selected = selected,
        .two_line = false,
        .help = methodHelp(&ui, &model.items[runnable[selected]], &lines),
        .hints = listHints(&hints, &ui, .key_use),
    });
}

pub fn methodSelection(session: *const vbe_probe.Session, image_name: []const u8, model: *const boot_method_model.List, runnable: []const usize, previous: usize, now: usize) void {
    _ = image_name;
    if (previous == now) return;
    var ui = boot_ui.partial(session.surface);
    var build: ListBuild = .{};
    methodRows(&ui, &build, model, runnable);
    var lines: [2][]const u8 = undefined;
    updateList(session, &ui, .{ .title = "", .rows = build.rows[0..build.count], .selected = now, .two_line = false, .help = methodHelp(&ui, &model.items[runnable[now]], &lines) }, previous);
}

// ------------------------------------------------------------------ unattended

fn unattendedRows(ui: *const Ui, build: *ListBuild, options: []const ?[]const u8, kind: []const u8) void {
    build.count = @min(options.len, max_rows);
    for (0..build.count) |index| {
        build.rows[index] = if (options[index]) |name|
            .{ .title = name, .icon = .{ .label = kind } }
        else
            .{ .title = ui.t(.unattended_none), .icon = .{ .vector = .close } };
    }
}

fn unattendedHelp(ui: *const Ui, option: ?[]const u8, line: *[1][]const u8) screens.Help {
    line[0] = if (option == null) ui.t(.unattended_none_detail) else ui.t(.unattended_file_detail);
    return .{ .title = ui.t(.unattended_title), .lines = line };
}

pub fn unattended(session: *const vbe_probe.Session, system_name: []const u8, file_kind_label: []const u8, options: []const ?[]const u8, selected: usize) void {
    var ui = boot_ui.menu(session.surface);
    var build: ListBuild = .{};
    unattendedRows(&ui, &build, options, file_kind_label);
    var line: [1][]const u8 = undefined;
    var hints: [4]Hint = undefined;
    showList(session, &ui, .{
        .title = ui.t(.unattended_title),
        .subtitle = system_name,
        .rows = build.rows[0..build.count],
        .selected = selected,
        .two_line = false,
        .help = unattendedHelp(&ui, options[selected], &line),
        .hints = listHints(&hints, &ui, .key_use),
    });
}

pub fn unattendedSelection(session: *const vbe_probe.Session, system_name: []const u8, file_kind_label: []const u8, options: []const ?[]const u8, previous: usize, now: usize) void {
    _ = system_name;
    if (previous == now) return;
    var ui = boot_ui.partial(session.surface);
    var build: ListBuild = .{};
    unattendedRows(&ui, &build, options, file_kind_label);
    var line: [1][]const u8 = undefined;
    updateList(session, &ui, .{ .title = "", .rows = build.rows[0..build.count], .selected = now, .two_line = false, .help = unattendedHelp(&ui, options[now], &line) }, previous);
}

// ------------------------------------------------------------------ power

fn powerRows(ui: *const Ui, rows: *[2]Row) []const Row {
    rows.* = .{
        .{ .title = ui.t(.power_restart), .icon = .{ .vector = .restart } },
        .{ .title = ui.t(.power_shutdown), .icon = .{ .vector = .shutdown } },
    };
    return rows;
}

pub fn power(session: *const vbe_probe.Session, selected: usize) void {
    var ui = boot_ui.menu(session.surface);
    var rows: [2]Row = undefined;
    var hints: [4]Hint = undefined;
    showList(session, &ui, .{ .title = ui.t(.power_title), .subtitle = ui.t(.power_subtitle), .rows = powerRows(&ui, &rows), .selected = selected, .two_line = false, .hints = listHints(&hints, &ui, .key_run) });
}

pub fn powerSelection(session: *const vbe_probe.Session, previous: usize, now: usize) void {
    if (previous == now) return;
    var ui = boot_ui.partial(session.surface);
    var rows: [2]Row = undefined;
    updateList(session, &ui, .{ .title = "", .rows = powerRows(&ui, &rows), .selected = now, .two_line = false }, previous);
}

// ------------------------------------------------------------------ notices

fn notice(session: *const vbe_probe.Session, ui: *const Ui, spec: screens.NoticeSpec) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    var clock: [48]u8 = undefined;
    screens.notice(ui, boot_ui.header(ui, &clock), spec);
    current.kind = .none;
}

pub fn xpResume(session: *const vbe_probe.Session) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{ ui.t(.bios_xp_resume_line1), ui.t(.bios_xp_resume_line2), ui.t(.bios_xp_resume_line3), ui.t(.bios_xp_resume_line4) };
    const hints = [_]Hint{
        .{ .key = "Enter", .label = ui.t(.bios_xp_resume_continue) },
        .{ .key = "Esc", .label = ui.t(.key_usos_menu) },
    };
    notice(session, &ui, .{ .title = ui.t(.bios_xp_resume_title), .icon = .info, .lines = &lines, .hints = &hints });
}

pub fn windowsSetupFailure(session: *const vbe_probe.Session, error_name: []const u8) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{ ui.t(.bios_setup_failed_line1), error_name, ui.t(.bios_setup_failed_line2), ui.t(.bios_setup_failed_line3) };
    const hints = [_]Hint{.{ .key = "Esc", .label = ui.t(.key_usos_menu) }};
    notice(session, &ui, .{ .title = ui.t(.bios_setup_failed_title), .icon = .error_circle, .tone = .danger, .lines = &lines, .hints = &hints });
}

pub fn backendFailure(session: *const vbe_probe.Session, method_label: []const u8, error_name: []const u8) void {
    var ui = boot_ui.menu(session.surface);
    var heading: [160]u8 = undefined;
    const lines = [_][]const u8{ ui.t(.bios_backend_failed_line1), error_name };
    var hints: [2]Hint = undefined;
    notice(session, &ui, .{ .title = ui.format(&heading, .bios_backend_failed_title, &.{ui.strings.lookup(method_label)}), .icon = .error_circle, .tone = .danger, .lines = &lines, .hints = noticeHints(&hints, &ui) });
}

pub fn noUtilities(session: *const vbe_probe.Session) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{ ui.t(.utilities_none_line1), ui.t(.utilities_none_line2) };
    var hints: [2]Hint = undefined;
    notice(session, &ui, .{ .title = ui.t(.utilities_none_title), .lines = &lines, .hints = noticeHints(&hints, &ui) });
}

pub fn missingImage(session: *const vbe_probe.Session, title: []const u8, path: []const u8) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{ ui.t(.notice_no_image_line1), path };
    var hints: [2]Hint = undefined;
    notice(session, &ui, .{ .title = title, .icon = .warning, .tone = .warning, .heading = ui.t(.notice_no_image_title), .lines = &lines, .hints = noticeHints(&hints, &ui) });
}

/// Enter on a system that needs the other firmware mode: say why and how.
pub fn firmwareMismatch(session: *const vbe_probe.Session, title: []const u8, requires_uefi: bool) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{
        ui.t(if (requires_uefi) .system_requires_uefi_detail else .system_requires_bios_detail),
        ui.t(if (requires_uefi) .system_requires_uefi_hint else .system_requires_bios_hint),
    };
    var hints: [2]Hint = undefined;
    notice(session, &ui, .{ .title = title, .icon = .warning, .tone = .warning, .heading = ui.t(if (requires_uefi) .system_requires_uefi else .system_requires_bios), .lines = &lines, .hints = noticeHints(&hints, &ui) });
}

pub fn manualPowerOff(session: *const vbe_probe.Session) void {
    var ui = boot_ui.menu(session.surface);
    const lines = [_][]const u8{ ui.t(.power_apm_line1), ui.t(.power_apm_line2) };
    notice(session, &ui, .{ .title = ui.t(.power_title), .icon = .power, .lines = &lines });
}

/// A simple list/notice screen for the DOS and Windows 9x helpers.
pub fn choice(session: *const vbe_probe.Session, title: []const u8, subtitle: []const u8, rows: []const Row, selected: usize, notes: []const []const u8, hints: []const Hint) void {
    var ui = boot_ui.menu(session.surface);
    var clock: [48]u8 = undefined;
    const help: ?screens.Help = if (notes.len > 0) .{ .title = "", .lines = notes } else null;
    menu_pointer.configure(session.surface, false, 0, 0);
    _ = screens.listScreen(&ui, boot_ui.header(&ui, &clock), .{ .title = title, .subtitle = subtitle, .rows = rows, .selected = selected, .two_line = false, .help = help, .hints = hints }, 0);
    current.kind = .none;
}

// ------------------------------------------------------------------ progress

fn progressFrame(session: *const vbe_probe.Session, heading: []const u8, title: []const u8, detail: []const u8, percent: u8, labels: []const []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    current.kind = .none;
    var scratch: lang_file.Table = undefined;
    var ui = boot_ui.progress(session.surface, &scratch);
    var clock: [48]u8 = undefined;
    graphics.preparation_screen.render(&ui, .{
        .mode = .progress,
        .current = 1,
        .total = @intCast(labels.len),
        .labels = labels,
        .heading = heading,
        .title = title,
        .detail = detail,
        .percent = percent,
    }, boot_ui.header(&ui, &clock));
}

const environment_labels = [_][]const u8{"Loading environment"};
const setup_labels = [_][]const u8{"Reading the installer from USB"};

pub fn preparationStart(session: *const vbe_probe.Session) void {
    environmentStart(session, "Starting Windows installer");
}

var environment_title: []const u8 linksection(".data") = "Starting Windows installer";

pub fn environmentStart(session: *const vbe_probe.Session, title: []const u8) void {
    environment_title = title;
    preparationProgress(session, 0);
}

pub fn preparationProgress(session: *const vbe_probe.Session, percent: u8) void {
    var number: [8]u8 = undefined;
    const value = std.fmt.bufPrint(&number, "{d}", .{percent}) catch "";
    var scratch: lang_file.Table = undefined;
    var ui = boot_ui.progress(session.surface, &scratch);
    var detail: [96]u8 = undefined;
    progressFrame(session, environment_title, "Loading environment", ui.format(&detail, .bios_loading_files, &.{value}), percent, &environment_labels);
}

pub fn windowsSetupStart(session: *const vbe_probe.Session) void {
    windowsSetupProgress(session, 0);
}

pub fn windowsSetupProgress(session: *const vbe_probe.Session, percent: u8) void {
    var number: [8]u8 = undefined;
    const value = std.fmt.bufPrint(&number, "{d}", .{percent}) catch "";
    var scratch: lang_file.Table = undefined;
    var ui = boot_ui.progress(session.surface, &scratch);
    var detail: [96]u8 = undefined;
    progressFrame(session, "Starting Windows Setup", "Reading the installer from USB", ui.format(&detail, .bios_setup_progress, &.{value}), percent, &setup_labels);
}


/// "Please wait" screen while a DOS/FreeDOS session is assembled in memory.
pub fn busy(session: *const vbe_probe.Session, title: []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    current.kind = .none;
    var scratch: lang_file.Table = undefined;
    var ui = boot_ui.progress(session.surface, &scratch);
    var clock: [48]u8 = undefined;
    const lines = [_][]const u8{ui.t(.wait_usb)};
    screens.notice(&ui, boot_ui.header(&ui, &clock), .{ .title = title, .icon = .floppy, .heading = ui.t(.bios_loading), .lines = &lines });
}

/// Strings for helper screens outside this file.
pub fn strings(session: *const vbe_probe.Session) Ui {
    return boot_ui.menu(session.surface);
}
