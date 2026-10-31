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
const filesystem = @import("filesystem.zig");
const settings_store = @import("settings_store.zig");

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
    io: *uefi.protocol.BlockIo = undefined,
    /// The file systems were read for the confirmation (once per row).
    inspected: bool = false,
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

var identify_buffer: [4096]u8 align(4096) = undefined;

/// EFI_NVM_EXPRESS_PASS_THRU_PROTOCOL (UEFI 2.10 13.15).
const NvmePassThru = extern struct {
    mode: *const extern struct { attributes: u32, io_align: u32, nvme_version: u32 },
    pass_thru: *const fn (*NvmePassThru, u32, *NvmePacket, ?*anyopaque) callconv(uefi.cc) uefi.Status,
    get_next_namespace: *const anyopaque,
    build_device_path: *const anyopaque,
    get_namespace: *const anyopaque,
    pub const guid align(8) = uefi.Guid{ .time_low = 0x52c78312, .time_mid = 0x8edc, .time_high_and_version = 0x4233, .clock_seq_high_and_reserved = 0x98, .clock_seq_low = 0xf2, .node = .{ 0x1a, 0x1a, 0xa5, 0xe3, 0x88, 0xa5 } };
};
const NvmeCommand = extern struct { cdw0: u32, flags: u8, nsid: u32, cdw2: u32 = 0, cdw3: u32 = 0, cdw10: u32 = 0, cdw11: u32 = 0, cdw12: u32 = 0, cdw13: u32 = 0, cdw14: u32 = 0, cdw15: u32 = 0 };
const NvmeCompletion = extern struct { dw0: u32 = 0, dw1: u32 = 0, dw2: u32 = 0, dw3: u32 = 0 };
const NvmePacket = extern struct {
    timeout: u64,
    transfer_buffer: ?*anyopaque,
    transfer_length: u32,
    metadata_buffer: ?*anyopaque = null,
    metadata_length: u32 = 0,
    queue_type: u8 = 0, // admin
    command: *NvmeCommand,
    completion: *NvmeCompletion,
};

/// EFI_ATA_PASS_THRU_PROTOCOL (UEFI 2.10 13.13).
const AtaPassThru = extern struct {
    mode: *const extern struct { attributes: u32, io_align: u32 },
    pass_thru: *const fn (*AtaPassThru, u16, u16, *AtaPacket, ?*anyopaque) callconv(uefi.cc) uefi.Status,
    pub const guid align(8) = uefi.Guid{ .time_low = 0x1d3de7f0, .time_mid = 0x0807, .time_high_and_version = 0x424f, .clock_seq_high_and_reserved = 0xaa, .clock_seq_low = 0x69, .node = .{ 0x11, 0xa5, 0x4e, 0x19, 0xa4, 0x6f } };
};
const AtaPacket = extern struct {
    asb: *[20]u8,
    acb: *[20]u8,
    timeout: u64,
    in_data: ?*anyopaque,
    out_data: ?*anyopaque = null,
    in_length: u32,
    out_length: u32 = 0,
    protocol: u8,
    length: u8,
};

/// EFI_USB_IO_PROTOCOL (UEFI 2.10 17.2.4), the calls used here.
const UsbIo = extern struct {
    control: *const anyopaque,
    bulk: *const anyopaque,
    async_interrupt: *const anyopaque,
    sync_interrupt: *const anyopaque,
    isochronous: *const anyopaque,
    async_isochronous: *const anyopaque,
    get_device_descriptor: *const fn (*UsbIo, *[18]u8) callconv(uefi.cc) uefi.Status,
    get_config_descriptor: *const anyopaque,
    get_interface_descriptor: *const anyopaque,
    get_endpoint_descriptor: *const anyopaque,
    get_string_descriptor: *const fn (*UsbIo, u16, u8, *?[*:0]u16) callconv(uefi.cc) uefi.Status,
    get_supported_languages: *const fn (*UsbIo, *?[*]u16, *u16) callconv(uefi.cc) uefi.Status,
    pub const guid align(8) = uefi.Guid{ .time_low = 0x2b2f68d6, .time_mid = 0x0cd2, .time_high_and_version = 0x44cf, .clock_seq_high_and_reserved = 0x8e, .clock_seq_low = 0x8b, .node = .{ 0xbb, 0xa2, 0x0b, 0x1b, 0x5b, 0x75 } };
};

