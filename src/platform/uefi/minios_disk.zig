//! The one disk question of the MiniOS flow, in the USOS menu. It is the
//! Alpine route's disk picker: the same renderer (the micro-Linux choice
//! menu, src/platform/linux/fb_menu_render.zig, imported as "fb_menu"), the
//! same screens and texts as tools/xp_menu_ui.sh usos_xp_choose_disk and
//! tools/xp_confirmation_ui.sh usos_xp_confirm (as tools/vista_csmwrap_prepare.sh
//! uses them): "<SYSTEM> - SELECT DISK" with "<model> (<n> GiB)", "S/N: ..."
//! and the bus / media chips, "Return to USOS", the CSMWrap note; then
//! "FORMAT THE ENTIRE DISK?" with the disk overview and Cancel preselected.
//! The chosen disk goes to MiniOS by identity (device path + size,
//! minios_plan.Disk); MiniOS checks it again and asks nothing.
//! Without graphics (text console) the earlier form-based question is used.
//! X470 2026-10-31 (B261031-170724): the plain form ("NVMe 476.9 GiB (MBR)")
//! was not the Alpine picker the user knows.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const fb_menu = @import("fb_menu");
const form = @import("manual_form.zig");
const view = @import("manual_view.zig");
const input = @import("input.zig");
const serial = @import("serial.zig");

const plan = usos.flow.minios_plan;
const model = fb_menu.menu_model;
const identity = usos.flow.minios_disk_identity;

const max_disks = 8;
const Row = struct {
    disk: plan.Disk,
    label: [80]u8 = undefined,
    label_len: usize = 0,
    /// Picker title "<model> (<n> GiB)" and detail "S/N: <serial>".
    title: [96]u8 = undefined,
    title_len: usize = 0,
    detail: [48]u8 = undefined,
    detail_len: usize = 0,
    id: identity.Identity = .{},
    layout: identity.Partitions = .{},
};
var rows: [max_disks]Row = undefined;
var fields: [max_disks + 1]form.Field = undefined;
var confirm_fields: [4]form.Field = undefined;
var dummy: u8 = 0;
const cancel_id: u8 = 200;
const erase_id: u8 = 201;
const other_id: u8 = 202;

fn body(path: *const uefi.protocol.DevicePath) ?[]const u8 {
    const bytes: [*]const u8 = @ptrCast(path);
    var offset: usize = 0;
    while (offset <= 4092) {
        const len = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        if (len < 4 or len > 4096 - offset) return null;
        if (bytes[offset] == 0x7f) return bytes[0..offset];
        offset += len;
    }
    return null;
}

fn bootBody() ?[]const u8 {
    const bs = uefi.system_table.boot_services orelse return null;
    const loaded = (bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch return null) orelse return null;
    const device = loaded.device_handle orelse return null;
    const path = (bs.handleProtocol(uefi.protocol.DevicePath, device) catch return null) orelse return null;
    return body(path);
}

/// EFI_DISK_INFO_PROTOCOL (PI spec, MdePkg DiskInfo.h): the controller's
/// IDENTIFY data (ATA IDENTIFY DEVICE or NVMe Identify Controller).
const DiskInfo = extern struct {
    interface: [16]u8,
    _inquiry: *const fn (*DiskInfo, ?*anyopaque, *u32) callconv(uefi.cc) uefi.Status,
    _identify: *const fn (*DiskInfo, ?*anyopaque, *u32) callconv(uefi.cc) uefi.Status,
    _sense: *const fn (*DiskInfo, ?*anyopaque, *u32, *u8) callconv(uefi.cc) uefi.Status,
    _which_ide: *const fn (*DiskInfo, *u32, *u32) callconv(uefi.cc) uefi.Status,

    pub const guid align(8) = uefi.Guid{
        .time_low = 0xd432a67f,
        .time_mid = 0x14dc,
        .time_high_and_version = 0x484b,
        .clock_seq_high_and_reserved = 0xb3,
        .clock_seq_low = 0xbb,
        .node = [_]u8{ 0x3f, 0x02, 0x91, 0x84, 0x93, 0x27 },
    };
};

var identify_buffer: [4096]u8 align(8) = undefined;

/// Model, serial and media of `handle` from EFI_DISK_INFO (empty when the
/// firmware has none: the picker then names the bus, as Linux names the
/// kernel device).
fn readIdentity(handle: uefi.Handle) identity.Identity {
    const bs = uefi.system_table.boot_services orelse return .{};
    const info = (bs.handleProtocol(DiskInfo, handle) catch return .{}) orelse return .{};
    const kind = identity.interfaceKind(info.interface);
    if (kind == .other) return .{};
    @memset(&identify_buffer, 0);
    var size: u32 = identify_buffer.len;
    if (info._identify(info, &identify_buffer, &size) != .success) return .{ .interface = kind };
    return identity.parse(kind, identify_buffer[0..@min(size, identify_buffer.len)]);
}

