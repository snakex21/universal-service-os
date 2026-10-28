//! Windows 95 from the UEFI menu: phase 1 runs in the QEMU VM only with a
//! 95 key (tools/w9x_csmwrap_prepare.sh types it into the OEM COA page);
//! without one the target falls back to the native Setup start, which
//! freezes on modern boards. When neither the chosen profile nor any other
//! answer holds a 95 key, the menu asks for it here ("Enter the Windows 95
//! product key"). The key is used for this start only: it goes into the
//! staged 95.INF (removed by micro-Linux after it is copied to RAM) and is
//! never written to a profile or traced.
//!
//! Windows 95 (2026-10-27): the key is optional. On the native phase 1
//! (EFI/USOS/win9x/phase1-native.flag) Setup shows its own Product ID page
//! and USOSPID.DRV types a staged key there; an empty key leaves that page
//! to the user. The field takes the 10-digit CD key (ddd-ddddddd, retail
//! CDs, SETUPPP.INF ProductType 1-6) and the OEM ID
//! (ddddd-OEM-ddddddd-ddddd, ProductType 7-9: every local 95 RTM / OSR1 /
//! OSR2.1 CD). The CD's ProductType sits in PRECOPY2.CAB (MSZIP; LZX on
//! OSR2), too costly to read here, so both shapes are accepted.
//!
//! Windows NT 4.0 (Workstation / Server, 2026-10-07): the same prompt and
//! key shapes; its install runs fully in the VM and GUI Setup would wait on
//! the key page, so the key is asked the same way (staged in NT4.SIF).
const std = @import("std");
const usos = @import("usos");
const form = @import("manual_form.zig");
const view = @import("manual_view.zig");

const answer = usos.flow.answer;
const Profile = answer.Profile;

const key_chars = form.charset("", true);

var key_text = form.TextValue{ .max = 29 };
var fields: [3]form.Field = undefined;
var show_invalid = false;
var dummy_context: u8 = 0;
const continue_id: u8 = 1;
const cancel_id: u8 = 2;

/// The system needs a 95 key from the menu: windows-95 with a profile
/// (or none) that lacks a 95-shaped key. A DATA answer file is the user's
/// own (its ProductID is checked by micro-Linux).
pub fn needed(system_id: []const u8, profile: ?*const Profile, answer_file: bool) bool {
    const nt4 = answer.nt4.isNt4(system_id);
    const posready = answer.posready.isPosReady(system_id);
    if (!std.ascii.eqlIgnoreCase(system_id, "windows-95") and !nt4 and !posready) return false;
    if (answer_file) return false;
    const p = profile orelse return true;
    if (nt4) return !answer.nt4.validKey(p.keyFor(system_id));
    if (posready) return !answer.posready.validKey(p.keyFor(system_id));
    // Manual Setup (win9x_setup=manual): Setup's own page asks for the key.
    if (p.win9x_setup == .manual) return false;
    return !answer.applies.has95Key(p);
}

/// A Windows 95 key shape (OEM ddddd-OEM-ddddddd-ddddd or retail ddd-ddddddd).
pub fn valid95(value: []const u8) bool {
    const shape = answer.profile.keyShape(value) orelse return false;
    return shape != .five_by_five;
}

/// The profile staged for this start: `base` (the chosen profile, or the
/// USOS default owner "USOS" in the menu language's zone when null) with
/// key.<system_id> set to `key`.
pub fn withKey(base: ?*const Profile, ui_language: []const u8, system_id: []const u8, key: []const u8) !Profile {
    var p: Profile = if (base) |b| b.* else blk: {
        var d = @import("profile_editor.zig").defaults(ui_language);
        // The USOS default MSBATCH.INF owner (an empty Name shows the page).
        try d.name.set("USOS");
        try d.user.set("USOS");
        try d.org.set("USOS");
        break :blk d;
    };
    p.remember_key = false;
    try p.setSystemKey(system_id, key);
    return p;
}

/// POSReady 2009 takes a 5x5 key; Windows 95 / NT 4.0 the 95 shapes.
var want_five_by_five = false;
/// Windows 95 / NT 4.0: an empty key goes on.
var may_be_empty = false;

/// Windows 95 may start without a key: Setup asks on its own Product ID
/// page. NT 4.0 too (2026-10-28): a Select / MSDN CD has no key page, and
/// for any other CD micro-Linux stops before the disk is changed
/// (nt4_key_gate in tools/nt4_csmwrap_target.sh) instead of letting the
/// install VM wait on the page. POSReady still needs one.
pub fn optional(system_id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(system_id, "windows-95") or answer.nt4.isNt4(system_id);
}

