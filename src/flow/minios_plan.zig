//! MiniOS instead of the default preparation (profile option
//! prep_env=minios): the pure decisions of src/platform/uefi/minios_start.zig,
//! host-tested.
//!
//! Routes:
//! * `.gpt_uefi`: Windows 10/11 x64 native UEFI (replaces the ISO's WinPE
//!   and Windows Setup);
//! * `.mbr_csmwrap`: 32-bit Windows 10 without CSM (win-x86-uefi-csmwrap;
//!   replaces the Alpine micro-Linux step 610 and the ISO's x86 WinPE +
//!   Setup): MBR disk, BIOS boot files, CSMWrap ESP at the end.
const std = @import("std");
const answer = @import("answer/root.zig");
const capability = @import("preparation_capability.zig");

pub const Route = enum { gpt_uefi, mbr_csmwrap };

pub fn wanted(p: ?*const answer.Profile, system_id: []const u8) bool {
    const profile = p orelse return false;
    if (profile.prep_env != .minios) return false;
    return capability.nativeModernNt(system_id);
}

/// The 32-bit CSMWrap route: Windows 10 only for now (8.1 / Embedded 8.1 and
/// the NT 6.0 / 6.1 PE10-donor route stay on Alpine).
pub fn wantedX86Csmwrap(p: ?*const answer.Profile, system_id: []const u8) bool {
    const profile = p orelse return false;
    return profile.prep_env == .minios and std.mem.eql(u8, system_id, "windows-10");
}

pub const Source = struct { disk_bytes: u64, start: u64, size: u64, serial: u64 };

/// USOSPREP_HW_V1 text, parsed by src/prep/uefi_main.zig config().
pub fn formatConfig(buffer: []u8, route: Route, token: [64]u8, index: u16, source: Source, iso_path: []const u8, build: []const u8, locale: []const u8, unattend: bool) ![]const u8 {
    for (iso_path) |c| if (c == '\r' or c == '\n' or c == 0) return error.InvalidImageName;
    if (index == 0) return error.InvalidImageIndex;
    const mode = if (route == .mbr_csmwrap) "mbr" else "gpt";
    const csmwrap = if (route == .mbr_csmwrap) "csmwrap=on\r\n" else "";
    return std.fmt.bufPrint(buffer, "USOSPREP_HW_V1\r\nmode={s}\r\ntoken={s}\r\nprofile=install\r\nwim_index={d}\r\nsource_bytes={d}\r\nsource_start={d}\r\nsource_size={d}\r\nsource_serial={x}\r\nsource_iso={s}\r\nbuild={s}\r\nlocale={s}\r\nunattend={s}\r\nboot_entry=on\r\n{s}", .{
        mode, token, index, source.disk_bytes, source.start, source.size, source.serial, iso_path, build, locale, if (unattend) "on" else "off", csmwrap,
    });
}

