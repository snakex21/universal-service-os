//! Firmware entropy policy and guarded x86 capabilities. No time/marker fallback.
//! Public UEFI EFI_RNG_PROTOCOL, Intel SDM CPUID/RDRAND/RDSEED, QEMU fw_cfg.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const builtin = @import("builtin");
const fw = @import("fw_cfg.zig");
pub const Source = enum { efi_rng, rdseed, rdrand, fw_cfg_host_csprng };
pub const Result = struct { bytes: [64]u8, source: Source };
pub const Providers = struct {
    context: *anyopaque,
    efi_rng: ?*const fn (*anyopaque, *[64]u8) bool = null,
    rdseed: ?*const fn (*anyopaque, *[64]u8) bool = null,
    rdrand: ?*const fn (*anyopaque, *[64]u8) bool = null,
    fw_cfg: ?*const fn (*anyopaque, *[64]u8) bool = null,
    qemu_detected: bool,
};
// A failure detector, not an entropy estimate: some broken RNGs report success
// while returning constants (including AMD's repeated 32-bit RDRAND value).
// Apply the same policy to every provider, including firmware and fw_cfg.
pub fn healthy(bytes: *const [64]u8) bool {
    if (std.mem.allEqual(u8, bytes, 0) or std.mem.allEqual(u8, bytes, 0xff)) return false;
    for (0..16) |i| {
        const word = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        for (0..i) |j| {
            if (word == std.mem.readInt(u32, bytes[j * 4 ..][0..4], .little)) return false;
        }
    }
    return true;
}
pub fn collect(providers: Providers) error{EntropyUnavailable}!Result {
    const functions = .{ providers.efi_rng, providers.rdseed, providers.rdrand, if (providers.qemu_detected) providers.fw_cfg else null };
    inline for (functions, .{ Source.efi_rng, Source.rdseed, Source.rdrand, Source.fw_cfg_host_csprng }) |function, source| {
        if (function) |read| {
            var bytes: [64]u8 = undefined;
            if (read(providers.context, &bytes) and healthy(&bytes)) return .{ .bytes = bytes, .source = source };
        }
    }
    return error.EntropyUnavailable;
}

pub fn hasCpuid() bool {
    if (comptime builtin.cpu.arch == .x86_64) return true;
    return asm volatile (
        \\pushfl
        \\popl %%eax
        \\movl %%eax, %%ecx
        \\xorl $0x200000, %%eax
        \\pushl %%eax
        \\popfl
        \\pushfl
        \\popl %%eax
        \\pushl %%ecx
        \\popfl
        \\xorl %%ecx, %%eax
        : [changed] "={eax}" (-> u32),
        :
        : .{ .ecx = true, .cc = true, .memory = true }) & 0x200000 != 0;
}
const Cpuid = struct { a: u32, b: u32, c: u32, d: u32 };
fn cpuid(leaf: u32, subleaf: u32) Cpuid {
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
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .a = a, .b = b, .c = c, .d = d };
}
pub fn qemuCpu() bool {
    if (!hasCpuid()) return false;
    const signature = cpuid(0x40000000, 0);
    return signature.b == 0x54474354 and signature.c == 0x43544743 and signature.d == 0x47435447;
}
pub fn cpuRandom(comptime seed: bool, output: *[64]u8) bool {
    if (!hasCpuid()) return false;
    const maximum = cpuid(0, 0).a;
    if (seed) {
        if (maximum < 7 or cpuid(7, 0).b & (1 << 18) == 0) return false;
    } else if (maximum < 1 or cpuid(1, 0).c & (1 << 30) == 0) return false;
    for (0..16) |i| {
        var success: u8 = 0;
        var value: u32 = 0;
        for (0..128) |_| {
            // Encoding EAX avoids requiring an unconditional post-i486 target.
            asm volatile (if (seed) ".byte 0x0f,0xc7,0xf8; setc %[success]" else ".byte 0x0f,0xc7,0xf0; setc %[success]"
                : [value] "={eax}" (value),
                  [success] "={cl}" (success),
                :
                : .{ .cc = true });
            if (success != 0) break;
        }
        if (success == 0) return false;
        std.mem.writeInt(u32, output[i * 4 ..][0..4], value, .little);
    }
    return true;
}
pub fn rdrand(_: *anyopaque, output: *[64]u8) bool {
    return cpuRandom(false, output);
}
pub fn rdseed(_: *anyopaque, output: *[64]u8) bool {
    return cpuRandom(true, output);
}
pub fn qemuEntropy(_: *anyopaque, output: *[64]u8) bool {
    // This callback is reachable only through collect's positive QEMU gate.
    output.* = fw.firmwareEntropy(true) catch return false;
    return true;
}

