const std = @import("std");
const e820 = @import("e820.zig");
const linux_boot_header = @import("linux_boot_header.zig");

pub const kernel_load_start: u64 = 0x00100000;
pub const initrd_alignment: u64 = 4096;

pub const Error = error{
    KernelFileTooSmall,
    ArithmeticOverflow,
    InvalidKernelAlignment,
    KernelLoadNotUsable,
    RuntimeWindowNotUsable,
    InitrdNoSpace,
};

pub const Range = struct {
    start: u64,
    end: u64,

    pub fn size(self: Range) u64 {
        return self.end - self.start;
    }

    pub fn overlaps(self: Range, other: Range) bool {
        return self.start < other.end and other.start < self.end;
    }
};

pub const Layout = struct {
    kernel_file_size: u64,
    kernel_protected: Range,
    kernel_runtime: Range,
    initramfs: Range,
};

pub fn plan(entries: []const e820.Entry, header: linux_boot_header.Header, kernel_file_size: u64, initramfs_size: u64) Error!Layout {
    if (kernel_file_size <= header.protected_file_offset) return error.KernelFileTooSmall;

    const protected_size = kernel_file_size - header.protected_file_offset;
    const protected_end = add(kernel_load_start, protected_size) orelse return error.ArithmeticOverflow;
    const protected = Range{ .start = kernel_load_start, .end = protected_end };
    if (!rangeIsUsable(entries, protected)) return error.KernelLoadNotUsable;

    const runtime_start = try runtimeStart(header);
    const runtime_end = add(runtime_start, header.init_size) orelse return error.ArithmeticOverflow;
    const runtime = Range{ .start = runtime_start, .end = runtime_end };
    if (!rangeIsUsable(entries, runtime)) return error.RuntimeWindowNotUsable;

    const initramfs = try allocateInitrd(entries, initramfs_size, header.initrd_addr_max, &.{ protected, runtime });
    return .{
        .kernel_file_size = kernel_file_size,
        .kernel_protected = protected,
        .kernel_runtime = runtime,
        .initramfs = initramfs,
    };
}

fn runtimeStart(header: linux_boot_header.Header) Error!u64 {
    if (!header.relocatable_kernel) return header.pref_address;
    const alignment = header.kernel_alignment;
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidKernelAlignment;
    const base = @max(kernel_load_start, header.pref_address);
    return alignUp(base, alignment) orelse error.ArithmeticOverflow;
}

fn allocateInitrd(entries: []const e820.Entry, size: u64, addr_max: u32, reserved: []const Range) Error!Range {
    if (size == 0) return error.InitrdNoSpace;
    const max_exclusive = @as(u64, addr_max) + 1;
    var best: ?Range = null;

    for (entries) |entry| {
        if (!entry.isUsable()) continue;
        const entry_end = entry.end() orelse continue;
        var ceiling = @min(entry_end, max_exclusive);
        if (ceiling <= entry.base or ceiling - entry.base < size) continue;

        var attempts: usize = 0;
        while (attempts <= reserved.len) : (attempts += 1) {
            if (ceiling < size) break;
            const raw_start = ceiling - size;
            const start = alignDown(raw_start, initrd_alignment);
            const end = add(start, size) orelse break;
            if (start < entry.base or end > ceiling) break;
            const candidate = Range{ .start = start, .end = end };

            var conflict: ?Range = null;
            for (reserved) |used| {
                if (!candidate.overlaps(used)) continue;
                if (conflict == null or used.start < conflict.?.start) conflict = used;
            }
            if (conflict) |used| {
                if (used.start <= entry.base) break;
                ceiling = @min(ceiling, used.start);
                continue;
            }

            if (best == null or candidate.start > best.?.start) best = candidate;
            break;
        }
    }

    return best orelse error.InitrdNoSpace;
}

pub fn rangeIsUsable(entries: []const e820.Entry, range: Range) bool {
    if (range.end <= range.start) return false;
    for (entries) |entry| {
        if (!entry.isUsable()) continue;
        const end = entry.end() orelse continue;
        if (entry.base <= range.start and range.end <= end) return true;
    }
    return false;
}

fn add(a: u64, b: u64) ?u64 {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

fn alignUp(value: u64, alignment: u64) ?u64 {
    const mask = alignment - 1;
    const expanded = add(value, mask) orelse return null;
    return expanded & ~mask;
}

fn alignDown(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

fn pinnedHeader() linux_boot_header.Header {
    return .{
        .setup_sects_raw = 31,
        .setup_sects = 31,
        .protected_file_offset = 0x4000,
        .syssize_paragraphs = 0,
        .vid_mode = 0xFFFF,
        .boot_flag = linux_boot_header.boot_flag_magic,
        .protocol = 0x020F,
        .kernel_version_offset = 0,
        .type_of_loader = 0,
        .loadflags = linux_boot_header.load_flag_loaded_high,
        .code32_start = 0x00100000,
        .ramdisk_image = 0,
        .ramdisk_size = 0,
        .heap_end_ptr = 0,
        .cmd_line_ptr = 0,
        .initrd_addr_max = 0x7FFFFFFF,
        .kernel_alignment = 0x01000000,
        .relocatable_kernel = true,
        .min_alignment = 21,
        .xloadflags = 0x007B,
        .cmdline_size = 2047,
        .hardware_subarch = 0,
        .payload_offset = 0,
        .payload_length = 0,
        .setup_data = 0,
        .pref_address = 0x01000000,
        .init_size = 39_862_272,
        .handover_offset = 0,
        .kernel_info_offset = 0x00BF81C0,
    };
}

test "pinned kernel layout fits with 128 MiB usable RAM" {
    const entries = [_]e820.Entry{
        .{ .base = 0x00000000, .length = 0x0009FC00, .kind = 1, .attributes = 1 },
        .{ .base = 0x00100000, .length = 0x07F00000, .kind = 1, .attributes = 1 },
    };
    const layout = try plan(&entries, pinnedHeader(), 12_575_744, 14_730_054);
    try std.testing.expectEqual(@as(u64, 0x00100000), layout.kernel_protected.start);
    try std.testing.expectEqual(@as(u64, 0x01000000), layout.kernel_runtime.start);
    try std.testing.expectEqual(@as(u64, 0x03604000), layout.kernel_runtime.end);
    try std.testing.expect(layout.initramfs.start >= layout.kernel_runtime.end);
    try std.testing.expectEqual(@as(u64, 14_730_054), layout.initramfs.size());
    try std.testing.expectEqual(@as(u64, 0), layout.initramfs.start & 0xFFF);
}

test "64 MiB map fails closed because pinned kernel runtime plus initramfs do not fit" {
    const entries = [_]e820.Entry{
        .{ .base = 0x00000000, .length = 0x0009FC00, .kind = 1, .attributes = 1 },
        .{ .base = 0x00100000, .length = 0x03F00000, .kind = 1, .attributes = 1 },
    };
    try std.testing.expectError(error.InitrdNoSpace, plan(&entries, pinnedHeader(), 12_575_744, 14_730_054));
}
