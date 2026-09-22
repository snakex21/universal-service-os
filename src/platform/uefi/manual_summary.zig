const usos = @import("usos");
const std = @import("std");
const e2e_flow = @import("e2e_flow.zig");
const esp_image_start = @import("esp_image_start.zig");
const input = @import("input.zig");
const view = @import("manual_view.zig");
const windows_native_iso = @import("windows_native_iso.zig");

pub fn show(
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    method: usos.catalog.BootMethod,
    unattended: ?[]const u8,
    firmware: usos.firmware.Firmware,
) void {
    if (!system.firmware.accepts(firmware)) return showFirmwareUnavailable(system.firmware.mismatchReason(firmware));
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable(method_firmware.mismatchReason(firmware));
    view.begin("summary", "Boot selection");
    view.writeText("System: ", system.name);
    view.writeText("Image: ", image.name.slice());
    view.writeText("Method: ", method.label());
    view.writeText("Unattended: ", unattended orelse "None");
    var start_row_index: usize = 4;
    var can_start = true;
    if (backend == .xp_uefi_staging) {
        view.writeText("Preparation: ", "UEFI; installed XP requires firmware CSM and MBR");
        view.writeText("Source: ", "XP SP3 x86; ACPI / SATA / USB drivers; optional PAE boot entry");
        view.writeText("Disk: ", "Selected and confirmed in the next graphical screen");
        start_row_index += 3;
        if (unattended != null) {
            can_start = false;
            view.row(false, "Custom unattended files are not supported on this XP UEFI path.");
            start_row_index += 1;
        }
    }
    const vista = std.mem.eql(u8, system.id, "windows-vista");
    if (image.kind == .iso and (vista or std.mem.eql(u8, system.id, "windows-7"))) {
        if (windows_native_iso.inspect(image.name.slice(), vista)) |inspection| {
            view.writeText("ISO case: ", if (vista) "Vista SP2 x64 -> PE10; target needs CSM enabled" else inspection.mode.label());
            view.writeText("Boot source ISO: ", inspection.bootName(image.name.slice()));
            var version_text: [96]u8 = undefined;
            const setup = inspection.boot_setup;
            view.writeText("Boot PE: ", std.fmt.bufPrint(&version_text, "{d}.{d}.{d} x64 / WIM index {d}", .{setup.major, setup.minor, setup.build, setup.index}) catch "Unavailable");
            view.writeText("USB: ", if (vista) "PE10 native USB; target uses Vista USB v11" else setup.usbLabel());
            start_row_index += 4;
            if (vista) {
                view.writeText("Target support: ", "KB2864202 + signed USB package + pre-Setup v11");
                if (unattended != null) can_start = false;
            } else if (windows_native_iso.externalDriverCount()) |count| {
                var count_text: [100]u8 = undefined;
                view.writeText("External drivers: ", if (count == 0) "None in Drivers/x64; target USB3 may be unavailable" else std.fmt.bufPrint(&count_text, "{d} INF files; Windows checks hardware match", .{count}) catch "Inventory unavailable");
            } else |err| {
                view.writeText("Driver inventory: ", @errorName(err));
            }
            start_row_index += 1;
        } else |err| {
            can_start = false;
            view.writeText("ISO inspection: ", @errorName(err));
            view.row(false, usos.windows7_iso.errorDetail(err));
            start_row_index += 2;
        }
    }
    view.row(can_start, if (can_start) actionLabel(image.kind, resolved) else "START BLOCKED - ESC TO RETURN");
    view.footer(true);

    while (true) switch (input.readBlocking()) {
        .enter => if (can_start) return start(root, system, image, method, unattended, firmware),
        .back => return,
        .pointer => |mouse| {
            if (mouse.right_click) return;
            if (can_start and mouse.left_click and view.hitRow(mouse.x, mouse.y, start_row_index + 1) == start_row_index) {
                return start(root, system, image, method, unattended, firmware);
            }
            if (mouse.moved) view.updatePointer();
        },
        else => {},
    };
}

