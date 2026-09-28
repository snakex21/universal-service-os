//! Linux ISO from DATA on UEFI (docs/design/linux-iso-boot.md sections 3-5):
//! the kernel and initrds are read from the ISO on NTFS, USOS's helper cpio
//! (\EFI\USOS\linux\usos-linux.cpio on the ESP) and a per-boot cpio with
//! /usos/iso.map (+ the rendered answer) are appended, the initrd is published
//! through LINUX_EFI_INITRD_MEDIA_GUID + EFI_LOAD_FILE2_PROTOCOL and the kernel
//! is started with LoadOptions = the recipe's command line.
//!
//! Secure Boot: the kernel goes through verified_image (shim 16 hooks
//! LoadImage: db, MOK or the Fedora CA). A kernel the running shim does not
//! trust is refused with error.SecureBootRejected; the distro-shim relay
//! (design section 5) is the next step.
const std = @import("std");
const uefi = std.os.uefi;
const cc = uefi.cc;
const Status = uefi.Status;
const usos = @import("usos");
const linux_iso = usos.flow.linux_iso;
const ntfs = usos.storage.ntfs;
const iso9660 = usos.image_probe.iso9660;
const data_volume = @import("data_volume.zig");
const verified_image = @import("verified_image.zig");
const file_read = @import("file_read.zig");
const serial = @import("serial.zig");
const PathBuffer = @import("windows_native_iso.zig").PathBuffer;
const secure_boot = @import("secure_boot.zig");

pub const helper_path = "\\EFI\\USOS\\linux\\usos-linux.cpio";
const max_helper_bytes = 1024 * 1024;
const max_kernel_bytes = 128 * 1024 * 1024;
const max_initrd_bytes = 1024 * 1024 * 1024;

pub const Error = error{
    BootServicesUnavailable,
    IsoNotContiguousEnough,
    IsoResidentOrSparse,
    IsoTooSmall,
    KernelTooLarge,
    InitrdTooLarge,
    HelperMissing,
    LinuxKernelReturned,
    RelayFailed,
    NoDistroShim,
};

/// An answer file rendered for this start (design section 7): the cpio path
/// and its bytes, plus words added to the kernel command line.
pub const Answer = struct {
    path: []const u8,
    bytes: []const u8,
    cmdline: []const u8 = "",
};

const State = struct {
    catalog: data_volume.Catalog,
    file: ntfs.File,
};

const IsoReader = struct {
    state: *State,
    pub fn size(self: *const IsoReader) u64 {
        return self.state.file.size();
    }
    pub fn readAt(self: *const IsoReader, offset: u64, output: []u8) !usize {
        try self.state.file.readAt(self.state.catalog.fs, self.state.catalog.reader(), offset, output);
        return output.len;
    }
};

/// recipe.plan's view of the ISO.
const IsoSource = struct {
    reader: *IsoReader,
    label_buf: [32]u8 = undefined,
    label_len: usize = 0,

    pub fn volumeLabel(self: *const IsoSource) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    pub fn exists(self: *const IsoSource, path: []const u8) bool {
        return (iso9660.findRecord(self.reader, path) catch null) != null;
    }
    pub fn read(self: *const IsoSource, path: []const u8, buffer: []u8) ?[]const u8 {
        const record = (iso9660.findRecord(self.reader, path) catch return null) orelse return null;
        if (record.is_directory or record.size > buffer.len) return null;
        const n: usize = @intCast(record.size);
        _ = self.reader.readAt(@as(u64, record.extent_lba) * 2048, buffer[0..n]) catch return null;
        return buffer[0..n];
    }
};

/// Written into the per-boot cpio as /preseed.cfg for d-i when no profile is
/// used; the rendered Debian answer file contains the same line.
pub const debian_default_preseed = "d-i cdrom-detect/try-usb boolean true" ++ "\n";

pub const Status_ = enum { reading, loading, starting };

/// Reads, prepares and starts the ISO. Returns only on failure.
pub fn start(
    root: *uefi.protocol.File,
    image_directory: []const u8,
    name: []const u8,
    answer: ?Answer,
    progress: *const fn (Status_) void,
) !void {
    return startMode(root, image_directory, name, answer, progress, .menu);
}

const Mode = enum {
    /// Started from the USOS menu (USOS shim, or no Secure Boot).
    menu,
    /// This USOS instance is the second stage of the ISO's own shim.
    relay,
};

