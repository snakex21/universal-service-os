//! `usos-fb-ui --nt4-kernel IN OUT` (micro-Linux, tools/nt4_csmwrap_target.sh,
//! native NT 4.0 only; docs/nt-native-plan.md) and the host tool
//! `usos-win3x-display nt4-kernel IN OUT`. Own implementation,
//! GPL-3.0-or-later.
//!
//! The NT 4.0 RTM kernels (NTOSKRNL.EXE, NTKRNLMP.EXE of the Workstation,
//! Server / Enterprise Server and Terminal Server Edition CDs) set the CPU up
//! in KiSetProcessorType with
//!
//!     mov eax,0 ; cpuid ; (restore the trap 6 handler) ; cmp eax,3 ; jg no_cpuid
//!
//! so a CPU whose CPUID leaf 0 reports more than 3 standard leaves (every
//! CPU since the Pentium 4 / Athlon 64; Zen 3: 10h) is recorded as a type 5
//! CPU without CPUID and the boot ends in a triple fault (X470 2026-10-07;
//! QEMU: EPYC-Milan,level=3 boots, level=4 resets). SP6a dropped the leaf
//! check. This tool reads the user's CD copy (a plain PE file or the one-file
//! MSZIP cabinet NTOSKRNL.EX_), raises the immediate 3 to 7Fh (the `jg` then
//! never jumps for a real CPU), recomputes the PE checksum and writes a plain
//! PE file. The byte sequence must occur exactly once (found by our own
//! binary comparison of the RTM and SP6a kernels: identical on the three CDs,
//! at different offsets); anything else writes nothing. A kernel that already
//! carries 7Fh is reported as patched and copied unchanged.
//! Exit: 0 patched or already patched, 1 not an NT 4.0 RTM kernel (no or
//! more than one match, not a PE, not a one-file .exe cabinet), 2 usage,
//! 3 I/O error. One log line on stderr.
const std = @import("std");
const cab = @import("cab.zig");

const max_file = 8 * 1024 * 1024;

/// mov eax,0 ; cpuid ; mov ecx,fs:[38h] ; pop [ecx+34h] ; pop [ecx+30h] ;
/// cmp eax, (imm8) ; jg (rel8)
const site = [_]u8{ 0xB8, 0, 0, 0, 0, 0x0F, 0xA2, 0x64, 0x8B, 0x0D, 0x38, 0, 0, 0, 0x8F, 0x41, 0x34, 0x8F, 0x41, 0x30, 0x83, 0xF8 };
pub const rtm_limit: u8 = 3;
pub const new_limit: u8 = 0x7F;
const jg_rel8: u8 = 0x7F;

pub const Outcome = enum { patched, already, no_match, many_matches, not_pe, not_kernel_cab, corrupt };

pub const Site = struct { offset: usize, value: u8 };

/// The immediate of the one `cmp eax, 3|7Fh ; jg` after the leaf 0 CPUID.
pub fn findSite(data: []const u8) error{ NoMatch, ManyMatches }!Site {
    var found: ?Site = null;
    var many = false;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, &site)) |i| : (pos = i + 1) {
        const imm = i + site.len;
        if (imm + 1 >= data.len or data[imm + 1] != jg_rel8) continue;
        if (data[imm] != rtm_limit and data[imm] != new_limit) continue;
        if (found != null) many = true;
        found = .{ .offset = imm, .value = data[imm] };
    }
    if (many) return error.ManyMatches;
    return found orelse error.NoMatch;
}

fn rd16(d: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, d[o..][0..2], .little);
}

/// File offset of the PE OptionalHeader.CheckSum of a 32-bit image.
pub fn checksumOffset(data: []const u8) ?usize {
    if (data.len < 0x40 or data[0] != 'M' or data[1] != 'Z') return null;
    const pe = std.mem.readInt(u32, data[0x3C..][0..4], .little);
    if (pe > data.len or data.len - pe < 24 + 0x60) return null;
    if (!std.mem.eql(u8, data[pe..][0..4], "PE\x00\x00")) return null;
    if (rd16(data, pe + 24) != 0x10B) return null;
    return pe + 24 + 64;
}

