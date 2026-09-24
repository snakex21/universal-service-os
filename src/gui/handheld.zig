//! Handheld detection and the footer hint style ("last input wins"), shared
//! by the UEFI menu and the micro-Linux framebuffer menus.
//!
//! Handheld firmware often delivers the built-in controls as keyboard keys
//! (arrows/Enter/Esc) through a USB HID boot keyboard interface of the
//! controller MCU. Keys from such a device are pad input: the footer then
//! names A/B instead of Enter/Esc. The machine itself is recognised from
//! SMBIOS type 1/2 (UEFI) or /sys/class/dmi/id (Linux); on a handheld the
//! hints start in pad style, and keys whose origin is unknown only switch to
//! keyboard style when a pad cannot produce them (letters, digits, ...).
const std = @import("std");

pub const Handheld = enum {
    rog_ally,
    rog_ally_x,
    steam_deck,
    legion_go,
    legion_go_s,
    msi_claw,

    pub fn label(self: Handheld) []const u8 {
        return switch (self) {
            .rog_ally => "ASUS ROG Ally",
            .rog_ally_x => "ASUS ROG Ally X",
            .steam_deck => "Valve Steam Deck",
            .legion_go => "Lenovo Legion Go",
            .legion_go_s => "Lenovo Legion Go S",
            .msi_claw => "MSI Claw",
        };
    }
};

// ------------------------------------------------------------ USB IDs

/// Built-in handheld controllers that firmware (or the controller itself,
/// e.g. the Steam Deck's "lizard mode") presents as a HID keyboard/mouse.
/// Keys from these USB devices are pad presses.
///
/// - 0B05:1ABE ROG Ally controller MCU (seen on the hardware: interfaces
///   0/1/2 are HID boot keyboard/mouse bound by AMI; Linux hid-asus
///   USB_DEVICE_ID_ASUSTEK_ROG_NKEY_ALLY).
/// - 0B05:1B4C ROG Ally X (hid-asus USB_DEVICE_ID_ASUSTEK_ROG_NKEY_ALLY_X).
/// - 28DE:1205 Steam Deck controller (hid-steam USB_DEVICE_ID_STEAM_DECK).
/// - 17EF:6182..6185 Legion Go controllers in their XInput/DInput/dual/FPS
///   modes (Handheld Daemon's list; not verified on the hardware).
/// - 0DB0:1901..1903 MSI Claw in XInput/DInput/desktop mode (IDs from the
///   Linux MSI Claw patches and Handheld Daemon; not verified on the
///   hardware).
pub fn padKeyboard(vid: u16, pid: u16) ?Handheld {
    return switch (vid) {
        0x0B05 => switch (pid) {
            0x1ABE => .rog_ally,
            0x1B4C => .rog_ally_x,
            else => null,
        },
        0x28DE => if (pid == 0x1205) .steam_deck else null,
        0x17EF => if (pid >= 0x6182 and pid <= 0x6185) .legion_go else null,
        0x0DB0 => if (pid >= 0x1901 and pid <= 0x1903) .msi_claw else null,
        else => null,
    };
}

// ------------------------------------------------------------ DMI / SMBIOS

/// SMBIOS type 1 (system) and type 2 (baseboard) strings, or the same
/// values from /sys/class/dmi/id (sys_vendor, product_name,
/// product_version, board_vendor, board_name).
pub const SystemInfo = struct {
    manufacturer: []const u8 = "",
    product: []const u8 = "",
    version: []const u8 = "",
    board_manufacturer: []const u8 = "",
    board_product: []const u8 = "",
};

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn same(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), expected);
}

