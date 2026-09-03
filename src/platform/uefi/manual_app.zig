const std = @import("std");
const usos = @import("usos");
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

pub fn run() void {
    const root = filesystem.openBootVolume() orelse return;
    defer root.close() catch {};
    manual_view.init(root);
    if (e2e_flow.resumePersistent(root, showResumeStatus)) return;

    while (manual_categories.select()) |category| {
        if (category == .utilities) {
            while (manual_utilities.select(root)) |utility| runEntry(root, utility);
            continue;
        }
        while (manual_systems.select(root, category)) |system| runEntry(root, system);
    }
}

fn runEntry(root: *std.os.uefi.protocol.File, entry: *const usos.catalog.SystemEntry) void {
    while (manual_images.select(root, entry)) |image| {
        while (manual_methods.select(entry, image)) |method| {
            if (entry.unattended_directory != null and (image.kind == .iso or image.kind == .wim)) {
                const unattended = manual_unattended.select(root, entry);
                if (unattended.back) continue;
                manual_summary.show(root, entry, image, method, unattended.path);
            } else {
                manual_summary.show(root, entry, image, method, null);
            }
        }
    }
}

fn showResumeStatus(stage: e2e_flow.ResumeStage) void {
    switch (stage) {
        .starting_windows_setup => {
            manual_view.begin("windows-handoff", "Starting Windows Setup");
            manual_view.row(false, "Windows installer preparation is complete.");
            manual_view.row(false, "Starting Windows Setup from the prepared WORK partition...");
            manual_view.passiveFooter();
        },
        .starting_chainload => {
            manual_view.begin("windows-handoff", "Starting chained bootloader");
            manual_view.row(false, "Boot media preparation is complete.");
            manual_view.row(false, "Starting EFI/BOOT from the prepared WORK partition...");
            manual_view.passiveFooter();
        },
    }
}