/// The image checksum (ImageHlp CheckSumMappedFile): 16-bit one's
/// complement style sum of the file with the CheckSum field as zero, plus
/// the file length.
pub fn peChecksum(data: []const u8, field: usize) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        var word: u32 = data[i];
        if (i + 1 < data.len) word |= @as(u32, data[i + 1]) << 8;
        if (i >= field and i < field + 4) word = 0;
        sum += word;
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    sum = (sum & 0xFFFF) + (sum >> 16);
    return sum + @as(u32, @intCast(data.len));
}

/// Patches `image` (a plain PE file, owned by the caller) in place.
pub fn patchImage(image: []u8) Outcome {
    const field = checksumOffset(image) orelse return .not_pe;
    const s = findSite(image) catch |err| return switch (err) {
        error.ManyMatches => .many_matches,
        error.NoMatch => .no_match,
    };
    if (s.value == new_limit) return .already;
    image[s.offset] = new_limit;
    std.mem.writeInt(u32, image[field..][0..4], peChecksum(image, field), .little);
    return .patched;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

/// `raw` (plain kernel or its one-file cabinet) -> a patched plain PE in `out`.
pub fn rebuild(gpa: std.mem.Allocator, raw: []const u8, out: *?[]u8) Outcome {
    out.* = null;
    var image: []u8 = undefined;
    if (cab.isCab(raw)) {
        var parsed = cab.parse(gpa, raw) catch return .corrupt;
        defer parsed.deinit(gpa);
        if (parsed.files.len != 1 or !endsWithIgnoreCase(parsed.files[0].name, ".exe")) return .not_kernel_cab;
        image = gpa.dupe(u8, parsed.files[0].data) catch return .corrupt;
    } else {
        image = gpa.dupe(u8, raw) catch return .corrupt;
    }
    const outcome = patchImage(image);
    if (outcome != .patched and outcome != .already) {
        gpa.free(image);
        return outcome;
    }
    out.* = image;
    return outcome;
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, in_path: []const u8, out_path: []const u8) u8 {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, in_path, gpa, .limited(max_file)) catch |err| {
        std.debug.print("[NT4_KERNEL] {s}: {s}\n", .{ in_path, @errorName(err) });
        return 3;
    };
    defer gpa.free(raw);
    var data: ?[]u8 = null;
    const outcome = rebuild(gpa, raw, &data);
    defer if (data) |d| gpa.free(d);
    switch (outcome) {
        .patched, .already => {
            const image = data.?;
            cwd.writeFile(io, .{ .sub_path = out_path, .data = image }) catch |err| {
                std.debug.print("[NT4_KERNEL] {s}: {s}\n", .{ out_path, @errorName(err) });
                return 3;
            };
            const s = findSite(image) catch unreachable;
            const field = checksumOffset(image).?;
            std.debug.print("[NT4_KERNEL] {s}: CPUID leaf limit {s} at offset 0x{x}, checksum 0x{x:0>8} ({s}, {d} bytes)\n", .{
                in_path,
                if (outcome == .patched) "3 -> 7Fh" else "already 7Fh",
                s.offset,
                std.mem.readInt(u32, image[field..][0..4], .little),
                if (cab.isCab(raw)) "cabinet" else "plain",
                image.len,
            });
            return 0;
        },
        else => {
            std.debug.print("[NT4_KERNEL] {s}: not patched ({s})\n", .{ in_path, @tagName(outcome) });
            return 1;
        },
    }
}

