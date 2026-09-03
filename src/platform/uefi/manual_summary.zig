const usos = @import("usos");
const std = @import("std");
const e2e_flow = @import("e2e_flow.zig");
const esp_image_start = @import("esp_image_start.zig");
const input = @import("input.zig");
const view = @import("manual_view.zig");

const start_row_index: usize = 4;

pub fn show(
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    method: usos.catalog.BootMethod,
    unattended: ?[]const u8,
) void {
    const resolved = usos.flow.preparation_capability.resolve(system.id, image.kind, method) orelse return showUnsupported();
    view.begin("summary", "Boot selection");
    view.writeText("System: ", system.name);
    view.writeText("Image: ", image.name.slice());
    view.writeText("Method: ", method.label());
    view.writeText("Unattended: ", unattended orelse "None");
    view.row(true, actionLabel(image.kind, resolved));
    view.footer(true);

    while (true) switch (input.readBlocking()) {
        .enter => return start(root, system, image, method, unattended),
        .back => return,
        .pointer => |mouse| {
            if (mouse.right_click) return;
            if (mouse.left_click and view.hitRow(mouse.x, mouse.y, start_row_index + 1) == start_row_index) {
                return start(root, system, image, method, unattended);
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
) void {
    const resolved = usos.flow.preparation_capability.resolve(system.id, image.kind, method) orelse return showUnsupported();

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

    const title = switch (resolved) {
        .chainload => "Preparing chainload media",
        .wimboot => "Preparing WIM boot",
        .vhdboot => "Preparing native VHD boot",
        else => "Loading Windows ISO",
    };
    view.begin("loading", title);
    view.writeText("System: ", system.name);
    view.writeText("Image: ", image.name.slice());
    view.writeText("Method: ", resolved.label());
    view.writeText("Unattended: ", unattended orelse "None");
    view.handoffStatus("Preparing verified micro-Linux backend...");
    view.passiveFooter();

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
}

fn showPreparationProgress(stage: usos.flow.preparation_boot_progress.Stage) void {
    view.handoffStatus(stage.label());
}
