const std = @import("std");
const graphics = @import("graphics");
const e820 = @import("e820.zig");
const linux_boot_header = @import("linux_boot_header.zig");
const vbe_probe = @import("vbe_probe.zig");

pub const boot_params_bytes: usize = 4096;
pub const boot_params_phys: u32 = 0x00060000;
pub const cmdline_phys: u32 = 0x00062000;
pub const cmdline_capacity: usize = 2048;

const setup_header_start: usize = 0x1F1;
const setup_header_end: usize = linux_boot_header.minimum_header_bytes;
const e820_entries_offset: usize = 0x1E8;
const setup_type_loader_offset: usize = 0x210;
const setup_loadflags_offset: usize = 0x211;
const setup_code32_start_offset: usize = 0x214;
const setup_ramdisk_image_offset: usize = 0x218;
const setup_ramdisk_size_offset: usize = 0x21C;
const setup_heap_end_ptr_offset: usize = 0x224;
const setup_cmd_line_ptr_offset: usize = 0x228;
const setup_hardware_subarch_offset: usize = 0x23C;
const setup_hardware_subarch_data_offset: usize = 0x240;
const setup_setup_data_offset: usize = 0x250;
const e820_table_offset: usize = 0x2D0;
const e820_entry_bytes: usize = 20;
const quiet_flag: u8 = 1 << 5;

const screen_orig_video_is_vga: usize = 0x0F;
const screen_lfb_width: usize = 0x12;
const screen_lfb_height: usize = 0x14;
const screen_lfb_depth: usize = 0x16;
const screen_lfb_base: usize = 0x18;
const screen_lfb_size: usize = 0x1C;
const screen_lfb_linelength: usize = 0x24;
const screen_red_size: usize = 0x26;
const screen_red_pos: usize = 0x27;
const screen_green_size: usize = 0x28;
const screen_green_pos: usize = 0x29;
const screen_blue_size: usize = 0x2A;
const screen_blue_pos: usize = 0x2B;
const screen_rsvd_size: usize = 0x2C;
const screen_rsvd_pos: usize = 0x2D;
const screen_pages: usize = 0x32;
const video_type_vlfb: u8 = 0x23;

pub const Error = error{
    SetupHeaderTooShort,
    TooManyE820Entries,
    InitrdAbove32Bit,
    InitrdTooLarge,
    CommandLineTooLong,
    FramebufferGeometryOverflow,
};

pub const Result = struct {
    cmdline_len: usize,
    e820_count: usize,
};

pub const XpStagingRequest = struct {
    image_name: []const u8,
    unattended_name: ?[]const u8 = null,
    bios_boot_drive: u8,
    bios_inventory: []const u8,
};

pub const CommandRequest = union(enum) {
    none,
    hardware,
    xp_resume,
    xp_staging: XpStagingRequest,
    windows2000_staging: XpStagingRequest,
    windows7_iso: XpStagingRequest,
    windows_vista_iso: XpStagingRequest,
};

pub fn build(
    params: *[boot_params_bytes]u8,
    cmdline: *[cmdline_capacity]u8,
    setup_header: []const u8,
    initrd_start: u64,
    initrd_size: u64,
    memory_map: []const e820.Entry,
    esp_part_guid_disk: [16]u8,
    graphics_session: ?vbe_probe.Session,
    request: CommandRequest,
) Error!Result {
    try buildStandalone(params, setup_header, memory_map, graphics_session);
    if (initrd_start > std.math.maxInt(u32)) return error.InitrdAbove32Bit;
    if (initrd_size > std.math.maxInt(u32)) return error.InitrdTooLarge;
    params[setup_loadflags_offset] |= quiet_flag;
    writeU32(params, setup_ramdisk_image_offset, @intCast(initrd_start));
    writeU32(params, setup_ramdisk_size_offset, @intCast(initrd_size));
    writeU32(params, setup_cmd_line_ptr_offset, cmdline_phys);
    const cmdline_len = try buildCommandLine(cmdline, esp_part_guid_disk, request);
    return .{ .cmdline_len = cmdline_len, .e820_count = memory_map.len };
}

