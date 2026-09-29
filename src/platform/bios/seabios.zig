//! SeaBIOS detection for the Legacy BIOS Core (docs/design/bios-via-csmwrap.md).
//!
//! SeaBIOS (plain, coreboot payload, or the CSM16 that CSMWrap copies to
//! 0xE0000) keeps its banner format "SeaBIOS (version %s)" below 1 MiB (the
//! filled-in version string lives only in relocated high memory). CSMWrap's
//! SeaBIOS fork also keeps its BIOS proxy mailbox in the F segment, 8-byte
//! aligned, starting with the signature "CSMPPrxy" (seabios/src/stacks.c
//! BIOS_PROXY_SIGNATURE). Vendor BIOSes carry neither, and everything keyed
//! on these flags (the INT 16h keyboard fallback, the DOS installer's
//! CSMWrap ESP, HIMEM /M:2, VBADOS, USOSKEY) stays off there.

/// SeaBIOS is the BIOS: USB keyboards only through INT 16h.
pub var present: bool linksection(".data") = false;
/// The BIOS is CSMWrap's SeaBIOS: the PC is UEFI without a firmware CSM.
pub var csmwrap: bool linksection(".data") = false;

pub fn detect() void {
    const rom: [*]const volatile u8 = @ptrFromInt(0xE0000);
    present = find(rom, 0x20000, "SeaBIOS (version", 1);
    csmwrap = present and find(rom + 0x10000, 0x10000, "CSMPPrxy", 8);
}

fn find(rom: [*]const volatile u8, len: usize, comptime needle: []const u8, step: usize) bool {
    var i: usize = 0;
    outer: while (i + needle.len <= len) : (i += step) {
        inline for (needle, 0..) |byte, j| {
            if (rom[i + j] != byte) continue :outer;
        }
        return true;
    }
    return false;
}

test "SeaBIOS banner format and the CSMWrap proxy mailbox" {
    const std = @import("std");
    var image = [_]u8{0} ** 0x20000;
    try std.testing.expect(!find(&image, image.len, "SeaBIOS (version", 1));
    const banner = "SeaBIOS (version %s)\n";
    @memcpy(image[0x1234 .. 0x1234 + banner.len], banner);
    try std.testing.expect(find(&image, image.len, "SeaBIOS (version", 1));
    try std.testing.expect(!find(image[0x10000..].ptr, 0x10000, "CSMPPrxy", 8));
    // Unaligned copies (e.g. inside code) do not count.
    @memcpy(image[0x10003 .. 0x10003 + 8], "CSMPPrxy");
    try std.testing.expect(!find(image[0x10000..].ptr, 0x10000, "CSMPPrxy", 8));
    @memcpy(image[0x1f7a8 .. 0x1f7a8 + 8], "CSMPPrxy");
    try std.testing.expect(find(image[0x10000..].ptr, 0x10000, "CSMPPrxy", 8));
}
