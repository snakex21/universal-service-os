const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub fn select(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) ?usos.catalog.BootMethod {
    var options: [10]usos.flow.boot_method_options.Option = undefined;
    const len = usos.flow.boot_method_options.collect(system, image.kind, &options);

    if (len == 0) {
        showNoMethodNotice(image);
        return null;
    }

    var selected: usize = 0;
    render(system, image, &options, len, selected);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, 0, len)) {
            .activate => {
                if (options[selected].enabled) return options[selected].method;
            },
            .back => return null,
            .changed => render(system, image, &options, len, selected),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn render(
    system: *const usos.catalog.SystemEntry,
    image: usos.catalog.ImageItem,
    options: *const [10]usos.flow.boot_method_options.Option,
    len: usize,
    selected: usize,
) void {
    view.begin("methods", image.name.slice());
    for (options[0..len], 0..) |option, index| {
        const label = displayLabel(system.id, image.kind, option.method);
        if (option.enabled) {
            view.row(index == selected, label);
        } else {
            view.rowDisabled(index == selected, label, option.reason);
        }
    }

    const current = options[selected];
    const help = usos.flow.boot_method_help.describe(system.id, image.kind, current.method);
    view.helpBox(help.title, help.line1, help.line2, if (current.enabled) "READY" else current.reason);
    view.footer(true);
}

fn displayLabel(system_id: []const u8, image: usos.catalog.ImageKind, method: usos.catalog.BootMethod) []const u8 {
    if (method == .automatic) {
        if (usos.flow.preparation_capability.resolve(system_id, image, method)) |resolved| {
            return switch (resolved) {
                .direct_iso => "Automatic (ISO)",
                .wimboot => "Automatic (WIMBoot)",
                .vhdboot => "Automatic (VHDBoot)",
                .direct_efi => "Automatic (EFI)",
                .chainload => "Automatic (Chainload)",
                .memdisk => "Automatic (Memdisk)",
                .disk_image => "Automatic (Disk image)",
                .floppy_image => "Automatic (Floppy image)",
                .automatic => "Automatic",
            };
        }
    }
    return method.label();
}

fn showNoMethodNotice(image: usos.catalog.ImageItem) void {
    view.begin("methods", image.name.slice());
    view.row(false, "No boot methods are configured for this system.");
    view.footer(true);
    while (true) {
        switch (input.readBlocking()) {
            .enter => return,
            .back => return,
            .pointer => |mouse| {
                if (mouse.right_click) return;
                if (mouse.left_click) return;
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}