/// Known handhelds by their DMI strings:
/// - ASUS: product "ROG Ally RC71L_RC71L", "ROG Ally X RC72LA_RC72LA"
///   (board RC71L / RC72LA).
/// - Valve: vendor "Valve", product "Jupiter" (LCD) or "Galileo" (OLED).
/// - Lenovo: product (machine type) 83E1 = Legion Go (version "Legion Go
///   8APU1"); 83L3/83N6/83Q2/83Q3 = Legion Go S; any version containing
///   "Legion Go".
/// - MSI: vendor "Micro-Star International", product "Claw ..." (Claw A1M,
///   Claw 7/8 AI+ A2VM).
pub fn fromDmi(info: SystemInfo) ?Handheld {
    const asus = has(info.manufacturer, "ASUS") or has(info.board_manufacturer, "ASUS");
    if (asus or has(info.product, "ROG Ally")) {
        if (has(info.product, "ROG Ally X") or has(info.product, "RC72L") or has(info.board_product, "RC72L")) return .rog_ally_x;
        if (has(info.product, "ROG Ally") or has(info.product, "RC71L") or has(info.board_product, "RC71L")) return .rog_ally;
    }
    if (has(info.manufacturer, "Valve") or has(info.board_manufacturer, "Valve")) {
        if (same(info.product, "Jupiter") or same(info.product, "Galileo") or same(info.board_product, "Jupiter") or same(info.board_product, "Galileo")) return .steam_deck;
    }
    if (has(info.manufacturer, "LENOVO") or has(info.board_manufacturer, "LENOVO")) {
        if (has(info.version, "Legion Go S")) return .legion_go_s;
        if (has(info.version, "Legion Go")) return .legion_go;
        if (same(info.product, "83E1")) return .legion_go;
        for ([_][]const u8{ "83L3", "83N6", "83Q2", "83Q3" }) |model| {
            if (same(info.product, model)) return .legion_go_s;
        }
    }
    if (has(info.manufacturer, "Micro-Star") or has(info.board_manufacturer, "Micro-Star") or has(info.manufacturer, "MSI")) {
        const product = std.mem.trim(u8, info.product, " ");
        if (product.len >= 4 and std.ascii.eqlIgnoreCase(product[0..4], "Claw")) return .msi_claw;
    }
    return null;
}

/// Reads type 1 and type 2 strings from an SMBIOS structure table (the
/// area the SMBIOS/SMBIOS3 entry point's table address points to). The
/// returned slices point into `table`.
pub fn parseSmbios(table: []const u8) SystemInfo {
    var info = SystemInfo{};
    var offset: usize = 0;
    var guard: usize = 0;
    while (offset + 4 <= table.len and guard < 1024) : (guard += 1) {
        const kind = table[offset];
        const length = table[offset + 1];
        if (length < 4 or offset + length > table.len) break;
        const formatted = table[offset .. offset + length];
        // The string set follows the formatted area and ends with two NULs.
        var end = offset + length;
        while (end + 1 < table.len and !(table[end] == 0 and table[end + 1] == 0)) : (end += 1) {}
        if (end + 1 >= table.len) break;
        const strings = table[offset + length .. end + 1];
        switch (kind) {
            1 => {
                info.manufacturer = smbiosString(formatted, strings, 0x04);
                info.product = smbiosString(formatted, strings, 0x05);
                info.version = smbiosString(formatted, strings, 0x06);
            },
            2 => if (info.board_manufacturer.len == 0 and info.board_product.len == 0) {
                info.board_manufacturer = smbiosString(formatted, strings, 0x04);
                info.board_product = smbiosString(formatted, strings, 0x05);
            },
            127 => break,
            else => {},
        }
        offset = end + 2;
    }
    return info;
}

fn smbiosString(formatted: []const u8, strings: []const u8, field: usize) []const u8 {
    if (field >= formatted.len) return "";
    const number = formatted[field];
    if (number == 0) return "";
    var index: u8 = 1;
    var iterator = std.mem.splitScalar(u8, strings, 0);
    while (iterator.next()) |value| : (index += 1) {
        if (value.len == 0) return "";
        if (index == number) return std.mem.trim(u8, value, " ");
    }
    return "";
}