/// Hardware description for standalone programs using the Linux boot protocol.
pub fn buildStandalone(
    params: *[boot_params_bytes]u8,
    setup_header: []const u8,
    memory_map: []const e820.Entry,
    graphics_session: ?vbe_probe.Session,
) Error!void {
    if (setup_header.len < setup_header_end) return error.SetupHeaderTooShort;
    if (memory_map.len > 128) return error.TooManyE820Entries;

    @memset(params, 0);
    @memcpy(params[setup_header_start..setup_header_end], setup_header[setup_header_start..setup_header_end]);

    params[setup_type_loader_offset] = 0xFF;
    params[setup_loadflags_offset] &= ~@as(u8, 0x80);
    writeU32(params, setup_code32_start_offset, 0x00100000);
    writeU32(params, setup_ramdisk_image_offset, 0);
    writeU32(params, setup_ramdisk_size_offset, 0);
    writeU16(params, setup_heap_end_ptr_offset, 0);
    writeU32(params, setup_cmd_line_ptr_offset, 0);
    writeU32(params, setup_hardware_subarch_offset, 0);
    writeU64(params, setup_hardware_subarch_data_offset, 0);
    writeU64(params, setup_setup_data_offset, 0);

    params[e820_entries_offset] = @intCast(memory_map.len);
    for (memory_map, 0..) |entry, index| {
        const offset = e820_table_offset + index * e820_entry_bytes;
        writeU64(params, offset, entry.base);
        writeU64(params, offset + 8, entry.length);
        writeU32(params, offset + 16, entry.kind);
    }

    if (graphics_session) |session| {
        try fillVesaScreenInfo(params, session);
    } else {
        params[6] = 3; // VGA text mode, 80 columns and 25 rows.
        params[7] = 80;
        params[14] = 25;
        params[15] = 1;
        writeU16(params, 16, 16);
    }
}

pub fn buildLive(output: *[boot_params_bytes]u8, cmdline: *[cmdline_capacity]u8, setup: []const u8, initrd_start: u64, initrd_size: u64, map: []const e820.Entry, graphics_session: ?vbe_probe.Session, command: []const u8) Error!void {
    if (command.len >= cmdline.len) return error.CommandLineTooLong;
    if (initrd_start > std.math.maxInt(u32)) return error.InitrdAbove32Bit;
    if (initrd_size > std.math.maxInt(u32)) return error.InitrdTooLarge;
    try buildStandalone(output, setup, map, graphics_session);
    @memset(cmdline, 0);
    @memcpy(cmdline[0..command.len], command);
    writeU32(output, setup_ramdisk_image_offset, @intCast(initrd_start));
    writeU32(output, setup_ramdisk_size_offset, @intCast(initrd_size));
    writeU32(output, setup_cmd_line_ptr_offset, cmdline_phys);
}

pub fn buildCommandLine(output: *[cmdline_capacity]u8, part_guid_disk: [16]u8, request: CommandRequest) Error!usize {
    const prefix = "console=tty0 console=ttyS0,115200 quiet loglevel=3 fbcon=nodefer vt.global_cursor_default=0 rdinit=/usos-init usos.esp_partuuid=";
    if (prefix.len + 36 + 1 > output.len) return error.CommandLineTooLong;
    @memset(output, 0);
    @memcpy(output[0..prefix.len], prefix);
    formatGuidDisk(part_guid_disk, output[prefix.len .. prefix.len + 36]);
    var used = prefix.len + 36;
    switch (request) {
        .none => {},
        .hardware => { used = try appendCommand(output, used, " usos.legacy_action=hardware"); },
        .xp_resume => { used = try appendCommand(output, used, " usos.legacy_action=xp-resume"); },
        .xp_staging, .windows2000_staging, .windows7_iso, .windows_vista_iso => |xp| {
            if (request == .windows7_iso or request == .windows_vista_iso) used = try appendCommand(output, used, " kexec_load_disabled=0");
            used = try appendCommand(output, used, switch (request) {
                .windows7_iso => " usos.legacy_action=windows7-iso usos.legacy_image_hex=",
                .windows_vista_iso => " usos.legacy_action=windows-vista-iso usos.legacy_image_hex=",
                .windows2000_staging => " usos.legacy_action=windows2000-staging usos.legacy_image_hex=",
                else => " usos.legacy_action=xp-staging usos.legacy_image_hex=",
            });
            used = try appendHex(output, used, xp.image_name);
            if (xp.unattended_name) |name| {
                used = try appendCommand(output, used, " usos.legacy_unattended_hex=");
                used = try appendHex(output, used, name);
            }
            used = try appendCommand(output, used, " usos.bios_boot_drive=");
            if (used + 2 >= output.len) return error.CommandLineTooLong;
            output[used] = hexNibble(xp.bios_boot_drive >> 4);
            output[used + 1] = hexNibble(xp.bios_boot_drive & 0x0f);
            used += 2;
            if (xp.bios_inventory.len != 0) {
                used = try appendCommand(output, used, " usos.bios_disks=");
                used = try appendCommand(output, used, xp.bios_inventory);
            }
        },
    }
    if (used >= output.len) return error.CommandLineTooLong;
    output[used] = 0;
    return used;
}

