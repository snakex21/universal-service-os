//! M0 characterization (docs/design/refactor-os-pipeline.md): the complete
//! routing and menu truth table of the host build, rendered as text and
//! compared with testdata/routing_golden.tsv.
//!
//! Covered per system x ImageKind x BootMethod x firmware:
//!   resolveForFirmware (backend, method, firmware requirement, validation
//!   badge, Secure Boot requirement), resolve/supports/validate (the
//!   firmware-less path used by e2e_flow.requestPreparation), the menu rows
//!   (boot_method_model.collect: label, enabled, selectable, reason, badge,
//!   status) and the help text, the answer-file policy and the Secure Boot
//!   block per system, and the progress stage labels.
//!
//! Host build only: in the freestanding BIOS Core, Windows 7/Vista native
//! ISO routing and their help/validation branches are compiled out (see
//! `native_windows7_enabled` in preparation_capability.zig).
//!
//! Regenerate after an intended change: USOS_UPDATE_GOLDEN=1 zig build test
const std = @import("std");
const systems = @import("../catalog/systems.zig");
const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const Firmware = @import("../core/firmware.zig").Firmware;
const capability = @import("preparation_capability.zig");
const validation = @import("backend_validation.zig");
const secure_boot_policy = @import("secure_boot_policy.zig");
const unattended_policy = @import("unattended_policy.zig");
const help = @import("boot_method_help.zig");
const progress = @import("preparation_boot_progress.zig");
const menu_model = @import("../gui/boot_method_model.zig");
const golden = @import("../testing/golden.zig");

const images = std.enums.values(ImageKind);
const methods = std.enums.values(BootMethod);
const firmwares = std.enums.values(Firmware);

fn opt(value: anytype) []const u8 {
    return if (value) |v| @tagName(v) else "-";
}

fn flag(value: bool) []const u8 {
    return if (value) "1" else "0";
}

pub fn render(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "# systems: id family category firmware image_directory unattended_directory answer_ext answer_label secure_boot_off methods\n");
    for (&systems.all) |*system| {
        try out.print(gpa, "system\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t", .{
            system.id,                            @tagName(system.family),                      @tagName(system.category),
            @tagName(system.firmware),            system.image_directory,                       system.unattended_directory orelse "-",
            unattended_policy.extension(system),  unattended_policy.fileKindLabel(system),      flag(secure_boot_policy.systemRequiresSecureBootOff(system.id)),
        });
        for (system.boot_methods, 0..) |method, i| {
            if (i != 0) try out.append(gpa, ',');
            try out.appendSlice(gpa, @tagName(method));
        }
        try out.append(gpa, '\n');
    }

    try out.appendSlice(gpa, "# route: system image method firmware backend backend_method backend_firmware validation backend_secure_boot_off\n");
    for (&systems.all) |*system| for (images) |image| for (methods) |method| for (firmwares) |firmware| {
        const backend = capability.resolveForFirmware(system, image, method, firmware);
        if (backend) |b| {
            try out.print(gpa, "route\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                system.id,                    @tagName(image),                  @tagName(method), @tagName(firmware),
                @tagName(b),                  @tagName(b.method()),             @tagName(b.firmwareRequirement()),
                @tagName(validation.statusSelection(b, system.id, image)), flag(secure_boot_policy.backendRequiresSecureBootOff(system.id, b)),
            });
        } else {
            try out.print(gpa, "route\t{s}\t{s}\t{s}\t{s}\t-\n", .{ system.id, @tagName(image), @tagName(method), @tagName(firmware) });
        }
    };

    try out.appendSlice(gpa, "# resolve (no firmware, e2e_flow): system image method resolve supports validate\n");
    for (&systems.all) |*system| for (images) |image| for (methods) |method| {
        const validated: []const u8 = if (capability.validate(system.id, image, method)) |_| "ok" else |err| @errorName(err);
        try out.print(gpa, "resolve\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
            system.id,                                               @tagName(image), @tagName(method),
            opt(capability.resolve(system.id, image, method)), flag(capability.supports(system.id, image, method)), validated,
        });
    };

    try out.appendSlice(gpa, "# menu: system image firmware index method backend enabled selectable validation label detail status reason\n");
    for (&systems.all) |*system| for (images) |image| for (firmwares) |firmware| {
        const list = menu_model.collect(system, image, firmware);
        for (list.slice(), 0..) |*item, index| {
            try out.print(gpa, "menu\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                system.id,          @tagName(image),        @tagName(firmware),         index,
                @tagName(item.method), opt(item.backend),   flag(item.enabled),         flag(item.selectable),
                opt(item.validation_status), item.label.slice(), item.detail(),        item.statusLabel(),
                if (item.reason.len == 0) "-" else item.reason,
            });
        }
    };

    try out.appendSlice(gpa, "# help: system image method title | line1 | line2\n");
    for (&systems.all) |*system| for (images) |image| for (methods) |method| {
        const h = help.describeEntry(system, image, method);
        try out.print(gpa, "help\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ system.id, @tagName(image), @tagName(method), h.title, h.line1, h.line2 });
    };

    try out.appendSlice(gpa, "# progress\n");
    for (std.enums.values(progress.Stage)) |stage| {
        try out.print(gpa, "progress\tmicro_linux\t{s}\t{s}\t{s}\n", .{ @tagName(stage), stage.label(), stage.detail() });
    }
    for (std.enums.values(progress.DirectIsoStage)) |stage| {
        try out.print(gpa, "progress\tdirect_iso\t{s}\t{d}\n", .{ @tagName(stage), stage.number() });
    }
    for (progress.DirectIsoStage.labels) |label| try out.print(gpa, "progress\tdirect_iso_label\t{s}\n", .{label});
    for (std.enums.values(progress.XpStage)) |stage| {
        try out.print(gpa, "progress\txp\t{s}\t{d}\t{s}\n", .{ @tagName(stage), stage.number(), stage.detail() });
    }
    for (progress.XpStage.labels) |label| try out.print(gpa, "progress\txp_label\t{s}\n", .{label});

    return out.toOwnedSlice(gpa);
}

test "routing, menus, help and policies match the golden truth table" {
    const gpa = std.testing.allocator;
    const actual = try render(gpa);
    defer gpa.free(actual);
    try golden.expectGolden("routing_golden.tsv", "src/flow/testdata/routing_golden.tsv", @embedFile("testdata/routing_golden.tsv"), actual);
}