/// SMBIOS 2.x ("_SM_") or 3.x ("_SM3_") entry point to the structure table
/// address and maximum length.
pub fn smbiosTable(entry: []const u8) ?struct { address: u64, length: usize } {
    if (entry.len >= 0x18 and std.mem.eql(u8, entry[0..5], "_SM3_")) {
        return .{ .address = std.mem.readInt(u64, entry[0x10..0x18], .little), .length = std.mem.readInt(u32, entry[0x0C..0x10], .little) };
    }
    if (entry.len >= 0x1E and std.mem.eql(u8, entry[0..4], "_SM_") and std.mem.eql(u8, entry[0x10..0x15], "_DMI_")) {
        return .{ .address = std.mem.readInt(u32, entry[0x18..0x1C], .little), .length = std.mem.readInt(u16, entry[0x16..0x18], .little) };
    }
    return null;
}

// ------------------------------------------------------------ hint style

/// Where a key press came from.
pub const KeyOrigin = enum {
    /// A keyboard device (USB keyboard, serial terminal, a desktop's PS/2).
    keyboard,
    /// A handheld controller presented as a keyboard (padKeyboard IDs).
    pad,
    /// Unknown: the ConIn splitter only, or a handheld's PS/2 (EC) keyboard
    /// that may carry both built-in buttons and a real keyboard.
    unattributed,
};

/// The footer style after a key press; true = pad hints (A/B).
/// `keyboard_only` = a key a pad cannot produce (letters, digits, other
/// printable characters except Space).
pub fn styleAfterKey(pad_style: bool, handheld: bool, origin: KeyOrigin, keyboard_only: bool) bool {
    return switch (origin) {
        .keyboard => false,
        .pad => true,
        .unattributed => if (!handheld or keyboard_only) false else pad_style,
    };
}

/// The footer style after a pointer event. Clicks and wheel turns switch to
/// keyboard hints, except a touch tap on a handheld (the player is holding
/// the pad) and clicks from a pad's own pointer (a stick as a mouse).
pub fn styleAfterPointer(pad_style: bool, handheld: bool, click_or_wheel: bool, touch: bool, from_pad: bool) bool {
    if (from_pad and click_or_wheel) return true;
    if (!click_or_wheel) return pad_style;
    if (touch and handheld) return pad_style;
    return false;
}

/// A UEFI key a pad cannot produce: a printable character other than Space.
pub fn uefiKeyboardOnly(scan: u16, unicode: u16) bool {
    _ = scan;
    return unicode > 0x20 and unicode != 0x7F;
}

/// An evdev key a pad cannot produce: the letter, digit and punctuation
/// keys of the main block (KEY_1..KEY_EQUAL, KEY_Q..KEY_RIGHTBRACE,
/// KEY_A..KEY_GRAVE, KEY_BACKSLASH..KEY_SLASH). Space is not one.
pub fn evdevKeyboardOnly(code: u16) bool {
    return (code >= 2 and code <= 13) or (code >= 16 and code <= 27) or (code >= 30 and code <= 41) or (code >= 43 and code <= 53);
}

// ------------------------------------------------------------ tests

test "handheld controller USB IDs" {
    try std.testing.expectEqual(@as(?Handheld, .rog_ally), padKeyboard(0x0B05, 0x1ABE));
    try std.testing.expectEqual(@as(?Handheld, .rog_ally_x), padKeyboard(0x0B05, 0x1B4C));
    try std.testing.expectEqual(@as(?Handheld, .steam_deck), padKeyboard(0x28DE, 0x1205));
    try std.testing.expectEqual(@as(?Handheld, .legion_go), padKeyboard(0x17EF, 0x6182));
    try std.testing.expectEqual(@as(?Handheld, .legion_go), padKeyboard(0x17EF, 0x6185));
    try std.testing.expectEqual(@as(?Handheld, null), padKeyboard(0x17EF, 0x6186));
    try std.testing.expectEqual(@as(?Handheld, .msi_claw), padKeyboard(0x0DB0, 0x1901));
    try std.testing.expectEqual(@as(?Handheld, null), padKeyboard(0x0B05, 0x1A38)); // an ASUS keyboard
    try std.testing.expectEqual(@as(?Handheld, null), padKeyboard(0x046D, 0xC31C)); // Logitech keyboard
    try std.testing.expectEqual(@as(?Handheld, null), padKeyboard(0x045E, 0x028E)); // XInput: read as a pad directly
}

