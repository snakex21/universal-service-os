const filesystem = @import("filesystem.zig");
const e2e_flow = @import("e2e_flow.zig");
const manual_categories = @import("manual_categories.zig");
const manual_images = @import("manual_images.zig");
const manual_methods = @import("manual_methods.zig");
const manual_summary = @import("manual_summary.zig");
const manual_systems = @import("manual_systems.zig");
const manual_unattended = @import("manual_unattended.zig");
const manual_view = @import("manual_view.zig");

pub fn run() void {
    const root = filesystem.openBootVolume() orelse return;
    defer root.close() catch {};
    if (e2e_flow.resumePersistent(root)) return;
    manual_view.init(root);

    while (manual_categories.select()) |category| {
        while (manual_systems.select(root, category)) |system| {
            while (manual_images.select(root, system)) |image| {
                while (manual_methods.select(system, image)) |method| {
                    const unattended = manual_unattended.select(root, system);
                    if (unattended.back) continue;
                    manual_summary.show(root, system, image, method, unattended.path);
                }
            }
        }
    }
}