fn startMode(
    root: *uefi.protocol.File,
    image_directory: []const u8,
    name: []const u8,
    answer: ?Answer,
    progress: *const fn (Status_) void,
    mode: Mode,
) !void {
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    progress(.reading);
    logf("[LINUX-ISO] open {s}\r\n", .{name});
    const state = try uefi.pool_allocator.create(State);
    defer uefi.pool_allocator.destroy(state);
    state.catalog = try data_volume.openCatalog();
    var path: PathBuffer = .{};
    try ntfs.openFile(state.catalog.fs, state.catalog.reader(), try path.build(image_directory, name), &state.file);
    var reader = IsoReader{ .state = state };

    logf("[LINUX-ISO] opened, {d} bytes\r\n", .{state.file.size()});
    // Where the ISO lies on the disk.
    var map = try isoMap(state);
    var pvd: [linux_iso.iso_map.pvd_bytes]u8 = undefined;
    _ = try reader.readAt(linux_iso.iso_map.pvd_offset, &pvd);
    map.crc = linux_iso.iso_map.pvdCrc(&pvd);

    var source = IsoSource{ .reader = &reader };
    const label = std.mem.trimEnd(u8, pvd[40..72], " \x00");
    source.label_len = @min(label.len, source.label_buf.len);
    @memcpy(source.label_buf[0..source.label_len], label[0..source.label_len]);
    const recipe = try uefi.pool_allocator.create(linux_iso.recipe.Recipe);
    defer uefi.pool_allocator.destroy(recipe);
    try linux_iso.recipe.plan(&source, recipe);
    logf("[LINUX-ISO] family={s} kernel={s} initrds={d} extents={d}\r\n", .{ @tagName(recipe.family), recipe.kernel(), recipe.initrdCount(), map.len });

    progress(.loading);
    // Kernel.
    const kernel_record = (try iso9660.findRecord(&reader, recipe.kernel())) orelse return error.FileNotFound;
    if (kernel_record.size > max_kernel_bytes) return error.KernelTooLarge;
    const kernel = try allocate(bs, @intCast(kernel_record.size));
    _ = try reader.readAt(@as(u64, kernel_record.extent_lba) * 2048, kernel);

    // Secure Boot: the running shim verifies the kernel (menu mode: USOS's
    // Fedora shim, e.g. Fedora kernels); a kernel it rejects is handed to the
    // ISO's own Microsoft-signed shim (design section 5). Relay mode: any
    // installed SHIM_LOCK must accept it.
    var handle: ?uefi.Handle = null;
    switch (mode) {
        .menu => {
            handle = verified_image.loadBuffer(kernel) catch |err| {
                if (err == error.SecureBootRejected and secure_boot.enforced() and recipe.shim_layout) {
                    freeBytes(bs, kernel);
                    return relay(root, &reader, image_directory, name);
                }
                return err;
            };
        },
        .relay => try verified_image.verifyWithAnyShim(kernel),
    }

    // Initrd = distro initrds + helper cpio + per-boot cpio, each 4-byte aligned.
    const helper_buffer = try allocate(bs, max_helper_bytes);
    defer freeBytes(bs, helper_buffer);
    logf("[LINUX-ISO] kernel read ({d} KiB)\r\n", .{kernel.len / 1024});
    const helper = file_read.into(root, helper_path, helper_buffer) orelse return error.HelperMissing;
    // Debian installer: the ISO appears as a USB partition (BLKPG fallback of
    // /usos/init); cdrom-detect only looks at USB partitions when asked.
    const default_preseed = Answer{ .path = "preseed.cfg", .bytes = debian_default_preseed };
    const effective = answer orelse if (recipe.family == .debian_installer) default_preseed else null;
    const per_boot = try perBootCpio(&map, effective, &per_boot_buffer);
    var total: u64 = helper.len + per_boot.len;
    var records: [linux_iso.grub_cfg.max_initrds]iso9660.Record = undefined;
    for (0..recipe.initrdCount()) |i| {
        records[i] = (try iso9660.findRecord(&reader, recipe.initrd(i))) orelse return error.FileNotFound;
        total += records[i].size + linux_iso.cpio.padding(records[i].size);
    }
    if (total > max_initrd_bytes) return error.InitrdTooLarge;
    const initrd = try allocate(bs, @intCast(total));
    var at: usize = 0;
    for (records[0..recipe.initrdCount()]) |record| {
        const n: usize = @intCast(record.size);
        _ = try reader.readAt(@as(u64, record.extent_lba) * 2048, initrd[at..][0..n]);
        at += n;
        const pad: usize = @intCast(linux_iso.cpio.padding(n));
        @memset(initrd[at..][0..pad], 0);
        at += pad;
    }
    @memcpy(initrd[at..][0..helper.len], helper);
    at += helper.len;
    @memcpy(initrd[at..][0..per_boot.len], per_boot);
    at += per_boot.len;
    initrd_bytes = initrd[0..at];

    // Command line (UTF-16, NUL-terminated).
    const words = if (answer) |a| a.cmdline else "";
    const cmdline = try utf16Cmdline(recipe.cmdline(), words);

    progress(.starting);
    logf("[LINUX-ISO] initrd assembled; loading kernel (secure boot: {s})\r\n", .{if (@import("secure_boot.zig").enforced()) "on" else "off"});
    try installInitrd(bs);
    defer uninstallInitrd(bs);
    logf("[LINUX-ISO] starting kernel ({d} KiB initrd)\r\n", .{at / 1024});
    if (handle) |loaded| {
        verified_image.setLoadOptions(loaded, cmdline);
        _ = verified_image.start(loaded) catch {};
    } else {
        verified_image.startApplicationManually(kernel, cmdline) catch {};
    }
    return error.LinuxKernelReturned;
}

