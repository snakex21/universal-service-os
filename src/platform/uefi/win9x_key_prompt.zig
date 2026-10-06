//! Windows 95 from the UEFI menu: phase 1 runs in the QEMU VM only with a
//! 95 key (tools/w9x_csmwrap_prepare.sh types it into the OEM COA page);
//! without one the target falls back to the native Setup start, which
//! freezes on modern boards. When neither the chosen profile nor any other
//! answer holds a 95 key, the menu asks for it here ("Enter the Windows 95
//! product key"). The key is used for this start only: it goes into the
//! staged 95.INF (removed by micro-Linux after it is copied to RAM) and is
//! never written to a profile or traced.
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
    if (!std.ascii.eqlIgnoreCase(system_id, "windows-95")) return false;
    if (answer_file) return false;
    const p = profile orelse return true;
    return !answer.applies.has95Key(p);
}

/// A Windows 95 key shape (OEM ddddd-OEM-ddddddd-ddddd or retail ddd-ddddddd).
pub fn valid95(value: []const u8) bool {
    const shape = answer.profile.keyShape(value) orelse return false;
    return shape != .five_by_five;
}

/// The profile staged for this start: `base` (the chosen profile, or the
/// USOS default owner "USOS" in the menu language's zone when null) with
/// key.windows-95 set to `key`.
pub fn withKey(base: ?*const Profile, ui_language: []const u8, key: []const u8) !Profile {
    var p: Profile = if (base) |b| b.* else blk: {
        var d = @import("profile_editor.zig").defaults(ui_language);
        // The USOS default MSBATCH.INF owner (an empty Name shows the page).
        try d.name.set("USOS");
        try d.user.set("USOS");
        try d.org.set("USOS");
        break :blk d;
    };
    p.remember_key = false;
    try p.setSystemKey("windows-95", key);
    return p;
}

fn hookInvalid(_: *anyopaque, index: usize) bool {
    return index == 0 and show_invalid and !valid95(key_text.slice());
}

/// Asks for the key; null on Back/Cancel. The returned slice lives until
/// the next call.
pub fn ask(system_name: []const u8) ?[]const u8 {
    key_text = .{ .max = 29 };
    show_invalid = false;
    var label: [96]u8 = undefined;
    var title: [96]u8 = undefined;
    fields[0] = .{ .kind = .text, .label = view.format(&label, .profile_field_key, &.{system_name}), .text = &key_text, .allowed = &key_chars, .uppercase = true, .product_key = true };
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
                if (valid95(key_text.slice())) return key_text.slice();
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
    try std.testing.expect(valid95("123-1234567") and !valid95("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") and !valid95("12345-OEM"));
}
