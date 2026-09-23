//! Boot summary: shows only the settings that apply to this selection
//! (no "None" placeholder rows) and the start button.
const usos = @import("usos");
const std = @import("std");
const e2e_flow = @import("e2e_flow.zig");
const esp_image_start = @import("esp_image_start.zig");
const input = @import("input.zig");
const view = @import("manual_view.zig");
const windows_native_iso = @import("windows_native_iso.zig");

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
    firmware: usos.firmware.Firmware,
) void {
    if (!system.firmware.accepts(firmware)) return showFirmwareUnavailable();
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable();

    var fields = Fields{};
    var notes: [2][]const u8 = undefined;
    var note_count: usize = 0;
    fields.add(view.t(.summary_system), system.name);
    fields.add(view.t(.summary_image), image.name.slice());
    fields.add(view.t(.summary_method), view.tr(method.label()));
    if (unattended) |path| fields.add(view.t(.summary_answer_file), path);
    var can_start = true;
    if (backend == .xp_uefi_staging) {
        fields.add(view.t(.summary_preparation), view.t(.summary_xp_preparation));
        fields.add(view.t(.summary_source), view.t(.summary_xp_source));
        fields.add(view.t(.summary_disk), view.t(.summary_xp_disk));
        if (unattended != null) {
            can_start = false;
            notes[note_count] = view.t(.summary_xp_no_unattended);
            note_count += 1;
        }
    }
    var version_text: [96]u8 = undefined;
    var count_text: [100]u8 = undefined;
    var number_text: [12]u8 = undefined;
    const vista = std.mem.eql(u8, system.id, "windows-vista");
    if (image.kind == .iso and (vista or std.mem.eql(u8, system.id, "windows-7"))) {
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
        } else |err| {
            can_start = false;
            fields.add(view.t(.summary_iso_inspection), @errorName(err));
            notes[note_count] = usos.windows7_iso.errorDetail(err);
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
    const backend = usos.flow.preparation_capability.resolveForFirmware(system, image.kind, method, firmware) orelse return showUnsupported();
    const resolved = backend.method();
    const method_firmware = backend.firmwareRequirement();
    if (!method_firmware.accepts(firmware)) return showFirmwareUnavailable();

    if (backend == .xp_uefi_staging) {
        // The splash stays up (spinner turning) while firmware loads the XP
        // kernel and initramfs, until usos-fb-ui draws its first screen.
        view.handover(view.t(.splash_starting));
        @import("xp_preparation.zig").start(root, image.name.slice(), unattended) catch |err| {
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

    const vista = std.mem.eql(u8, system.id, "windows-vista");
    if (image.kind == .iso and (vista or std.mem.eql(u8, system.id, "windows-7")) and resolved == .direct_iso) {
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

fn showError(title: []const u8, err: anyerror) void {
    // Keep the failure visible instead of immediately redrawing the method menu.
    var buffer: [96]u8 = undefined;
    const lines = [_][]const u8{ std.fmt.bufPrint(&buffer, "{s}: {s}", .{ view.t(.summary_error), @errorName(err) }) catch @errorName(err), view.t(.error_stopped) };
    view.notice(title, .error_circle, .danger, "", &lines);
    view.waitForDismiss();
}

fn showPreparationProgress(stage: usos.flow.preparation_boot_progress.Stage) void {
    view.handoverStatus(view.tr(stage.detail()));
}
