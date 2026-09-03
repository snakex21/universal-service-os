const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub fn select(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) ?usos.catalog.BootMethod {
    var methods: [10]usos.catalog.BootMethod = undefined;
    var len: usize = 0;

    for (system.boot_methods) |method| {
        methods[len] = method;
        len += 1;
    }

    if (len == 0) {
        view.begin("methods", image.name.slice());
        view.row(false, "No boot method supports this image.");
        view.footer(true);
        while (true) {
            switch (input.readBlocking()) {
                .back => return null,
                .enter => return null,
                .pointer => |mouse| {
                    if (mouse.right_click) return null;
                    if (mouse.left_click) return null;
                    if (mouse.moved) view.updatePointer();
                },
                else => {},
            }
        }
    }

    var selected: usize = 0;
    render(system, image, &methods, len, selected);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, 0, len)) {
            .activate => {
                const method = methods[selected];
                if (usos.flow.preparation_capability.supports(system.id, image.kind, method)) return method;
                showBackendDisabledNotice(image, method);
                render(system, image, &methods, len, selected);
            },
            .back => return null,
            .changed => render(system, image, &methods, len, selected),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn render(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem, methods: *const [10]usos.catalog.BootMethod, len: usize, selected: usize) void {
    view.begin("methods", image.name.slice());
    for (methods[0..len], 0..) |method, index| {
        if (usos.flow.preparation_capability.supports(system.id, image.kind, method)) {
            view.row(index == selected, method.label());
        } else {
            view.rowDisabled(index == selected, method.label(), "[backend: Windows 11 + ISO only]");
        }
    }
    view.footer(true);
}

fn showBackendDisabledNotice(image: usos.catalog.ImageItem, method: usos.catalog.BootMethod) void {
    view.begin("methods", method.label());
    view.writeText("Image: ", image.name.slice());
    view.row(false, usos.flow.preparation_capability.unavailable_reason);
    view.row(false, "This method remains visible because its backend is planned.");
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