fn appendCommand(output: *[cmdline_capacity]u8, used: usize, text: []const u8) Error!usize {
    if (used + text.len >= output.len) return error.CommandLineTooLong;
    @memcpy(output[used .. used + text.len], text);
    return used + text.len;
}

fn appendHex(output: *[cmdline_capacity]u8, initial_used: usize, text: []const u8) Error!usize {
    var used = initial_used;
    for (text) |byte| {
        if (used + 2 >= output.len) return error.CommandLineTooLong;
        output[used] = hexNibble(byte >> 4);
        output[used + 1] = hexNibble(byte & 0x0f);
        used += 2;
    }
    return used;
}

fn hexNibble(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn fillVesaScreenInfo(params: *[boot_params_bytes]u8, session: vbe_probe.Session) Error!void {
    const fb = session.framebuffer;
    if (fb.width > std.math.maxInt(u16) or fb.height > std.math.maxInt(u16)) return error.FramebufferGeometryOverflow;
    if (fb.pixels_per_scan_line > std.math.maxInt(u16) / 4) return error.FramebufferGeometryOverflow;
    if (fb.address > std.math.maxInt(u32)) return error.FramebufferGeometryOverflow;

    const pitch = fb.pixels_per_scan_line * 4;
    const visible_bytes = @as(u64, pitch) * fb.height;
    const lfb_units = (visible_bytes + 0xFFFF) >> 16;
    if (lfb_units > std.math.maxInt(u32)) return error.FramebufferGeometryOverflow;

    params[screen_orig_video_is_vga] = video_type_vlfb;
    writeU16(params, screen_lfb_width, @intCast(fb.width));
    writeU16(params, screen_lfb_height, @intCast(fb.height));
    writeU16(params, screen_lfb_depth, 32);
    writeU32(params, screen_lfb_base, @intCast(fb.address));
    writeU32(params, screen_lfb_size, @intCast(lfb_units));
    writeU16(params, screen_lfb_linelength, @intCast(pitch));
    params[screen_red_size] = 8;
    params[screen_green_size] = 8;
    params[screen_blue_size] = 8;
    params[screen_rsvd_size] = 8;
    params[screen_green_pos] = 8;
    params[screen_rsvd_pos] = 24;
    switch (fb.pixel_format) {
        .bgrx8 => {
            params[screen_red_pos] = 16;
            params[screen_blue_pos] = 0;
        },
        .rgbx8 => {
            params[screen_red_pos] = 0;
            params[screen_blue_pos] = 16;
        },
        .bit_mask => return error.FramebufferGeometryOverflow,
    }
    writeU16(params, screen_pages, 1);
}

pub fn formatGuidDisk(disk: [16]u8, output: []u8) void {
    std.debug.assert(output.len >= 36);
    var index: usize = 0;
    const order = [_]u8{ 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15 };
    for (order, 0..) |source, part_index| {
        if (part_index == 4 or part_index == 6 or part_index == 8 or part_index == 10) {
            output[index] = '-';
            index += 1;
        }
        const value = disk[source];
        output[index] = hex(value >> 4);
        output[index + 1] = hex(value & 0x0F);
        index += 2;
    }
}

fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    writeU16(bytes, offset, @truncate(value));
    writeU16(bytes, offset + 2, @truncate(value >> 16));
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    writeU32(bytes, offset, @truncate(value));
    writeU32(bytes, offset + 4, @truncate(value >> 32));
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, readU16(bytes, offset)) | (@as(u32, readU16(bytes, offset + 2)) << 16);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) | (@as(u64, readU32(bytes, offset + 4)) << 32);
}

test "GPT on-disk GUID becomes canonical PARTUUID" {
    const disk = [_]u8{ 0x75, 0xE1, 0x57, 0x02, 0x85, 0x16, 0x11, 0x43, 0x91, 0xAA, 0x5A, 0x83, 0xD8, 0xEB, 0x41, 0xE5 };
    var out: [36]u8 = undefined;
    formatGuidDisk(disk, &out);
    try std.testing.expectEqualStrings("0257e175-1685-4311-91aa-5a83d8eb41e5", &out);
}