// ------------------------------------------------------------- disk log

/// The disk question's log on the USB drive. The serial line alone was the
/// only sink before 2026-10-31 (B261031-185528 had no `identity=` line in
/// any file: the X470 has no serial capture), so every line also lands in
/// this file. The serial number is never logged (only serial_known).
pub const log_path = "\\EFI\\USOS\\Logs\\minios-disks.txt";
var log_storage: [24576]u8 = undefined;
var log_len: usize = 0;

fn logLine(comptime fmt: []const u8, args: anytype) void {
    var line: [400]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "[MINIOS] " ++ fmt ++ "\r\n", args) catch "[MINIOS] (log line too long)\r\n";
    serial.writeAscii(text);
    const n = @min(text.len, log_storage.len - log_len);
    @memcpy(log_storage[log_len..][0..n], text[0..n]);
    log_len += n;
}

fn flushLog() void {
    const root = filesystem.openBootVolume() orelse return;
    defer root.close() catch {};
    settings_store.replaceFile(root, log_path, log_storage[0..log_len]) catch {};
}

// ------------------------------------------------------------ identity

const Source = enum { nvme_passthru, ata_passthru, usb, disk_info, none };

/// One probe attempt, logged as one line.
const Attempt = struct {
    protocol: bool = false,
    status: []const u8 = "not_tried",
    id: ?identity.Identity = null,
};

fn statusName(status: uefi.Status) []const u8 {
    return @tagName(status);
}

/// ACB / ASB of the ATA pass-thru (IoAlign applies to them too).
var ata_blocks: [2][64]u8 align(64) = undefined;

/// NVMe Identify Controller (CNS 1) through the controller's pass-thru:
/// model bytes 24-63, serial 4-23, as Linux reads them. The namespace's
/// BlockIo handle does not carry the protocol: LocateDevicePath walks the
/// device path up to the controller handle (PciRoot/Pci) that does.
fn nvmeIdentity(path: *const uefi.protocol.DevicePath) Attempt {
    const bs = uefi.system_table.boot_services orelse return .{ .status = "no_boot_services" };
    const located = (bs.locateDevicePath(path, NvmePassThru) catch return .{ .status = "locate_error" }) orelse return .{ .status = "not_found" };
    const node: [*]const u8 = @ptrCast(located[0]);
    if (node[0] != 3 or node[1] != 0x17) return .{ .protocol = true, .status = "remaining_node_not_nvme" };
    const pt = (bs.handleProtocol(NvmePassThru, located[1]) catch return .{ .status = "handle_error" }) orelse return .{ .status = "handle_null" };
    if (pt.mode.io_align > identify_buffer.len) return .{ .protocol = true, .status = "io_align_too_large" };
    @memset(&identify_buffer, 0);
    var command: NvmeCommand = .{ .cdw0 = identity.nvme_identify.opcode, .flags = identity.nvme_identify.flags, .nsid = 0, .cdw10 = identity.nvme_identify.cdw10 };
    var completion: NvmeCompletion = .{};
    var packet: NvmePacket = .{ .timeout = 50_000_000, .transfer_buffer = &identify_buffer, .transfer_length = identity.nvme_identify.bytes, .command = &command, .completion = &completion };
    const status = pt.pass_thru(pt, 0, &packet, null);
    if (status != .success) return .{ .protocol = true, .status = statusName(status) };
    const id = identity.parse(.nvme, &identify_buffer);
    return .{ .protocol = true, .status = if (id.model_len > 0) "success" else "success_no_model", .id = if (id.model_len > 0) id else null };
}

