const menu_pointer = @import("menu_pointer.zig");
const std = @import("std");
const catalog = @import("catalog");
const boot_method_model = catalog.boot_method_model;
const graphics = @import("graphics");
const vbe_probe = @import("vbe_probe.zig");
const rtc = @import("rtc.zig");
const legacy_icons = @import("legacy_icons");

const Canvas = graphics.menu_canvas.Canvas;
const HomeItem = graphics.menu_canvas.HomeItem;
const Row = graphics.menu_canvas.Row;
const Theme = graphics.Theme;

const firmware_label = "FIRMWARE: BIOS";
const footer_home = "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC - POWER    D - DIAGNOSTICS";
const footer_list = "ARROWS/MOUSE - SELECT    ENTER/CLICK - OPEN    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS";
const footer_notice = "ENTER / ESC / BACKSPACE - BACK    D - DIAGNOSTICS";

pub fn visibleRows(session: *const vbe_probe.Session) usize {
    return Canvas.init(session.surface, Theme{}).visibleRows();
}

pub fn refreshClock(session: *const vbe_probe.Session) void {
    var clock_buffer: [26]u8 = undefined;
    const status = headerStatus(&clock_buffer);
    if (status.len == 0) return;
    Canvas.init(session.surface, Theme{}).refreshHeaderStatus(status);
}

pub fn categories(session: *const vbe_probe.Session, selected: usize) void {
    menu_pointer.configure(session.surface, true, catalog.categories.all.len + 1, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginHome(firmware_label, headerStatus(&clock_buffer));
    const count = catalog.categories.all.len + 1;
    var index: usize = 0;
    while (index < count) : (index += 1) drawCategoryCard(canvas, index, index == selected);
    canvas.footer(footer_home);
}

pub fn categorySelection(session: *const vbe_probe.Session, previous: usize, current: usize) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, true, catalog.categories.all.len + 1, current);
    const canvas = Canvas.init(session.surface, Theme{});
    drawCategoryCard(canvas, previous, false);
    drawCategoryCard(canvas, current, true);
}

fn drawCategoryCard(canvas: Canvas, index: usize, selected: bool) void {
    const count = catalog.categories.all.len + 1;
    if (index >= count) return;
    if (index < catalog.categories.all.len) {
        const category = catalog.categories.all[index];
        canvas.homeItem(index, count, .{
            .title = category.label(),
            .description = categoryDescription(category),
            .symbol = categorySymbol(category),
        }, selected);
        return;
    }
    canvas.homeItem(index, count, HomeItem{
        .title = "POWER",
        .description = "Restart or shut down this computer",
        .symbol = "P",
    }, selected);
}

pub fn systems(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, selected: usize, count: usize) void {
    menu_pointer.configure(session.surface, false, count, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList(category.label(), "Supported systems and image availability", firmware_label, headerStatus(&clock_buffer));
    const visible = canvas.visibleRows();
    const start = graphics.menu_canvas.listStart(selected, count, visible);
    const end = @min(count, start + visible);
    var index = start;
    while (index < end) : (index += 1) drawSystemRow(canvas, discovery, category, index, start, index == selected);
    canvas.footer(footer_list);
}

pub fn systemSelection(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, previous: usize, current: usize, count: usize) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, count, current);
    const canvas = Canvas.init(session.surface, Theme{});
    const visible = canvas.visibleRows();
    const previous_start = graphics.menu_canvas.listStart(previous, count, visible);
    const current_start = graphics.menu_canvas.listStart(current, count, visible);
    if (previous_start != current_start) {
        canvas.clearListRows();
        const end = @min(count, current_start + visible);
        var index = current_start;
        while (index < end) : (index += 1) drawSystemRow(canvas, discovery, category, index, current_start, index == current);
        return;
    }
    drawSystemRow(canvas, discovery, category, previous, current_start, false);
    drawSystemRow(canvas, discovery, category, current, current_start, true);
}