var sector_buffer: [4096]u8 align(4096) = undefined;

/// Partition count and allocated sectors from the GPT or MBR (read only).
fn readPartitions(io: *uefi.protocol.BlockIo) identity.Partitions {
    const media = io.media;
    io.readBlocks(media.media_id, 1, sector_buffer[0..512]) catch return .{};
    if (std.mem.eql(u8, sector_buffer[0..8], "EFI PART")) {
        const gpt = identity.GptHeader.parse(sector_buffer[0..512]) orelse return .{ .table = .gpt };
        var result: identity.Partitions = .{ .table = .gpt };
        var lba = gpt.entries_lba;
        var left = gpt.count;
        while (left > 0 and lba <= media.last_block) : (lba += 1) {
            io.readBlocks(media.media_id, lba, sector_buffer[0..512]) catch return result;
            const per = 512 / gpt.entry_size;
            for (0..@min(per, left)) |i| result.addGpt(sector_buffer[i * gpt.entry_size ..][0..gpt.entry_size]);
            left -= @min(per, left);
        }
        return result;
    }
    io.readBlocks(media.media_id, 0, sector_buffer[0..512]) catch return .{};
    return identity.Partitions.fromMbr(sector_buffer[0..512]);
}

/// Lists the disks MiniOS accepts for this route (logged with the reason
/// for every refused one). Returns the number of rows.
fn collect(route: plan.Route) usize {
    const bs = uefi.system_table.boot_services orelse return 0;
    const boot = bootBody() orelse return 0;
    const handles = (bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid }) catch return 0) orelse return 0;
    defer bs.freePool(@ptrCast(@alignCast(handles.ptr))) catch {};
    var count: usize = 0;
    for (handles) |handle| {
        const io = (bs.handleProtocol(uefi.protocol.BlockIo, handle) catch continue) orelse continue;
        const media = io.media;
        if (media.logical_partition) continue;
        const path = (bs.handleProtocol(uefi.protocol.DevicePath, handle) catch continue) orelse continue;
        const b = body(path) orelse continue;
        if (b.len == 0) continue;
        const sectors = media.last_block +% 1;
        const bus = plan.busName(b);
        const info: plan.DiskInfo = .{ .block_size = media.block_size, .sectors = sectors, .read_only = media.read_only, .present = media.media_present, .bus = bus, .boot = std.mem.startsWith(u8, boot, b) };
        var line: [192]u8 = undefined;
        if (plan.refusal(route, info)) |why| {
            serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk not offered bus={s} sectors={d}: {s}\r\n", .{ bus, sectors, why }) catch "[MINIOS] disk not offered\r\n");
            continue;
        }
        if (b.len > plan.max_disk_path or count == max_disks) continue;
        const row = &rows[count];
        row.* = .{ .disk = .{ .sectors = sectors } };
        @memcpy(row.disk.path[0..b.len], b);
        row.disk.path_len = b.len;
        row.id = readIdentity(handle);
        row.id.bus = identity.busToken(bus, row.id.interface);
        row.layout = readPartitions(io);
        const bytes = sectors * 512;
        row.title_len = if (identity.pickerTitle(&row.title, &row.id, bytes)) |t| t.len else |_| 0;
        row.detail_len = if (std.fmt.bufPrint(&row.detail, "S/N: {s}", .{row.id.serialText()})) |t| t.len else |_| 0;
        const tenths = bytes * 10 / (1024 * 1024 * 1024);
        const label: []const u8 = std.fmt.bufPrint(&row.label, "{s}   {d}.{d} GiB   ({s})", .{ bus, tenths / 10, tenths % 10, @tagName(row.layout.table) }) catch "disk";
        row.label_len = label.len;
        serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk offered {s} model=\"{s}\" bus={s} media={s} partitions={d}\r\n", .{ row.label[0..row.label_len], row.id.modelText(), row.id.bus orelse "-", row.id.media orelse "-", row.layout.count }) catch "[MINIOS] disk offered\r\n");
        count += 1;
    }
    return count;
}

pub const Outcome = union(enum) { disk: plan.Disk, cancelled, none };

