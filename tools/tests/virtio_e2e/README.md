# User Storage-driver end-to-end proof (virtio)

Proves the path of docs/drivers.md for a storage controller Windows has no
inbox driver for: `DATA\Drivers\Windows 11\Storage\<package>` → micro-Linux
stager (`usos-fb-ui --stage-drivers`) → `WORK\$WinPEDriver$` → Windows Setup
loads it and sees the disk.

## Test asset (not a product dependency)

virtio-win, Fedora's stable build, downloaded once to
`%LOCALAPPDATA%\USOS\test-assets\` (outside the repository):

| | |
|---|---|
| URL | https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso (redirects to archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso) |
| Version | 0.1.302 (Last-Modified 2026-08-27) |
| Size | 877 373 440 bytes |
| SHA-256 | `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d` |
| Used | `viostor\w11\amd64`, `vioscsi\w11\amd64` (driver version 100.103.104.30200, 2026-07-22), extracted to `virtio-win-0.1.302\` |

Files that the sandboxed agent tools write under `%LOCALAPPDATA%` are not
visible to services (VBoxSVC, Mount-DiskImage), so VM disks are kept under
`tools\tests\artifacts\` (git-ignored).

## run_setup_virtio_qemu.py (QEMU, TCG)

    python tools/tests/virtio_e2e/run_setup_virtio_qemu.py --iso "media/Systems/Windows/Windows 11/Images/Win11_25H2_Polish_x64_v2.iso"

Elevated shell, 7-Zip. Steps: the real stager on the virtio-win files in
micro-Linux; a WORK VHD (FAT32 ESP with USOS in `phase=prepared`, so USOS
does its real handoff: NTFS driver, WORK by `.usos-work`,
`EFI\USOS-WORK\BOOTX64.EFI`; NTFS WORK = extracted ISO + `$WinPEDriver$` +
an answer file whose only action samples `diskpart list disk` and shuts
down). Target: empty 20 GiB qcow2 on `virtio-blk-pci`.

Result 2026-09-24 (build B260924-181530): about 6 minutes per run.

* positive: `Disk 1 Online 20 GB` listed; Setup's setupact.log shows
  "Succeeded in loading driver from path [C:\$WinPEDriver$\Storage-01\viostor.inf]";
* negative (same disk, `$WinPEDriver$` renamed): only `Disk 0` (WORK).

`--full-install` installs Windows 11 Pro onto a 64 GiB virtio-blk disk with
`usos-e2e-virtio.xml` (LabConfig bypasses, image index 5 = Pro, generic Pro
key, local account, first logon writes `C:\usos-e2e-desktop.txt` and shuts
down) and looks for that marker in the target image. WORK is attached as a
removable USB disk. Drop QEMU monitor commands into
`tools\tests\artifacts\virtio-e2e\monitor.txt` to act on a running VM.

Result 2026-09-24 (stopped by decision before OOBE, about 90 min of TCG):
Setup wiped and partitioned Disk 1 (the virtio-blk disk: 260 MB System,
16 MB MSR, 63.7 GB "Windows"), copied and applied the image ("Instalowanie
systemu Windows 11 ... 83%"), rebooted, and the **installed Windows booted
from the virtio disk** ("Trwa instalowanie 42% ... 54%" of the post-reboot
phase), which needs viostor inside the installed system: `$WinPEDriver$`
drivers are injected into the target. Evidence (logs, screenshots) in
`artifacts\e2e-virtio\qemu\`. The first logon was not reached (not needed).

Finding while getting there: with an ESP-typed partition on the WORK disk
(100 MB here), Setup chose that disk for its system partition and failed
(`setuperr.log`: "DiskLayoutMakeSystem: Failed to create system partition",
"No viable region to allocate 209715200 bytes"), also with WORK attached as a
removable USB disk. The test disk's boot partition is therefore FAT32 with a
Basic Data type (OVMF boots it all the same). Whether Setup started from the
real stick (USOS_ESP 512 MB+) puts boot files on the stick is an open
question for hardware (follow-up task).

## VirtualBox 7.2.16 (VT-x, fast)

USOS stick image from `tools/prepare_e2e_base.ps1 -DataDriversPath`
(Win11 ISO + the answer file on DATA, drivers in `DATA\Drivers\Windows 11\Storage`)
on SATA, 64 GB target on a VirtIO SCSI controller. Driven through the USOS
menu with `VBoxManage controlvm keyboardputscancode`: Windows → Windows 11 →
ISO → Automatic → usos-e2e-virtio.xml → Load. USOS prepared WORK (the serial
log shows `user drivers staged=yes`, vioscsi + viostor) and handed off to
Setup. Screenshots: `artifacts\e2e-virtio\`.

* with the driver: Setup loaded vioscsi from `D:\$WinPEDriver$`, the
  "Red Hat VirtIO SCSI pass-through controller" (PCI 1AF4:1048) is
  **Started** (oem0.inf), but VirtualBox exposes **no disk** behind it
  (diskpart rescan: only Disk 0);
* without it: the same controller is a problem device (no driver).

So VirtualBox proves the USOS side (staging, Setup loading the driver) but
not a visible disk: a VirtualBox virtio-scsi / vioscsi limitation. The VM was
deleted afterwards.
