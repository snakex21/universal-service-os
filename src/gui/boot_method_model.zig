const BootMethod = @import("../catalog/boot_method.zig").BootMethod;
const FixedText = @import("../core/fixed_text.zig").FixedText;
const Firmware = @import("../core/firmware.zig").Firmware;
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;
const capability = @import("../flow/preparation_capability.zig");
const help_model = @import("../flow/boot_method_help.zig");
const options_model = @import("../flow/boot_method_options.zig");
const validation = @import("../flow/backend_validation.zig");

pub const max_items: usize = 10;
pub const Backend = capability.Backend;

pub const Item = struct {
    method: BootMethod,
    backend: ?capability.Backend,
    enabled: bool,
    selectable: bool,
    reason: []const u8,
    validation_status: ?validation.Status,
    label: FixedText,
    help: help_model.Help,

    pub fn detail(self: *const Item) []const u8 {
        if (!self.enabled and self.reason.len != 0) return self.reason;
        if (self.validation_status) |status| return status.badge();
        return "";
    }

    pub fn statusLabel(self: *const Item) []const u8 {
        if (!self.enabled and self.reason.len != 0) return self.reason;
        if (self.validation_status) |status| return status.helpLabel();
        return "UNAVAILABLE";
    }
};

pub const List = struct {
    items: [max_items]Item = undefined,
    len: usize = 0,

    pub fn slice(self: *const List) []const Item {
        return self.items[0..self.len];
    }

    pub fn selectable(self: *const List, output: *[max_items]bool) []const bool {
        for (self.items[0..self.len], 0..) |item, index| output[index] = item.selectable;
        return output[0..self.len];
    }

    pub fn enabledCount(self: *const List) usize {
        var count: usize = 0;
        for (self.items[0..self.len]) |item| {
            if (item.enabled) count += 1;
        }
        return count;
    }

    pub fn singleEnabledIndex(self: *const List) ?usize {
        var found: ?usize = null;
        for (self.items[0..self.len], 0..) |item, index| {
            if (!item.enabled) continue;
            if (found != null) return null;
            found = index;
        }
        return found;
    }
};

pub fn collect(system: *const SystemEntry, image: ImageKind, firmware: Firmware) List {
    var raw: [max_items]options_model.Option = undefined;
    const raw_len = options_model.collect(system, image, firmware, &raw);
    var result = List{};
    result.len = raw_len;
    for (raw[0..raw_len], 0..) |option, index| {
        var label = FixedText{};
        const win2k = @import("std").mem.eql(u8, system.id, "windows-2000");
        setLabel(&label, if (win2k and option.method == .automatic and option.backend == .xp_staging)
            "Automatic (Windows 2000 Setup)"
        else baseLabel(option.method, option.backend));
        if (option.validation_status) |status| {
            const badge = status.badge();
            if (badge.len != 0) {
                appendLabel(&label, " ");
                appendLabel(&label, badge);
            }
        }
        result.items[index] = .{
            .method = option.method,
            .backend = option.backend,
            .enabled = option.enabled,
            .selectable = option.firmware_compatible,
            .reason = option.reason,
            .validation_status = option.validation_status,
            .label = label,
            .help = help_model.describeEntry(system, image, option.method),
        };
    }
    return result;
}

fn baseLabel(method: BootMethod, backend: ?capability.Backend) []const u8 {
    if (method != .automatic) return method.label();
    const resolved = backend orelse return "Automatic";
    return switch (resolved) {
        .windows_iso => "Automatic (ISO)",
        .windows_bios_iso => "Automatic (Windows Setup)",
        .win9x_dos => "Automatic (DOS Setup)",
        .dos_bios_iso => "Automatic (MS-DOS / Windows 3.x)",
        .linux_live_iso => "Automatic (SliTaz Live)",
        .linux_iso => "Automatic (Linux ISO)",
        .xp_staging => "Automatic (XP staging)",
        .xp_uefi_staging => "Automatic (UEFI preparation / XP via CSM)",
        .wimboot => "Automatic (WIMBoot)",
        .vhdboot => "Automatic (VHDBoot)",
        .direct_efi => "Automatic (EFI)",
        .chainload => "Automatic (Chainload)",
    };
}

fn setLabel(target: *FixedText, text: []const u8) void {
    const count = @min(text.len, target.bytes.len);
    @memcpy(target.bytes[0..count], text[0..count]);
    target.len = count;
}

fn appendLabel(target: *FixedText, text: []const u8) void {
    const room = target.bytes.len - target.len;
    const count = @min(room, text.len);
    @memcpy(target.bytes[target.len .. target.len + count], text[0..count]);
    target.len += count;
}

test "XP Automatic uses XP staging backend and shared tested-in-VM badge" {
    const std = @import("std");
    const systems = @import("../catalog/systems.zig");
    const xp = systems.findById("windows-xp").?;
    const list = collect(xp, .iso, .bios);
    try std.testing.expect(list.len > 0);
    try std.testing.expectEqual(BootMethod.automatic, list.items[0].method);
    try std.testing.expectEqual(capability.Backend.xp_staging, list.items[0].backend.?);
    try std.testing.expect(list.items[0].enabled);
    try std.testing.expectEqualStrings("Automatic (XP staging) [TESTED IN VM]", list.items[0].label.slice());
}

test "XP BIOS exposes exactly one enabled method" {
    const std = @import("std");
    const systems = @import("../catalog/systems.zig");
    const xp = systems.findById("windows-xp").?;
    const list = collect(xp, .iso, .bios);
    try std.testing.expectEqual(@as(usize, 1), list.enabledCount());
    const index = list.singleEnabledIndex().?;
    try std.testing.expectEqual(BootMethod.automatic, list.items[index].method);
    try std.testing.expectEqual(capability.Backend.xp_staging, list.items[index].backend.?);
}

test "XP UEFI exposes one automatic experimental ISO preparation path" {
    const std = @import("std");
    const xp = @import("../catalog/systems.zig").findById("windows-xp").?;
    const list = collect(xp, .iso, .uefi);
    try std.testing.expectEqual(@as(usize, 1), list.enabledCount());
    const item = list.items[list.singleEnabledIndex().?];
    try std.testing.expectEqual(BootMethod.automatic, item.method);
    try std.testing.expectEqual(capability.Backend.xp_uefi_staging, item.backend.?);
    try std.testing.expectEqual(validation.Status.experimental, item.validation_status.?);
}

test "Direct EFI remains visible but disabled in BIOS when configured" {
    const std = @import("std");
    const systems = @import("../catalog/systems.zig");
    const ubuntu = systems.findById("ubuntu").?;
    const list = collect(ubuntu, .efi, .bios);
    var found = false;
    for (list.items[0..list.len]) |item| {
        if (item.method != .direct_efi) continue;
        found = true;
        try std.testing.expect(!item.enabled);
        try std.testing.expect(!item.selectable);
        try std.testing.expectEqualStrings("[requires UEFI; running BIOS]", item.reason);
        try std.testing.expectEqual(validation.Status.tested_in_vm, item.validation_status.?);
    }
    try std.testing.expect(found);
}
