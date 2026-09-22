# Windows 7: missing source after successful WinPE boot

Update after the next physical attempt: the user's Athlon reached native Setup
and its disk-selection page, confirming source access on the removable Kingston.
The subsequent system-partition rejection and its correction are documented in
[windows7-system-partition-2026-09-10.md](windows7-system-partition-2026-09-10.md).
The remaining sections below retain the evidence from the earlier source test.

## Confirmed observations

The physical Athlon/Kingston attempt reached WinPE 6.1 and our launcher, which
reported `The prepared USOS source could not be opened.` This is after the
native BIOS one-shot boot; it is distinct from the earlier Linux/kexec hang.

Host readback on 2026-09-10 verified that Kingston reports Removable Media,
WORK is partition 3, its installation files exist, and the `.usos-work` nonce
matches the launcher embedded in the physical `boot.cpio`. No physical disk
was modified during this diagnosis.

A QEMU TCG control boots the original Polish Windows 7 SP1 x64 DVD with 2 GB
RAM and a 256 MB GPT USB fixture containing ESP/FAT32, DATA/NTFS, WORK/NTFS:

| USB removable flag | Diskpart list volume |
| --- | --- |
| on | DVD and USOS_ESP only; WORK absent |
| off | DVD, USOS_DATA, USOS_WORK and hidden USOS_ESP |

Evidence: `zig-out/win7-bios/source-access/removable-volumes-final.png` and
`fixed-volumes-complete.png`. Harness: `zig-out/win7-usb-qemu.cmd` and
`win7-usb-qmp.py`. The previous single-partition IDE source fixture did not
exercise this restriction.

Microsoft documents multi-partition removable USB support as requiring
Windows/WinPE 10 version 1703 or later:
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe--use-a-single-usb-key-for-winpe-and-a-wim-file---wim?view=windows-11

## Candidate remedy under test

Expose the existing WORK byte range as a read-only virtual volume in WinPE.
Do not repartition the physical USB, write to target disks, or install a driver
on the host. ImDisk is being tested only in the disposable WinPE VM. A production
implementation must match the expected GPT disk/WORK identity and bounds, then
validate the nonce and installation image before launching Setup. Merely adding
a drive letter cannot solve a partition the OS has not enumerated.

## Implemented remedy and validation

`tools/windows_source_mount.c` locates the requested WORK GUID only on USB
devices, validates both GPT headers and entry arrays (CRC, bounds, overlap),
checks the NTFS boot sector, and opens a read-only ImDisk view of that byte range.
It refuses ambiguous identities and refuses mounting outside WinPE. No CRT newer
than Windows 7 is linked. Driver registration exists only in WinPE RAM and is
marked for deletion immediately after starting; no driver is installed on the
host or into the target Windows image. The launcher rechecks the ownership nonce
and explicitly supplies `/installfrom` before launching Setup.

Both x86 and x64 readers passed 14 offline malformed-input/read-only tests.
ImDisk 2.1.2 x64 loaded successfully in unmodified WinPE 6.1.7601, without test
signing. Vendor binaries, hashes, notices and source are pinned under
`tools/vendor/imdisk/2.1.2` and included with the prepared boot archive.

The full-source VM used a removable 8 GB GPT USB with original Win7 SP1 files on
WORK and a separate empty 32 GB virtual target. The boot DVD was replaced with a
tools-only disc after WinPE loaded, so it could not supply `install.wim`. The
actual production launcher/reader passed the source check, displayed Setup,
accepted the target and began expanding Windows. QEMU reported zero USB writes.
Evidence: `full-reader-stage.png`, `full-setup-disk.png`,
`full-setup-copying.png` under the evidence directory above. A USB 2.0 follow-up
uses the same removable-media semantics to finish the full image-read test
without USB 1.1 transfer limits. Completion is recorded below when observed.

Release build and Go checks passed: `B260910-180835-9BECABBF`.
Prepared physical CPIO SHA256:
`935681dd5a1bef44448382bb2d9f984c539b7329dd8333189b503d9fb209e2cc`.
Original `boot.wim` retained SHA256
`f53d14ee6c951244aeda6e4b486bd837674cd657e7454c96fa7c27a29fa99d69`.

Physical validation of this source fix on the Athlon remains outstanding.
The earlier physical success established native BIOS -> WinPE only; it did not
establish source access or a completed Windows 7 installation.

The exact replacement CPIO was also booted through vendor wimboot in VirtualBox
to verify file injection and WinPE compatibility. With no matching USB attached,
the production helper ran and correctly stopped with `expected WORK partition
not found on USB`; it did not fall through to a target disk. Evidence:
`cpio-injection.png`. This is an expected negative test, not an installation pass.

Kingston release update and prepared-cache readback both passed. Evidence:
`kingston-update-result.log` and `kingston-source-cache-result.log` in the source
access evidence directory. The 512-byte native BIOS one-shot marker is armed for
the next boot; this intentionally bypasses the still-unvalidated Linux/kexec
path for the already prepared original Win7 SP1 source. Subsequent boots return
to the normal menu after that marker is consumed.

## Final source-read result

The USB 2.0 / removable-media WinPE test read **all 2,827,635,054 bytes** of
`S:\sources\install.wim` through the production read-only mapping. The native
test helper (`zig-out/win7-read-image-test.c`, no CRT) opens the file read-only,
loops `ReadFile` to EOF, and checks both the known ISO file length and the actual
handle length. Result: `PASS: all 2827635054 bytes read from mapped WORK`.
Evidence: `complete-read-check5.png`, `full-read-blockstats.txt`. The earlier
`copy /b ... nul` attempt failed on its destination and is not counted as a read
test. QEMU reported **zero writes to the emulated USB** throughout this test.

Windows Setup also copied files and reached 42% expansion on its empty
virtual target. This validates source access and installation progress, not a
completed installation/OOBE. The VM was stopped after the full-source read check;
the physical Athlon installation remains the next hardware validation.
