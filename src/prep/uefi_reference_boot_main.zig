//! Separate QEMU-only reference diagnostic. Never linked into normal USOS.
//! SPDX-License-Identifier: GPL-3.0-or-later
pub const prep_boot_only=true;
pub const prep_reference_boot=true;
pub fn main() @import("std").os.uefi.Status {
    return @import("uefi_main.zig").main();
}
