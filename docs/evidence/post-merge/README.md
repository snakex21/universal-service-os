# Post-merge UI and USB evidence

This evidence was captured from the `post-merge-v2` qcow2 overlay. No physical
device was attached to QEMU. The run was stopped after the already verified
Windows handoff because further Windows installation testing was explicitly out
of scope.

Confirmed by the screenshots and serial log:

- system icons and disabled planned systems are visible,
- `win10-11 best-ustawienia.xml` is enumerated with its original filename,
- the loading screen is clean and UEFI diagnostics no longer overwrite it,
- `prepare-requested`, BootOrder backup and BootNext are recorded,
- `device_guard` passes before `mkfs.ntfs`,
- the unattended file is copied to WORK as `Autounattend.xml`,
- the prepared state and Windows handoff are reached.

The release consistency check also confirmed that the x86_64 EFI binary used by
`zig-out/usb` and `zig-out/manual-usb` is byte-identical:

`5876055EF372E3104B37B5674504E0B101D4EE51923A78AB060ED9876865B60A`

A negative control substituted the ARM64 bootstrap for the manual x86_64 file;
the consistency check stopped with `BOOTX64.EFI mismatch`, as required.

See `SHA256SUMS.txt` for the captured evidence hashes.
