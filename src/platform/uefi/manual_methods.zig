const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

pub fn select(system: *const usos.catalog.SystemEntry, image: usos.catalog.ImageItem) ?usos.catalog.BootMethod {
    var methods: [10]usos.catalog.BootMethod = undefined;
    var len: usize = 0;

    for (system.boot_methods) |method| {
        if (!usos.catalog.boot_compatibility.canUse(system, image.kind, method)) continue;
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
    render(image, &methods, len, selected);

    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, len, 0, len)) {
            .activate => return methods[selected],
            .back => return null,
            .changed => render(image, &methods, len, selected),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn render(image: usos.catalog.ImageItem, methods: *const [10]usos.catalog.BootMethod, len: usize, selected: usize) void {
    view.begin("methods", image.name.slice());
    for (methods[0..len], 0..) |method, index| {
        view.row(index == selected, method.label());
    }
    view.footer(true);
}