fn start(
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    method: usos.catalog.BootMethod,
    unattended: ?[]const u8,
    firmware: usos.firmware.Firmware,
) void {
    if (!system.firmware.accepts(firmware)) return showFirmwareUnavailable(system.firmware.mismatchReason(firmware));
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable(method_firmware.mismatchReason(firmware));

    if (backend == .xp_uefi_staging) {
        view.handoffStatus("STARTING XP DISK SELECTION");
        @import("xp_preparation.zig").start(root, image.name.slice(), unattended) catch |err| {
            view.refreshFramebuffer();
            showError("XP preparation failed", err);
        };
        return;
    }
    if (image.kind == .efi and (resolved == .direct_efi or resolved == .chainload)) {
        view.begin("loading", "Starting EFI application");
        view.writeText("System: ", system.name);
        view.writeText("Image: ", image.name.slice());
        view.writeText("Method: ", resolved.label());
        view.row(false, "Transferring control through UEFI LoadImage/StartImage...");
        view.passiveFooter();
        esp_image_start.start(root, system.image_directory, image.name.slice()) catch |err| {
            showError("EFI start failed", err);
        };
        return;
    }

    const vista = std.mem.eql(u8, system.id, "windows-vista");
    if (image.kind == .iso and (vista or std.mem.eql(u8, system.id, "windows-7")) and resolved == .direct_iso) {
        view.windowsIsoStatus(.validating, "Reading the selected Windows ISO");
        windows_native_iso.start(root, image.name.slice(), unattended, vista, view.windowsIsoStatus) catch |err| {
            view.refreshFramebuffer();
            showError("Windows ISO start failed", err);
        };
        return;
    }

    view.handoffStatus("STARTING PREPARATION ENVIRONMENT");

    e2e_flow.requestPreparation(root, system, image, resolved, unattended, showPreparationProgress) catch |err| {
        showError("Preparation failed", err);
    };
}

fn actionLabel(kind: usos.catalog.ImageKind, resolved: usos.catalog.BootMethod) []const u8 {
    if (kind == .efi and (resolved == .direct_efi or resolved == .chainload)) return "PRESS ENTER OR CLICK HERE TO START THE EFI APPLICATION";
    return switch (resolved) {
        .chainload => "PRESS ENTER OR CLICK HERE TO PREPARE AND CHAINLOAD",
        .wimboot => "PRESS ENTER OR CLICK HERE TO BUILD AND BOOT THE WIM ENVIRONMENT",
        .vhdboot => "PRESS ENTER OR CLICK HERE TO PREPARE NATIVE VHD/VHDX BOOT",
        else => "PRESS ENTER OR CLICK HERE TO LOAD THE WINDOWS ISO",
    };
}

fn showFirmwareUnavailable(reason: []const u8) void {
    view.begin("summary", "Firmware mismatch");
    view.row(false, reason);
    view.row(false, "This selection cannot start in the current firmware mode.");
    view.footer(true);
}

fn showUnsupported() void {
    view.begin("summary", "Boot method unavailable");
    view.row(false, "The selected method has no executable backend.");
    view.footer(true);
}

fn showError(title: []const u8, err: anyerror) void {
    view.begin("summary", title);
    view.writeText("Error: ", @errorName(err));
    view.row(false, "The operation stopped safely. Inspect the serial log if needed.");
    view.footer(true);
    // Keep the failure visible instead of immediately redrawing the method menu.
    while (true) switch (input.readBlocking()) {
        .enter, .back => return,
        .pointer => |mouse| {
            if (mouse.left_click or mouse.right_click) return;
            if (mouse.moved) view.updatePointer();
        },
        else => {},
    };
}

fn showPreparationProgress(stage: usos.flow.preparation_boot_progress.Stage) void {
    view.handoffStatus(stage.detail());
}