/// ATA IDENTIFY DEVICE through the SATA controller's pass-thru (port and
/// port multiplier port from the SATA device path node). AMI firmware may
/// not install EFI_ATA_PASS_THRU for the AMD AHCI controller: then
/// EFI_DISK_INFO (AHCI / IDE interface, IDENTIFY data) is used.
fn ataIdentity(path: *const uefi.protocol.DevicePath) Attempt {
    const bs = uefi.system_table.boot_services orelse return .{ .status = "no_boot_services" };
    const located = (bs.locateDevicePath(path, AtaPassThru) catch return .{ .status = "locate_error" }) orelse return .{ .status = "not_found" };
    const node: [*]const u8 = @ptrCast(located[0]);
    if (node[0] != 3 or node[1] != 0x12) return .{ .protocol = true, .status = "remaining_node_not_sata" };
    const port = std.mem.readInt(u16, node[4..6], .little);
    const pmp = std.mem.readInt(u16, node[6..8], .little);
    const pt = (bs.handleProtocol(AtaPassThru, located[1]) catch return .{ .status = "handle_error" }) orelse return .{ .status = "handle_null" };
    if (pt.mode.io_align > 64) return .{ .protocol = true, .status = "io_align_too_large" };
    @memset(identify_buffer[0..512], 0);
    const acb = &ata_blocks[0];
    const asb = &ata_blocks[1];
    @memset(acb, 0);
    @memset(asb, 0);
    // EFI_ATA_COMMAND_BLOCK: command at 2, device/head at 7, sector count
    // at 12.
    acb[2] = identity.ata_identify.command;
    acb[7] = identity.ata_identify.deviceHead(pmp);
    acb[12] = 1;
    var packet: AtaPacket = .{ .asb = asb[0..20], .acb = acb[0..20], .timeout = 50_000_000, .in_data = &identify_buffer, .in_length = 512, .protocol = identity.ata_identify.protocol_pio_in, .length = identity.ata_identify.length };
    const status = pt.pass_thru(pt, port, pmp, &packet, null);
    if (status != .success) return .{ .protocol = true, .status = statusName(status) };
    const id = identity.parse(.ahci, identify_buffer[0..512]);
    return .{ .protocol = true, .status = if (id.model_len > 0) "success" else "success_no_model", .id = if (id.model_len > 0) id else null };
}

fn usbString(io: *UsbIo, lang: u16, index: u8, out: *identity.Identity, serial_field: bool) void {
    if (index == 0) return;
    const bs = uefi.system_table.boot_services orelse return;
    var text: ?[*:0]u16 = null;
    if (io.get_string_descriptor(io, lang, index, &text) != .success) return;
    const str = text orelse return;
    const units = std.mem.span(str);
    if (serial_field) identity.setSerialUtf16(out, units) else identity.setModelUtf16(out, units);
    bs.freePool(@ptrCast(@alignCast(str))) catch {};
}

/// USB disk: the model from the disk's SCSI INQUIRY (EFI_DISK_INFO of the
/// USB mass storage driver; product, as Linux), else the USB iProduct
/// string; the serial from the USB iSerialNumber string (Linux's serial).
fn usbIdentity(path: *const uefi.protocol.DevicePath, handle: uefi.Handle) Attempt {
    const bs = uefi.system_table.boot_services orelse return .{ .status = "no_boot_services" };
    const located = (bs.locateDevicePath(path, UsbIo) catch return .{ .status = "locate_error" }) orelse return .{ .status = "not_found" };
    const io = (bs.handleProtocol(UsbIo, located[1]) catch return .{ .status = "handle_error" }) orelse return .{ .status = "handle_null" };
    var id: identity.Identity = .{ .interface = .usb };
    var inquiry_status: []const u8 = "no_disk_info";
    if (bs.handleProtocol(DiskInfo, handle) catch null) |info| {
        @memset(identify_buffer[0..96], 0);
        var size: u32 = 96;
        const status = info._inquiry(info, &identify_buffer, &size);
        inquiry_status = statusName(status);
        if (status == .success) identity.setInquiryModel(&id, identify_buffer[0..@min(size, 96)]);
    }
    var device: [18]u8 = undefined;
    const ok = io.get_device_descriptor(io, &device) == .success;
    if (ok) if (identity.usbStrings(&device)) |strings| {
        var lang: u16 = 0x0409;
        var table: ?[*]u16 = null;
        var table_size: u16 = 0;
        if (io.get_supported_languages(io, &table, &table_size) == .success and table != null and table_size >= 2) lang = table.?[0];
        if (id.model_len == 0) usbString(io, lang, strings.product, &id, false);
        usbString(io, lang, strings.serial, &id, true);
    };
    const got = id.model_len > 0 or id.serial_len > 0;
    logLine("identity usb inquiry={s} device_descriptor={s}", .{ inquiry_status, if (ok) "success" else "failed" });
    return .{ .protocol = true, .status = if (got) "success" else "no_strings", .id = if (got) id else null };
}

