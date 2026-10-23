# Floppy disk sets as installation media (2026-10-23)

User decision 2026-10-23 (before 1.0): a folder of diskette images in a
system's `Images` folder is a media entry like an ISO, e.g.

```
DATA\Systems\Windows\Windows for Workgroups 3.11\Images\WfW 3.11 PL\
    disk01.img ... disk10.img
```

## Design

* **Detection** (`src/catalog/floppy_set.zig`, `media_discovery.zig`): a
  sub-folder of `Images` with at least one diskette image is one
  `ImageKind.floppy_set` item named after the folder (`ImageItem.disks` =
  number of images). Diskette image = `.img/.ima/.vfd/.flp` of 160, 180, 320,
  360, 720, 1200, 1440 or 2880 KiB (an NTFS index size of 0 also counts; the
  micro-Linux step checks the real size). A hard-disk image (FreeDOS
  `FullUSB.img`) or a folder without diskettes is not a set. UEFI and host
  builds only; the freestanding BIOS Core neither lists nor starts sets.
* **Routing** (`os_profiles.zig`): `win3x-floppy-set-uefi-csmwrap` (UEFI,
  Automatic) -> `win9x_uefi` for `floppy_set_ids` = Windows 3.1, 3.11, WfW
  3.11 and 1.01-3.0; `floppy-set-unsupported` refuses a set for every other
  system and firmware. The image list shows `FDD` + "Floppy disk set: N
  disks", or for other systems "not supported" with a notice on Enter
  (three new boot strings, 27 locales).
* **Request**: unchanged `request.ini`; `iso=` names the folder
  (`Systems/Windows/<system>/Images/<set>`).
* **Step 620** (`w9x_csmwrap_prepare.sh`): a folder is accepted only for tag
  W3 (stops otherwise). `dos_csmwrap_target.sh`: `DOS_WIN3_ISO` naming a
  folder -> `tools/floppy_set.sh` `floppy_set_merge` into the same
  `$work/win` the ISO is mounted on; everything after it (copy to
  `C:\USOSDOS\WINSETUP`, `usos-fb-ui --win3x-display` patch table, key
  scripts, early Windows) is the ISO path.
* **Merge** (`tools/floppy_set.sh`): images in natural order (case and
  separators ignored, digit runs compared as numbers: disk2 < disk10, DISK_1
  = disk01 = "Disk 1 of 10"); each read with `mcopy -s -n -m -i IMG '::*'`
  (mtools, no loop device); names upper case, one directory level kept
  (Windows 1.0x `PIF`). Same name on several diskettes: first copy kept,
  identical copies skipped, a different copy logged as
  `floppy set: conflict NAME: diskN differs from diskM, the copy from diskM
  is kept`. This equals `tools/prepare_windows3_media.py`, which built the
  library ISOs from the same diskettes (it refused conflicts).

Not covered (documented "unsupported format"): MS-DOS from its own floppy set
(the DOS flow needs the El Torito ISO's boot floppy), 9x (DMF 1.68 MB
diskettes, CD-based Setup folder), NT 3.x/4.0 (CD flows), the BIOS menu. The
Windows-side installer needs nothing: it neither validates nor converts
system media (DATA is read by the UEFI menu directly).

## Tests

* Host: `tools/tests/test_floppy_set.py` (the shell helper under the host
  shell with stand-in mcopy/mdir over `tools/dos_media_fat12.py`: filters,
  natural order, merge with directories, duplicates, conflicts, unreadable
  and empty sets; wiring; Zig/shell size and extension tables equal). Zig:
  `floppy_set.zig`, `media_discovery.zig` (one entry per set, non-diskette
  folders ignored, media status), `os_profiles.zig` (routing), the routing
  golden table.
* QEMU only (`tools/tests/run_w9x_micro_linux_qemu.py w3 --win3-floppies`,
  the real micro-Linux of build B261023-212042 with this branch's step-620
  scripts, NVMe target, then OVMF -> CSMWrap boot): WfW 3.11 PL from the
  user's 10 x 1.44 MB diskettes: `10 diskettes merged, 703 files, 0
  identical duplicates, 0 conflicts` (703 = the files of the library ISO's
  manifest); `[WIN3X_DISPLAY] VGA.DR_ ... -> 59d1faf8...` and `VGALOGO.LG_
  -> 8da538eb...` (the same patched hashes as from the ISO); Setup ran by
  itself and Program Manager ("Menedżer programów") was on screen after about
  7.5 minutes. Installed (read from the target disk): VGA.DRV = 59d1faf8...,
  VGALOGO.LGO = 8da538eb..., WIN.COM = 72754064..., display.drv=vga.drv:
  the same files as the WfW 3.11 PL install from the ISO
  (docs/win3x-vga-redraw-2026-10-23.md). Not tried on the X470.
