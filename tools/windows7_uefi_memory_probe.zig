// Read-only hardware snapshot. Never unlock, clear or change legacy memory/MSRs.
const std = @import("std");
const uefi = std.os.uefi;
const trace = @import("windows7_uefi_trace.zig");
pub const Cpu = struct { a: u32, b: u32, c: u32, d: u32 };
pub fn cpuid(leaf: u32) Cpu {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (@as(u32, 0)),
    );
    return .{ .a = a, .b = b, .c = c, .d = d };
}
pub fn rdmsr(index: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [index] "{ecx}" (index),
    );
    return (@as(u64, hi) << 32) | lo;
}
pub fn amdSyscfgSupported(vendor: Cpu, features: Cpu) bool {
    const family = ((features.a >> 8) & 15) + ((features.a >> 20) & 255);
    return vendor.b == 0x68747541 and vendor.d == 0x69746e65 and vendor.c == 0x444d4163 and
        (features.c & (@as(u32, 1) << 31)) == 0 and (family == 0x17 or family == 0x19) and
        (features.d & (1 << 5)) != 0;
}
pub const LegacyRegion = opaque {
    pub const guid = uefi.Guid{ .time_low = 0x0fc9013a, .time_mid = 0x0568, .time_high_and_version = 0x4ba9, .clock_seq_high_and_reserved = 0x9b, .clock_seq_low = 0x7e, .node = .{ 0xc9, 0xc3, 0x90, 0xa6, 0x60, 0x9b } };
};
pub const LegacyRegion2 = opaque {
    pub const guid = uefi.Guid{ .time_low = 0x70101eaf, .time_mid = 0x0085, .time_high_and_version = 0x440c, .clock_seq_high_and_reserved = 0xb3, .clock_seq_low = 0x56, .node = .{ 0x8e, 0xe3, 0x6f, 0xef, 0x24, 0xf0 } };
};
var map_buffer: [65536]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
pub fn record(device: uefi.Handle, directory: []const u16) void {
    const bs = uefi.system_table.boot_services orelse return;
    const vendor = cpuid(0);
    if (vendor.a < 1) return;
    const features = cpuid(1);
    const has_mtrr = (features.d & ((1 << 5) | (1 << 12))) == ((1 << 5) | (1 << 12)) and (features.c & (1 << 31)) == 0;
    const cap = if (has_mtrr) rdmsr(0xfe) else 0;
    const def = if (has_mtrr) rdmsr(0x2ff) else 0;
    const fixed = has_mtrr and (cap & (1 << 8)) != 0;
    const c0 = if (fixed) rdmsr(0x268) else 0;
    const c8 = if (fixed) rdmsr(0x269) else 0;
    const syscfg_read = amdSyscfgSupported(vendor, features);
    const syscfg = if (syscfg_read) rdmsr(0xc0010010) else 0;
    const lr = (bs.locateProtocol(LegacyRegion, null) catch null) != null;
    const lr2 = (bs.locateProtocol(LegacyRegion2, null) catch null) != null;
    const gop = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null;
    var region_type: u32 = 0xffffffff;
    var attributes: u64 = 0;
    if (bs.getMemoryMap(&map_buffer)) |map| {
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            if (entry.physical_start <= 0xc0000 and (0xc0000 - entry.physical_start) / 4096 < entry.number_of_pages) {
                region_type = @intFromEnum(entry.type);
                attributes = @bitCast(entry.attribute);
                break;
            }
        }
    } else |_| {}
    const ivt = @as(*volatile u32, @ptrFromInt(0x40)).*;
    var first: [16]u8 = undefined;
    for (&first, 0..) |*byte, i| byte.* = @as(*volatile u8, @ptrFromInt(0xc0000 + i)).*;
    var text: [1900]u8 = undefined;
    const message = std.fmt.bufPrint(
        &text,
        "USOS legacy memory diagnostic v1 (before UefiSeven; no memory/MSR writes)\r\n" ++
            "CPUID.1 EAX={x:0>8} ECX={x:0>8} EDX={x:0>8}\r\n" ++
            "LegacyRegion={} LegacyRegion2={} INT10={x:0>8}\r\n" ++
            "C0000 first16={x}\r\nC0000 memory_type={x} attributes={x:0>16}\r\n" ++
            "MTRR_read={} CAP={x:0>16} DEF={x:0>16}\r\n" ++
            "FIXED_read={} C0000_MSR268={x:0>16} C8000_MSR269={x:0>16}\r\n" ++
            "AMD_SYS_CFG_read={} SYS_CFG={x:0>16}\r\n" ++
            "NOTE: AMD RdDram/WrDram bits may be masked when MtrrFixDramModEn=0.\r\n" ++
            "GOP_present={} framebuffer={x:0>16} size={x}\r\n",
        .{ features.a, features.c, features.d, lr, lr2, ivt, first, region_type, attributes, has_mtrr, cap, def, fixed, c0, c8, syscfg_read, syscfg, gop != null, if (gop) |g| g.mode.frame_buffer_base else 0, if (gop) |g| g.mode.frame_buffer_size else 0 },
    ) catch return;
    trace.recordNamed(device, directory, std.unicode.utf8ToUtf16LeStringLiteral("usos-memory.log"), message);
}
test "AMD SYS_CFG read is gated to supported bare-metal AMD families" {
    const amd = Cpu{ .a = 1, .b = 0x68747541, .d = 0x69746e65, .c = 0x444d4163 };
    var features = Cpu{ .a = 0x00a20f12, .b = 0, .c = 0, .d = 1 << 5 };
    try std.testing.expect(amdSyscfgSupported(amd, features));
    features.c = 1 << 31;
    try std.testing.expect(!amdSyscfgSupported(amd, features));
    features.c = 0;
    features.a = 0x00000600;
    try std.testing.expect(!amdSyscfgSupported(amd, features));
    features.a = 0x00a20f12;
    features.d = 0;
    try std.testing.expect(!amdSyscfgSupported(amd, features));
    features.d = 1 << 5;
    try std.testing.expect(!amdSyscfgSupported(.{ .a = 1, .b = 0x756e6547, .c = 0x6c65746e, .d = 0x49656e69 }, features));
}