fn logf(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    serial.writeAscii(std.fmt.bufPrint(&buffer, format, args) catch return);
}

fn allocate(bs: *uefi.tables.BootServices, bytes: usize) ![]u8 {
    const pages = try bs.allocatePages(.any, .loader_data, (bytes + 4095) / 4096);
    return std.mem.sliceAsBytes(pages)[0..bytes];
}

fn freeBytes(bs: *uefi.tables.BootServices, bytes: []u8) void {
    const page_ptr: [*]align(4096) [4096]u8 = @ptrCast(@alignCast(bytes.ptr));
    bs.freePages(page_ptr[0 .. (bytes.len + 4095) / 4096]) catch {};
}

/// The ISO's NTFS runs as absolute disk sectors of 512 bytes.
fn isoMap(state: *State) !linux_iso.iso_map.Map {
    const file = &state.file;
    if (file.resident_len != null) return error.IsoResidentOrSparse;
    const size = file.size();
    if (size < linux_iso.iso_map.pvd_offset + linux_iso.iso_map.pvd_bytes) return error.IsoTooSmall;
    const cluster: u64 = state.catalog.fs.cluster_bytes;
    const part_start = state.catalog.partition.start_lba;
    var map = linux_iso.iso_map.Map{ .size = size };
    var covered: u64 = 0;
    for (file.stream.runs[0..file.stream.len]) |run| {
        if (run.sparse or run.lcn < 0) return error.IsoResidentOrSparse;
        if (covered >= size) break;
        var bytes = run.clusters * cluster;
        if (covered + bytes > size) bytes = size - covered;
        const lba = part_start + @as(u64, @intCast(run.lcn)) * (cluster / 512);
        map.append(lba, (bytes + 511) / 512) catch return error.IsoNotContiguousEnough;
        covered += bytes;
    }
    if (covered < size) return error.IsoResidentOrSparse;
    return map;
}

fn perBootCpio(map: *const linux_iso.iso_map.Map, answer: ?Answer, buffer: []u8) ![]const u8 {
    const map_text = try map.write(&map_text_buffer);
    var writer = linux_iso.cpio.Writer{ .out = buffer };
    try writer.directory("usos");
    try writer.file("usos/iso.map", 0o644, map_text);
    if (answer) |a| {
        if (std.mem.startsWith(u8, a.path, "usos/answer/")) try writer.directory("usos/answer");
        try writer.file(a.path, 0o600, a.bytes);
    }
    return writer.finish();
}

var cmdline_utf16: [2048]u16 = undefined;
var per_boot_buffer: [16 * 1024]u8 = undefined;
var map_text_buffer: [4096]u8 = undefined;

fn utf16Cmdline(recipe_words: []const u8, extra: []const u8) ![]const u16 {
    var n: usize = 0;
    for ([_][]const u8{ recipe_words, extra }) |part| {
        if (part.len == 0) continue;
        if (n != 0) {
            cmdline_utf16[n] = ' ';
            n += 1;
        }
        if (n + part.len + 1 > cmdline_utf16.len) return error.CommandLineTooLong;
        for (part) |c| {
            cmdline_utf16[n] = c;
            n += 1;
        }
    }
    cmdline_utf16[n] = 0;
    return cmdline_utf16[0 .. n + 1];
}

// ---------------------------------------------------------------- initrd LoadFile2

