//! Separate opt-in QEMU client; no dependency from the normal prep or menu.
//! SPDX-License-Identifier: GPL-3.0-or-later
pub const prep_boot_only = true;
pub fn main() @import("std").os.uefi.Status {
    return @import("uefi_main.zig").main();
}