/// The disk chosen in the USOS menu (minios_disk.zig, the flow's one disk
/// question), handed to MiniOS by identity: its device path (body without
/// the End node) and its size. MiniOS asks nothing and refuses a mismatch.
pub const max_disk_path = 256;
pub const Disk = struct {
    path: [max_disk_path]u8 = undefined,
    path_len: usize = 0,
    sectors: u64 = 0,
    pub fn pathBytes(self: *const Disk) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Appends the menu's disk and ui=quiet to a formatConfig text in `buffer`.
pub fn appendDisk(buffer: []u8, config: []const u8, disk: *const Disk) ![]const u8 {
    if (disk.path_len < 4 or disk.path_len > max_disk_path or disk.sectors == 0) return error.InvalidDisk;
    if (config.ptr != buffer.ptr) return error.InvalidArgument;
    var hex: [max_disk_path * 2]u8 = undefined;
    const hex_text = std.fmt.bufPrint(&hex, "{x}", .{disk.pathBytes()}) catch return error.InvalidDisk;
    const tail = try std.fmt.bufPrint(buffer[config.len..], "disk_path={s}\r\ndisk_sectors={d}\r\nui=quiet\r\n", .{ hex_text, disk.sectors });
    return buffer[0 .. config.len + tail.len];
}

/// The bus of a whole-disk device path (the last messaging node), as the
/// MiniOS log names it.
pub fn busName(body: []const u8) []const u8 {
    var name: []const u8 = "disk";
    var offset: usize = 0;
    while (offset + 4 <= body.len) {
        const len = std.mem.readInt(u16, body[offset + 2 ..][0..2], .little);
        if (len < 4 or len > body.len - offset) break;
        if (body[offset] == 0x03) name = switch (body[offset + 1]) {
            0x17 => "NVMe",
            0x12 => "SATA",
            0x05, 0x0f, 0x10 => "USB",
            0x02 => "SCSI",
            0x01 => "ATAPI",
            0x16 => "SAS",
            else => name,
        };
        offset += len;
    }
    return name;
}

pub const DiskInfo = struct { block_size: u32, sectors: u64, read_only: bool, present: bool, bus: []const u8, boot: bool };
pub const mbr_max_sectors: u64 = 0xffffffff;
pub const min_sectors: u64 = 16 * 1024 * 1024 * 1024 / 512;

/// Why the menu does not offer a disk to MiniOS (null: offered); the same
/// rules as MiniOS's own checks (src/prep/uefi_main.zig takeMenuTarget).
pub fn refusal(route: Route, d: DiskInfo, nvme_package: bool) ?[]const u8 {
    if (d.boot) return "the USOS stick";
    if (!d.present or d.read_only) return "not present or read-only";
    if (d.block_size != 512) return "not 512-byte sectors";
    if (d.sectors < min_sectors) return "smaller than 16 GiB";
    if (route == .mbr_csmwrap and d.sectors > mbr_max_sectors) return "larger than 2 TiB (MBR)";
    if (route == .mbr_csmwrap and std.mem.eql(u8, d.bus, "NVMe") and !nvme_package) return "NVMe without the usosnvme package";
    if (std.mem.eql(u8, d.bus, "USB")) return "USB disk";
    return null;
}

test "menu disk handoff: config lines, bus names and the MiniOS rules" {
    var buffer: [2048]u8 = undefined;
    const token: [64]u8 = @splat('a');
    const base = try formatConfig(&buffer, .mbr_csmwrap, token, 4, .{ .disk_bytes = 1 << 40, .start = 1 << 20, .size = 1 << 30, .serial = 7 }, "Systems/Windows/Windows 10/Images/w.iso", "B1", "pl-PL", true);
    var disk: Disk = .{ .sectors = 1000215216 };
    const nvme = [_]u8{ 2, 1, 12, 0, 0xd0, 0x41, 3, 0x0a, 0, 0, 0, 0, 1, 1, 6, 0, 0, 1, 3, 0x17, 16, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    @memcpy(disk.path[0..nvme.len], &nvme);
    disk.path_len = nvme.len;
    const text = try appendDisk(&buffer, base, &disk);
    try std.testing.expect(std.mem.endsWith(u8, text, "csmwrap=on\r\ndisk_path=02010c00d041030a0000000001010600000103171000010000000000000000000000\r\ndisk_sectors=1000215216\r\nui=quiet\r\n"));
    try std.testing.expectEqualStrings("NVMe", busName(&nvme));
    try std.testing.expectEqualStrings("disk", busName(nvme[0..12]));
    const ok: DiskInfo = .{ .block_size = 512, .sectors = 1000215216, .read_only = false, .present = true, .bus = "NVMe", .boot = false };
    try std.testing.expect(refusal(.mbr_csmwrap, ok, true) == null);
    try std.testing.expect(refusal(.mbr_csmwrap, ok, false) != null);
    try std.testing.expect(refusal(.gpt_uefi, ok, false) == null);
    var big = ok;
    big.sectors = mbr_max_sectors + 1;
    big.bus = "SATA";
    try std.testing.expect(refusal(.mbr_csmwrap, big, true) != null and refusal(.gpt_uefi, big, true) == null);
    var stick = ok;
    stick.boot = true;
    try std.testing.expect(refusal(.gpt_uefi, stick, true) != null);
    var four_k = ok;
    four_k.block_size = 4096;
    try std.testing.expect(refusal(.gpt_uefi, four_k, true) != null);
    var empty: Disk = .{};
    try std.testing.expectError(error.InvalidDisk, appendDisk(&buffer, base, &empty));
}

/// The install image MiniOS applies: the profile's edition on this ISO
/// (MiniOS has no edition list of its own).
pub fn imageIndex(p: *const answer.Profile, system_id: []const u8, images: ?*const answer.editions.List) ?u16 {
    return switch (answer.matchEdition(p, system_id, images)) {
        .found => |image| image.index,
        else => null,
    };
}

pub fn localeTag(p: *const answer.Profile) []const u8 {
    const index = p.language orelse return "en-US";
    if (index >= answer.tables.languages.len) return "en-US";
    return answer.tables.languages[index].tag;
}

test "MiniOS config matches the MiniOS hardware parser keys" {
    var buffer: [1024]u8 = undefined;
    const token: [64]u8 = @splat('a');
    const text = try formatConfig(&buffer, .gpt_uefi, token, 6, .{ .disk_bytes = 128043712512, .start = 17179869184, .size = 110863843328, .serial = 0x12345678abcdef01 }, "Systems/Windows/Windows 11/Images/Win11.iso", "B261028-200000-ABCDEF01", "pl-PL", true);
    try std.testing.expect(std.mem.startsWith(u8, text, "USOSPREP_HW_V1\r\nmode=gpt\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "wim_index=6\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "source_serial=12345678abcdef01\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unattend=on\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "target_sectors") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "csmwrap") == null);
    const mbr = try formatConfig(&buffer, .mbr_csmwrap, token, 2, .{ .disk_bytes = 1 << 40, .start = 1 << 20, .size = 1 << 30, .serial = 7 }, "Systems/Windows/Windows 10/Images/Win10 x86.iso", "B1", "pl-PL", true);
    try std.testing.expect(std.mem.startsWith(u8, mbr, "USOSPREP_HW_V1\r\nmode=mbr\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, mbr, "boot_entry=on\r\ncsmwrap=on\r\n"));
    try std.testing.expectError(error.InvalidImageName, formatConfig(&buffer, .gpt_uefi, token, 6, .{ .disk_bytes = 1, .start = 1, .size = 1, .serial = 1 }, "a\r\nmode=mbr", "B", "en-US", false));
    try std.testing.expectError(error.InvalidImageIndex, formatConfig(&buffer, .gpt_uefi, token, 0, .{ .disk_bytes = 1, .start = 1, .size = 1, .serial = 1 }, "a.iso", "B", "en-US", false));
}

test "only Windows 10/11 profiles with prep_env=minios select MiniOS" {
    var p = answer.Profile{};
    try std.testing.expect(!wanted(&p, "windows-11"));
    try std.testing.expect(!wantedX86Csmwrap(&p, "windows-10"));
    p.prep_env = .minios;
    try std.testing.expect(wanted(&p, "windows-11") and wanted(&p, "windows-10"));
    try std.testing.expect(!wanted(&p, "windows-7") and !wanted(&p, "windows-xp"));
    try std.testing.expect(!wanted(null, "windows-11"));
    // 32-bit CSMWrap route: Windows 10 only.
    try std.testing.expect(wantedX86Csmwrap(&p, "windows-10"));
    try std.testing.expect(!wantedX86Csmwrap(&p, "windows-8-1") and !wantedX86Csmwrap(&p, "windows-7") and !wantedX86Csmwrap(null, "windows-10"));
    try std.testing.expectEqualStrings("en-US", localeTag(&p));
    // No edition in the profile and more than one image: no index (Setup).
    try std.testing.expect(imageIndex(&p, "windows-11", null) == null);
}