/// EFI_DISK_INFO IDENTIFY data (the fallback; AMI provides it for AHCI).
fn diskInfoIdentity(handle: uefi.Handle) Attempt {
    const bs = uefi.system_table.boot_services orelse return .{ .status = "no_boot_services" };
    const info = (bs.handleProtocol(DiskInfo, handle) catch return .{ .status = "handle_error" }) orelse return .{ .status = "not_found" };
    const kind = identity.interfaceKind(info.interface);
    if (kind == .other) return .{ .protocol = true, .status = "interface_unknown" };
    @memset(&identify_buffer, 0);
    var size: u32 = identify_buffer.len;
    const status = info._identify(info, &identify_buffer, &size);
    if (status != .success) return .{ .protocol = true, .status = statusName(status), .id = .{ .interface = kind } };
    const id = identity.parse(kind, identify_buffer[0..@min(size, identify_buffer.len)]);
    return .{ .protocol = true, .status = if (id.model_len > 0) "success" else "success_no_model", .id = id };
}

fn logAttempt(disk: usize, probe: []const u8, a: *const Attempt) void {
    const id = a.id orelse identity.Identity{};
    logLine("identity disk={d} probe={s} protocol={s} status={s} interface={s} model=\"{s}\" serial_known={any}", .{ disk, probe, if (a.protocol) "yes" else "no", a.status, @tagName(id.interface), id.modelText(), id.serial_len > 0 });
}

/// Model, serial and media of `handle` read from the device as Linux reads
/// them: NVMe Identify Controller (NVMe pass-thru), ATA IDENTIFY DEVICE
/// (ATA pass-thru), USB descriptors / INQUIRY, and EFI_DISK_INFO when
/// those fail. Every attempt is logged; empty: the picker names the bus.
fn readIdentity(disk: usize, handle: uefi.Handle, path: *const uefi.protocol.DevicePath, bus: []const u8) identity.Identity {
    var best: identity.Identity = .{};
    var source: Source = .none;
    if (std.mem.eql(u8, bus, "NVMe")) {
        const a = nvmeIdentity(path);
        logAttempt(disk, "nvme_passthru", &a);
        if (a.id) |id| {
            best = id;
            source = .nvme_passthru;
        }
    }
    if (source == .none and std.mem.eql(u8, bus, "SATA")) {
        const a = ataIdentity(path);
        logAttempt(disk, "ata_passthru", &a);
        if (a.id) |id| {
            best = id;
            source = .ata_passthru;
        }
    }
    if (source == .none and std.mem.eql(u8, bus, "USB")) {
        const a = usbIdentity(path, handle);
        logAttempt(disk, "usb_io", &a);
        if (a.id) |id| {
            best = id;
            source = .usb;
        }
    }
    if (source == .none) {
        const a = diskInfoIdentity(handle);
        logAttempt(disk, "disk_info", &a);
        if (a.id) |id| {
            // An interface without model still gives the bus / media chips.
            if (id.model_len > 0) source = .disk_info;
            if (id.model_len > 0 or best.interface == .other) best = id;
        }
    }
    logLine("identity disk={d} source={s} bus={s} model_known={any} serial_known={any}", .{ disk, @tagName(source), bus, best.model_len > 0, best.serial_len > 0 });
    return best;
}

// ------------------------------------------------------ partition table

var sector_buffer: [4096]u8 align(4096) = undefined;

/// Partition list from the GPT or MBR (+ EBR chain, at most 64 links),
/// read only.
fn readPartitions(io: *uefi.protocol.BlockIo) identity.Partitions {
    const media = io.media;
    io.readBlocks(media.media_id, 1, sector_buffer[0..512]) catch return .{};
    if (std.mem.eql(u8, sector_buffer[0..8], "EFI PART")) {
        const gpt = identity.GptHeader.parse(sector_buffer[0..512]) orelse return .{ .table = .gpt };
        var result: identity.Partitions = .{ .table = .gpt };
        var lba = gpt.entries_lba;
        var left = gpt.count;
        var index: u32 = 0;
        while (left > 0 and lba <= media.last_block) : (lba += 1) {
            io.readBlocks(media.media_id, lba, sector_buffer[0..512]) catch return result;
            const per = 512 / gpt.entry_size;
            for (0..@min(per, left)) |i| {
                result.addGpt(sector_buffer[i * gpt.entry_size ..][0..gpt.entry_size], index);
                index += 1;
            }
            left -= @min(per, left);
        }
        return result;
    }
    io.readBlocks(media.media_id, 0, sector_buffer[0..512]) catch return .{};
    var result = identity.Partitions.fromMbr(sector_buffer[0..512]);
    const ext = result.extended_start orelse return result;
    var lba = ext;
    var hops: usize = 0;
    while (hops < 64 and lba <= media.last_block) : (hops += 1) {
        io.readBlocks(media.media_id, lba, sector_buffer[0..512]) catch break;
        const link = identity.Ebr.parse(sector_buffer[0..512], ext, lba) orelse break;
        if (link.logical) |l| result.addLogical(l.start, l.sectors);
        lba = link.next orelse break;
    }
    return result;
}