fn drawSystemRow(canvas: Canvas, discovery: *catalog.media_discovery.Discovery, category: catalog.Category, index: usize, start: usize, selected: bool) void {
    const entry = catalog.systems.byCategoryIndex(category, index) orelse return;
    const media = discovery.mediaStatus(entry.image_directory);
    var detail_buffer: [40]u8 = undefined;
    const detail = if (!entry.firmware.accepts(.bios))
        entry.firmware.mismatchReason(.bios)
    else if (!media.hasImages())
        "[no image]"
    else
        std.fmt.bufPrint(&detail_buffer, "[images={d}]", .{media.imageCount()}) catch "[images]";
    var icon_buffer: [legacy_icons.byte_len]u8 = undefined;
    const icon: ?[]const u8 = if (legacy_icons.get(entry.id)) |encoded| graphics.rgba_rle.decode(encoded, &icon_buffer) catch null else null;
    canvas.listRow(index - start, Row{
        .value = entry.name,
        .detail = detail,
        .icon_rgba = icon,
        .icon_symbol = entry.name[0..@min(entry.name.len, 1)],
        .selected = selected,
        .unavailable = !entry.firmware.accepts(.bios),
    });
}

pub fn utilities(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List, selected: usize) void {
    menu_pointer.configure(session.surface, false, list.len, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList("Utilities", "Diagnostics, recovery and firmware tools", firmware_label, headerStatus(&clock_buffer));
    const visible = canvas.visibleRows();
    const start = graphics.menu_canvas.listStart(selected, list.len, visible);
    const end = @min(list.len, start + visible);
    var index = start;
    while (index < end) : (index += 1) drawUtilityRow(canvas, discovery, list, index, start, index == selected);
    canvas.footer(footer_list);
}

pub fn utilitySelection(session: *const vbe_probe.Session, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List, previous: usize, current: usize) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, list.len, current);
    const canvas = Canvas.init(session.surface, Theme{});
    const visible = canvas.visibleRows();
    const previous_start = graphics.menu_canvas.listStart(previous, list.len, visible);
    const current_start = graphics.menu_canvas.listStart(current, list.len, visible);
    if (previous_start != current_start) {
        canvas.clearListRows();
        const end = @min(list.len, current_start + visible);
        var index = current_start;
        while (index < end) : (index += 1) drawUtilityRow(canvas, discovery, list, index, current_start, index == current);
        return;
    }
    drawUtilityRow(canvas, discovery, list, previous, current_start, false);
    drawUtilityRow(canvas, discovery, list, current, current_start, true);
}

fn drawUtilityRow(canvas: Canvas, discovery: *catalog.media_discovery.Discovery, list: *const catalog.utility_catalog.List, index: usize, start: usize, selected: bool) void {
    const item = &list.items[index];
    if (item.builtin == .hardware) {
        canvas.listRow(index - start, Row{ .value = item.name.slice(), .detail = "Built-in: CPU, RAM, board and disks | 64-bit CPU", .icon_symbol = "H", .selected = selected });
        return;
    }
    if (item.builtin == .freedos) {
        canvas.listRow(index - start, Row{ .value = item.name.slice(), .detail = "DOS programs from USB | File manager and command prompt", .icon_symbol = "D", .selected = selected });
        return;
    }
    const media = discovery.mediaStatus(item.imageDirectory());
    var detail_buffer: [40]u8 = undefined;
    const detail = if (!media.hasImages())
        "[no image]"
    else
        std.fmt.bufPrint(&detail_buffer, "[images={d}]", .{media.imageCount()}) catch "[images]";
    const utility_name = item.name.slice();
    canvas.listRow(index - start, Row{
        .value = utility_name,
        .detail = detail,
        .icon_symbol = utility_name[0..@min(utility_name.len, 1)],
        .selected = selected,
    });
}

pub fn images(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize) void {
    renderImages(session, title, images_list, selected, false);
}

pub fn systemImages(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize) void {
    renderImages(session, title, images_list, selected, true);
}