fn checksum(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |value| sum +%= value;
    return sum == 0;
}
pub const Smbios = struct { address: u64, length: usize };
pub fn smbiosEntry(bytes: []const u8) ?Smbios {
    if (bytes.len < 24) return null;
    if (std.mem.eql(u8, bytes[0..4], "_SM_")) {
        if (bytes.len < 0x1f) return null;
        const length = bytes[5];
        if (length < 0x1f or length > bytes.len or !checksum(bytes[0..length]) or !std.mem.eql(u8, bytes[16..21], "_DMI_") or !checksum(bytes[16..31])) return null;
        return .{ .address = std.mem.readInt(u32, bytes[24..28], .little), .length = std.mem.readInt(u16, bytes[22..24], .little) };
    }
    if (std.mem.eql(u8, bytes[0..5], "_SM3_")) {
        const length = bytes[6];
        if (length < 24 or length > bytes.len or !checksum(bytes[0..length])) return null;
        return .{ .address = std.mem.readInt(u64, bytes[16..24], .little), .length = std.mem.readInt(u32, bytes[12..16], .little) };
    }
    return null;
}
fn stringAt(strings: []const u8, number: u8) []const u8 {
    if (number == 0) return "";
    var cursor: usize = 0;
    var i: usize = 1;
    while (cursor < strings.len) : (i += 1) {
        const end = std.mem.indexOfScalarPos(u8, strings, cursor, 0) orelse return "";
        if (i == number) return strings[cursor..end];
        cursor = end + 1;
    }
    return "";
}
pub fn qemuSmbios(table: []const u8) bool {
    var cursor: usize = 0;
    while (cursor + 4 <= table.len) {
        const length = table[cursor + 1];
        if (length < 4 or cursor + length > table.len) return false;
        const strings = cursor + length;
        var end = strings;
        while (end + 1 < table.len and !(table[end] == 0 and table[end + 1] == 0)) : (end += 1) {}
        if (end + 1 >= table.len) return false;
        if (table[cursor] == 1 and length >= 8) {
            const vendor = stringAt(table[strings .. end + 1], table[cursor + 4]);
            const product = stringAt(table[strings .. end + 1], table[cursor + 5]);
            return std.mem.eql(u8, vendor, "QEMU") and (std.mem.startsWith(u8, product, "Standard PC") or std.mem.startsWith(u8, product, "QEMU"));
        }
        if (table[cursor] == 127) break;
        cursor = end + 2;
    }
    return false;
}
fn biosSmbiosRange(location: Smbios) bool {
    if (location.address < 0x1000 or location.address >= 0x100000 or location.length == 0 or location.length > 65536) return false;
    return location.length <= 0x100000 - location.address;
}
pub fn qemuBios() bool {
    if (qemuCpu()) return true;
    var address: usize = 0xf0000;
    while (address + 32 <= 0x100000) : (address += 16) {
        const bytes: [*]const u8 = @ptrFromInt(address);
        const location = smbiosEntry(bytes[0..32]) orelse continue;
        if (!biosSmbiosRange(location)) continue;
        const table: [*]const u8 = @ptrFromInt(@as(usize, @intCast(location.address)));
        if (qemuSmbios(table[0..location.length])) return true;
    }
    return false;
}

// Diverse deterministic test data only; never used as a production fallback.
fn fakeEntropy(out: *[64]u8) void {
    var state: u32 = 0x6d253f91;
    for (0..16) |i| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        std.mem.writeInt(u32, out[i * 4 ..][0..4], state, .little);
    }
}