fn validInput(value: []const u8) bool {
    if (value.len == 0 and may_be_empty) return true;
    return if (want_five_by_five) answer.posready.validKey(value) else valid95(value);
}

fn hookInvalid(_: *anyopaque, index: usize) bool {
    return index == 0 and show_invalid and !validInput(key_text.slice());
}

/// Asks for the key; null on Back/Cancel, empty when an optional key
/// (Windows 95, NT 4.0) was left out. The returned slice lives until the next call.
pub fn ask(system_name: []const u8, system_id: []const u8) ?[]const u8 {
    want_five_by_five = answer.posready.isPosReady(system_id);
    may_be_empty = optional(system_id);
    key_text = .{ .max = 29 };
    show_invalid = false;
    var label: [96]u8 = undefined;
    var title: [96]u8 = undefined;
    // Windows 95 / NT 4.0: the label names the two shapes (the title
    // already names the system); the subtitle says Setup's page asks.
    const label_arg = if (want_five_by_five) system_name else answer.profile.keyFormats(.win95);
    fields[0] = .{ .kind = .text, .label = view.format(&label, .profile_field_key, &.{label_arg}), .text = &key_text, .allowed = &key_chars, .uppercase = true, .product_key = true, .key_style = if (want_five_by_five) .any else .win95 };
    fields[1] = .{ .kind = .action, .label = view.t(.key_continue), .primary = true, .id = continue_id };
    fields[2] = .{ .kind = .action, .label = view.t(.profile_cancel), .id = cancel_id };
    const hooks = form.Hooks{ .context = @ptrCast(&dummy_context), .invalid = hookInvalid };
    var selected: usize = 0;
    const heading = view.format(&title, .win9x_key_title, &.{system_name});
    while (true) {
        switch (form.run(heading, view.t(.win9x_key_subtitle), &fields, hooks, &selected)) {
            .back => return null,
            .x_on, .y_on => {},
            .action => |id| {
                if (id == cancel_id) return null;
                if (validInput(key_text.slice())) return key_text.slice();
                show_invalid = true;
                selected = 0;
            },
        }
    }
}

test "a 95 key is asked only for Windows 95 without one" {
    var p = Profile{};
    try std.testing.expect(needed("windows-95", null, false));
    try std.testing.expect(needed("windows-95", &p, false));
    try std.testing.expect(!needed("windows-95", null, true));
    try std.testing.expect(!needed("windows-98-se", null, false));
    try p.setSystemKey("windows-95", "12345-OEM-1234567-12345");
    try std.testing.expect(!needed("windows-95", &p, false));
    try std.testing.expect(needed("windows-nt-4", &p, false) and needed("windows-nt-4-server", null, false));
    try p.setSystemKey("windows-nt-4", "123-4567890");
    try std.testing.expect(!needed("windows-nt-4", &p, false) and !needed("windows-nt-4", null, true));
    // NT 3.51 takes no key (INITIAL.INF DisplayPidDlg = NO): never asked.
    try std.testing.expect(!needed("windows-nt-3-51", null, false) and !needed("windows-nt-3-51-server", null, false));
    // POSReady 2009: a 5x5 key.
    try std.testing.expect(needed("windows-embedded-posready-2009", null, false));
    try p.setSystemKey("windows-embedded-posready-2009", "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try std.testing.expect(!needed("windows-embedded-posready-2009", &p, false));
    try std.testing.expect(valid95("123-1234567") and !valid95("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") and !valid95("12345-OEM"));
    // Manual Setup: Setup's own page asks, not the menu.
    var manual = Profile{ .win9x_setup = .manual };
    try std.testing.expect(!needed("windows-95", &manual, false));
    try std.testing.expect(needed("windows-95", null, false));
    // Windows 95 and NT 4.0: the key may be left out; POSReady needs its key.
    try std.testing.expect(optional("windows-95") and optional("windows-nt-4") and optional("windows-nt-4-server") and optional("windows-nt-4-tse"));
    try std.testing.expect(!optional("windows-embedded-posready-2009") and !optional("windows-98-se") and !optional("windows-nt-3-51"));
    may_be_empty = true;
    want_five_by_five = false;
    try std.testing.expect(validInput("") and validInput("123-4567890") and validInput("12345-OEM-0000007-54321") and !validInput("123-45"));
    may_be_empty = false;
    try std.testing.expect(!validInput(""));
    // The CD key typed as on the yellow sticker is a 95 key.
    try std.testing.expect(valid95("875-1234567"));
}
