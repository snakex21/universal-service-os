//! Secure Boot key UI: the home-screen offer ("save the USOS key?"), the
//! confirmation, the result, and the Tools -> Secure Boot page with the
//! computer's state, "Add the key", "Open BIOS settings" and the
//! "Remind on the home screen" toggle. Storage and rules: mok_key.zig.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const input = @import("input.zig");
const mok_key = @import("mok_key.zig");
const manual_power = @import("manual_power.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const settings_store = @import("settings_store.zig");

var root_dir: ?*uefi.protocol.File = null;
/// "Not now" hides the banner until the next start.
var dismissed = false;

pub fn init(root: *uefi.protocol.File) void {
    root_dir = root;
    _ = mok_key.status(root);
    mok_key.writeReport(root);
}

fn currentSettings() []const u8 {
    return settings_store.current();
}

fn status() mok_key.Status {
    const root = root_dir orelse return .{};
    return mok_key.status(root);
}

/// The home banner (message, action) or null.
pub fn banner() ?[2][]const u8 {
    if (dismissed) return null;
    const current = status();
    if (!usos.flow.mok_list.shouldOffer(current.state, current.key, current.certificate, !mok_key.remindEnabled(currentSettings()))) return null;
    if (current.untrusted_list) return null;
    return .{ view.t(.sbkey_banner), view.t(.sbkey_banner_action) };
}

// ------------------------------------------------------------ offer

/// Banner activated: [Add] [Not now] [Don't ask again].
pub fn offer() void {
    var rows = [_]usos.gui.ui.Row{
        .{ .title = view.t(.sbkey_add), .icon = .{ .vector = .shield } },
        .{ .title = view.t(.sbkey_not_now), .icon = .{ .vector = .chevron_left } },
        .{ .title = view.t(.sbkey_never), .icon = .{ .vector = .close } },
    };
    const lines = [_][]const u8{ view.t(.sbkey_offer_line1), view.t(.sbkey_offer_line2) };
    const help = usos.gui.menu_screens.Help{ .title = view.t(.sbkey_title), .lines = &lines };
    var selected: usize = 0;
    var list: view.ListScreen = undefined;
    list.open(view.t(.sbkey_title), view.t(.sbkey_banner), &rows, selected, false, help);
    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, rows.len, &list)) {
            .activate => switch (selected) {
                0 => {
                    addWithConfirmation();
                    return;
                },
                1 => {
                    dismissed = true;
                    return;
                },
                else => {
                    setRemind(false);
                    const note = [_][]const u8{view.t(.sbkey_never_note)};
                    view.notice(view.t(.sbkey_title), .info, .neutral, "", &note);
                    view.waitForDismiss();
                    return;
                },
            },
            .back => return,
            .changed => list.updateSelection(selected, help),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

/// "Do you agree to save the USOS key?" [Yes] [No], then save and report.
fn addWithConfirmation() void {
    var rows = [_]usos.gui.ui.Row{
        .{ .title = view.t(.sbkey_yes), .icon = .{ .vector = .check } },
        .{ .title = view.t(.sbkey_no), .icon = .{ .vector = .close } },
    };
    const lines = [_][]const u8{ view.t(.sbkey_confirm_line1), view.t(.sbkey_confirm_line2) };
    const help = usos.gui.menu_screens.Help{ .title = view.t(.sbkey_confirm_title), .lines = &lines };
    // "No" is preselected: saving needs a deliberate move.
    var selected: usize = 1;
    var list: view.ListScreen = undefined;
    list.open(view.t(.sbkey_confirm_title), view.t(.sbkey_title), &rows, selected, false, help);
    while (true) {
        switch (navigation.handle(input.readBlocking(), &selected, rows.len, &list)) {
            .activate => {
                if (selected != 0) return;
                return saveAndReport();
            },
            .back => return,
            .changed => list.updateSelection(selected, help),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn saveAndReport() void {
    const root = root_dir orelse return;
    mok_key.save(root) catch |err| {
        const lines = [_][]const u8{ view.t(.sbkey_failed_line1), @errorName(err) };
        view.notice(view.t(.sbkey_failed_title), .error_circle, .danger, "", &lines);
        view.waitForDismiss();
        return;
    };
    mok_key.writeReport(root);
    savedScreen();
}

/// "Key saved. You can now turn Secure Boot on in the BIOS settings."
/// [Open BIOS settings] [Back to the menu].
fn savedScreen() void {
    const firmware_ui = manual_power.firmwareUiSupported();
    var rows = [_]usos.gui.ui.Row{
        .{ .title = view.t(.sbkey_open_setup), .detail = if (firmware_ui) "" else view.t(.power_firmware_unsupported), .icon = .{ .vector = .firmware }, .enabled = firmware_ui },
        .{ .title = view.t(.sbkey_back_menu), .icon = .{ .vector = .chevron_left } },
    };
    var selectable = [_]bool{ firmware_ui, true };
    const lines = [_][]const u8{view.t(.sbkey_saved_line1)};
    const help = usos.gui.menu_screens.Help{ .title = view.t(.sbkey_saved_title), .lines = &lines, .badge = .{ .text = view.t(.sbinfo_key_short_saved), .tone = .success } };
    var selected: usize = if (firmware_ui) 0 else 1;
    var list: view.ListScreen = undefined;
    list.open(view.t(.sbkey_saved_title), view.t(.sbkey_title), &rows, selected, false, help);
    while (true) {
        switch (navigation.handleSelectable(input.readBlocking(), &selected, rows.len, &list, &selectable)) {
            .activate => {
                if (selected == 1) return;
                manual_power.openFirmwareSetup();
                list.redrawFull(selected, help);
            },
            .back => return,
            .changed => list.updateSelection(selected, help),
            .pointer_moved => view.updatePointer(),
            .ignored => {},
        }
    }
}

fn setRemind(enabled: bool) void {
    settings_store.set(mok_key.remind_key, if (enabled) "1" else "0") catch |err| {
        const lines = [_][]const u8{@errorName(err)};
        view.notice(view.t(.sbkey_title), .warning, .warning, "", &lines);
        view.waitForDismiss();
        return;
    };
}

// ------------------------------------------------------------ Tools page

/// The Tools list row for this page.
pub fn toolsRow() usos.gui.ui.Row {
    const current = status();
    const badge: ?usos.gui.ui.Badge = switch (current.key) {
        .saved => .{ .text = view.t(.sbinfo_key_short_saved), .tone = .success },
        .missing => .{ .text = view.t(.sbinfo_key_short_missing), .tone = .warning },
        .unknown => null,
    };
    return .{ .title = view.t(.sbinfo_title), .detail = view.t(.sbinfo_desc), .icon = .{ .vector = .shield }, .badge = badge };
}

const row_count = 4;

pub fn page() void {
    var selected: usize = 0;
    while (true) {
        const current = status();
        const firmware_ui = manual_power.firmwareUiSupported();
        const remind = mok_key.remindEnabled(currentSettings());
        var rows = [row_count]usos.gui.ui.Row{
            .{ .title = view.t(.sbkey_add), .detail = addDetail(current), .icon = .{ .vector = .shield }, .enabled = current.canSave() },
            .{ .title = view.t(.sbkey_open_setup), .detail = if (firmware_ui) "" else view.t(.power_firmware_unsupported), .icon = .{ .vector = .firmware }, .enabled = firmware_ui },
            .{ .title = view.t(.sbinfo_remind), .icon = .{ .vector = .info }, .badge = .{ .text = if (remind) view.t(.sbinfo_on) else view.t(.sbinfo_off), .tone = if (remind) .success else .neutral } },
            .{ .title = view.t(.sbinfo_how), .icon = .{ .vector = .chevron_right } },
        };
        var selectable = [row_count]bool{ current.canSave(), firmware_ui, true, true };
        if (!selectable[selected]) selected = usos.gui.selectable_list.first(&selectable) orelse 2;
        var lines: [6][]const u8 = undefined;
        const help = stateHelp(current, &lines);
        var list: view.ListScreen = undefined;
        list.open(view.t(.sbinfo_title), view.t(.sbinfo_desc), &rows, selected, false, help);
        const action: ?usize = loop: while (true) {
            switch (navigation.handleSelectable(input.readBlocking(), &selected, row_count, &list, &selectable)) {
                .activate => break :loop selected,
                .back => break :loop null,
                .changed => list.updateSelection(selected, help),
                .pointer_moved => view.updatePointer(),
                .ignored => {},
            }
        };
        switch (action orelse return) {
            0 => addWithConfirmation(),
            1 => manual_power.openFirmwareSetup(),
            2 => {
                setRemind(!remind);
                if (!remind) dismissed = false;
            },
            else => howTo(),
        }
    }
}

fn addDetail(current: mok_key.Status) []const u8 {
    if (!current.certificate) return view.t(.sbinfo_no_cert);
    if (current.key == .saved) return view.t(.sbinfo_key_saved);
    if (current.state != .disabled) return view.t(.sbinfo_add_needs_off);
    return "";
}

/// Help panel: key status as the title, Secure Boot / platform key lines.
fn stateHelp(current: mok_key.Status, lines: *[6][]const u8) usos.gui.menu_screens.Help {
    var count: usize = 0;
    lines[count] = switch (current.key) {
        .saved => view.t(.sbinfo_key_saved),
        .missing => view.t(.sbinfo_key_missing),
        .unknown => view.t(.sbinfo_key_unknown),
    };
    count += 1;
    lines[count] = switch (current.state) {
        .enforcing => view.t(.sbinfo_sb_on),
        .disabled => view.t(.sbinfo_sb_off),
        .setup_mode => view.t(.sbinfo_sb_setup),
        .unsupported => view.t(.sbinfo_sb_unsupported),
    };
    count += 1;
    if (current.state != .unsupported) {
        lines[count] = if (current.canEnable()) view.t(.sbinfo_pk_yes) else view.t(.sbinfo_pk_no);
        count += 1;
    }
    if (current.denied) {
        lines[count] = view.t(.sbinfo_key_denied);
        count += 1;
    }
    if (current.key == .saved) {
        lines[count] = view.t(.sbinfo_remove_hint);
        count += 1;
    }
    const title = view.t(.sbkey_title);
    const badge: usos.gui.ui.Badge = switch (current.key) {
        .saved => .{ .text = view.t(.sbinfo_key_short_saved), .tone = .success },
        .missing => .{ .text = view.t(.sbinfo_key_short_missing), .tone = .warning },
        .unknown => .{ .text = "?", .tone = .neutral },
    };
    return .{ .title = title, .lines = lines[0..count], .badge = badge };
}

fn howTo() void {
    const lines = [_][]const u8{ view.t(.sbinfo_how_line1), view.t(.sbinfo_how_line2), view.t(.sbinfo_how_line3), view.t(.sbinfo_how_line4) };
    view.notice(view.t(.sbinfo_how), .shield, .neutral, "", &lines);
    view.waitForDismiss();
}
