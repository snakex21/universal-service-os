//! Tools -> Drivers: the built-in UEFI drivers (NTFS, TouchI2cDxe) and the
//! user drivers from DATA\Drivers\UEFI with their match result, Secure
//! Boot status and load result, and an on/off toggle per driver. The
//! toggles are usos-settings.ini keys on the ESP (touch_driver=auto|off,
//! driver.<folder>=on|off) because the menu reads DATA read-only; they
//! take effect at the next start. Loading and rules: uefi_drivers.zig,
//! src/flow/driver_manifest.zig.
const std = @import("std");
const usos = @import("usos");
const input = @import("input.zig");
const navigation = @import("manual_navigation.zig");
const view = @import("manual_view.zig");
const uefi_drivers = @import("uefi_drivers.zig");
const touch_driver = @import("touch_driver.zig");
const settings_store = @import("settings_store.zig");
const secure_boot = @import("secure_boot.zig");

const Row = usos.gui.ui.Row;
const Help = usos.gui.menu_screens.Help;
const touch_policy = usos.flow.touch_driver_policy;

const builtin_rows = 2;
const max_rows = builtin_rows + uefi_drivers.max_drivers + 1;

/// The Tools list row for this page.
pub fn toolsRow() Row {
    const drivers = uefi_drivers.list();
    var started: usize = 0;
    for (drivers) |*entry| {
        if (entry.outcome == .started) started += 1;
    }
    return .{ .title = view.t(.drivers_title), .detail = view.t(.drivers_desc), .icon = .{ .vector = .chip }, .badge = if (drivers.len == 0) null else .{ .text = countText(started, drivers.len), .tone = if (started == drivers.len) .success else .neutral } };
}

var count_text: [16]u8 = undefined;

fn countText(started: usize, total: usize) []const u8 {
    return std.fmt.bufPrint(&count_text, "{d}/{d}", .{ started, total }) catch "";
}

var details: [max_rows][160]u8 = undefined;
var help_lines: [8][]const u8 = undefined;
var help_text: [8][200]u8 = undefined;

pub fn page() void {
    var selected: usize = 0;
    var changed = false;
    while (true) {
        const drivers = uefi_drivers.list();
        var rows: [max_rows]Row = undefined;
        var selectable: [max_rows]bool = undefined;
        rows[0] = .{ .title = "NTFS", .detail = view.t(.drivers_ntfs_detail), .icon = .{ .vector = .drive }, .badge = .{ .text = view.t(.drivers_builtin), .tone = .neutral } };
        selectable[0] = true;
        const touch = touch_driver.report();
        const touch_on = touch.mode == .auto;
        rows[1] = .{ .title = "TouchI2cDxe", .detail = touchDetail(touch, &details[1]), .icon = .{ .vector = .chip }, .badge = onOff(touch_on, false) };
        selectable[1] = true;
        var total: usize = builtin_rows;
        for (drivers, 0..) |*entry, index| {
            rows[total] = .{ .title = entry.name(), .detail = userDetail(entry, &details[builtin_rows + index]), .icon = .{ .vector = .chip }, .badge = onOff(entry.switchedOn(), entry.setting == .blocked), .enabled = entry.toggleUsable() };
            selectable[total] = true;
            total += 1;
        }
        if (drivers.len == 0) {
            rows[total] = .{ .title = view.t(.drivers_none), .detail = view.t(.drivers_how), .icon = .{ .vector = .info }, .enabled = false };
            selectable[total] = false;
            total += 1;
        }
        if (selected >= total or !selectable[selected]) selected = 0;
        var list: view.ListScreen = undefined;
        list.open(view.t(.drivers_title), subtitle(changed), rows[0..total], selected, true, rowHelp(selected));
        const action: ?usize = loop: while (true) {
            switch (navigation.handleSelectable(input.readBlocking(), &selected, total, &list, selectable[0..total])) {
                .activate => break :loop selected,
                .back => break :loop null,
                .changed => list.updateSelection(selected, rowHelp(selected)),
                .pointer_moved => view.updatePointer(),
                .ignored => {},
            }
        };
        const index = action orelse return;
        if (index == 0) continue;
        if (index == 1) {
            settings_store.set("touch_driver", if (touch_on) "off" else "auto") catch |err| showError(err);
            // The page shows the setting as it will apply at the next start.
            touch_driver.setModeForReport(if (touch_on) .off else .auto);
            changed = true;
            continue;
        }
        const entry = &drivers[index - builtin_rows];
        uefi_drivers.setSwitched(entry, !entry.switchedOn()) catch |err| {
            showError(err);
            continue;
        };
        changed = true;
    }
}

fn subtitle(changed: bool) []const u8 {
    return if (changed) view.t(.drivers_next_boot) else view.t(.drivers_desc);
}

fn onOff(on: bool, blocked: bool) usos.gui.ui.Badge {
    if (blocked) return .{ .text = view.t(.drivers_blocked), .tone = .danger };
    return if (on) .{ .text = view.t(.drivers_on), .tone = .success } else .{ .text = view.t(.drivers_off), .tone = .neutral };
}

