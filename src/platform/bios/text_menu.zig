const menu_pointer = @import("menu_pointer.zig");
const std = @import("std");
const catalog = @import("catalog");
const boot_method_model = catalog.boot_method_model;
const console = @import("console.zig");
const diagnostics = @import("diagnostics.zig");
const menu_telemetry = @import("menu_telemetry.zig");
const menu_policy = @import("menu_policy");
const legacy_boot_actions = @import("legacy_boot_actions.zig");
const power_menu = @import("power_menu.zig");
const graphics_menu = @import("graphics_menu.zig");
const vbe_probe = @import("vbe_probe.zig");

const scan_up: u8 = 0x48;
const scan_down: u8 = 0x50;
const scan_left: u8 = 0x4B;
const scan_right: u8 = 0x4D;
const category_count: usize = catalog.categories.all.len;
const power_index: usize = category_count;
const category_item_count: usize = category_count + 1;

pub fn runXpMenuAutoTest(
    discovery: *catalog.media_discovery.Discovery,
    diag: diagnostics.Info,
    actions: legacy_boot_actions.Context,
    graphics: *?vbe_probe.Session,
    select_none: bool,
) void {
    _ = diag;
    console.line("[LEGACY_MENU_TEST] BEGIN XP METHODS AUTO TEST");
    const system = catalog.systems.findById("windows-xp") orelse {
        console.line("[LEGACY_MENU_TEST] FAIL Windows XP catalog entry missing");
        return;
    };
    const media = discovery.mediaStatus(system.image_directory);
    if (!media.hasImages()) {
        console.line("[LEGACY_MENU_TEST] FAIL Windows XP has no images");
        return;
    }
    const images = discovery.images(system.image_directory);
    if (images.len == 0) {
        console.line("[LEGACY_MENU_TEST] FAIL Windows XP image listing empty");
        return;
    }
    const image = images.items[0];
    const model = boot_method_model.collect(system, image.kind, .bios);
    var automatic_index: ?usize = null;
    var chainload_index: ?usize = null;
    for (model.items[0..model.len], 0..) |item, index| {
        if (item.method == .automatic) automatic_index = index;
        if (item.method == .chainload) chainload_index = index;
    }
    const selected = automatic_index orelse {
        console.line("[LEGACY_MENU_TEST] FAIL Automatic method missing");
        return;
    };
    const single_enabled = model.singleEnabledIndex() orelse {
        console.line("[LEGACY_MENU_TEST] FAIL XP method screen would not be bypassed; enabled method count is not one");
        return;
    };
    if (single_enabled != selected) {
        console.line("[LEGACY_MENU_TEST] FAIL single enabled XP method is not Automatic");
        return;
    }
    const automatic = &model.items[selected];
    if (!automatic.enabled or automatic.backend == null or automatic.backend.? != .xp_staging) {
        console.line("[LEGACY_MENU_TEST] FAIL Automatic did not resolve to xp-staging");
        return;
    }
    console.line("[LEGACY_MENU_TEST] BOOT METHOD BYPASS PASS enabled=1 backend=xp-staging");
    console.line("[LEGACY_MENU_TEST] XP AUTOMATIC backend=xp-staging status=TESTED_IN_VM PASS");
    if (chainload_index) |index| {
        const chainload = &model.items[index];
        if (chainload.enabled) {
            console.line("[LEGACY_MENU_TEST] FAIL Chainload unexpectedly enabled in BIOS");
            return;
        }
        console.print("[LEGACY_MENU_TEST] CHAINLOAD DISABLED reason=");
        console.line(chainload.reason);
    } else {
        console.line("[LEGACY_MENU_TEST] FAIL Chainload method missing");
        return;
    }

    const unattended_directory = system.unattended_directory orelse {
        console.line("[LEGACY_MENU_TEST] FAIL XP unattended directory missing");
        return;
    };
    if (!std.mem.eql(u8, catalog.unattended_policy.extension(system), ".sif")) {
        console.line("[LEGACY_MENU_TEST] FAIL XP unattended extension is not .sif");
        return;
    }
    var sif_storage: [8]catalog.FixedText = undefined;
    const sif_count = discovery.listFilesWithExtension(unattended_directory, ".sif", sif_storage[0..]);
    if (sif_count != 1 or !std.ascii.eqlIgnoreCase(sif_storage[0].slice(), "safe.sif")) {
        console.line("[LEGACY_MENU_TEST] FAIL expected exactly safe.sif in XP unattended catalog");
        return;
    }
    const test_unattended_name: ?[]const u8 = if (select_none) null else "safe.sif";
    var unattended_options: [2]?[]const u8 = .{ null, "safe.sif" };
    renderUnattended(system, unattended_options[0..], if (select_none) 0 else 1, graphics);
    console.line(if (select_none)
        "[LEGACY_MENU_TEST] UNATTENDED SCREEN PASS extension=.sif discovered=safe.sif selected=None"
    else
        "[LEGACY_MENU_TEST] UNATTENDED SCREEN PASS extension=.sif selected=safe.sif");

    legacy_boot_actions.execute(actions, automatic.backend.?, system.id, image.name.slice(), test_unattended_name, graphics.*) catch |err| {
        console.print("[LEGACY_MENU_TEST] FAIL backend error=");
        console.line(@errorName(err));
        return;
    };
}

