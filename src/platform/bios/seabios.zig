//! SeaBIOS detection for the Legacy BIOS Core (docs/design/bios-via-csmwrap.md).
//!
//! SeaBIOS (plain, coreboot payload, or the CSM16 that CSMWrap copies to
//! 0xE0000) carries "SeaBIOS (version <v>)" in its image below 1 MiB; the
//! CSMWrap build's version contains "-CSMWrap-" (578d260b-CSMWrap-3.1.2-usos3).
//! Vendor BIOSes carry neither, and everything keyed on these flags (the INT
//! 16h keyboard fallback, the DOS installer's CSMWrap ESP, HIMEM /M:2,
//! VBADOS) stays off there.

/// SeaBIOS is the BIOS: USB keyboards only through INT 16h.
pub var present: bool linksection(".data") = false;
/// The BIOS is CSMWrap's SeaBIOS: the PC is UEFI without a firmware CSM.
pub var csmwrap: bool linksection(".data") = false;

pub fn detect() void {
    const rom: [*]const volatile u8 = @ptrFromInt(0xE0000);
    detectIn(rom, 0x20000);
}

fn detectIn(rom: [*]const volatile u8, len: usize) void {
    const needle = "SeaBIOS (version ";
    var i: usize = 0;
    outer: while (i + needle.len + 64 < len) : (i += 1) {
        for (needle, 0..) |byte, j| {
            if (rom[i + j] != byte) continue :outer;
        }
        present = true;
        // The version ends at ')'; look for "-CSMWrap-" inside it.
        var k = i + needle.len;
        while (k < i + needle.len + 64 and rom[k] != ')') : (k += 1) {
            if (rom[k] == '-' and rom[k + 1] == 'C' and rom[k + 2] == 'S' and rom[k + 3] == 'M' and rom[k + 4] == 'W') csmwrap = true;
        }
        return;
    }
}

test "SeaBIOS and CSMWrap version strings" {
    const std = @import("std");
    var image = [_]u8{0} ** 256;
    present = false;
    csmwrap = false;
    detectIn(&image, image.len);
    try std.testing.expect(!present and !csmwrap);
    const plain = "SeaBIOS (version rel-1.16.3-0-ga6ed6b701f0a)";
    @memcpy(image[10 .. 10 + plain.len], plain);
    detectIn(&image, image.len);
    try std.testing.expect(present and !csmwrap);
    const wrapped = "SeaBIOS (version 578d260b-CSMWrap-3.1.2-usos3)";
    @memset(&image, 0);
    @memcpy(image[20 .. 20 + wrapped.len], wrapped);
    present = false;
    detectIn(&image, image.len);
    try std.testing.expect(present and csmwrap);
}