fn touchDetail(status: touch_driver.Status, buffer: []u8) []const u8 {
    const state = switch (status.outcome) {
        .started => view.t(.drivers_state_started),
        .failed, .file_missing => view.t(.drivers_state_failed_short),
        else => switch (status.decision) {
            .disabled_by_setting => view.t(.drivers_state_off),
            else => view.t(.drivers_state_not_matched),
        },
    };
    return std.fmt.bufPrint(buffer, "{s} · {s}", .{ view.t(.drivers_builtin), state }) catch state;
}

fn userDetail(entry: *const uefi_drivers.Entry, buffer: []u8) []const u8 {
    const where = switch (entry.match) {
        .everywhere => view.t(.drivers_match_everywhere),
        .matched => view.t(.drivers_match_yes),
        .not_matched => view.t(.drivers_match_no),
    };
    return std.fmt.bufPrint(buffer, "{s} · {s}", .{ where, stateText(entry) }) catch where;
}

fn stateText(entry: *const uefi_drivers.Entry) []const u8 {
    return switch (entry.decision) {
        .load => switch (entry.outcome) {
            .started => view.t(.drivers_state_started),
            .needs_signature => view.t(.drivers_state_signature),
            .duplicate => view.t(.drivers_state_duplicate),
            .file_error => view.t(.drivers_state_file),
            .runtime_unsupported, .load_failed, .start_failed => view.t(.drivers_state_failed_short),
            .not_loaded => view.t(.drivers_state_off),
        },
        .disabled_in_manifest, .disabled_in_settings => view.t(.drivers_state_off),
        .blocked_after_hang => view.t(.drivers_state_blocked),
        .hardware_not_matched => view.t(.drivers_state_not_matched),
        .image_refused => if (entry.outcome == .file_error) view.t(.drivers_state_file) else view.t(.drivers_state_refused),
    };
}

fn line(index: usize, comptime key: view.Key, value: []const u8) []const u8 {
    var args = [_][]const u8{value};
    return view.format(&help_text[index], key, &args);
}

fn sbLine(entry: *const uefi_drivers.Entry) []const u8 {
    if (!secure_boot.enforced()) return view.t(.drivers_sb_off);
    return switch (entry.sb_path) {
        .needs_signature => view.t(.drivers_state_signature),
        .verify => if (entry.outcome == .started) view.t(.drivers_sb_verified) else if (entry.outcome == .needs_signature) view.t(.drivers_state_signature) else view.t(.drivers_sb_signed),
        .plain => view.t(.drivers_sb_off),
    };
}

fn rowHelp(selected: usize) ?Help {
    const drivers = uefi_drivers.list();
    var n: usize = 0;
    if (selected == 0) {
        help_lines[n] = view.t(.drivers_ntfs_line1);
        n += 1;
        help_lines[n] = view.t(.drivers_ntfs_line2);
        n += 1;
        return .{ .title = "NTFS", .lines = help_lines[0..n], .badge = .{ .text = view.t(.drivers_builtin), .tone = .neutral } };
    }
    if (selected == 1) {
        const status = touch_driver.report();
        help_lines[n] = line(n, .drivers_file, touch_driver.driver_path);
        n += 1;
        help_lines[n] = view.t(.drivers_touch_match);
        n += 1;
        help_lines[n] = touchDetail(status, &help_text[n]);
        n += 1;
        help_lines[n] = view.t(.drivers_toggle_hint);
        n += 1;
        return .{ .title = "TouchI2cDxe", .lines = help_lines[0..n], .badge = onOff(status.mode == .auto, false) };
    }
    if (selected - builtin_rows >= drivers.len) {
        help_lines[n] = view.t(.drivers_how);
        n += 1;
        return .{ .title = view.t(.drivers_none), .lines = help_lines[0..n] };
    }
    const entry = &drivers[selected - builtin_rows];
    var path: [200]u8 = undefined;
    help_lines[n] = line(n, .drivers_file, std.fmt.bufPrint(&path, "Drivers\\UEFI\\{s}\\{s}", .{ entry.folder(), entry.efiName() }) catch entry.folder());
    n += 1;
    help_lines[n] = line(n, .drivers_type, @tagName(entry.manifest.type));
    n += 1;
    help_lines[n] = switch (entry.match) {
        .everywhere => view.t(.drivers_match_everywhere),
        .matched => view.t(.drivers_match_yes),
        .not_matched => view.t(.drivers_match_no),
    };
    n += 1;
    help_lines[n] = sbLine(entry);
    n += 1;
    help_lines[n] = if (entry.err) |err| line(n, .drivers_state_failed, @errorName(err)) else stateText(entry);
    n += 1;
    if (entry.setting == .blocked) {
        help_lines[n] = view.t(.drivers_blocked_note);
        n += 1;
    }
    help_lines[n] = if (entry.toggleUsable()) view.t(.drivers_toggle_hint) else view.t(.drivers_toggle_unusable);
    n += 1;
    return .{ .title = entry.name(), .lines = help_lines[0..n], .badge = onOff(entry.switchedOn(), entry.setting == .blocked) };
}

fn showError(err: anyerror) void {
    const lines = [_][]const u8{@errorName(err)};
    view.notice(view.t(.drivers_title), .warning, .warning, "", &lines);
    view.waitForDismiss();
}