/// The flow's only disk question: the picker, then the erase confirmation.
/// `name` is the system as Alpine names it ("Windows 10").
pub fn ask(route: plan.Route, name: []const u8) Outcome {
    const count = collect(route);
    if (count == 0) return .none;
    if (view.screenUi() == null) return askForm(count, name);
    while (true) {
        const chosen = pick(count, name, route) orelse return .cancelled;
        const row = &rows[chosen];
        // vista_csmwrap_prepare.sh: "Inspecting disk" while the overview is
        // read (MiniOS has it already from the picker scan).
        if (confirm(row, name, route)) {
            var line: [160]u8 = undefined;
            serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk confirmed {s} model=\"{s}\"\r\n", .{ row.label[0..row.label_len], row.id.modelText() }) catch "[MINIOS] disk confirmed\r\n");
            return .{ .disk = row.disk };
        }
        serial.writeAscii("[MINIOS] erase confirmation cancelled; back to the disk list\r\n");
    }
}

// ---------------------------------------------------------- Alpine picker

var state: model.State = .{};
var title_storage: [128]u8 = undefined;
var subtitle_storage: [160]u8 = undefined;
var note_storage: [192]u8 = undefined;
var overview: identity.Overview = .{};

/// usos_xp_choose_disk: the disks, then "Return to USOS". Null: back.
fn pick(count: usize, name: []const u8, route: plan.Route) ?usize {
    state = .{};
    var upper: [96]u8 = undefined;
    const shown = upper[0..@min(name.len, upper.len)];
    _ = std.ascii.upperString(shown, name[0..shown.len]);
    state.title = std.fmt.bufPrint(&title_storage, "{s} - SELECT DISK", .{shown}) catch "SELECT DISK";
    state.subtitle = std.fmt.bufPrint(&subtitle_storage, "Select the disk for {s}.", .{name}) catch "";
    for (rows[0..count], 0..) |*row, i| {
        state.items[i] = .{ .title = row.title[0..row.title_len], .detail = row.detail[0..row.detail_len] };
        const item = &state.items[i];
        if (row.id.bus) |bus| {
            item.badges[item.badge_count] = bus;
            item.badge_count += 1;
            if (row.id.media) |media| {
                item.badges[item.badge_count] = media;
                item.badge_count += 1;
            }
        }
    }
    state.items[count] = .{ .title = "Return to USOS" };
    state.count = count + 1;
    // USOS_XP_DISK_NOTE of vista_csmwrap_prepare.sh (x86_self=1).
    if (route == .mbr_csmwrap) {
        state.info[state.info_count] = std.fmt.bufPrint(&note_storage, "Without CSM, {s} starts through CSMWrap, so USOS prepares the target disk first.", .{name}) catch "";
        state.info_count += 1;
    }
    state.info[state.info_count] = "The disk will only be changed after your confirmation.";
    state.info_count += 1;
    const chosen = runMenu() orelse return null;
    return if (chosen < count) chosen else null;
}

/// usos_xp_confirm with the vista_csmwrap_prepare.sh screen text.
fn confirm(row: *const Row, name: []const u8, route: plan.Route) bool {
    if (route == .mbr_csmwrap) view.miniosStage(3, "Inspecting disk", "Reading partitions, free space and system files.", name);
    overview.build(&row.id, &row.layout, row.disk.sectors, name, route == .mbr_csmwrap);
    state = .{};
    state.title = "FORMAT THE ENTIRE DISK?";
    state.subtitle = "Review the selected disk and confirm the operation.";
    state.items[0] = .{ .title = "Confirm", .detail = "Erase ALL partitions and data on the selected disk" };
    state.items[1] = .{ .title = "Cancel", .detail = "Return to disk selection" };
    state.count = 2;
    // Cancel is preselected: Enter pressed twice never confirms an erase.
    state.selected = 1;
    for (overview.lines(), 0..) |line, i| state.info[i] = line;
    state.info_count = overview.count;
    const chosen = runMenu() orelse return false;
    return chosen == 0;
}

fn draw(context: *const anyopaque, u: *const usos.gui.ui.Ui, header: usos.gui.ui.HeaderInfo) void {
    const s: *const model.State = @ptrCast(@alignCast(context));
    fb_menu.renderPage(u, header, s.*, 0, 0, false, false);
}

fn page(layout: fb_menu.Layout, down: bool) void {
    if (state.detailCount() > layout.info_lines) {
        for (0..@max(1, layout.info_lines)) |_| state.scrollInfo(down, layout.info_lines);
    } else state.move(down);
}