// ------------------------------------------- file systems (confirmation)

const fs_probe = identity.fs_probe;
const storage = usos.storage;

/// Disk reads for the confirmation overview: byte-addressed over BlockIo,
/// bounded per disk (read_budget) so a huge or damaged volume cannot stall
/// the menu.
const read_budget: u64 = 96 * 1024 * 1024;
var bounce: [65536]u8 align(4096) = undefined;
const DiskReader = struct {
    io: *uefi.protocol.BlockIo,
    spent: u64 = 0,

    fn reader(self: *DiskReader) storage.random_reader.Reader {
        return .{ .context = self, .read_fn = readFn };
    }

    fn readFn(context: *anyopaque, offset: u64, output: []u8) storage.random_reader.Error!void {
        const self: *DiskReader = @ptrCast(@alignCast(context));
        const media = self.io.media;
        const block: u64 = media.block_size;
        if (block == 0 or block > bounce.len) return error.Io;
        self.spent += output.len;
        if (self.spent > read_budget) return error.Io;
        var done: usize = 0;
        while (done < output.len) {
            const at = offset + done;
            const lba = at / block;
            const skip: usize = @intCast(at % block);
            const blocks = @min((skip + (output.len - done) + block - 1) / block, bounce.len / block);
            if (lba + blocks - 1 > media.last_block) return error.OutOfBounds;
            const bytes: usize = @intCast(blocks * block);
            self.io.readBlocks(media.media_id, lba, bounce[0..bytes]) catch return error.Io;
            const n = @min(bytes - skip, output.len - done);
            @memcpy(output[done..][0..n], bounce[skip..][0..n]);
            done += n;
        }
    }
};

var head: [fs_probe.head_bytes]u8 = undefined;
var chunk: [65536]u8 = undefined;
var ntfs_fs: storage.ntfs.FileSystem = undefined;
var ntfs_file: storage.ntfs.File = undefined;