fn renderImages(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, selected: usize, methods_enabled: bool) void {
    menu_pointer.configure(session.surface, false, images_list.len, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList(title, "Available boot images", firmware_label, headerStatus(&clock_buffer));
    const visible = canvas.visibleRows();
    const start = graphics.menu_canvas.listStart(selected, images_list.len, visible);
    const end = @min(images_list.len, start + visible);
    var index = start;
    while (index < end) : (index += 1) drawImageRow(canvas, images_list, index, start, index == selected);
    canvas.footer(if (methods_enabled)
        "ARROWS/MOUSE - SELECT    ENTER/CLICK - BOOT METHOD    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS"
    else
        "ARROWS/MOUSE - SELECT    ENTER/CLICK - RUN    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS");
}

pub fn imageSelection(session: *const vbe_probe.Session, title: []const u8, images_list: *const catalog.ImageList, previous: usize, current: usize, methods_enabled: bool) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, images_list.len, current);
    const canvas = Canvas.init(session.surface, Theme{});
    const visible = canvas.visibleRows();
    const previous_start = graphics.menu_canvas.listStart(previous, images_list.len, visible);
    const current_start = graphics.menu_canvas.listStart(current, images_list.len, visible);
    if (previous_start != current_start) {
        _ = title;
        _ = methods_enabled;
        canvas.clearListRows();
        const end = @min(images_list.len, current_start + visible);
        var index = current_start;
        while (index < end) : (index += 1) drawImageRow(canvas, images_list, index, current_start, index == current);
        return;
    }
    drawImageRow(canvas, images_list, previous, current_start, false);
    drawImageRow(canvas, images_list, current, current_start, true);
}

fn drawImageRow(canvas: Canvas, images_list: *const catalog.ImageList, index: usize, start: usize, selected: bool) void {
    const image = images_list.items[index];
    var name_buffer: [160]u8 = undefined;
    const value = std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ kindPrefix(image.kind), image.name.slice() }) catch image.name.slice();
    canvas.listRow(index - start, Row{
        .value = value,
        .selected = selected,
    });
}

pub fn methods(session: *const vbe_probe.Session, image_name: []const u8, model: *const boot_method_model.List, selected: usize) void {
    menu_pointer.configure(session.surface, false, model.len, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList("BOOT METHOD", image_name, firmware_label, headerStatus(&clock_buffer));
    const visible = canvas.visibleRows();
    const start = graphics.menu_canvas.listStart(selected, model.len, visible);
    const end = @min(model.len, start + visible);
    var index = start;
    while (index < end) : (index += 1) drawMethodRow(canvas, model, index, start, index == selected);
    const current = &model.items[selected];
    canvas.listHelp(current.help.line1);
    canvas.footer("ARROWS/MOUSE - SELECT    ENTER/CLICK - USE METHOD    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS");
}

pub fn methodSelection(session: *const vbe_probe.Session, image_name: []const u8, model: *const boot_method_model.List, previous: usize, current: usize) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, model.len, current);
    const canvas = Canvas.init(session.surface, Theme{});
    const visible = canvas.visibleRows();
    const previous_start = graphics.menu_canvas.listStart(previous, model.len, visible);
    const current_start = graphics.menu_canvas.listStart(current, model.len, visible);
    if (previous_start != current_start) {
        _ = image_name;
        canvas.clearListRows();
        const end = @min(model.len, current_start + visible);
        var index = current_start;
        while (index < end) : (index += 1) drawMethodRow(canvas, model, index, current_start, index == current);
        canvas.listHelp(model.items[current].help.line1);
        return;
    }
    drawMethodRow(canvas, model, previous, current_start, false);
    drawMethodRow(canvas, model, current, current_start, true);
    canvas.listHelp(model.items[current].help.line1);
}

fn drawMethodRow(canvas: Canvas, model: *const boot_method_model.List, index: usize, start: usize, selected: bool) void {
    const item = &model.items[index];
    canvas.listRow(index - start, Row{
        .value = item.label.slice(),
        .detail = item.detail(),
        .selected = selected,
        .unavailable = !item.enabled,
    });
}

pub fn unattended(
    session: *const vbe_probe.Session,
    system_name: []const u8,
    file_kind_label: []const u8,
    options: []const ?[]const u8,
    selected: usize,
) void {
    menu_pointer.configure(session.surface, false, options.len, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    var subtitle_buffer: [128]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buffer, "{s} - {s}", .{ system_name, file_kind_label }) catch system_name;
    canvas.beginList("UNATTENDED", subtitle, firmware_label, headerStatus(&clock_buffer));
    const visible = canvas.visibleRows();
    const start = graphics.menu_canvas.listStart(selected, options.len, visible);
    const end = @min(options.len, start + visible);
    var index = start;
    while (index < end) : (index += 1) drawUnattendedRow(canvas, options, index, start, index == selected);
    drawUnattendedHelp(canvas, options[selected]);
    canvas.footer("ARROWS/MOUSE - SELECT    ENTER/CLICK - USE    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS");
}

