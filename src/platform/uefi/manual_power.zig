const std = @import("std");
const uefi = std.os.uefi;
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");

const os_indications_name = std.unicode.utf8ToUtf16LeStringLiteral("OsIndications");
const os_indications_supported_name = std.unicode.utf8ToUtf16LeStringLiteral("OsIndicationsSupported");
const boot_to_fw_ui: u64 = 0x0000000000000001;
const option_count: usize = 3;

pub fn show() void {
    const firmware_ui = firmwareUiSupported();
    var selectable = [_]bool{ true, true, firmware_ui };
    var rows = [_]view.ListRow{
        .{ .plain = "Restart" },
        .{ .plain = "Shut down" },
        if (firmware_ui)
            .{ .plain = "Firmware setup (BIOS/UEFI)" }
        else
            .{ .disabled = .{ .value = "Firmware setup (BIOS/UEFI)", .reason = "Not supported by this firmware" } },
    };
    var selected: usize = 0;
    var list = view.ListScreen.open("power", "POWER", &rows, selected, option_count, null);

    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, option_count, list.visibleStart(), list.visibleCount(), &selectable)) {
            .activate => switch (selected) {
                0 => uefi.system_table.runtime_services.resetSystem(.cold, .success, null),
                1 => uefi.system_table.runtime_services.resetSystem(.shutdown, .success, null),
                2 => enterFirmwareSetup() catch |err| {
                    showFirmwareError(err);
                    const current_support = firmwareUiSupported();
                    selectable[2] = current_support;
                    rows[2] = if (current_support)
                        .{ .plain = "Firmware setup (BIOS/UEFI)" }
                    else
                        .{ .disabled = .{ .value = "Firmware setup (BIOS/UEFI)", .reason = "Not supported by this firmware" } };
                    list.redrawFull(selected, null);
                },
                else => {},
            },
            .back => return,
            .changed => list.updateSelection(selected, null),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn firmwareUiSupported() bool {
    const supported = readGlobalU64(os_indications_supported_name) catch return false;
    return if (supported) |value| (value & boot_to_fw_ui) != 0 else false;
}

fn enterFirmwareSetup() !void {
    const supported = (try readGlobalU64(os_indications_supported_name)) orelse return error.OsIndicationsUnsupported;
    if ((supported & boot_to_fw_ui) == 0) return error.BootToFirmwareUiUnsupported;

    const rt = uefi.system_table.runtime_services;
    var attributes: uefi.tables.RuntimeServices.VariableAttributes = .{
        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,
    };
    var current: u64 = 0;
    if (try readGlobalU64WithAttributes(os_indications_name)) |value| {
        current = value.value;
        attributes = value.attributes;
    }

    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, current | boot_to_fw_ui, .little);
    try rt.setVariable(os_indications_name, &uefi.tables.global_variable, attributes, &bytes);
    rt.resetSystem(.cold, .success, null);
}

const GlobalU64 = struct {
    value: u64,
    attributes: uefi.tables.RuntimeServices.VariableAttributes,
};

fn readGlobalU64(name: [*:0]const u16) !?u64 {
    const result = try readGlobalU64WithAttributes(name);
    return if (result) |value| value.value else null;
}

fn readGlobalU64WithAttributes(name: [*:0]const u16) !?GlobalU64 {
    const rt = uefi.system_table.runtime_services;
    const size_info = try rt.getVariableSize(name, &uefi.tables.global_variable) orelse return null;
    if (size_info[0] != 8) return error.InvalidOsIndicationsSize;
    var storage: [8]u8 = undefined;
    const result = try rt.getVariable(name, &uefi.tables.global_variable, &storage) orelse return null;
    if (result[0].len != 8) return error.InvalidOsIndicationsSize;
    return .{
        .value = std.mem.readInt(u64, result[0][0..8], .little),
        .attributes = result[1],
    };
}

fn showFirmwareError(err: anyerror) void {
    view.begin("power-error", "FIRMWARE SETUP");
    view.row(false, "Could not request firmware setup on next reboot.");
    view.rowParts(false, "Error: ", @errorName(err));
    view.footer(true);
    while (true) {
        switch (input.readBlocking()) {
            .back, .enter => return,
            .pointer => |mouse| {
                if (mouse.right_click or mouse.left_click) return;
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}