/// A minimal 32-bit PE (0x400 bytes) with the RTM routine at 0x200.
fn samplePe(buf: *[0x400]u8, limit: u8) void {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    std.mem.writeInt(u32, buf[0x3C..][0..4], 0x80, .little);
    @memcpy(buf[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, buf[0x80 + 4 ..][0..2], 0x14C, .little);
    std.mem.writeInt(u16, buf[0x80 + 24 ..][0..2], 0x10B, .little);
    std.mem.writeInt(u32, buf[0x80 + 24 + 64 ..][0..4], 0x12345678, .little);
    @memcpy(buf[0x200..][0..site.len], &site);
    buf[0x200 + site.len] = limit;
    buf[0x200 + site.len + 1] = jg_rel8;
    buf[0x200 + site.len + 2] = 0x46;
    for (buf[0x300..], 0..) |*b, i| b.* = @truncate(i * 7 + 1);
}

test "the leaf limit becomes 7Fh and the checksum is recomputed" {
    var pe: [0x400]u8 = undefined;
    samplePe(&pe, rtm_limit);
    try std.testing.expectEqual(Outcome.patched, patchImage(&pe));
    try std.testing.expectEqual(new_limit, pe[0x200 + site.len]);
    try std.testing.expectEqual(jg_rel8, pe[0x200 + site.len + 1]);
    // pefile.PE(data=...).generate_checksum() of the patched sample.
    try std.testing.expectEqual(@as(u32, 0x00006220), std.mem.readInt(u32, pe[0x80 + 24 + 64 ..][0..4], .little));
    // Only those two places differ from the unpatched sample.
    var orig: [0x400]u8 = undefined;
    samplePe(&orig, rtm_limit);
    var diff: usize = 0;
    for (pe, orig) |a, b| diff += @intFromBool(a != b);
    try std.testing.expect(diff <= 1 + 4);
    // A second run changes nothing.
    const again = pe;
    try std.testing.expectEqual(Outcome.already, patchImage(&pe));
    try std.testing.expectEqualSlices(u8, &again, &pe);
}

test "no match, two matches or no PE: nothing is patched" {
    var pe: [0x400]u8 = undefined;
    samplePe(&pe, 4);
    try std.testing.expectEqual(Outcome.no_match, patchImage(&pe));
    samplePe(&pe, rtm_limit);
    @memcpy(pe[0x280..][0 .. site.len + 2], pe[0x200..][0 .. site.len + 2]);
    try std.testing.expectEqual(Outcome.many_matches, patchImage(&pe));
    samplePe(&pe, rtm_limit);
    pe[0x80] = 'X';
    try std.testing.expectEqual(Outcome.not_pe, patchImage(&pe));
}

test "a one-file kernel cabinet comes out as a plain patched PE" {
    const gpa = std.testing.allocator;
    var pe: [0x400]u8 = undefined;
    samplePe(&pe, rtm_limit);
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3;
    header[25] = 1;
    header[26] = 1;
    const like = cab.Cabinet{ .header = &header, .folder_reserve = 0, .data_reserve = 0, .folder_extra = &.{}, .compress = 1, .files = &.{}, .body = &.{} };
    const packed_kernel = try cab.build(gpa, &like, &.{.{ .name = "ntoskrnl.exe", .data = &pe, .date = 0, .time = 0, .attribs = 0x20 }});
    defer gpa.free(packed_kernel);
    var out: ?[]u8 = null;
    try std.testing.expectEqual(Outcome.patched, rebuild(gpa, packed_kernel, &out));
    defer gpa.free(out.?);
    try std.testing.expectEqual(@as(usize, pe.len), out.?.len);
    try std.testing.expectEqual(new_limit, out.?[0x200 + site.len]);
    const other = try cab.build(gpa, &like, &.{.{ .name = "initial.inf", .data = &pe, .date = 0, .time = 0, .attribs = 0 }});
    defer gpa.free(other);
    var none: ?[]u8 = null;
    try std.testing.expectEqual(Outcome.not_kernel_cab, rebuild(gpa, other, &none));
}