pub fn unattendedSelection(
    session: *const vbe_probe.Session,
    system_name: []const u8,
    file_kind_label: []const u8,
    options: []const ?[]const u8,
    previous: usize,
    current: usize,
) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, options.len, current);
    const canvas = Canvas.init(session.surface, Theme{});
    const visible = canvas.visibleRows();
    const previous_start = graphics.menu_canvas.listStart(previous, options.len, visible);
    const current_start = graphics.menu_canvas.listStart(current, options.len, visible);
    if (previous_start != current_start) {
        _ = system_name;
        _ = file_kind_label;
        canvas.clearListRows();
        const end = @min(options.len, current_start + visible);
        var index = current_start;
        while (index < end) : (index += 1) drawUnattendedRow(canvas, options, index, current_start, index == current);
        drawUnattendedHelp(canvas, options[current]);
        return;
    }
    drawUnattendedRow(canvas, options, previous, current_start, false);
    drawUnattendedRow(canvas, options, current, current_start, true);
    drawUnattendedHelp(canvas, options[current]);
}

fn drawUnattendedRow(canvas: Canvas, options: []const ?[]const u8, index: usize, start: usize, selected: bool) void {
    canvas.listRow(index - start, Row{
        .value = options[index] orelse "None",
        .detail = if (options[index] == null) "[manual/default]" else "[user file]",
        .selected = selected,
    });
}

fn drawUnattendedHelp(canvas: Canvas, option: ?[]const u8) void {
    canvas.listHelp(if (option == null)
        "Use the default setup options without a custom answer file."
    else
        "The selected answer file will be copied after target-safety validation.");
}

pub fn preparationStart(session: *const vbe_probe.Session) void {
    environmentStart(session, "STARTING WINDOWS INSTALLER");
}

pub fn environmentStart(session: *const vbe_probe.Session, title: []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList(title, "Legacy BIOS", firmware_label, headerStatus(&clock_buffer));
    canvas.listRow(0, .{
        .value = "LOADING ENVIRONMENT",
        .detail = "RUNNING",
        .selected = true,
    });
    canvas.progressBar(0, "Loading startup files - 0%");
    canvas.footer("PLEASE WAIT");
}

pub fn preparationProgress(session: *const vbe_probe.Session, percent: u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var label_buffer: [80]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "Loading startup files - {d}%", .{percent}) catch "Loading startup files";
    canvas.progressBar(percent, label);
}

pub fn xpResume(session: *const vbe_probe.Session) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    const lines = [_][]const u8{
        "A Windows XP installation was prepared on a target disk.",
        "After Text Mode has copied files and restarted, press ENTER.",
        "USOS will verify that disk and restore its startup code.",
        "Then remove USOS and start the target disk to continue Setup.",
    };
    canvas.notice("WINDOWS XP - CONTINUE INSTALLATION", &lines, "ENTER - CONTINUE XP    ESC - USOS MENU");
}

pub fn windowsSetupStart(session: *const vbe_probe.Session) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList("STARTING WINDOWS SETUP", "Legacy BIOS", firmware_label, headerStatus(&clock_buffer));
    canvas.listRow(0, .{ .value = "READING INSTALLER FROM USB", .detail = "RUNNING", .selected = true });
    canvas.listHelp("Loading Windows Setup into memory. Keep the USB drive connected.");
    windowsSetupProgress(session, 0);
    canvas.footer("PLEASE WAIT - KEEP THE USB DRIVE CONNECTED");
}

pub fn windowsSetupProgress(session: *const vbe_probe.Session, percent: u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var label_buffer: [80]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "Loading Windows Setup - {d}%", .{percent}) catch "Loading Windows Setup";
    canvas.progressBar(percent, label);
}

