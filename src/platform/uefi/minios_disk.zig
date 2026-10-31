//! The one disk question of the MiniOS flow, in the USOS menu (same form
//! style and language as the rest of the menu; the texts are the translated
//! micro-Linux disk-picker strings). The chosen disk goes to MiniOS by
//! identity (device path + size, minios_plan.Disk); MiniOS checks it again
//! and asks nothing.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const form = @import("manual_form.zig");
const view = @import("manual_view.zig");
const serial = @import("serial.zig");

const plan = usos.flow.minios_plan;

const max_disks = 8;
const Row = struct { disk: plan.Disk, label: [80]u8 = undefined, label_len: usize = 0 };
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

fn tableName(io: *uefi.protocol.BlockIo) []const u8 {
    var sector: [4096]u8 align(4096) = undefined;
    io.readBlocks(io.media.media_id, 1, sector[0..512]) catch return "?";
    if (std.mem.eql(u8, sector[0..8], "EFI PART")) return "GPT";
    io.readBlocks(io.media.media_id, 0, sector[0..512]) catch return "?";
    return if (sector[510] == 0x55 and sector[511] == 0xaa) "MBR" else "-";
}

/// Lists the disks MiniOS accepts for this route (logged with the reason
/// for every refused one). Returns the number of rows.
fn collect(route: plan.Route, nvme_package: bool) usize {
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
        var line: [160]u8 = undefined;
        if (plan.refusal(route, info, nvme_package)) |why| {
            serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk not offered bus={s} sectors={d}: {s}\r\n", .{ bus, sectors, why }) catch "[MINIOS] disk not offered\r\n");
            continue;
        }
        if (b.len > plan.max_disk_path or count == max_disks) continue;
        const row = &rows[count];
        row.* = .{ .disk = .{ .sectors = sectors } };
        @memcpy(row.disk.path[0..b.len], b);
        row.disk.path_len = b.len;
        const tenths = sectors * 512 * 10 / (1024 * 1024 * 1024);
        const label: []const u8 = std.fmt.bufPrint(&row.label, "{s}   {d}.{d} GiB   ({s})", .{ bus, tenths / 10, tenths % 10, tableName(io) }) catch "disk";
        row.label_len = label.len;
        serial.writeAscii(std.fmt.bufPrint(&line, "[MINIOS] disk offered {s}\r\n", .{row.label[0..row.label_len]}) catch "[MINIOS] disk offered\r\n");
        count += 1;
    }
    return count;
}

pub const Outcome = union(enum) { disk: plan.Disk, cancelled, none };

/// The flow's only disk question: a list, then the erase confirmation.
/// `name` is the system and environment, e.g. "Windows 10 (MiniOS)".
pub fn ask(route: plan.Route, name: []const u8, nvme_package: bool) Outcome {
    const count = collect(route, nvme_package);
    if (count == 0) return .none;
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