fn u16s(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

/// xp_detect_system.sh on NTFS: Windows (ntoskrnl.exe + config\SYSTEM),
/// XP installation files, Windows boot files, else none.
fn ntfsSystem(r: storage.random_reader.Reader) []const u8 {
    const ntfs = storage.ntfs;
    inline for (.{ "Windows", "WINNT" }) |dir| {
        const kernel = [_][]const u16{ u16s(dir), u16s("System32"), u16s("ntoskrnl.exe") };
        const hive = [_][]const u16{ u16s(dir), u16s("System32"), u16s("config"), u16s("SYSTEM") };
        if (ntfs.openFile(ntfs_fs, r, &kernel, &ntfs_file)) |_| {
            if (ntfs.openFile(ntfs_fs, r, &hive, &ntfs_file)) |_| return "Windows (system files)" else |_| {}
        } else |_| {}
    }
    inline for (.{ "$WIN_NT$.~BT", "$WIN_NT$.~LS" }) |dir| {
        const parts = [_][]const u16{u16s(dir)};
        if (ntfs.directoryInfo(ntfs_fs, r, &parts)) |_| return "XP installation files" else |_| {}
    }
    inline for (.{ "bootmgr", "NTLDR" }) |file| {
        const parts = [_][]const u16{u16s(file)};
        if (ntfs.openFile(ntfs_fs, r, &parts, &ntfs_file)) |_| return "Windows boot files" else |_| {}
    }
    return "No system detected";
}

fn probeNtfs(r: storage.random_reader.Reader, start: u64, size: u64, p: *fs_probe.Probe) void {
    const n = fs_probe.Ntfs.parse(head[0..512]) orelse return;
    // Label: $VOLUME_NAME of the $Volume record (MFT 3).
    if (r.readAt(start + n.recordOffset(3), chunk[0..n.record_bytes])) |_| {
        if (fs_probe.applyFixups(chunk[0..n.record_bytes], n.bytes_per_sector)) {
            if (fs_probe.ntfsVolumeName(chunk[0..n.record_bytes])) |name| p.setLabelUtf16(name);
        }
    } else |_| {}
    ntfs_fs = storage.ntfs.mount(r, .{ .start_bytes = start, .size_bytes = size }) catch |err| {
        logLine("fs ntfs mount failed: {s}", .{@errorName(err)});
        return;
    };
    // Used clusters: the set bits of $Bitmap (as ntfs3's statfs).
    const bitmap = [_][]const u16{u16s("$Bitmap")};
    if (storage.ntfs.openFile(ntfs_fs, r, &bitmap, &ntfs_file)) |_| {
        const want = @min((n.total_clusters + 7) / 8, ntfs_file.size());
        if (want <= 64 * 1024 * 1024) {
            var used: u64 = 0;
            var offset: u64 = 0;
            const ok = while (offset < want) {
                const len: usize = @intCast(@min(chunk.len, want - offset));
                ntfs_file.readAt(ntfs_fs, r, offset, chunk[0..len]) catch break false;
                used += fs_probe.countSetBits(chunk[0..len], n.total_clusters - offset * 8);
                offset += len;
            } else true;
            if (ok) {
                const space = n.space(used);
                p.used = space.used;
                p.free = space.free;
            } else logLine("fs ntfs $Bitmap read failed at {d}", .{offset});
        } else logLine("fs ntfs $Bitmap too large ({d} bytes), space unknown", .{want});
    } else |err| logLine("fs ntfs $Bitmap not opened: {s}", .{@errorName(err)});
    p.system = ntfsSystem(r);
}

/// The first cluster of a FAT directory (`cluster` 0: the FAT12/16 root),
/// searched along its chain (at most 512 clusters).
fn fatFind(r: storage.random_reader.Reader, start: u64, bpb: fs_probe.FatBpb, dir_cluster: u32, name83: *const [11]u8, directory: bool) ?u32 {
    if (dir_cluster == 0) {
        const bytes = @min(@as(usize, bpb.rootDirSectors()) * bpb.bytes_per_sector, chunk.len);
        r.readAt(start + @as(u64, bpb.rootDirSector()) * bpb.bytes_per_sector, chunk[0..bytes]) catch return null;
        return switch (fs_probe.fatDirFind(chunk[0..bytes], name83, directory)) {
            .found => |c| c,
            else => null,
        };
    }
    var cluster = dir_cluster;
    const cbytes: usize = @intCast(@min(bpb.clusterBytes(), chunk.len));
    var hops: usize = 0;
    while (hops < 512 and cluster >= 2 and cluster < bpb.clusters + 2) : (hops += 1) {
        r.readAt(start + bpb.clusterOffset(cluster), chunk[0..cbytes]) catch return null;
        switch (fs_probe.fatDirFind(chunk[0..cbytes], name83, directory)) {
            .found => |c| return c,
            .end => return null,
            .more => {},
        }
        var entry: [4]u8 = undefined;
        r.readAt(start + @as(u64, bpb.reserved) * bpb.bytes_per_sector + fs_probe.fatEntryOffset(bpb.bits, cluster), entry[0..if (bpb.bits == 32) 4 else 2]) catch return null;
        cluster = fs_probe.fatNext(bpb.bits, &entry, cluster) orelse return null;
    }
    return null;
}

fn fatSystem(r: storage.random_reader.Reader, start: u64, bpb: fs_probe.FatBpb) []const u8 {
    const root: u32 = if (bpb.bits == 32) bpb.root_cluster else 0;
    inline for (.{ "WINDOWS    ", "WINNT      " }) |dir| {
        if (fatFind(r, start, bpb, root, dir, true)) |windows| {
            if (fatFind(r, start, bpb, windows, "SYSTEM32   ", true)) |system32| {
                if (fatFind(r, start, bpb, system32, "NTOSKRNLEXE", false) != null) {
                    if (fatFind(r, start, bpb, system32, "CONFIG     ", true)) |config| {
                        if (fatFind(r, start, bpb, config, "SYSTEM     ", false) != null) return "Windows (system files)";
                    }
                }
            }
        }
    }
    if (fatFind(r, start, bpb, root, "$WIN_NT$~BT", true) != null or fatFind(r, start, bpb, root, "$WIN_NT$~LS", true) != null) return "XP installation files";
    if (fatFind(r, start, bpb, root, "BOOTMGR    ", false) != null or fatFind(r, start, bpb, root, "NTLDR      ", false) != null) return "Windows boot files";
    return "No system detected";
}

fn probeFat(r: storage.random_reader.Reader, start: u64, p: *fs_probe.Probe) void {
    const bpb = fs_probe.FatBpb.parse(head[0..512]) orelse return;
    // Label: the root directory's volume label entry wins (blkid).
    const root_offset = if (bpb.bits == 32) bpb.clusterOffset(bpb.root_cluster) else @as(u64, bpb.rootDirSector()) * bpb.bytes_per_sector;
    const root_bytes: usize = @intCast(@min(if (bpb.bits == 32) bpb.clusterBytes() else @as(u64, bpb.rootDirSectors()) * bpb.bytes_per_sector, chunk.len));
    if (r.readAt(start + root_offset, chunk[0..root_bytes])) |_| {
        if (fs_probe.fatDirLabel(chunk[0..root_bytes])) |label| p.setLabel(label);
    } else |_| {}
    // Free clusters: valid FSInfo, else the FAT counted (Linux vfat).
    var free: ?u32 = null;
    if (bpb.bits == 32 and bpb.fsinfo_sector != 0) {
        if (r.readAt(start + @as(u64, bpb.fsinfo_sector) * bpb.bytes_per_sector, chunk[0..512])) |_| {
            free = fs_probe.fsinfoFree(chunk[0..512], bpb.clusters);
        } else |_| {}
    }
    if (free == null) {
        const total = fs_probe.fatBytes(bpb.bits, bpb.clusters);
        if (total <= 32 * 1024 * 1024) {
            const step: usize = if (bpb.bits == 12) 49152 else chunk.len; // FAT12: whole entry pairs
            const per: u32 = switch (bpb.bits) {
                12 => 32768,
                16 => 32768,
                else => 16384,
            };
            var count: u32 = 0;
            var offset: u64 = 0;
            var first: u32 = 0;
            const ok = while (offset < total) {
                const len: usize = @intCast(@min(step, total - offset));
                r.readAt(start + @as(u64, bpb.reserved) * bpb.bytes_per_sector + offset, chunk[0..len]) catch break false;
                count += fs_probe.countFreeFat(bpb.bits, chunk[0..len], first, bpb.clusters);
                offset += len;
                first += per;
            } else true;
            if (ok) free = count;
        }
    }
    if (free) |f| {
        const space = fs_probe.fatSpace(bpb, f);
        p.used = space.used;
        p.free = space.free;
    }
    p.system = fatSystem(r, start, bpb);
}

fn probeExfat(r: storage.random_reader.Reader, start: u64, p: *fs_probe.Probe) void {
    const ex = fs_probe.Exfat.parse(head[0..512]) orelse return;
    const bytes: usize = @intCast(@min(@as(u64, 1) << (@as(u6, ex.sector_shift) + ex.cluster_shift), chunk.len));
    r.readAt(start + ex.clusterOffset(ex.root_cluster), chunk[0..bytes]) catch return;
    if (fs_probe.exfatLabel(chunk[0..bytes])) |label| p.setLabelUtf16(label);
}

/// File system, label, used / free space and system of every listed
/// partition (xp_disk_overview.sh), read only and bounded.
fn probeFileSystems(io: *uefi.protocol.BlockIo, layout: *identity.Partitions) void {
    var disk: DiskReader = .{ .io = io };
    const r = disk.reader();
    const block: u64 = io.media.block_size;
    for (layout.entries[0..layout.entry_count]) |*e| {
        if (e.container or e.sectors == 0) continue;
        const start = e.start * block;
        const size = e.sectors * block;
        const n: usize = @intCast(@min(size, head.len));
        @memset(&head, 0);
        if (n < 512) continue;
        r.readAt(start, head[0..n]) catch |err| {
            logLine("fs partition={d} head read failed: {s}", .{ e.number, @errorName(err) });
            continue;
        };
        e.probe = fs_probe.probeHead(head[0..n]);
        switch (e.probe.fs) {
            .ntfs => probeNtfs(r, start, size, &e.probe),
            .vfat => probeFat(r, start, &e.probe),
            .exfat => probeExfat(r, start, &e.probe),
            else => {},
        }
        logLine("fs partition={d} fs={s} label=\"{s}\" mib={d} used_mib={?d} free_mib={?d} system={s}", .{ e.number, e.probe.fs.name(), e.probe.labelText(), e.mib(), if (e.probe.used) |u| u / 1048576 else null, if (e.probe.free) |f| f / 1048576 else null, e.probe.system orelse "unknown" });
    }
    logLine("fs probe read {d} KiB", .{disk.spent / 1024});
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
        if (plan.refusal(route, info)) |why| {
            logLine("disk not offered bus={s} sectors={d}: {s}", .{ bus, sectors, why });
            continue;
        }
        if (b.len > plan.max_disk_path or count == max_disks) continue;
        const row = &rows[count];
        row.* = .{ .disk = .{ .sectors = sectors }, .io = io };
        @memcpy(row.disk.path[0..b.len], b);
        row.disk.path_len = b.len;
        row.id = readIdentity(count, handle, path, bus);
        row.id.bus = identity.busToken(bus, row.id.interface);
        row.layout = readPartitions(io);
        const bytes = sectors * 512;
        row.title_len = if (identity.pickerTitle(&row.title, &row.id, bytes)) |t| t.len else |_| 0;
        row.detail_len = if (std.fmt.bufPrint(&row.detail, "S/N: {s}", .{row.id.serialText()})) |t| t.len else |_| 0;
        const tenths = bytes * 10 / (1024 * 1024 * 1024);
        const label: []const u8 = std.fmt.bufPrint(&row.label, "{s}   {d}.{d} GiB   ({s})", .{ bus, tenths / 10, tenths % 10, @tagName(row.layout.table) }) catch "disk";
        row.label_len = label.len;
        logLine("disk offered disk={d} {s} model=\"{s}\" bus={s} media={s} table={s} partitions={d} serial_known={any}", .{ count, row.label[0..row.label_len], row.id.modelText(), row.id.bus orelse "-", row.id.media orelse "-", @tagName(row.layout.table), row.layout.count, row.id.serial_len > 0 });
        count += 1;
    }
    return count;
}