/// fb_menu.zig's event handling on the menu's input. Returns the chosen
/// row, or null for Esc / right click / the footer's Esc hint.
fn runMenu() ?usize {
    var redraw = true;
    while (true) {
        if (redraw) {
            view.traceFormScreen(state.title);
            if (!view.customFrame(@ptrCast(&state), draw)) return null;
            redraw = false;
        }
        const u = view.screenUi() orelse return null;
        const layout = fb_menu.Layout.init(&u, state);
        switch (input.readBlocking()) {
            .up, .left => {
                state.move(false);
                redraw = true;
            },
            .down, .right => {
                state.move(true);
                redraw = true;
            },
            .home => {
                state.selected = 0;
                redraw = true;
            },
            .end => {
                state.selected = state.count - 1;
                redraw = true;
            },
            // PgUp/PgDn page an overflowing details panel, else move.
            .page_up => {
                page(layout, false);
                redraw = true;
            },
            .page_down => {
                page(layout, true);
                redraw = true;
            },
            .enter => return state.selected,
            .back => return null,
            .pointer => |mouse| {
                if (mouse.right_click) return null;
                if (mouse.scroll != 0) {
                    // Positive notches turn the wheel away (towards the top).
                    const down = mouse.scroll < 0;
                    switch (layout.wheelTarget(state, true, @intCast(mouse.x), @intCast(mouse.y))) {
                        .details => state.scrollInfo(down, layout.info_lines),
                        .list => if (down) {
                            if (state.selected + 1 < state.count) state.move(true);
                        } else if (state.selected > 0) state.move(false),
                        .none => {},
                    }
                    redraw = true;
                    continue;
                }
                if (mouse.left_click) {
                    var hint_buffer: [4]usos.gui.ui.Hint = undefined;
                    const hints = fb_menu.footerHints(&hint_buffer, &u, state, layout, false);
                    if (u.footerHit(hints, "", mouse.x, mouse.y)) |index| {
                        if (index == 1) return state.selected;
                        if (index == 2) return null;
                    }
                    if (layout.hit(@intCast(mouse.x), @intCast(mouse.y), state.count)) |index| return index;
                    continue;
                }
                if (mouse.moved) view.updatePointer();
            },
            else => {},
        }
    }
}

// ------------------------------------------------- text console fallback

fn askForm(count: usize, name: []const u8) Outcome {
    var title_buf: [160]u8 = undefined;
    var subtitle_buf: [256]u8 = undefined;
    var title_en: [96]u8 = undefined;
    var subtitle_en: [96]u8 = undefined;
    const title = view.trFormat(&title_buf, std.fmt.bufPrint(&title_en, "{s} - SELECT DISK", .{name}) catch name);
    const subtitle = view.trFormat(&subtitle_buf, std.fmt.bufPrint(&subtitle_en, "Select the disk for {s}.", .{name}) catch name);
    while (true) {
        for (rows[0..count], 0..) |*row, i| fields[i] = .{ .kind = .action, .label = row.label[0..row.label_len], .id = @intCast(i + 1), .primary = i == 0 };
        fields[count] = .{ .kind = .action, .label = view.t(.profile_cancel), .id = cancel_id };
        var selected: usize = 0;
        const chosen: usize = switch (form.run(title, subtitle, fields[0 .. count + 1], .{ .context = @ptrCast(&dummy) }, &selected)) {
            .back => return .cancelled,
            .x_on, .y_on => continue,
            .action => |id| if (id == cancel_id or id == 0 or id > count) return .cancelled else id - 1,
        };
        const row = &rows[chosen];
        confirm_fields[0] = .{ .kind = .section, .label = row.label[0..row.label_len] };
        confirm_fields[1] = .{ .kind = .action, .label = view.tr("Erase ALL partitions and data on the selected disk"), .id = erase_id, .primary = true };
        confirm_fields[2] = .{ .kind = .action, .label = view.tr("Select another disk"), .id = other_id };
        confirm_fields[3] = .{ .kind = .action, .label = view.t(.profile_cancel), .id = cancel_id };
        var confirm_selected: usize = 1;
        switch (form.run(view.tr("ERASE ALL DATA ON THIS DISK"), view.tr("All partitions, systems and files on this disk will be erased."), &confirm_fields, .{ .context = @ptrCast(&dummy) }, &confirm_selected)) {
            .back => continue,
            .x_on, .y_on => continue,
            .action => |id| switch (id) {
                erase_id => {
                    var line: [128]u8 = undefined;
                    serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk confirmed {s}\r\n", .{row.label[0..row.label_len]}) catch "[MINIOS] disk confirmed\r\n");
                    return .{ .disk = row.disk };
                },
                other_id => continue,
                else => return .cancelled,
            },
        }
    }
}