pub fn run(discovery: *catalog.media_discovery.Discovery, diag: diagnostics.Info, actions: legacy_boot_actions.Context, initial_graphics: ?vbe_probe.Session) noreturn {
    var graphics = initial_graphics;
    if (graphics) |session| {
        console.print("VESA-2 MENU ACTIVE ");
        console.printU32(session.surface.framebuffer.width);
        console.put('x');
        console.printU32(session.surface.framebuffer.height);
        console.line("");
    } else {
        console.line("VESA-2 TEXT FALLBACK ACTIVE");
    }
    var selected_category: usize = 0;
    var full_redraw = true;
    while (true) {
        menu_telemetry.setSelection(.categories, selected_category);
        if (full_redraw) {
            renderCategories(&graphics, selected_category);
            full_redraw = false;
        }
        const key = readMenuKey(&graphics);
        if (key.selection != 255) {
            const index: usize = key.selection;
            updateCategorySelection(&graphics, &selected_category, index);
        }
        menu_telemetry.recordKey(.categories, selected_category, key);
        if (isDiagnosticsKey(key.ascii)) {
            _ = showDiagnostics(&graphics, diag);
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) {
            updateCategorySelection(&graphics, &selected_category, power_index);
            continue;
        }
        if (key.scan == scan_up) {
            const next = if (graphics != null) moveCategoryVertical(selected_category, false) else previousIndex(selected_category, category_item_count);
            updateCategorySelection(&graphics, &selected_category, next);
            continue;
        }
        if (key.scan == scan_down) {
            const next = if (graphics != null) moveCategoryVertical(selected_category, true) else nextIndex(selected_category, category_item_count);
            updateCategorySelection(&graphics, &selected_category, next);
            continue;
        }
        if (key.scan == scan_left) {
            const next = if (graphics != null) moveCategoryHorizontal(selected_category, false) else previousIndex(selected_category, category_item_count);
            updateCategorySelection(&graphics, &selected_category, next);
            continue;
        }
        if (key.scan == scan_right) {
            const next = if (graphics != null) moveCategoryHorizontal(selected_category, true) else nextIndex(selected_category, category_item_count);
            updateCategorySelection(&graphics, &selected_category, next);
            continue;
        }
        if (key.ascii != 13) continue;
        if (selected_category == power_index) {
            power_menu.show(diag, &graphics);
            full_redraw = true;
            continue;
        }
        const category = catalog.categories.all[selected_category];
        if (category == .utilities) {
            showUtilities(discovery, diag, actions, &graphics);
        } else {
            showSystems(discovery, diag, actions, category, &graphics);
        }
        full_redraw = true;
    }
}

fn updateCategorySelection(graphics: *?vbe_probe.Session, selected: *usize, next: usize) void {
    if (selected.* == next) return;
    const previous = selected.*;
    selected.* = next;
    if (graphics.*) |*session| {
        graphics_menu.categorySelection(session, previous, next);
    } else {
        renderCategories(graphics, next);
    }
}