test "standalone boot carries E820 without initrd or USOS command line" {
    var setup = [_]u8{0xff} ** linux_boot_header.minimum_header_bytes;
    setup[0x211] = 1;
    var output: [boot_params_bytes]u8 = undefined;
    const map = [_]e820.Entry{.{ .base = 0x100000, .length = 0x7f00000, .kind = 1, .attributes = 1 }};
    try buildStandalone(&output, &setup, &map, null);
    try std.testing.expectEqual(@as(u32, 0), readU32(&output, setup_cmd_line_ptr_offset));
    try std.testing.expectEqual(@as(u32, 0), readU32(&output, setup_ramdisk_image_offset));
    try std.testing.expectEqual(@as(u32, 0), readU32(&output, setup_ramdisk_size_offset));
    try std.testing.expectEqual(@as(u8, 1), output[e820_entries_offset]);
    try std.testing.expectEqual(@as(u64, 0x7f00000), readU64(&output, e820_table_offset + 8));
    try std.testing.expectEqual(@as(u8, 80), output[7]);
    try std.testing.expectEqual(@as(u8, 25), output[14]);
    try std.testing.expectEqual(@as(u8, 1), output[setup_loadflags_offset]);
}

test "hardware diagnostics request carries no selected disk or installation image" {
    var cmdline: [cmdline_capacity]u8 = undefined;
    const length = try buildCommandLine(&cmdline, [_]u8{0x11} ** 16, .hardware);
    const text = cmdline[0..length];
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=hardware") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "legacy_image") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "bios_disks") == null);
}

test "Live boot uses only the distribution command and exact RAM image" {
    const setup = [_]u8{0} ** linux_boot_header.minimum_header_bytes;
    const map = [_]e820.Entry{.{ .base = 0x100000, .length = 0x7f00000, .kind = 1, .attributes = 1 }};
    var output: [boot_params_bytes]u8 = undefined;
    var command: [cmdline_capacity]u8 = undefined;
    try buildLive(&output, &command, &setup, 0x4000000, 123456, &map, null, "root=/dev/null rw noswap");
    try std.testing.expectEqualStrings("root=/dev/null rw noswap", std.mem.sliceTo(&command, 0));
    try std.testing.expectEqual(@as(u32, 0x4000000), readU32(&output, setup_ramdisk_image_offset));
    try std.testing.expectEqual(@as(u32, 123456), readU32(&output, setup_ramdisk_size_offset));
    try std.testing.expectEqual(@as(u32, cmdline_phys), readU32(&output, setup_cmd_line_ptr_offset));
    try std.testing.expectError(error.InitrdAbove32Bit, buildLive(&output, &command, &setup, 0x100000000, 1, &map, null, "x"));
    try std.testing.expectError(error.CommandLineTooLong, buildLive(&output, &command, &setup, 0, 1, &map, null, &([_]u8{'x'} ** cmdline_capacity)));
}

test "boot params copy setup header and install initrd cmdline E820" {
    var setup: [linux_boot_header.minimum_header_bytes]u8 = [_]u8{0} ** linux_boot_header.minimum_header_bytes;
    setup[0x211] = linux_boot_header.load_flag_loaded_high;
    var params: [boot_params_bytes]u8 = undefined;
    var cmdline: [cmdline_capacity]u8 = undefined;
    const map = [_]e820.Entry{
        .{ .base = 0, .length = 0x9FC00, .kind = 1, .attributes = 1 },
        .{ .base = 0x100000, .length = 0x7EE0000, .kind = 1, .attributes = 1 },
    };
    const disk = [_]u8{ 0x75, 0xE1, 0x57, 0x02, 0x85, 0x16, 0x11, 0x43, 0x91, 0xAA, 0x5A, 0x83, 0xD8, 0xEB, 0x41, 0xE5 };
    const result = try build(&params, &cmdline, &setup, 0x071D3000, 14_730_054, &map, disk, null, .none);
    try std.testing.expectEqual(@as(u8, 0xFF), params[setup_type_loader_offset]);
    try std.testing.expect((params[setup_loadflags_offset] & linux_boot_header.load_flag_loaded_high) != 0);
    try std.testing.expect((params[setup_loadflags_offset] & quiet_flag) != 0);
    try std.testing.expectEqual(@as(u32, 0x071D3000), readU32(&params, setup_ramdisk_image_offset));
    try std.testing.expectEqual(@as(u32, 14_730_054), readU32(&params, setup_ramdisk_size_offset));
    try std.testing.expectEqual(@as(u32, cmdline_phys), readU32(&params, setup_cmd_line_ptr_offset));
    try std.testing.expectEqual(@as(u8, 2), params[e820_entries_offset]);
    try std.testing.expectEqual(@as(u64, 0x100000), readU64(&params, e820_table_offset + e820_entry_bytes));
    try std.testing.expectEqual(@as(u32, 1), readU32(&params, e820_table_offset + e820_entry_bytes + 16));
    try std.testing.expect(result.cmdline_len < cmdline_capacity);
    try std.testing.expect(std.mem.indexOf(u8, cmdline[0..result.cmdline_len], "usos.esp_partuuid=0257e175-1685-4311-91aa-5a83d8eb41e5") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmdline[0..result.cmdline_len], "initrd=") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmdline[0..result.cmdline_len], "fbcon=nodefer") != null);
}

