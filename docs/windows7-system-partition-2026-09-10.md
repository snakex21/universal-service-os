# Windows 7: target partition rejected after successful Setup launch

## Latest physical result: user-confirmed installation success

After testing the updated Kingston, the user reported that Windows 7 finally
installed successfully on the physical Athlon/MS-7100. This closes the reported
system-partition installation blocker for this prepared original Windows 7 SP1
source and native BIOS boot path. This result is user-reported; no new physical
logs were collected in this follow-up. Console appearance was not separately
confirmed by the user.

It does not establish a completed Windows 10 installation or validate the
Linux/kexec handoff on this motherboard. The earlier July 2019 Windows 7 ISO
used WinPE 10 and passed a separate VM test; the final prepared source here
uses the original Windows 7 installer. Keep those results distinct. Vista is
covered by the subsequent [Vista BIOS validation](windows-vista-bios-2026-09-10.md);
its physical Athlon test remains pending.

The sections below record the diagnosis and validation before that report.

## Physical report and read-only inspection

The user reached the native disk-selection page on the Athlon/MS-7100 with
2 GB RAM. Setup showed one 111.8 GB primary partition and reported that it
could neither create nor locate a system partition. Formatting did not help.
This confirms that the earlier read-only WORK mapping now provides the source
on the physical removable Kingston; it does not establish installation success.

The attached Intel was read only. Its MBR signature is `84a8d49f`, capacity
120034123776 bytes, partition start LBA 2048, length 234436608 sectors.
At the time of inspection the entry was inactive, type `06`, and the first
partition sector was zero. The host could not mount a filesystem, so no
physical Panther logs could be recovered. This is an incomplete partition
state, but is not by itself the demonstrated cause of Setup's rejection.

Evidence is under `zig-out/win7-bios/system-partition`: `disks.json`,
`disk-8-parts.json`, and `intel-first-2m.bin`. Disk numbers are observations,
not identities to reuse when writing media. The Intel was never opened for
write, repartitioned, formatted or used as a VM device.

## Reproduced cause

The control VM uses a sparse disposable 120034123776-byte disk with the Intel's
captured MBR, a removable GPT USB with ESP/DATA/WORK, 2 GB RAM and legacy BIOS.
The USB is BIOS hard disk 80h, ahead of the IDE target. The original Win7 SP1
DVD loads WinPE; its media is replaced with a tools-only disc before launching
the production USOS source reader and `setup.exe /installfrom`.

The same 111.8 GB partition error was reproduced. The exported
`guest-logs/setupact.log` identifies the cause:

```
GetSystemDiskNTPath: Found system disk at [\Device\Harddisk1\DR1].
GetSystemDiskNumber: Disk [1] is the system disk.
GetMachineInfo:Couldn't find info for boot disk [1]
[BLOCKING reason for disk 0: CanBeSystemVolume]
Wybrany dysk nie jest dyskiem rozruchowym komputera.
```

Setup identifies the USB as the firmware boot disk and rejects the actual
internal installation target as a system volume. The previous blank-disk test
had a different firmware disk order and did not cover this condition.

The Easy2Boot author's description of the same log messages and its firmware
disk-mapping remedy supports this interpretation:
https://rmprepusb.blogspot.com/2016/08/upgrading-win7-to-win10-still-works.html
The general Rufus FAQ also records this class of USB-dependent partition error:
https://github.com/pbatard/rufus/wiki/FAQ#setup-was-unable-to-create-a-new-system-partition-or-locate-an-existing-system-partition

## Changes

`windows_disk_order.S` is used only by the native Windows BIOS handoff. If the
known USOS boot drive is 80h and the BIOS reports 2..16 hard disks, the temporary
INT13 mapping moves that USB to the last position while retaining the other
disks' relative order. If USOS is already behind another disk, numbering is
unchanged. The hook does not write sectors, choose an installation partition,
format a disk or change firmware settings. Windows Setup still performs disk
selection and partition creation with its normal UI.

The hook occupies unused padding in the pinned wimboot prefix. The vendor file
on disk and protected-mode payload remain unchanged. The resident hook lies
below wimboot's real-mode BSS at 20a00h. Carry/interrupt flags and BIOS geometry
and size results are preserved. Four Unicorn tests execute the real assembly
against a firmware surrogate, covering rotation, pass-through, return values,
errors and no-op conditions.

`windows_setup_launcher.c` replaces the visible CMD shell with a Win7-compatible
native GUI executable. The preparation script runs with `CREATE_NO_WINDOW`;
the actual Windows Setup remains visible. Output is logged beside the injected
executable in WinPE RAM. A startup failure produces a visible diagnostic dialog.
Both x86 and AMD64 launchers are bundled, and Winpeshl selects the running
WinPE architecture. Application-created diagnostic files remain beside the
injected program. No persistent service or application configuration is written
on the host or Intel.

Winpeshl's supported custom-shell/environment-variable mechanism:
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpeshlini-reference-launching-an-app-when-winpe-starts

The normal Linux/kexec handoff remains a separate, previously unvalidated
hardware path. This correction targets the native BIOS handoff that has already
reached Windows Setup on the user's machine.

## Integration validation

VirtualBox passed native Core boot with the USOS source as BIOS disk 80h and a
disposable target containing the captured Intel MBR. The source fixture contains
a read-only clone of the physical ESP and local Windows source files, converted
to a dynamically allocated VDI. No physical device is attached to either VM.
The guest has 2 GB RAM and legacy BIOS. Both virtual drives use IDE; removable
USB source access remains covered by the earlier QEMU tests and physical report.

The actual production Core and CPIO launched Setup without a console. Selecting
the 111.8 GB target and pressing Next passed the partition check and expanded
Windows. After the first restart, the virtual USOS source was detached entirely.
The target booted by itself, completed the installation phase and reached the
account-creation page. OOBE was then completed with a disposable test account,
using Setup's normal Skip button for the product key, with the VM network
disconnected. Windows reached its desktop (`vbox-desktop.png`). Thus its startup
files do not depend on the source disk.
Screenshots `vbox-native.png`, `vbox-disk.png`, `vbox-after-next.png`,
`vbox-target-boot.png` and `vbox-target-boot2.png` document these transitions.
A separate run with no matching source reached the launcher's visible error
dialog (`vbox-control.png`), confirming failures are not silently hidden.

QEMU 11.1 TCG produced invalid initrd pointers in both Syslinux and native Core
tests before WinPE. The same Syslinux case had failed with unmodified vendor
wimboot in the previous session. VirtualBox loaded both paths successfully.
This is an unresolved emulator/handoff discrepancy, not counted as a passing
QEMU integration test or proof about the physical firmware.

Four real-assembly disk-order tests, fourteen source-reader tests, the complete
release build, Go tests and payload consistency checks passed. At deployment,
the physical Athlon test was still pending; its later user-reported success is
recorded at the top of this document.

## Kingston update

Release `B260910-193835-A2AE2C61` was written to the identity-checked Kingston.
The updater verified the BIOS Core and payload by readback and verified that
the GPT identities, offsets and sizes were preserved (`kingston-update.log`).
The prepared Win7 CPIO was then replaced, read back and matched SHA-256
`7decbfb4a816dec75a4a00bbfd7a0a8871d33b701db3147b95fbccb9276e5311`.
The one-shot native Windows boot is armed for the next boot. The cache operation
did not write WORK, DATA or the Intel (`kingston-cpio-update.log`).
The Intel's first 2 MiB were subsequently read again and matched the initial
capture byte-for-byte (`intel-unchanged.log`).