test "handhelds by DMI strings" {
    try std.testing.expectEqual(@as(?Handheld, .rog_ally), fromDmi(.{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "ROG Ally RC71L_RC71L", .board_product = "RC71L" }));
    try std.testing.expectEqual(@as(?Handheld, .rog_ally_x), fromDmi(.{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "ROG Ally X RC72LA_RC72LA" }));
    try std.testing.expectEqual(@as(?Handheld, .rog_ally), fromDmi(.{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "System Product Name", .board_product = "RC71L" }));
    try std.testing.expectEqual(@as(?Handheld, .steam_deck), fromDmi(.{ .manufacturer = "Valve", .product = "Jupiter" }));
    try std.testing.expectEqual(@as(?Handheld, .steam_deck), fromDmi(.{ .manufacturer = "Valve", .product = "Galileo\n" }));
    try std.testing.expectEqual(@as(?Handheld, .legion_go), fromDmi(.{ .manufacturer = "LENOVO", .product = "83E1", .version = "Legion Go 8APU1" }));
    try std.testing.expectEqual(@as(?Handheld, .legion_go), fromDmi(.{ .manufacturer = "LENOVO", .product = "83E1" }));
    try std.testing.expectEqual(@as(?Handheld, .legion_go_s), fromDmi(.{ .manufacturer = "LENOVO", .product = "83L3", .version = "Legion Go S 8ARP1" }));
    try std.testing.expectEqual(@as(?Handheld, .msi_claw), fromDmi(.{ .manufacturer = "Micro-Star International Co., Ltd.", .product = "Claw A1M" }));
    try std.testing.expectEqual(@as(?Handheld, .msi_claw), fromDmi(.{ .manufacturer = "Micro-Star International Co., Ltd.", .product = "Claw 8 AI+ A2VM" }));
    // Desktops and laptops of the same vendors are not handhelds.
    try std.testing.expectEqual(@as(?Handheld, null), fromDmi(.{ .manufacturer = "ASUSTeK COMPUTER INC.", .product = "ROG STRIX B550-F GAMING" }));
    try std.testing.expectEqual(@as(?Handheld, null), fromDmi(.{ .manufacturer = "LENOVO", .product = "82JW", .version = "Legion 5 15ACH6H" }));
    try std.testing.expectEqual(@as(?Handheld, null), fromDmi(.{ .manufacturer = "Micro-Star International Co., Ltd.", .product = "MS-7C56" }));
    try std.testing.expectEqual(@as(?Handheld, null), fromDmi(.{ .manufacturer = "To Be Filled By O.E.M.", .product = "To Be Filled By O.E.M.", .board_manufacturer = "ASRock", .board_product = "B550 Taichi" }));
    try std.testing.expectEqual(@as(?Handheld, null), fromDmi(.{}));
}

fn appendStructure(list: *std.ArrayList(u8), kind: u8, formatted: []const u8, strings: []const []const u8) !void {
    try list.append(std.testing.allocator, kind);
    try list.append(std.testing.allocator, @intCast(formatted.len + 4));
    try list.appendSlice(std.testing.allocator, &.{ 0x00, 0x01 });
    try list.appendSlice(std.testing.allocator, formatted);
    for (strings) |value| {
        try list.appendSlice(std.testing.allocator, value);
        try list.append(std.testing.allocator, 0);
    }
    if (strings.len == 0) try list.append(std.testing.allocator, 0);
    try list.append(std.testing.allocator, 0);
}

test "SMBIOS type 1 and type 2 strings" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    // Type 0 (BIOS) with no strings, then type 1, type 2, end of table.
    try appendStructure(&list, 0, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &.{});
    try appendStructure(&list, 1, &.{ 1, 2, 3, 0 }, &.{ "ASUSTeK COMPUTER INC.", "ROG Ally RC71L_RC71L ", "1.0" });
    try appendStructure(&list, 2, &.{ 1, 2, 0, 0 }, &.{ "ASUSTeK COMPUTER INC.", "RC71L" });
    try appendStructure(&list, 127, &.{}, &.{});
    const info = parseSmbios(list.items);
    try std.testing.expectEqualStrings("ASUSTeK COMPUTER INC.", info.manufacturer);
    try std.testing.expectEqualStrings("ROG Ally RC71L_RC71L", info.product);
    try std.testing.expectEqualStrings("1.0", info.version);
    try std.testing.expectEqualStrings("RC71L", info.board_product);
    try std.testing.expectEqual(@as(?Handheld, .rog_ally), fromDmi(info));

    // Truncated or empty tables never read out of bounds.
    _ = parseSmbios(list.items[0 .. list.items.len / 2]);
    _ = parseSmbios(&.{});
    try std.testing.expectEqualStrings("", parseSmbios(&.{ 1, 8, 0, 0, 5, 0, 0, 0, 0, 0 }).manufacturer);
}