test "XP staging request hex-encodes image and optional WINNT.SIF names" {
    const disk = [_]u8{ 0x75, 0xE1, 0x57, 0x02, 0x85, 0x16, 0x11, 0x43, 0x91, 0xAA, 0x5A, 0x83, 0xD8, 0xEB, 0x41, 0xE5 };
    var cmdline: [cmdline_capacity]u8 = undefined;
    const len = try buildCommandLine(&cmdline, disk, .{ .xp_staging = .{
        .image_name = "XP Test.iso",
        .unattended_name = "safe setup.sif",
        .bios_boot_drive = 0x80,
        .bios_inventory = "80:0000000000100000:512,81:0000000000200000:512",
    } });
    const text = cmdline[0..len];
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=xp-staging") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kexec_load_disabled") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_image_hex=585020546573742e69736f") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_unattended_hex=736166652073657475702e736966") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.bios_boot_drive=80") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.bios_disks=80:0000000000100000:512,81:0000000000200000:512") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "XP Test.iso") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "safe setup.sif") == null);
}

test "XP resume requests no staging or image and retains ESP identity" {
    var output: [cmdline_capacity]u8 = undefined;
    const len = try buildCommandLine(&output, [_]u8{0x11} ** 16, .xp_resume);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "usos.legacy_action=xp-resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "legacy_image_hex") == null);
    try std.testing.expect(std.mem.indexOf(u8, output[0..len], "xp-staging") == null);
    try std.testing.expectEqual(@as(u8, 0), output[len]);
}

test "Windows 2000 request selects its own source identity" {
    var output: [cmdline_capacity]u8 = undefined;
    const len = try buildCommandLine(&output, [_]u8{0x11} ** 16, .{ .windows2000_staging = .{
        .image_name = "2K.iso", .bios_boot_drive = 0x80, .bios_inventory = "",
    } });
    const text = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=windows2000-staging") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_image_hex=324b2e69736f") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=xp-staging") == null);
    try std.testing.expectEqual(@as(u8, 0), output[len]);
}

test "Windows 7 BIOS request preserves source and XML names without XP disk staging" {
    var output: [cmdline_capacity]u8 = undefined;
    const len = try buildCommandLine(&output, [_]u8{0x11} ** 16, .{ .windows7_iso = .{
        .image_name = "Win 7.iso",
        .unattended_name = "My setup.xml",
        .bios_boot_drive = 0x81,
        .bios_inventory = "",
    } });
    const text = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=windows7-iso") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kexec_load_disabled=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_image_hex=57696e20372e69736f") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_unattended_hex=4d792073657475702e786d6c") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.bios_boot_drive=81") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.bios_disks=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "xp-staging") == null);
    try std.testing.expectEqual(@as(u8, 0), output[len]);
}

test "Vista enables direct handoff and preserves the actual BIOS boot drive" {
    var output: [cmdline_capacity]u8 = undefined;
    const len = try buildCommandLine(&output, [_]u8{0x11} ** 16, .{ .windows_vista_iso = .{
        .image_name = "Vista.iso", .unattended_name = null,
        .bios_boot_drive = 0x80, .bios_inventory = "",
    } });
    const text = output[0..len];
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.legacy_action=windows-vista-iso") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kexec_load_disabled=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "usos.bios_boot_drive=80") != null);
}
