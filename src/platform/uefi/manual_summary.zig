//! Boot summary: shows only the settings that apply to this selection
//! (no "None" placeholder rows) and the start button.
const usos = @import("usos");
const std = @import("std");
const e2e_flow = @import("e2e_flow.zig");
const esp_image_start = @import("esp_image_start.zig");
const input = @import("input.zig");
const view = @import("manual_view.zig");
const windows_native_iso = @import("windows_native_iso.zig");
const secure_boot = @import("secure_boot.zig");
const manual_images = @import("manual_images.zig");
const manual_unattended = @import("manual_unattended.zig");
const xp_settings = @import("xp_settings.zig");

const Fields = struct {
    labels: [16][]const u8 = undefined,
    values: [16][]const u8 = undefined,
    count: usize = 0,

    fn add(self: *Fields, label: []const u8, value: []const u8) void {
        if (value.len == 0 or self.count == self.labels.len) return;
        self.labels[self.count] = label;
        self.values[self.count] = value;
        self.count += 1;
    }
};

pub fn show(
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    method: usos.catalog.BootMethod,
    unattended: ?[]const u8,
    answers_available: usize,
    firmware: usos.firmware.Firmware,
) void {
    if (!system.firmware.accepts(firmware)) return showFirmwareUnavailable();
    if (manual_images.blockReason(image)) |reason| return showMediaBlocked(image.name.slice(), reason);
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable();
    if (secure_boot.enforced() and usos.flow.secure_boot_policy.backendRequiresSecureBootOff(system.id, backend)) return showSecureBootRequired();

    var fields = Fields{};
    var notes: [2][]const u8 = undefined;
    var note_count: usize = 0;
    fields.add(view.t(.summary_system), system.name);
    fields.add(view.t(.summary_image), image.name.slice());
    fields.add(view.t(.summary_method), view.tr(method.label()));
    var no_answer_text: [160]u8 = undefined;
    var answer_text: [200]u8 = undefined;
    const settings_name = usos.catalog.os_profiles.traits(system.id).settings_file;
    if (backend == .xp_uefi_staging) {
        // XP UEFI-CSM: a .sif is merged into the automatic answer; without
        // one, usos-xp.ini (if active) makes Setup hands-off.
        if (unattended) |path| {
            fields.add(view.t(.summary_answer_file), view.format(&answer_text, .summary_xp_sif_merged, &.{path}));
        } else if (settings_name) |name| {
            if (system.unattended_directory) |directory| {
                const summary = xp_settings.read(directory, name);
                fields.add(view.t(.summary_answer_file), manual_unattended.settingsText(&answer_text, &summary));
            }
        }
    } else {
        if (unattended) |path| fields.add(view.t(.summary_answer_file), path);
        // No answer file on DATA: say where one would be picked up (the
        // selection screen is skipped when the folder is empty).
        if (unattended == null and answers_available == 0 and image.kind == .iso and std.mem.startsWith(u8, system.id, "windows-")) {
            if (system.unattended_directory) |directory| fields.add(view.t(.summary_answer_file), view.format(&no_answer_text, .summary_no_answer_files, &.{directory}));
        }
    }
    var can_start = true;
    if (backend == .xp_uefi_staging) {
        fields.add(view.t(.summary_preparation), view.t(.summary_xp_preparation));
        fields.add(view.t(.summary_source), view.t(.summary_xp_source));
        fields.add(view.t(.summary_disk), view.t(.summary_xp_disk));
    }
    var version_text: [96]u8 = undefined;
    var count_text: [100]u8 = undefined;
    var number_text: [12]u8 = undefined;
    var user_text: [120]u8 = undefined;
    const native = usos.catalog.os_profiles.traits(system.id).native_uefi;
    const vista = native == .vista;
    const modern_native = image.kind == .iso and backend == .windows_iso and usos.flow.preparation_capability.nativeModernNt(system.id);
    var modern_pe_text: [96]u8 = undefined;
    var modern_driver_text: [120]u8 = undefined;
    if (modern_native) {
        if (windows_native_iso.inspectModern(system.image_directory, image.name.slice())) |inspection| {
            fields.add(view.t(.summary_iso_case), view.t(.summary_native_case));
            const setup = inspection.setup;
            fields.add(view.t(.summary_boot_pe), std.fmt.bufPrint(&modern_pe_text, "{d}.{d}.{d} x64 / WIM index {d}", .{ setup.major, setup.minor, setup.build, setup.index }) catch view.t(.summary_unavailable));
            const folder = windows_native_iso.systemFolder(system.image_directory) catch "";
            if (windows_native_iso.userDriverCountsFor(folder)) |counts| {
                var used_text: [12]u8 = undefined;
                var skipped_text: [12]u8 = undefined;
                const used = std.fmt.bufPrint(&used_text, "{d}", .{counts[0]}) catch "?";
                const skipped = std.fmt.bufPrint(&skipped_text, "{d}", .{counts[1]}) catch "?";
                fields.add(view.t(.summary_user_drivers), view.format(&modern_driver_text, .summary_user_drivers_folder, &.{ folder, used, skipped }));
            }
            fields.add(view.t(.summary_esp_guard_label), view.t(.summary_esp_guard));
        } else |err| {
            can_start = false;
            fields.add(view.t(.summary_iso_inspection), @errorName(err));
            notes[note_count] = view.tr(usos.windows7_iso.errorDetail(err));
            note_count += 1;
        }
    }
    if (image.kind == .iso and native.legacyPe()) {
        if (windows_native_iso.inspect(image.name.slice(), vista)) |inspection| {
            fields.add(view.t(.summary_iso_case), if (vista) view.t(.summary_vista_case) else inspection.mode.label());
            fields.add(view.t(.summary_boot_source), inspection.bootName(image.name.slice()));
            const setup = inspection.boot_setup;
            fields.add(view.t(.summary_boot_pe), std.fmt.bufPrint(&version_text, "{d}.{d}.{d} x64 / WIM index {d}", .{ setup.major, setup.minor, setup.build, setup.index }) catch view.t(.summary_unavailable));
            fields.add(view.t(.summary_usb), if (vista) view.t(.summary_vista_usb) else setup.usbLabel());
            if (vista) {
                fields.add(view.t(.summary_target_support), view.t(.summary_vista_support));
                if (unattended != null) can_start = false;
            } else if (windows_native_iso.externalDriverCount()) |drivers| {
                const number = std.fmt.bufPrint(&number_text, "{d}", .{drivers}) catch "?";
                fields.add(view.t(.summary_drivers), if (drivers == 0) view.t(.summary_no_drivers) else view.format(&count_text, .summary_inf_count, &.{number}));
            } else |err| {
                fields.add(view.t(.summary_driver_inventory), @errorName(err));
            }
            if (!vista) {
                if (windows_native_iso.userDriverCounts()) |counts| {
                    var used_text: [12]u8 = undefined;
                    var skipped_text: [12]u8 = undefined;
                    const used = std.fmt.bufPrint(&used_text, "{d}", .{counts[0]}) catch "?";
                    const skipped = std.fmt.bufPrint(&skipped_text, "{d}", .{counts[1]}) catch "?";
                    fields.add(view.t(.summary_user_drivers), view.format(&user_text, .summary_user_drivers_count, &.{ used, skipped }));
                }
            }
        } else |err| {
            can_start = false;
            fields.add(view.t(.summary_iso_inspection), @errorName(err));
            notes[note_count] = donorNote(err) orelse view.tr(usos.windows7_iso.errorDetail(err));
            note_count += 1;
        }
    }
    view.summary(.{
        .title = view.t(.summary_title),
        .subtitle = view.t(.summary_subtitle),
        .labels = fields.labels[0..fields.count],
        .values = fields.values[0..fields.count],
        .notes = notes[0..note_count],
        .action = if (can_start) actionLabel(image.kind, resolved, backend) else view.t(.action_blocked),
        .action_enabled = can_start,
    });

    while (true) switch (input.readBlocking()) {
        .enter => if (can_start) return start(root, system, image, method, unattended, firmware),
        .back => return,
        .pointer => |mouse| {
            if (mouse.right_click) return;
            if (can_start and mouse.left_click and view.hitSummaryButton(mouse.x, mouse.y)) {
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
    if (!system.firmware.accepts(firmware)) return showFirmwareUnavailable();
    // No USB gamepad transfer may outlive the menu into another loader;
    // the pads are picked up again if the launch fails and the menu returns.
    input.stopGamepads();
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    // Progress rows come from the selection's profile (plan).
    view.setPlanLabels(if (usos.flow.plan.make(system, image.kind, method, firmware)) |plan| plan.labels() else null);
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable();
    if (secure_boot.enforced() and usos.flow.secure_boot_policy.backendRequiresSecureBootOff(system.id, backend)) return showSecureBootRequired();

    if (backend == .xp_uefi_staging) {
        // The progress page (like the Vista/7 ISO path) stays up while the
        // firmware loads the XP kernel and initramfs, until usos-fb-ui draws
        // the disk selection.
        showXpProgress(.checking);
        @import("xp_preparation.zig").start(root, image.name.slice(), unattended, showXpProgress) catch |err| {
            view.refreshFramebuffer();
            showError(view.t(.error_xp), err);
        };
        return;
    }
    if (image.kind == .efi and (resolved == .direct_efi or resolved == .chainload)) {
        const lines = [_][]const u8{ system.name, image.name.slice(), view.t(.efi_line1) };
        view.status(view.t(.efi_title), view.tr(resolved.label()), &lines);
        esp_image_start.start(root, system.image_directory, image.name.slice()) catch |err| {
            showError(view.t(.error_efi), err);
        };
        return;
    }

    if (manual_images.blockReason(image)) |reason| return showMediaBlocked(image.name.slice(), reason);
    if (image.kind == .iso and backend == .windows_iso and usos.flow.preparation_capability.nativeModernNt(system.id)) {
        view.windowsIsoStatus(.validating, "Reading the selected Windows ISO");
        windows_native_iso.startModern(root, system.image_directory, image.name.slice(), unattended, false, view.windowsIsoStatus) catch |err| {
            view.refreshFramebuffer();
            showError(view.t(.error_iso), err);
        };
        return;
    }
    const native = usos.catalog.os_profiles.traits(system.id).native_uefi;
    const vista = native == .vista;
    if (image.kind == .iso and native.legacyPe() and resolved == .direct_iso) {
        view.windowsIsoStatus(.validating, "Reading the selected Windows ISO");
        windows_native_iso.start(root, image.name.slice(), unattended, vista, view.windowsIsoStatus) catch |err| {
            view.refreshFramebuffer();
            showError(view.t(.error_iso), err);
        };
        return;
    }

    // Same "Starting…" splash for the micro-Linux preparation: systemd-boot
    // and the kernel's EFI stub load their files under the spinner, and
    // Linux keeps the frame until usos-fb-ui takes over.
    view.handover(view.t(.splash_starting));

    e2e_flow.requestPreparation(root, system, image, resolved, unattended, showPreparationProgress) catch |err| {
        showError(view.t(.error_preparation), err);
    };
}

/// A WinPE / rescue ISO (boot.wim without an install image): started as
/// it is through wimboot, straight from DATA; never prepared as an installer.
pub fn showWinPe(
    root: *std.os.uefi.protocol.File,
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    firmware: usos.firmware.Firmware,
) void {
    if (!system.firmware.accepts(firmware) or firmware != .uefi) return showFirmwareUnavailable();
    if (manual_images.blockReason(image)) |reason| return showMediaBlocked(image.name.slice(), reason);
    var fields = Fields{};
    fields.add(view.t(.summary_system), system.name);
    fields.add(view.t(.summary_image), image.name.slice());
    fields.add(view.t(.summary_iso_case), view.t(.media_winpe));
    if (image.media) |info| {
        if (info.arch != .unknown) fields.add(view.t(.summary_boot_pe), info.arch.label());
    }
    const notes = [_][]const u8{ view.t(.media_winpe_line1), view.t(.media_winpe_line2) };
    const can_start = @import("builtin").cpu.arch == .x86_64;
    view.summary(.{
        .title = view.t(.summary_title),
        .subtitle = view.t(.summary_subtitle),
        .labels = fields.labels[0..fields.count],
        .values = fields.values[0..fields.count],
        .notes = &notes,
        .action = if (can_start) view.t(.action_winpe) else view.t(.action_blocked),
        .action_enabled = can_start,
    });
    while (true) switch (input.readBlocking()) {
        .enter => if (can_start) return startWinPe(root, system, image),
        .back => return,
        .pointer => |mouse| {
            if (mouse.right_click) return;
            if (can_start and mouse.left_click and view.hitSummaryButton(mouse.x, mouse.y)) return startWinPe(root, system, image);
            if (mouse.moved) view.updatePointer();
        },
        else => {},
    };
}

fn startWinPe(root: *std.os.uefi.protocol.File, system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) void {
    input.stopGamepads();
    view.setPlanLabels(null);
    view.windowsIsoStatus(.validating, "Reading the selected WinPE ISO");
    windows_native_iso.startModern(root, system.image_directory, image.name.slice(), null, true, view.windowsIsoStatus) catch |err| {
        view.refreshFramebuffer();
        showError(view.t(.error_iso), err);
    };
}

fn showMediaBlocked(name: []const u8, reason: usos.image_probe.windows_media.Block) void {
    const lines = [_][]const u8{ manual_images.blockText(reason), view.t(.media_blocked_line2) };
    view.notice(name, .warning, .warning, view.t(.media_blocked_title), &lines);
    view.waitForDismiss();
}

/// Missing or damaged PE10 donor (Programs/USOS/WinPE): a localized
/// "run Repair in the USOS installer" message.
fn donorNote(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.Windows10PeDonorMissing, error.Windows10PeDonorInvalid, error.Windows10PeDonorNotRecorded => view.t(.donor_missing),
        error.Windows10PeDonorCorrupt => view.t(.donor_corrupt),
        else => null,
    };
}

fn actionLabel(kind: usos.catalog.ImageKind, resolved: usos.catalog.BootMethod, backend: usos.flow.preparation_capability.Backend) []const u8 {
    if (backend == .xp_uefi_staging) return view.t(.action_xp);
    if (kind == .efi and (resolved == .direct_efi or resolved == .chainload)) return view.t(.action_efi);
    return switch (resolved) {
        .chainload => view.t(.action_chainload),
        .wimboot => view.t(.action_wimboot),
        .vhdboot => view.t(.action_vhdboot),
        else => view.t(.action_iso),
    };
}

fn showFirmwareUnavailable() void {
    const lines = [_][]const u8{view.t(.error_firmware_line1)};
    view.notice(view.t(.error_firmware_title), .warning, .warning, "", &lines);
    view.waitForDismiss();
}

fn showUnsupported() void {
    const lines = [_][]const u8{view.t(.error_unsupported_line1)};
    view.notice(view.t(.error_unsupported_title), .warning, .warning, "", &lines);
    view.waitForDismiss();
}

fn showSecureBootRequired() void {
    const lines = [_][]const u8{ view.t(.summary_secure_boot_line1), view.t(.summary_secure_boot_line2) };
    view.notice(view.t(.summary_secure_boot_title), .warning, .warning, view.t(.summary_secure_boot_badge), &lines);
    view.waitForDismiss();
}

fn showError(title: []const u8, err: anyerror) void {
    // Keep the failure visible instead of immediately redrawing the method menu.
    var buffer: [96]u8 = undefined;
    const detail = if (err == error.SecureBootRejected) view.t(.error_secure_boot_rejected) else view.t(.error_stopped);
    const lines = [_][]const u8{ std.fmt.bufPrint(&buffer, "{s}: {s}", .{ view.t(.summary_error), @errorName(err) }) catch @errorName(err), detail };
    view.notice(title, .error_circle, .danger, "", &lines);
    view.waitForDismiss();
}

/// Same heading as the micro-Linux XP pages (tools/micro_linux_ui.sh).
const xp_heading = "Windows XP";

fn showXpProgress(stage: usos.flow.preparation_boot_progress.XpStage) void {
    view.xpStatus(stage, xp_heading);
}

fn showPreparationProgress(stage: usos.flow.preparation_boot_progress.Stage) void {
    view.handoverStatus(view.tr(stage.detail()));
}
