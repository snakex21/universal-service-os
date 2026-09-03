const std = @import("std");
const uefi = std.os.uefi;

const boot_order_name = std.unicode.utf8ToUtf16LeStringLiteral("BootOrder");
const boot_current_name = std.unicode.utf8ToUtf16LeStringLiteral("BootCurrent");
const boot_next_name = std.unicode.utf8ToUtf16LeStringLiteral("BootNext");
const backup_name = std.unicode.utf8ToUtf16LeStringLiteral("USOSBootOrderBackup");
const max_boot_order_bytes = 4096;

pub const usos_vendor_guid = uefi.Guid{
    .time_low = 0x2d7140c8,
    .time_mid = 0x78a1,
    .time_high_and_version = 0x4e9d,
    .clock_seq_high_and_reserved = 0xa1,
    .clock_seq_low = 0x77,
    .node = [_]u8{ 0x55, 0x53, 0x4f, 0x53, 0x42, 0x4f },
};

pub const Error = error{
    BootOrderMissing,
    BootOrderTooLarge,
    BootCurrentMissing,
    InvalidBootCurrent,
};

/// Preserves the exact current BootOrder before touching BootNext, then makes
/// the currently running USOS Boot#### entry the firmware's one-shot next boot.
pub fn prepareReturnToCurrentBoot() !u16 {
    const rt = uefi.system_table.runtime_services;

    const size_info = try rt.getVariableSize(boot_order_name, &uefi.tables.global_variable) orelse return error.BootOrderMissing;
    if (size_info[0] == 0 or size_info[0] > max_boot_order_bytes) return error.BootOrderTooLarge;

    var order_storage: [max_boot_order_bytes]u8 = undefined;
    const order_result = try rt.getVariable(boot_order_name, &uefi.tables.global_variable, order_storage[0..size_info[0]]) orelse return error.BootOrderMissing;
    const original_order = order_result[0];

    const backup_attrs: uefi.tables.RuntimeServices.VariableAttributes = .{
        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,
    };
    // This write must succeed before BootNext is changed. Failure propagates
    // and leaves BootNext untouched.
    try rt.setVariable(backup_name, &usos_vendor_guid, backup_attrs, original_order);

    var current_storage: [2]u8 = undefined;
    const current_result = try rt.getVariable(boot_current_name, &uefi.tables.global_variable, &current_storage) orelse return error.BootCurrentMissing;
    if (current_result[0].len != 2) return error.InvalidBootCurrent;
    const boot_current = std.mem.readInt(u16, current_result[0][0..2], .little);

    const boot_attrs: uefi.tables.RuntimeServices.VariableAttributes = .{
        .non_volatile = true,
        .bootservice_access = true,
        .runtime_access = true,
    };
    var next_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &next_bytes, boot_current, .little);
    try rt.setVariable(boot_next_name, &uefi.tables.global_variable, boot_attrs, &next_bytes);
    return boot_current;
}