/// LINUX_EFI_INITRD_MEDIA_GUID (drivers/firmware/efi/libstub).
const initrd_media_guid align(8) = uefi.Guid{
    .time_low = 0x5568e427,
    .time_mid = 0x68fc,
    .time_high_and_version = 0x4f3d,
    .clock_seq_high_and_reserved = 0xac,
    .clock_seq_low = 0x74,
    .node = .{ 0xca, 0x55, 0x52, 0x31, 0xcc, 0x68 },
};

const load_file2_guid align(8) = uefi.Guid{
    .time_low = 0x4006c0c1,
    .time_mid = 0xfcb3,
    .time_high_and_version = 0x403e,
    .clock_seq_high_and_reserved = 0x99,
    .clock_seq_low = 0x6d,
    .node = .{ 0x4a, 0x6c, 0x87, 0x24, 0xe0, 0x6d },
};

const LoadFile2 = extern struct {
    load_file: *const fn (*const LoadFile2, ?*const anyopaque, bool, *usize, ?*anyopaque) callconv(cc) Status,
};

const InitrdDevicePath = extern struct {
    vendor_type: u8 = 4, // media
    vendor_subtype: u8 = 3, // vendor
    vendor_length: [2]u8 = .{ 20, 0 },
    guid: uefi.Guid align(1) = initrd_media_guid,
    end_type: u8 = 0x7f,
    end_subtype: u8 = 0xff,
    end_length: [2]u8 = .{ 4, 0 },
};

var initrd_bytes: []const u8 = &.{};
var initrd_path = InitrdDevicePath{};
var initrd_protocol = LoadFile2{ .load_file = loadInitrd };
var initrd_handle: ?uefi.Handle = null;

fn loadInitrd(_: *const LoadFile2, _: ?*const anyopaque, boot_policy: bool, size: *usize, buffer: ?*anyopaque) callconv(cc) Status {
    if (boot_policy) return .unsupported;
    if (buffer == null or size.* < initrd_bytes.len) {
        size.* = initrd_bytes.len;
        return .buffer_too_small;
    }
    const out: [*]u8 = @ptrCast(buffer.?);
    @memcpy(out[0..initrd_bytes.len], initrd_bytes);
    size.* = initrd_bytes.len;
    return .success;
}

fn installInitrd(bs: *uefi.tables.BootServices) !void {
    const Install = *const fn (*?uefi.Handle, *const uefi.Guid, uefi.tables.InterfaceType, *anyopaque) callconv(cc) Status;
    const install: Install = @ptrCast(bs._installProtocolInterface);
    var handle: ?uefi.Handle = null;
    if (install(&handle, &uefi.protocol.DevicePath.guid, .native, @ptrCast(&initrd_path)) != .success) return error.Unexpected;
    if (install(&handle, &load_file2_guid, .native, @ptrCast(&initrd_protocol)) != .success) return error.Unexpected;
    initrd_handle = handle;
}

fn uninstallInitrd(bs: *uefi.tables.BootServices) void {
    const handle = initrd_handle orelse return;
    const Uninstall = *const fn (uefi.Handle, *const uefi.Guid, *anyopaque) callconv(cc) Status;
    const uninstall: Uninstall = @ptrCast(bs._uninstallProtocolInterface);
    _ = uninstall(handle, &load_file2_guid, @ptrCast(&initrd_protocol));
    _ = uninstall(handle, &uefi.protocol.DevicePath.guid, @ptrCast(&initrd_path));
    initrd_handle = null;
}

// ---------------------------------------------------------------- distro-shim relay

pub const relay_plan_path = "\\EFI\\USOS\\linux\\relay.ini";
const relay_plan_file = std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\linux\\relay.ini");
/// shim takes its second stage from its own directory: on the USOS ESP that is
/// \EFI\BOOT\grubx64.efi = USOS. The name is not BOOT*.EFI (no fallback).
const relay_file_node = std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\BOOT\\USOSRELAY.EFI");