test "SMBIOS entry points" {
    var entry3 = [_]u8{0} ** 0x18;
    @memcpy(entry3[0..5], "_SM3_");
    std.mem.writeInt(u32, entry3[0x0C..0x10], 0x1234, .little);
    std.mem.writeInt(u64, entry3[0x10..0x18], 0x8C00_0000, .little);
    const table3 = smbiosTable(&entry3).?;
    try std.testing.expectEqual(@as(u64, 0x8C00_0000), table3.address);
    try std.testing.expectEqual(@as(usize, 0x1234), table3.length);

    var entry2 = [_]u8{0} ** 0x1F;
    @memcpy(entry2[0..4], "_SM_");
    @memcpy(entry2[0x10..0x15], "_DMI_");
    std.mem.writeInt(u16, entry2[0x16..0x18], 0x800, .little);
    std.mem.writeInt(u32, entry2[0x18..0x1C], 0x000F_0000, .little);
    const table2 = smbiosTable(&entry2).?;
    try std.testing.expectEqual(@as(u64, 0xF_0000), table2.address);
    try std.testing.expectEqual(@as(usize, 0x800), table2.length);
    try std.testing.expectEqual(@as(?@TypeOf(table2), null), smbiosTable("garbage garbage garbage garbage"));
}

test "last input wins, with handheld rules for unattributed keys" {
    // Attributed keys decide on their own.
    try std.testing.expect(!styleAfterKey(true, true, .keyboard, false));
    try std.testing.expect(styleAfterKey(false, false, .pad, false));
    // Unattributed on a desktop: keyboard.
    try std.testing.expect(!styleAfterKey(true, false, .unattributed, false));
    // Unattributed on a handheld: arrows/Enter/Esc/Space keep the style,
    // a letter or digit means a keyboard.
    try std.testing.expect(styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0x01, 0)));
    try std.testing.expect(styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0, ' ')));
    try std.testing.expect(styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0, 13)));
    try std.testing.expect(styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0, 27)));
    try std.testing.expect(!styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0, 'a')));
    try std.testing.expect(!styleAfterKey(true, true, .unattributed, uefiKeyboardOnly(0, '7')));
    try std.testing.expect(!styleAfterKey(false, true, .unattributed, false));
    try std.testing.expect(evdevKeyboardOnly(30)); // KEY_A
    try std.testing.expect(evdevKeyboardOnly(2)); // KEY_1
    try std.testing.expect(!evdevKeyboardOnly(57)); // KEY_SPACE
    try std.testing.expect(!evdevKeyboardOnly(28)); // KEY_ENTER
    try std.testing.expect(!evdevKeyboardOnly(1)); // KEY_ESC
    try std.testing.expect(!evdevKeyboardOnly(103)); // KEY_UP
}

test "pointer input and the hint style" {
    // A mouse click or wheel turn means keyboard hints.
    try std.testing.expect(!styleAfterPointer(true, false, true, false, false));
    try std.testing.expect(!styleAfterPointer(true, true, true, false, false));
    // A touch tap on a handheld keeps pad hints; on a desktop it does not.
    try std.testing.expect(styleAfterPointer(true, true, true, true, false));
    try std.testing.expect(!styleAfterPointer(true, false, true, true, false));
    // Movement alone changes nothing; the pad's own pointer means pad.
    try std.testing.expect(styleAfterPointer(true, false, false, false, false));
    try std.testing.expect(styleAfterPointer(false, false, true, false, true));
}