fn renderCategories(graphics: *?vbe_probe.Session, selected: usize) void {
    if (graphics.*) |*session| {
        graphics_menu.categories(session, selected);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.line("FIRMWARE: BIOS");
    console.line("");
    console.line("CATEGORIES");
    for (catalog.categories.all, 0..) |category, index| {
        console.print(if (index == selected) "> " else "  ");
        console.line(category.label());
    }
    console.print(if (selected == power_index) "> " else "  ");
    console.line("POWER");
    console.line("");
    console.line("ARROWS: MOVE   ENTER: OPEN   ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
}

fn showSystems(discovery: *catalog.media_discovery.Discovery, diag: diagnostics.Info, actions: legacy_boot_actions.Context, category: catalog.Category, graphics: *?vbe_probe.Session) void {
    const count = catalog.systems.countInCategory(category);
    if (count == 0) return;
    var navigable: [catalog.systems.all.len]bool = [_]bool{false} ** catalog.systems.all.len;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = catalog.systems.byCategoryIndex(category, index) orelse continue;
        const media = discovery.mediaStatus(entry.image_directory);
        navigable[index] = (menu_policy.Access{
            .firmware_compatible = entry.firmware.accepts(.bios),
            .has_images = media.hasImages(),
        }).navigable();
    }
    diagnostics.captureAfterDiscovery(diag);
    var selected = firstNavigable(navigable[0..count]) orelse 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;

    while (true) {
        menu_telemetry.setSelection(.systems, selected);
        if (full_redraw) {
            renderSystems(discovery, category, selected, count, graphics);
            full_redraw = false;
        }
        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return;
        if (key.selection != 255) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.systemSelection(session, discovery, category, previous, selected, count) else full_redraw = true;
        }
        menu_telemetry.recordKey(.systems, selected, key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return;
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return;
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = moveNavigable(navigable[0..count], selected, key.scan == scan_down);
            if (graphics.*) |*session| {
                graphics_menu.systemSelection(session, discovery, category, previous, selected, count);
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii != 13) continue;
        const entry = catalog.systems.byCategoryIndex(category, selected) orelse continue;
        const media = discovery.mediaStatus(entry.image_directory);
        switch ((menu_policy.Access{
            .firmware_compatible = entry.firmware.accepts(.bios),
            .has_images = media.hasImages(),
        }).activation()) {
            // Selectable so the badge can be read; never launched here.
            .firmware_mismatch => {
                showFirmwareMismatchNotice(diag, entry, graphics);
                full_redraw = true;
                continue;
            },
            .secure_boot_off_required => continue,
            .no_image => {
                showMissingImageNotice(diag, entry.name, entry.image_directory, graphics);
                full_redraw = true;
                continue;
            },
            .backend_unavailable => continue,
            .open => {
                if (showSystemImages(discovery, diag, actions, entry, graphics)) return;
                full_redraw = true;
            },
        }
    }
}

fn renderSystems(discovery: *catalog.media_discovery.Discovery, category: catalog.Category, selected: usize, count: usize, graphics: *?vbe_probe.Session) void {
    if (graphics.*) |*session| {
        graphics_menu.systems(session, discovery, category, selected, count);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.print("FIRMWARE: BIOS   CATEGORY: ");
    console.line(category.label());
    console.line("");
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry = catalog.systems.byCategoryIndex(category, index) orelse continue;
        const media = discovery.mediaStatus(entry.image_directory);
        console.print(if (index == selected) "> " else "  ");
        console.print(entry.name);
        if (!entry.firmware.accepts(.bios)) {
            console.print(" ");
            console.print(entry.firmware.mismatchReason(.bios));
        } else if (!media.hasImages()) {
            console.print(" [no image]");
        } else {
            console.print(" [images=");
            console.printU32(@intCast(media.imageCount()));
            console.put(']');
        }
        console.line("");
    }
    console.line("");
    console.line("ARROWS: MOVE   ENTER: OPEN   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
}

fn showUtilities(discovery: *catalog.media_discovery.Discovery, diag: diagnostics.Info, actions: legacy_boot_actions.Context, graphics: *?vbe_probe.Session) void {
    var utilities = catalog.utility_catalog.List{};
    catalog.utility_catalog.discover(discovery, &utilities);
    utilities.appendHardware();
    utilities.appendFreeDos();

    diagnostics.captureAfterDiscovery(diag);
    var selected: usize = 0;
    var index: usize = 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;
    while (true) {
        menu_telemetry.setSelection(.utilities, selected);
        if (full_redraw) {
            if (graphics.*) |*session| {
                graphics_menu.utilities(session, discovery, &utilities, selected);
            } else {
                console.clear();
                console.line("UNIVERSAL SERVICE OS");
                console.line("FIRMWARE: BIOS   CATEGORY: Utilities");
                console.line("");
                index = 0;
                while (index < utilities.len) : (index += 1) {
                    const item = &utilities.items[index];
                    if (item.builtin != .none) {
                        console.print(if (index == selected) "> " else "  ");
                        console.line(if (item.builtin == .hardware) "Hardware & SMART [built-in, 64-bit CPU]" else "FreeDOS [built-in, DOS programs from USB]");
                        continue;
                    }
                    const media = discovery.mediaStatus(item.imageDirectory());
                    console.print(if (index == selected) "> " else "  ");
                    console.print(item.name.slice());
                    if (!media.hasImages()) {
                        console.print(" [no image]");
                    } else {
                        console.print(" [images=");
                        console.printU32(@intCast(media.imageCount()));
                        console.put(']');
                    }
                    console.line("");
                }
                console.line("");
                console.line("ARROWS: MOVE   ENTER: OPEN   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
            }
            full_redraw = false;
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return;
        if (key.selection != 255) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.utilitySelection(session, discovery, &utilities, previous, selected) else full_redraw = true;
        }
        menu_telemetry.recordKey(.utilities, selected, key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return;
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return;
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = if (key.scan == scan_down) nextIndex(selected, utilities.len) else previousIndex(selected, utilities.len);
            if (graphics.*) |*session| {
                graphics_menu.utilitySelection(session, discovery, &utilities, previous, selected);
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii != 13) continue;
        const item = &utilities.items[selected];
        if (item.builtin == .freedos) {
            @import("freedos_tools.zig").run(actions.esp_fs, actions.reader, actions.bulk_reader, graphics.*) catch |err| {
                showBackendFailureNotice(diag, "FreeDOS tools", err, graphics);
            };
            full_redraw = true;
            continue;
        }
        if (item.builtin == .hardware) {
            @import("linux_load_probe.zig").runHardware(actions.esp_fs, actions.reader, actions.bulk_reader, actions.esp_part_guid_disk, graphics.*) catch |err| {
                showBackendFailureNotice(diag, "Hardware & SMART (64-bit CPU)", err, graphics);
            };
            full_redraw = true;
            continue;
        }
        const media = discovery.mediaStatus(item.imageDirectory());
        switch ((menu_policy.Access{
            .firmware_compatible = true,
            .has_images = media.hasImages(),
        }).activation()) {
            .no_image => {
                showMissingImageNotice(diag, item.name.slice(), item.imageDirectory(), graphics);
                full_redraw = true;
                continue;
            },
            .open => {
                if (showImages(discovery, diag, actions, item.name.slice(), item.imageDirectory(), graphics)) return;
                full_redraw = true;
            },
            .firmware_mismatch, .secure_boot_off_required, .backend_unavailable => continue,
        }
    }
}

fn showFirmwareMismatchNotice(diag: diagnostics.Info, entry: *const catalog.SystemEntry, graphics: *?vbe_probe.Session) void {
    var idle_ticks: u32 = 0;
    while (true) {
        if (graphics.*) |*session| {
            graphics_menu.firmwareMismatch(session, entry.name, entry.firmware == .uefi);
        } else {
            console.clear();
            console.line("UNIVERSAL SERVICE OS");
            console.line("FIRMWARE: BIOS");
            console.line("");
            console.print(entry.name);
            console.print(" ");
            console.line(entry.firmware.mismatchReason(.bios));
            console.line("");
            console.line("Start the USB stick in UEFI mode to use this system.");
            console.line("");
            console.line("ENTER/ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return;
        if (isDiagnosticsKey(key.ascii)) {
            _ = showDiagnostics(graphics, diag);
            continue;
        }
        if (key.ascii == 13 or key.ascii == 27 or key.ascii == 8) return;
    }
}

fn showMissingImageNotice(diag: diagnostics.Info, title: []const u8, directory_path: []const u8, graphics: *?vbe_probe.Session) void {
    var idle_ticks: u32 = 0;
    while (true) {
        if (graphics.*) |*session| {
            graphics_menu.missingImage(session, title, menu_policy.displayImagePath(directory_path));
        } else {
            console.clear();
            console.line("UNIVERSAL SERVICE OS");
            console.line("FIRMWARE: BIOS");
            console.line("");
            console.print("NO IMAGES: ");
            console.line(title);
            console.line("");
            console.line("No supported image files were found.");
            console.line("Copy ISO/WIM/IMG/VHD/VHDX/EFI into:");
            console.line(menu_policy.displayImagePath(directory_path));
            console.line("");
            console.line("ENTER/ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return;
        if (isDiagnosticsKey(key.ascii)) {
            _ = showDiagnostics(graphics, diag);
            continue;
        }
        if (key.ascii == 13 or key.ascii == 27 or key.ascii == 8) return;
    }
}

fn showSystemImages(
    discovery: *catalog.media_discovery.Discovery,
    diag: diagnostics.Info,
    actions: legacy_boot_actions.Context,
    system: *const catalog.SystemEntry,
    graphics: *?vbe_probe.Session,
) bool {
    const images = discovery.images(system.image_directory);
    if (images.len == 0) return false;
    var selected: usize = 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;
    while (true) {
        menu_telemetry.setSelection(.images, selected);
        if (full_redraw) {
            if (graphics.*) |*session| {
                graphics_menu.systemImages(session, system.name, &images, selected);
            } else {
                console.clear();
                console.line("UNIVERSAL SERVICE OS");
                console.print("FIRMWARE: BIOS   IMAGES: ");
                console.line(system.name);
                console.line("");
                for (images.items[0..images.len], 0..) |image, index| {
                    console.print(if (index == selected) "> " else "  ");
                    console.print(kindPrefix(image.kind));
                    console.line(image.name.slice());
                }
                console.line("");
                console.line("ARROWS: MOVE   ENTER: BOOT METHOD   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
            }
            full_redraw = false;
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return true;
        if (key.selection != 255) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.imageSelection(session, system.name, &images, previous, selected, true) else full_redraw = true;
        }
        menu_telemetry.recordKey(.images, selected, key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return true;
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return false;
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = if (key.scan == scan_down) nextIndex(selected, images.len) else previousIndex(selected, images.len);
            if (graphics.*) |*session| {
                graphics_menu.imageSelection(session, system.name, &images, previous, selected, true);
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii != 13) continue;
        if (showMethods(discovery, diag, actions, system, images.items[selected], graphics)) return true;
        full_redraw = true;
    }
}

fn showMethods(
    discovery: *catalog.media_discovery.Discovery,
    diag: diagnostics.Info,
    actions: legacy_boot_actions.Context,
    system: *const catalog.SystemEntry,
    image: catalog.ImageItem,
    graphics: *?vbe_probe.Session,
) bool {
    const model = boot_method_model.collect(system, image.kind, .bios);
    if (model.len == 0) return false;
    if (model.singleEnabledIndex()) |index| {
        return executeMethodChoice(discovery, diag, actions, system, image, &model.items[index], graphics);
    }
    // Only methods that can run here are offered; the rest are not shown.
    var runnable_storage: [boot_method_model.max_items]usize = undefined;
    var runnable_count: usize = 0;
    for (model.items[0..model.len], 0..) |item, index| {
        if (!item.enabled) continue;
        runnable_storage[runnable_count] = index;
        runnable_count += 1;
    }
    if (runnable_count == 0) return false;
    const runnable = runnable_storage[0..runnable_count];
    var selected: usize = 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;

    while (true) {
        menu_telemetry.setSelection(.methods, runnable[selected]);
        if (full_redraw) {
            renderMethods(&model, runnable, image, selected, graphics);
            full_redraw = false;
        }
        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return true;
        if (key.selection != 255 and key.selection < runnable.len) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.methodSelection(session, image.name.slice(), &model, runnable, previous, selected) else full_redraw = true;
        }
        menu_telemetry.recordKey(.methods, runnable[selected], key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return true;
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return false;
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = if (key.scan == scan_down) nextIndex(selected, runnable.len) else previousIndex(selected, runnable.len);
            if (graphics.*) |*session| {
                graphics_menu.methodSelection(session, image.name.slice(), &model, runnable, previous, selected);
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii != 13) continue;
        if (executeMethodChoice(discovery, diag, actions, system, image, &model.items[runnable[selected]], graphics)) return true;
        full_redraw = true;
    }
}

fn executeMethodChoice(
    discovery: *catalog.media_discovery.Discovery,
    diag: diagnostics.Info,
    actions: legacy_boot_actions.Context,
    system: *const catalog.SystemEntry,
    image: catalog.ImageItem,
    item: *const boot_method_model.Item,
    graphics: *?vbe_probe.Session,
) bool {
    const backend = item.backend orelse return false;
    const unattended_name = if ((backend == .xp_staging or backend == .windows_bios_iso) and system.unattended_directory != null) blk: {
        const choice = showUnattended(discovery, diag, system, graphics);
        if (choice.back) return false;
        break :blk choice.path;
    } else null;
    legacy_boot_actions.execute(actions, backend, system.id, image.name.slice(), unattended_name, graphics.*) catch |err| {
        showBackendFailureNotice(diag, item.label.slice(), err, graphics);
        return false;
    };
    return true;
}

const UnattendedChoice = struct {
    back: bool = false,
    path: ?[]const u8 = null,
};

fn showUnattended(
    discovery: *catalog.media_discovery.Discovery,
    diag: diagnostics.Info,
    system: *const catalog.SystemEntry,
    graphics: *?vbe_probe.Session,
) UnattendedChoice {
    const directory = system.unattended_directory orelse return .{};
    var file_storage: [8]catalog.FixedText = undefined;
    var options: [9]?[]const u8 = .{ null, null, null, null, null, null, null, null, null };
    const extension = catalog.unattended_policy.extension(system);
    const found = discovery.listFilesWithExtension(directory, extension, file_storage[0..]);
    // Without answer files there is nothing to choose: skip the screen.
    if (found == 0) return .{};
    var index: usize = 0;
    while (index < found) : (index += 1) options[index + 1] = file_storage[index].slice();
    const len = found + 1;
    var selected: usize = 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;

    while (true) {
        menu_telemetry.setSelection(.unattended, selected);
        if (full_redraw) {
            renderUnattended(system, options[0..len], selected, graphics);
            full_redraw = false;
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return .{ .back = true };
        if (key.selection != 255) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.unattendedSelection(session, system.name, catalog.unattended_policy.fileKindLabel(system), options[0..len], previous, selected) else full_redraw = true;
        }
        menu_telemetry.recordKey(.unattended, selected, key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return .{ .back = true };
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return .{ .back = true };
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = if (key.scan == scan_down) nextIndex(selected, len) else previousIndex(selected, len);
            if (graphics.*) |*session| {
                graphics_menu.unattendedSelection(
                    session,
                    system.name,
                    catalog.unattended_policy.fileKindLabel(system),
                    options[0..len],
                    previous,
                    selected,
                );
            } else {
                full_redraw = true;
            }
            continue;
        }
        if (key.ascii == 13) return .{ .path = options[selected] };
    }
}

fn renderUnattended(system: *const catalog.SystemEntry, options: []const ?[]const u8, selected: usize, graphics: *?vbe_probe.Session) void {
    if (graphics.*) |*session| {
        graphics_menu.unattended(session, system.name, catalog.unattended_policy.fileKindLabel(system), options, selected);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.line("FIRMWARE: BIOS   UNATTENDED");
    console.print("SYSTEM: ");
    console.line(system.name);
    console.print("ANSWER FILE: ");
    console.line(catalog.unattended_policy.fileKindLabel(system));
    console.line("");
    for (options, 0..) |option, row| {
        console.print(if (row == selected) "> " else "  ");
        console.line(option orelse "None");
    }
    console.line("");
    if (options[selected] == null) {
        console.line("Use the default setup options without a custom answer file.");
    } else {
        console.line("The selected answer file will be copied after target-safety validation.");
    }
    console.line("");
    console.line("ARROWS: MOVE   ENTER: USE   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
}

fn renderMethods(model: *const boot_method_model.List, runnable: []const usize, image: catalog.ImageItem, selected: usize, graphics: *?vbe_probe.Session) void {
    if (graphics.*) |*session| {
        graphics_menu.methods(session, image.name.slice(), model, runnable, selected);
        return;
    }
    console.clear();
    console.line("UNIVERSAL SERVICE OS");
    console.line("FIRMWARE: BIOS   BOOT METHOD");
    console.print("IMAGE: ");
    console.line(image.name.slice());
    console.line("");
    for (runnable, 0..) |index, row| {
        console.print(if (row == selected) "> " else "  ");
        console.line(textLabel(&model.items[index]));
    }
    const current = &model.items[runnable[selected]];
    console.line("");
    console.line(current.help.title);
    console.line(current.help.line1);
    console.line(current.help.line2);
    if (current.validation_status == .tested_in_vm) console.line("Tested in a virtual machine");
    console.line("");
    console.line("ARROWS: MOVE   ENTER: SELECT   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
}

/// The method label without the "[TESTED IN VM]" suffix: the details
/// below the list say where the method was verified.
fn textLabel(item: *const boot_method_model.Item) []const u8 {
    const text = item.label.slice();
    const suffix = if (item.validation_status) |status| status.badge() else "";
    if (suffix.len == 0 or !std.mem.endsWith(u8, text, suffix)) return text;
    return std.mem.trimEnd(u8, text[0 .. text.len - suffix.len], " ");
}

fn showBackendFailureNotice(diag: diagnostics.Info, method_label: []const u8, err: anyerror, graphics: *?vbe_probe.Session) void {
    var idle_ticks: u32 = 0;
    while (true) {
        if (graphics.*) |*session| {
            graphics_menu.backendFailure(session, method_label, @errorName(err));
        } else {
            console.clear();
            console.line("UNIVERSAL SERVICE OS");
            console.line("FIRMWARE: BIOS");
            console.line("");
            console.print("BOOT METHOD FAILED: ");
            console.line(method_label);
            console.print("ERROR: ");
            console.line(@errorName(err));
            console.line("");
            console.line("ENTER/ESC/BACKSPACE: BACK   D: DIAGNOSTICS");
        }
        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return;
        if (isDiagnosticsKey(key.ascii)) {
            _ = showDiagnostics(graphics, diag);
            continue;
        }
        if (key.ascii == 13 or key.ascii == 27 or key.ascii == 8) return;
    }
}

fn showImages(discovery: *catalog.media_discovery.Discovery, diag: diagnostics.Info, actions: legacy_boot_actions.Context, title: []const u8, directory_path: []const u8, graphics: *?vbe_probe.Session) bool {
    const images = discovery.images(directory_path);
    if (images.len == 0) return false;
    var selected: usize = 0;
    var idle_ticks: u32 = 0;
    var full_redraw = true;
    while (true) {
        menu_telemetry.setSelection(.images, selected);
        if (full_redraw) {
            if (graphics.*) |*session| {
                graphics_menu.images(session, title, &images, selected);
            } else {
                console.clear();
                console.line("UNIVERSAL SERVICE OS");
                console.print("FIRMWARE: BIOS   IMAGES: ");
                console.line(title);
                console.line("");
                for (images.items[0..images.len], 0..) |image, index| {
                    console.print(if (index == selected) "> " else "  ");
                    console.print(kindPrefix(image.kind));
                    console.line(image.name.slice());
                }
                console.line("");
                console.line("ARROWS: MOVE   ENTER: RUN   ESC/BACKSPACE: BACK   D: DIAGNOSTICS   AUTO-RETURN: 30s");
            }
            full_redraw = false;
        }

        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return true;
        if (key.selection != 255) {
            const previous = selected;
            selected = key.selection;
            if (graphics.*) |*session| graphics_menu.imageSelection(session, title, &images, previous, selected, false) else full_redraw = true;
        }
        menu_telemetry.recordKey(.images, selected, key);
        if (isDiagnosticsKey(key.ascii)) {
            if (showDiagnostics(graphics, diag)) return true;
            full_redraw = true;
            continue;
        }
        if (key.ascii == 27 or key.ascii == 8) return false;
        if (key.scan == scan_up or key.scan == scan_down) {
            const previous = selected;
            selected = if (key.scan == scan_down) nextIndex(selected, images.len) else previousIndex(selected, images.len);
            if (graphics.*) |*session| {
                graphics_menu.imageSelection(session, title, &images, previous, selected, false);
            } else {
                full_redraw = true;
            }
        }
        if (key.ascii == 13) {
            @import("memtest_native_iso.zig").run(actions.reader, actions.bulk_reader, title, images.items[selected], graphics.*) catch |err| {
                showBackendFailureNotice(diag, "Memtest86+ i586 ISO", err, graphics);
            };
            full_redraw = true;
        }
    }
}

fn waitBackOrDiagnostics(diag: diagnostics.Info, graphics: *?vbe_probe.Session) bool {
    var idle_ticks: u32 = 0;
    while (true) {
        menu_telemetry.setSelection(.utilities, 0);
        const key = readTimedKey(diag, &idle_ticks, graphics) orelse return true;
        menu_telemetry.recordKey(.utilities, 0, key);
        if (isDiagnosticsKey(key.ascii)) return showDiagnostics(graphics, diag);
        if (key.ascii == 27 or key.ascii == 8 or key.ascii == 13) return false;
    }
}

fn showDiagnostics(graphics: *?vbe_probe.Session, diag: diagnostics.Info) bool {
    if (graphics.*) |*session| {
        session.enterText();
        const result = diagnostics.show(diag);
        if (session.restore()) {
            console.line("VESA-2 GRAPHICS RESTORED");
        } else {
            graphics.* = null;
            console.line("VESA-2 GRAPHICS RESTORE FAILED - TEXT FALLBACK ACTIVE");
        }
        return result;
    }
    return diagnostics.show(diag);
}

fn readMenuKey(graphics: *?vbe_probe.Session) console.Key {
    if (graphics.* == null) {
        menu_pointer.stopListening();
        return console.readKey();
    }
    menu_pointer.listen();
    defer menu_pointer.stopListening();
    while (true) {
        if (console.readKeyTimeoutTicks(18)) |key| return key;
        if (graphics.*) |*session| {
            menu_pointer.hide();
            graphics_menu.refreshClock(session);
            menu_pointer.listen();
        }
    }
}

fn readTimedKey(diag: diagnostics.Info, idle_ticks: *u32, graphics: *?vbe_probe.Session) ?console.Key {
    if (graphics.* != null) menu_pointer.listen() else menu_pointer.stopListening();
    defer menu_pointer.stopListening();
    while (idle_ticks.* < diagnostics.key_timeout_ticks) {
        const remaining = diagnostics.key_timeout_ticks - idle_ticks.*;
        const slice = @min(remaining, @as(u32, 18));
        if (console.readKeyTimeoutTicks(slice)) |key| {
            idle_ticks.* = 0;
            return key;
        }
        idle_ticks.* += slice;
        if (graphics.*) |*session| {
            menu_pointer.hide();
            graphics_menu.refreshClock(session);
            menu_pointer.listen();
        }
    }
    diagnostics.captureTimeout(diag);
    idle_ticks.* = 0;
    return null;
}

fn isDiagnosticsKey(ascii: u8) bool {
    return ascii == 'd' or ascii == 'D';
}

fn firstNavigable(navigable: []const bool) ?usize {
    for (navigable, 0..) |value, index| if (value) return index;
    return null;
}

fn moveNavigable(navigable: []const bool, current: usize, forward: bool) usize {
    if (navigable.len == 0) return current;
    var candidate = current;
    var attempts: usize = 0;
    while (attempts < navigable.len) : (attempts += 1) {
        candidate = if (forward) nextIndex(candidate, navigable.len) else previousIndex(candidate, navigable.len);
        if (navigable[candidate]) return candidate;
    }
    return current;
}

fn moveCategoryHorizontal(current: usize, forward: bool) usize {
    if (!forward) return if (current % 2 == 1) current - 1 else current;
    return if (current % 2 == 0 and current + 1 < category_item_count) current + 1 else current;
}

fn moveCategoryVertical(current: usize, forward: bool) usize {
    if (!forward) return if (current >= 2) current - 2 else current;
    return if (current + 2 < category_item_count) current + 2 else current;
}

fn nextIndex(current: usize, count: usize) usize {
    if (count == 0) return 0;
    return if (current + 1 < count) current + 1 else 0;
}

fn previousIndex(current: usize, count: usize) usize {
    if (count == 0) return 0;
    return if (current == 0) count - 1 else current - 1;
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

test "selection skips only non-navigable firmware rows" {
    const navigable = [_]bool{ false, true, true, true };
    try std.testing.expectEqual(@as(?usize, 1), firstNavigable(&navigable));
    try std.testing.expectEqual(@as(usize, 2), moveNavigable(&navigable, 1, true));
    try std.testing.expectEqual(@as(usize, 3), moveNavigable(&navigable, 2, true));
    try std.testing.expectEqual(@as(usize, 1), moveNavigable(&navigable, 3, true));
}

test "graphical categories follow the same 2-column geometry as UEFI" {
    try std.testing.expectEqual(@as(usize, 1), moveCategoryHorizontal(0, true));
    try std.testing.expectEqual(@as(usize, 0), moveCategoryHorizontal(1, false));
    try std.testing.expectEqual(@as(usize, 2), moveCategoryVertical(0, true));
    try std.testing.expectEqual(@as(usize, 4), moveCategoryVertical(2, true));
    try std.testing.expectEqual(@as(usize, power_index), moveCategoryVertical(3, true));
}