/// Starts the ISO's Microsoft-signed shim (\EFI\BOOT\BOOTX64.EFI of the ISO)
/// as if it were \EFI\BOOT\USOSRELAY.EFI on the USOS ESP. It starts USOS
/// again as its second stage; that instance finds relay.ini (resumeRelay).
fn relay(root: *uefi.protocol.File, reader: *IsoReader, image_directory: []const u8, name: []const u8) !void {
    const bs = uefi.system_table.boot_services orelse return error.BootServicesUnavailable;
    const record = (iso9660.findRecord(reader, "EFI/BOOT/BOOTX64.EFI") catch null) orelse return error.NoDistroShim;
    if (record.size > 8 * 1024 * 1024) return error.NoDistroShim;
    const shim = try allocate(bs, @intCast(record.size));
    defer freeBytes(bs, shim);
    _ = try reader.readAt(@as(u64, record.extent_lba) * 2048, shim);

    var plan: [700]u8 = undefined;
    const text = try std.fmt.bufPrint(&plan, "[relay]\r\nversion=1\r\ndirectory={s}\r\nname={s}\r\n", .{ image_directory, name });
    try writeEspFile(root, relay_plan_file, text);
    errdefer deleteEspFile(root, relay_plan_file);

    const path = try relayDevicePath(bs);
    logf("[LINUX-ISO] Secure Boot: kernel not trusted by the USOS shim; relaying through the ISO's shim ({d} bytes)\r\n", .{shim.len});
    const image = try verified_image.loadBufferAt(shim, path);
    _ = verified_image.start(image) catch {};
    // The relay instance normally never returns (it starts the kernel).
    deleteEspFile(root, relay_plan_file);
    return error.RelayFailed;
}

var relay_path_buffer: [512]u8 align(8) = undefined;

/// <device path of the USOS ESP> + File(\EFI\BOOT\USOSRELAY.EFI) + End.
fn relayDevicePath(bs: *uefi.tables.BootServices) !*const uefi.protocol.DevicePath {
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.RelayFailed;
    const device = loaded.device_handle orelse return error.RelayFailed;
    const device_path = (try bs.handleProtocol(uefi.protocol.DevicePath, device)) orelse return error.RelayFailed;
    const bytes: [*]const u8 = @ptrCast(device_path);
    var at: usize = 0;
    while (true) {
        const node_type = bytes[at];
        const len = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
        if (node_type == 0x7f or len < 4) break;
        at += len;
        if (at > 400) return error.RelayFailed;
    }
    @memcpy(relay_path_buffer[0..at], bytes[0..at]);
    const name_bytes = (relay_file_node.len + 1) * 2;
    const node_len: u16 = @intCast(4 + name_bytes);
    relay_path_buffer[at] = 4; // media
    relay_path_buffer[at + 1] = 4; // file path
    std.mem.writeInt(u16, relay_path_buffer[at + 2 ..][0..2], node_len, .little);
    for (relay_file_node, 0..) |unit, i| std.mem.writeInt(u16, relay_path_buffer[at + 4 + i * 2 ..][0..2], unit, .little);
    std.mem.writeInt(u16, relay_path_buffer[at + 4 + relay_file_node.len * 2 ..][0..2], 0, .little);
    at += node_len;
    @memcpy(relay_path_buffer[at..][0..4], &[4]u8{ 0x7f, 0xff, 4, 0 });
    return @ptrCast(&relay_path_buffer);
}

/// Second USOS instance (the ISO's shim started \EFI\BOOT\grubx64.efi): when
/// relay.ini exists, delete it and start that ISO's kernel, verified by the
/// shim that started us. Returns (to the menu) when there is no plan or the
/// start fails.
pub fn resumeRelay(root: *uefi.protocol.File) void {
    var buffer: [700]u8 = undefined;
    const text = file_read.into(root, relay_plan_path, &buffer) orelse return;
    deleteEspFile(root, relay_plan_file);
    var directory: []const u8 = "";
    var name: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "directory=")) directory = line["directory=".len..];
        if (std.mem.startsWith(u8, line, "name=")) name = line["name=".len..];
    }
    if (!std.mem.startsWith(u8, directory, "\\Systems\\Linux\\") or name.len == 0) return;
    logf("[LINUX-ISO] relay instance: {s}\r\n", .{name});
    startMode(root, directory, name, null, noProgress, .relay) catch |err| {
        logf("[LINUX-ISO] relay start failed: {s}\r\n", .{@errorName(err)});
    };
}

fn noProgress(_: Status_) void {}

fn writeEspFile(root: *uefi.protocol.File, name: [*:0]const u16, bytes: []const u8) !void {
    deleteEspFile(root, name);
    const file = try root.open(name, .read_write_create, .{});
    defer file.close() catch {};
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try file.write(bytes[written..]);
        if (n == 0) return error.RelayFailed;
        written += n;
    }
    try file.flush();
}

fn deleteEspFile(root: *uefi.protocol.File, name: [*:0]const u16) void {
    if (root.open(name, .read_write, .{})) |old| {
        _ = old.delete() catch {};
    } else |_| {}
}
