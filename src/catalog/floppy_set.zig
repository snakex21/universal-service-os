//! Floppy disk sets as installation media (2026-10-23): a folder inside a
//! system's DATA Images folder that holds diskette images (disk01.img ...
//! disk10.img, any names) is listed as ONE media entry named after the
//! folder (ImageKind.floppy_set). The micro-Linux step merges the diskettes
//! (tools/floppy_set.sh: the same extensions and sizes, natural disk order).
//! Windows 1.0x-3.x / WfW take it (os_profiles floppy_set_ids); other systems
//! show the entry as an unsupported format.
const std = @import("std");
const builtin = @import("builtin");

/// The freestanding BIOS Core neither lists nor starts floppy sets (Core size
/// budget; its Windows 3.x path reads an ISO): UEFI and host builds only.
pub const enabled = builtin.os.tag != .freestanding;

/// At most this many diskettes are counted (the menu shows the number).
pub const max_disks: u8 = 99;

/// Diskette image extensions (case ignored).
pub const extensions = [_][]const u8{ ".img", ".ima", ".vfd", ".flp" };

/// Diskette sizes in bytes: 160/180/320/360 KiB (5.25"), 720 KiB, 1.2 MiB,
/// 1.44 MiB and 2.88 MiB.
pub const sizes = [_]u32{ 163840, 184320, 327680, 368640, 737280, 1228800, 1474560, 2949120 };

pub fn hasImageExtension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    for (extensions) |extension| {
        if (std.ascii.eqlIgnoreCase(name[dot..], extension)) return true;
    }
    return false;
}

pub fn isDisketteSize(size: u32) bool {
    return std.mem.indexOfScalar(u32, &sizes, size) != null;
}

/// One directory entry of the folder: a diskette image? `size == 0` counts
/// too: an NTFS directory index may hold a stale size of 0 for a file that
/// was just copied; the micro-Linux step checks the real size again.
pub fn isDisketteImage(name: []const u8, size: u32) bool {
    return hasImageExtension(name) and (size == 0 or isDisketteSize(size));
}

/// The folder name as a DATA path below `directory` ("\Systems\...\Images").
pub fn childPath(buffer: []u8, directory: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ directory, name }) catch null;
}

test "diskette images: extensions and sizes" {
    try std.testing.expect(isDisketteImage("disk01.img", 1474560));
    try std.testing.expect(isDisketteImage("DISK_1.IMA", 737280));
    try std.testing.expect(isDisketteImage("Disk 1 of 10.vfd", 368640));
    try std.testing.expect(isDisketteImage("a.FLP", 2949120));
    try std.testing.expect(isDisketteImage("disk2.img", 0));
    try std.testing.expect(isDisketteImage("d.img", 163840));
    try std.testing.expect(isDisketteImage("d.img", 184320));
    try std.testing.expect(isDisketteImage("d.img", 327680));
    try std.testing.expect(isDisketteImage("d.img", 1228800));
    // A hard-disk image (FreeDOS FullUSB.img) and other files are not.
    try std.testing.expect(!isDisketteImage("FullUSB.img", 536870912));
    try std.testing.expect(!isDisketteImage("disk1.iso", 1474560));
    try std.testing.expect(!isDisketteImage("readme.txt", 1474560));
    try std.testing.expect(!isDisketteImage("img", 1474560));
    try std.testing.expect(!isDisketteImage("disk.img", 1474561));
}

test "child path joins the folder below Images" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\\Systems\\Windows\\WfW\\Images\\WfW 3.11 PL", childPath(&buffer, "\\Systems\\Windows\\WfW\\Images", "WfW 3.11 PL").?);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(childPath(&tiny, "\\Systems\\Windows", "x") == null);
}