pub const Outcome = union(enum) { disk: plan.Disk, cancelled, none };

/// The flow's only disk question: the picker, then the erase confirmation.
/// `name` is the system as Alpine names it ("Windows 10").
pub fn ask(route: plan.Route, name: []const u8) Outcome {
    log_len = 0;
    logLine("disk question {s} route={s} system=\"{s}\"", .{ usos.build_info.id, @tagName(route), name });
    const count = collect(route);
    logLine("disks offered: {d}", .{count});
    flushLog();
    if (count == 0) return .none;
    if (view.screenUi() == null) return askForm(count, name);
    while (true) {
        const chosen = pick(count, name, route) orelse return .cancelled;
        const row = &rows[chosen];
        // vista_csmwrap_prepare.sh: "Inspecting disk" while the overview is
        // read (MiniOS has it already from the picker scan).
        if (confirm(row, name, route)) {
            logLine("disk confirmed {s} model=\"{s}\"", .{ row.label[0..row.label_len], row.id.modelText() });
            flushLog();
            return .{ .disk = row.disk };
        }
        logLine("erase confirmation cancelled; back to the disk list", .{});
        flushLog();
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
fn confirm(row: *Row, name: []const u8, route: plan.Route) bool {
    if (route == .mbr_csmwrap) view.miniosStage(3, "Inspecting disk", "Reading partitions, free space and system files.", name);
    if (!row.inspected) {
        logLine("inspecting {s}", .{row.label[0..row.label_len]});
        probeFileSystems(row.io, &row.layout);
        row.inspected = true;
        flushLog();
    }
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
                    logLine("disk confirmed {s}", .{row.label[0..row.label_len]});
                    flushLog();
                    return .{ .disk = row.disk };
                },
                other_id => continue,
                else => return .cancelled,
            },
        }
    }
}