test "entropy refuses unknown fw_cfg before calling its provider and prioritizes firmware RNG" {
    const Fake = struct {
        calls: u32 = 0,
        fn read(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            fakeEntropy(out);
            return true;
        }
    };
    var fake: Fake = .{};
    try std.testing.expectError(error.EntropyUnavailable, collect(.{ .context = &fake, .fw_cfg = Fake.read, .qemu_detected = false }));
    try std.testing.expectEqual(@as(u32, 0), fake.calls);
    const fw_result = try collect(.{ .context = &fake, .fw_cfg = Fake.read, .qemu_detected = true });
    try std.testing.expectEqual(Source.fw_cfg_host_csprng, fw_result.source);
    const result = try collect(.{ .context = &fake, .efi_rng = Fake.read, .rdrand = Fake.read, .fw_cfg = Fake.read, .qemu_detected = true });
    try std.testing.expectEqual(Source.efi_rng, result.source);
    try std.testing.expectEqual(@as(u32, 2), fake.calls);
}
test "QEMU SMBIOS requires a valid structure and manufacturer/product pair" {
    var table = [_]u8{ 1, 8, 0, 0, 1, 2, 0, 0 } ++ "QEMU\x00Standard PC (Q35)\x00\x00".*;
    try std.testing.expect(qemuSmbios(&table));
    table[8] = 'X';
    try std.testing.expect(!qemuSmbios(&table));
    try std.testing.expect(!qemuSmbios("unstructured QEMU Standard PC"));
}
test "hardware RNG executes only behind actual host CPUID support" {
    var bytes: [64]u8 = undefined;
    if (cpuRandom(false, &bytes)) try std.testing.expect(!std.mem.allEqual(u8, &bytes, 0));
    if (cpuRandom(true, &bytes)) try std.testing.expect(!std.mem.allEqual(u8, &bytes, 0));
    try std.testing.expectError(error.EntropyUnavailable, fw.firmwareEntropy(false));
}
test "failed or zero-filled firmware RNG falls through without reaching unknown IO" {
    const Fake = struct {
        calls: usize = 0,
        fn zero(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            @memset(out, 0);
            return true;
        }
        fn seed(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            fakeEntropy(out);
            return true;
        }
    };
    var fake: Fake = .{};
    const result = try collect(.{ .context = &fake, .efi_rng = Fake.zero, .rdseed = Fake.seed, .fw_cfg = Fake.zero, .qemu_detected = false });
    try std.testing.expectEqual(Source.rdseed, result.source);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "all entropy providers reject constants and repeated 32-bit words then fall back" {
    const Fake = struct {
        bad: [64]u8,
        bad_calls: usize = 0,
        good_calls: usize = 0,
        fn invalid(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.bad_calls += 1;
            out.* = self.bad;
            return true;
        }
        fn good(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.good_calls += 1;
            fakeEntropy(out);
            return true;
        }
    };
    var repeated: [64]u8 = undefined;
    for (0..16) |i| std.mem.writeInt(u32, repeated[i * 4 ..][0..4], 0xdeadbeef, .little);
    var separated: [64]u8 = undefined;
    fakeEntropy(&separated);
    @memcpy(separated[60..64], separated[0..4]);
    for ([_][64]u8{ @splat(0), @splat(0xff), repeated, separated }) |bad| {
        // Each source is independently denied; a bad final provider fails closed.
        inline for (.{ Source.efi_rng, Source.rdseed, Source.rdrand, Source.fw_cfg_host_csprng }) |source| {
            var fake: Fake = .{ .bad = bad };
            var providers: Providers = .{ .context = &fake, .qemu_detected = true };
            switch (source) {
                .efi_rng => providers.efi_rng = Fake.invalid,
                .rdseed => providers.rdseed = Fake.invalid,
                .rdrand => providers.rdrand = Fake.invalid,
                .fw_cfg_host_csprng => providers.fw_cfg = Fake.invalid,
            }
            try std.testing.expectError(error.EntropyUnavailable, collect(providers));
            try std.testing.expectEqual(@as(usize, 1), fake.bad_calls);
        }
        // Every transition in the ordered chain falls through to a healthy source.
        inline for (.{ Source.efi_rng, Source.rdseed, Source.rdrand }) |source| {
            var fake: Fake = .{ .bad = bad };
            var providers: Providers = .{ .context = &fake, .qemu_detected = true };
            const expected: Source = switch (source) {
                .efi_rng => blk: {
                    providers.efi_rng = Fake.invalid;
                    providers.rdseed = Fake.good;
                    break :blk .rdseed;
                },
                .rdseed => blk: {
                    providers.rdseed = Fake.invalid;
                    providers.rdrand = Fake.good;
                    break :blk .rdrand;
                },
                .rdrand => blk: {
                    providers.rdrand = Fake.invalid;
                    providers.fw_cfg = Fake.good;
                    break :blk .fw_cfg_host_csprng;
                },
                .fw_cfg_host_csprng => unreachable,
            };
            const result = try collect(providers);
            try std.testing.expectEqual(expected, result.source);
            var good: [64]u8 = undefined;
            fakeEntropy(&good);
            try std.testing.expectEqualSlices(u8, &good, &result.bytes);
            try std.testing.expectEqual(@as(usize, 1), fake.bad_calls);
            try std.testing.expectEqual(@as(usize, 1), fake.good_calls);
        }
    }
}

test "a failed provider cannot contribute bytes or prevent the remaining chain" {
    const Fake = struct {
        calls: usize = 0,
        fn failed(ctx: *anyopaque, out: *[64]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            fakeEntropy(out);
            return false;
        }
        fn good(_: *anyopaque, out: *[64]u8) bool {
            fakeEntropy(out);
            return true;
        }
    };
    var fake: Fake = .{};
    const result = try collect(.{ .context = &fake, .efi_rng = Fake.failed, .rdseed = Fake.failed, .rdrand = Fake.failed, .fw_cfg = Fake.good, .qemu_detected = true });
    try std.testing.expectEqual(Source.fw_cfg_host_csprng, result.source);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}
test "SMBIOS entry point validates both checksums before accepting physical address" {
    var entry: [32]u8 = @splat(0);
    @memcpy(entry[0..4], "_SM_");
    entry[5] = 31;
    @memcpy(entry[16..21], "_DMI_");
    std.mem.writeInt(u16, entry[22..24], 128, .little);
    std.mem.writeInt(u32, entry[24..28], 0xf1000, .little);
    var sum: u8 = 0;
    for (entry[16..31]) |b| sum +%= b;
    entry[21] -%= sum;
    sum = 0;
    for (entry[0..31]) |b| sum +%= b;
    entry[4] -%= sum;
    const located = smbiosEntry(&entry).?;
    try std.testing.expectEqual(@as(u64, 0xf1000), located.address);
    entry[24] ^= 1;
    try std.testing.expect(smbiosEntry(&entry) == null);
}
test "BIOS SMBIOS physical range rejects overflowing or out-of-ROM tables" {
    try std.testing.expect(biosSmbiosRange(.{ .address = 0xf0000, .length = 65536 }));
    try std.testing.expect(!biosSmbiosRange(.{ .address = 0xf0001, .length = 65536 }));
    try std.testing.expect(!biosSmbiosRange(.{ .address = 0x100000, .length = 1 }));
    try std.testing.expect(!biosSmbiosRange(.{ .address = std.math.maxInt(u64) - 31, .length = 64 }));
    try std.testing.expect(!biosSmbiosRange(.{ .address = 0x1000, .length = 0 }));
    var entry: [32]u8 = @splat(0);
    @memcpy(entry[0..5], "_SM3_");
    entry[6] = 24;
    std.mem.writeInt(u32, entry[12..16], 64, .little);
    std.mem.writeInt(u64, entry[16..24], std.math.maxInt(u64) - 31, .little);
    var sum: u8 = 0;
    for (entry[0..24]) |value| sum +%= value;
    entry[5] -%= sum;
    const located = smbiosEntry(&entry).?;
    try std.testing.expect(!biosSmbiosRange(located));
}
