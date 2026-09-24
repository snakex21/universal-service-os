//! When the UEFI menu starts the vendored TouchI2cDxe driver
//! (tools/vendor/touchi2cdxe, \EFI\USOS\touchi2c_x64.efi): only on machines
//! whose SMBIOS identity matches one of the driver's profiles, so the
//! driver's fixed AMD FCH MMIO/AOAC accesses never happen on other hardware
//! (the driver itself fails closed as well). The strings mirror the
//! driver's own match: a Type 2 baseboard product that starts with the
//! profile's board name, or an exact Type 1 product name.
const std = @import("std");
const handheld = @import("../gui/handheld.zig");

pub const Target = enum {
    /// ROG Ally 2023: exact RC71L profile (USOS patch; Novatek NVTK0603 on
    /// I2C0 0xFEDC2000, address 0x01, descriptor register 0x0000).
    rog_ally_rc71l,
    /// ROG Ally X 2024: upstream sweep profile (untested upstream).
    rog_ally_x_rc72la,
    /// ROG Xbox Ally / Xbox Ally X 2025: upstream profile confirmed on hardware.
    rog_xbox_ally_rc73,
    /// Steam Deck OLED / LCD: upstream profiles confirmed on hardware.
    steam_deck_galileo,
    steam_deck_jupiter,

    pub fn label(self: Target) []const u8 {
        return switch (self) {
            .rog_ally_rc71l => "ROG Ally RC71L (exact profile)",
            .rog_ally_x_rc72la => "ROG Ally X RC72LA (sweep profile)",
            .rog_xbox_ally_rc73 => "ROG Xbox Ally RC73XA/RC73YA",
            .steam_deck_galileo => "Steam Deck OLED (Galileo)",
            .steam_deck_jupiter => "Steam Deck LCD (Jupiter)",
        };
    }
};

const boards = [_]struct { prefix: []const u8, target: Target }{
    .{ .prefix = "RC71L", .target = .rog_ally_rc71l },
    .{ .prefix = "RC72LA", .target = .rog_ally_x_rc72la },
    .{ .prefix = "RC73XA", .target = .rog_xbox_ally_rc73 },
    .{ .prefix = "RC73YA", .target = .rog_xbox_ally_rc73 },
};

const products = [_]struct { name: []const u8, target: Target }{
    .{ .name = "Galileo", .target = .steam_deck_galileo },
    .{ .name = "Jupiter", .target = .steam_deck_jupiter },
};

/// The driver profile this machine matches, or null (do not load).
pub fn target(info: handheld.SystemInfo) ?Target {
    const board = std.mem.trim(u8, info.board_product, " \t\r\n");
    for (boards) |entry| {
        if (std.mem.startsWith(u8, board, entry.prefix)) return entry.target;
    }
    const product = std.mem.trim(u8, info.product, " \t\r\n");
    for (products) |entry| {
        if (std.mem.eql(u8, product, entry.name)) return entry.target;
    }
    return null;
}

/// usos-settings.ini `touch_driver=auto|off` (default auto; anything
/// unknown keeps auto). off never loads the driver, even on a match.
pub const Mode = enum { auto, off };

pub fn parseMode(settings: []const u8) Mode {
    var mode: Mode = .auto;
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "touch_driver")) continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no")) {
            mode = .off;
        } else if (std.ascii.eqlIgnoreCase(value, "auto")) {
            mode = .auto;
        }
    }
    return mode;
}

pub const Decision = enum {
    load,
    disabled_by_setting,
    no_smbios,
    hardware_not_matched,

    pub fn text(self: Decision) []const u8 {
        return switch (self) {
            .load => "load",
            .disabled_by_setting => "skipped (touch_driver=off)",
            .no_smbios => "skipped (no SMBIOS table)",
            .hardware_not_matched => "skipped (SMBIOS does not match a supported handheld)",
        };
    }
};

pub fn decide(mode: Mode, info: ?handheld.SystemInfo) Decision {
    if (mode == .off) return .disabled_by_setting;
    const system = info orelse return .no_smbios;
    return if (target(system) != null) .load else .hardware_not_matched;
}

test "touch driver loads only on handhelds its profiles cover" {
    // ROG Ally 2023 as AMI reports it (and QEMU -smbios type=2,product=RC71L).
    try std.testing.expectEqual(@as(?Target, .rog_ally_rc71l), target(.{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "ROG Ally RC71L_RC71L", .board_product = "RC71L" }));
    try std.testing.expectEqual(@as(?Target, .rog_ally_x_rc72la), target(.{ .product = "ROG Ally X RC72LA_RC72LA", .board_product = "RC72LA" }));
    try std.testing.expectEqual(@as(?Target, .rog_xbox_ally_rc73), target(.{ .board_product = "RC73XA" }));
    try std.testing.expectEqual(@as(?Target, .rog_xbox_ally_rc73), target(.{ .board_product = "RC73YA" }));
    try std.testing.expectEqual(@as(?Target, .steam_deck_galileo), target(.{ .manufacturer = "Valve", .product = "Galileo", .board_product = "Galileo" }));
    try std.testing.expectEqual(@as(?Target, .steam_deck_jupiter), target(.{ .manufacturer = "Valve", .product = "Jupiter" }));
    // Desktops, QEMU and handhelds without a driver profile: never.
    try std.testing.expectEqual(@as(?Target, null), target(.{ .manufacturer = "To Be Filled By O.E.M.", .product = "To Be Filled By O.E.M.", .board_manufacturer = "ASRock", .board_product = "X470 Taichi" }));
    try std.testing.expectEqual(@as(?Target, null), target(.{ .manufacturer = "QEMU", .product = "Standard PC (Q35 + ICH9, 2009)" }));
    try std.testing.expectEqual(@as(?Target, null), target(.{ .manufacturer = "LENOVO", .product = "83E1", .version = "Legion Go 8APU1" }));
    // The product string alone ("ROG Ally RC71L_RC71L") is not the driver's key.
    try std.testing.expectEqual(@as(?Target, null), target(.{ .product = "ROG Ally RC71L_RC71L" }));
    // Case matters like in the driver (AsciiStrnCmp); "rc71l" is no match.
    try std.testing.expectEqual(@as(?Target, null), target(.{ .board_product = "rc71l" }));
    try std.testing.expectEqual(@as(?Target, null), target(.{}));
}

test "touch_driver setting and the load decision" {
    try std.testing.expectEqual(Mode.auto, parseMode(""));
    try std.testing.expectEqual(Mode.off, parseMode("[ui]\r\nlanguage=pl\r\ntouch_driver=off\r\n"));
    try std.testing.expectEqual(Mode.off, parseMode("touch_driver = OFF"));
    try std.testing.expectEqual(Mode.auto, parseMode("touch_driver=auto\n"));
    try std.testing.expectEqual(Mode.auto, parseMode("touch_driver=maybe\n"));
    try std.testing.expectEqual(Mode.auto, parseMode("touch_driver=off\ntouch_driver=auto\n"));
    const ally = handheld.SystemInfo{ .board_product = "RC71L" };
    try std.testing.expectEqual(Decision.load, decide(.auto, ally));
    try std.testing.expectEqual(Decision.disabled_by_setting, decide(.off, ally));
    try std.testing.expectEqual(Decision.no_smbios, decide(.auto, null));
    try std.testing.expectEqual(Decision.hardware_not_matched, decide(.auto, handheld.SystemInfo{ .board_product = "B550 Taichi" }));
}