pub fn windowsSetupFailure(session: *const vbe_probe.Session, error_name: []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    const lines = [_][]const u8{
        "Windows Setup could not be loaded.",
        error_name,
        "The prepared installation files have been kept on the USB drive.",
        "Restart to retry, or press ESC to return to the USOS menu.",
    };
    canvas.notice("WINDOWS SETUP - START FAILED", &lines, "ESC - USOS MENU");
}

pub fn backendFailure(session: *const vbe_probe.Session, method_label: []const u8, error_name: []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var heading: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&heading, "BOOT METHOD FAILED: {s}", .{method_label}) catch "BOOT METHOD FAILED";
    const lines = [_][]const u8{
        "The selected Legacy backend returned an error.",
        error_name,
    };
    canvas.notice(title, &lines, footer_notice);
}

pub fn noUtilities(session: *const vbe_probe.Session) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    const lines = [_][]const u8{"No utility folders were found on this USOS media."};
    canvas.notice("UTILITIES", &lines, footer_notice);
}

pub fn missingImage(session: *const vbe_probe.Session, title: []const u8, path: []const u8) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    var heading: [96]u8 = undefined;
    const heading_text = std.fmt.bufPrint(&heading, "NO IMAGES: {s}", .{title}) catch "NO IMAGES";
    const lines = [_][]const u8{
        "No supported image files were found.",
        "Copy ISO/WIM/IMG/VHD/VHDX/EFI into:",
        path,
    };
    canvas.notice(heading_text, &lines, footer_notice);
}

pub fn power(session: *const vbe_probe.Session, selected: usize) void {
    menu_pointer.configure(session.surface, false, 2, selected);
    const canvas = Canvas.init(session.surface, Theme{});
    var clock_buffer: [26]u8 = undefined;
    canvas.beginList("POWER", "Restart or shut down this computer", firmware_label, headerStatus(&clock_buffer));
    drawPowerRow(canvas, 0, selected == 0);
    drawPowerRow(canvas, 1, selected == 1);
    canvas.footer("ARROWS/MOUSE - SELECT    ENTER/CLICK - RUN    ESC/RIGHT CLICK - BACK    D - DIAGNOSTICS");
}

pub fn powerSelection(session: *const vbe_probe.Session, previous: usize, current: usize) void {
    if (previous == current) return;
    menu_pointer.configure(session.surface, false, 2, current);
    const canvas = Canvas.init(session.surface, Theme{});
    drawPowerRow(canvas, previous, false);
    drawPowerRow(canvas, current, true);
}

fn drawPowerRow(canvas: Canvas, index: usize, selected: bool) void {
    canvas.listRow(index, .{ .value = if (index == 0) "Restart" else "Shut down", .selected = selected });
}

pub fn manualPowerOff(session: *const vbe_probe.Session) void {
    menu_pointer.configure(session.surface, false, 0, 0);
    const canvas = Canvas.init(session.surface, Theme{});
    const lines = [_][]const u8{
        "APM power-off is unavailable on this machine.",
        "Turn off the computer manually.",
    };
    canvas.notice("POWER", &lines, footer_notice);
}

fn headerStatus(buffer: *[26]u8) []const u8 {
    return rtc.formatHeader(buffer) orelse "";
}

fn categoryDescription(category: catalog.Category) []const u8 {
    return switch (category) {
        .windows => "Install and repair Microsoft Windows",
        .linux => "Linux installers and live systems",
        .beta => "Whistler, Longhorn and other builds",
        .dos => "DOS systems and legacy boot images",
        .utilities => "Diagnostics, recovery and firmware tools",
    };
}

fn categorySymbol(category: catalog.Category) []const u8 {
    return switch (category) {
        .windows => "W",
        .linux => "L",
        .beta => "B",
        .dos => "D",
        .utilities => "+",
    };
}

fn kindPrefix(kind: catalog.ImageKind) []const u8 {
    return switch (kind) {
        .iso => "[ISO] ",
        .wim => "[WIM] ",
        .img => "[IMG] ",
        .vhd => "[VHD] ",
        .vhdx => "[VHDX] ",
        .efi => "[EFI] ",
    };
}
