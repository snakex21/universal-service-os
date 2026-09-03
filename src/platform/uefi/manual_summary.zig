const usos = @import("usos");
const std = @import("std");
const e2e_flow = @import("e2e_flow.zig");
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
    view.begin("summary", "Boot selection");
    view.writeText("System: ", system.name);
    view.writeText("Image: ", image.name.slice());
    view.writeText("Method: ", method.label());
    view.writeText("Unattended: ", unattended orelse "None");
    view.row(true, "PRESS ENTER OR CLICK HERE TO LOAD THE WINDOWS ISO");
    view.footer(true);

    while (true) switch (input.readBlocking()) {
        .enter => return start(root, system, image, unattended),
        .back => return,
        .pointer => |mouse| {
            if (mouse.right_click) return;
            if (mouse.left_click and view.hitRow(mouse.x, mouse.y, start_row_index + 1) == start_row_index) {
                return start(root, system, image, unattended);
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
    unattended: ?[]const u8,
) void {
    e2e_flow.requestPreparation(root, system, image, unattended) catch |err| {
        view.begin("summary", "Preparation failed");
        view.writeText("Error: ", @errorName(err));
        view.row(false, "Preparation stopped safely. Inspect the serial log.");
        view.footer(true);
    };
}
