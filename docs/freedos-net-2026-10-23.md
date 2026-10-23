# FreeDOS 1.4: network through USOSPKT + mTCP (2026-10-23)

Goal: the same network as the MS-DOS 6.22 flow (docs/dos-usospkt-2026-10-23.md,
X470 PASS 2026-10-23: DHCP + HTGET of 68k.news on the I211) in the FreeDOS
1.4 install path.

Status: **QEMU only (82576 `-nic user,model=igb`, not I211)**: the real
micro-Linux writes the image and stages C:\NET, FreeDOS boots through
OVMF -> CSMWrap -> SeaBIOS, DHCP and HTGET of http://68k.news PASS. **Not
run on the X470 yet.**

## How the FreeDOS install works (evidence)

FreeDOS comes from the UEFI menu as a Custom OS image-to-disk
(docs/custom-os-2026-10-11.md): step 620 runs `tools/image_disk_target.sh`,
which writes `FreeDOS 1.4 FullUSB.img` unchanged to the target disk, adds
the CSMWrap ESP (BIOS-only MBR image) and the boot entry. `freedos_fix`
renames `SETUP.BAT` to `SETUP.OFF`.

The FullUSB image (1 GiB, MBR, one FAT32 partition at LBA 63, label
FD14-FULL) read on the host:

- root: `KERNEL.SYS`, `COMMAND.COM`, `FDAUTO.BAT`, `FDCONFIG.SYS`,
  `SETUP.BAT`, `FREEDOS\` (`BIN`, `NLS`, `SETUP`), `FDOS-x86\` (the
  installer's sliced archive), `PACKAGES\` (the repository for FDIMPLES).
- `FDAUTO.BAT` ends with `if not exist SETUP.BAT goto Done` / `CALL SETUP.BAT
  full`: the disk is the installer's live environment. With SETUP.BAT renamed
  the installer never runs, so **the written disk itself is the final
  system** - files placed on it stay; no second install copies anything.
- `FDCONFIG.SYS`: HIMEMX only (`DOS=HIGH,UMB`, no JEMM/EMM386), shell
  `COMMAND.COM /E:2048 /P=\FDAUTO.BAT`.
- Network autoload: `FDAUTO.BAT` has `if exist %dosdir%\bin\fdnet.bat call
  %dosdir%\bin\fdnet.bat start`, but `FREEDOS\BIN` on FullUSB has no
  FDNET.BAT and no packet drivers (FDNET is a package in `PACKAGES\`, not
  installed). So no FreeDOS packet driver loads; nothing to disable.
  `MTCPCFG` is not set by FreeDOS.

## Design

`freedos_net` in `tools/image_disk_target.sh` (called from `freedos_fix`
after the SETUP switch, on the image's FAT partition through mtools, which
the micro-Linux already has):

1. Source = the stick's `EFI\USOS\dos-native\msdos` (mounted read-only at
   `/mnt/esp`; the payload already ships the 14 network files for the MS-DOS
   flow; `USOS_DOS_NET_DIR` overrides it for tests). Same list as
   `build_dos_network.NET_FILES` (host test keeps them equal). A missing file
   or mtools tool: one log line, FreeDOS is written without network (no stop).
2. `mmd ::/NET`, `mcopy -o` each file, read back and sha256-compared.
3. `FDAUTO.BAT`: unless it already has the line, insert
   `rem USOS network: ...` + `if exist C:\NET\USOSPKT.COM call
   C:\NET\NETSTART.BAT` right before `if not exist SETUP.BAT goto Done`
   (after the FDNET line, before FreeDOS's welcome text); if that line is
   missing, append at the end. Every line CRLF; written back and read back.

The same `NETSTART.BAT` as MS-DOS: `MTCPCFG=C:\NET\MTCP.CFG` (created from
MTCP.DEF on first boot), PATH + C:\NET, `USOSPKT 0x60`, errorlevel != 0 ->
one line, no DHCP; DHCP `-retries 2 -timeout 6`. The boot cannot hang
without a NIC (USOSPKT exits at once, errorlevel 1) or without DHCP (at most
~12 s). If the user later installs FDNET and it loads a driver on 0x60,
USOSPKT refuses the occupied vector (errorlevel 2) and NETSTART stops.

## Files

| file | change |
|---|---|
| `tools/image_disk_target.sh` | `freedos_net`, called from `freedos_fix`; header note |
| `tools/tests/test_freedos_net.py` | host: staging, FDAUTO insertion point, CRLF, idempotency, fallback append, missing-file skip, mkdir failure stop, list = NET_FILES (7 tests, mtools shim on a folder) |
| `tools/tests/run_custom_os_micro_linux_qemu.py` | overlay carries the `--root` build's network files (`USOS_DOS_NET_DIR`) |

## Tests

Host: `python tools/tests/test_freedos_net.py` 7 OK; existing
`test_image_disk_pmbr` (10), `test_image_disk_elcr` (5),
`test_esp_writes_helper` (8), `test_uefi_boot_entry` (16),
`test_dos_network` (6) OK.

QEMU only (`run_custom_os_micro_linux_qemu.py --system freedos`, image
`FreeDOS 1.4 FullUSB.img`, 2 GiB scratch disk, deleted afterwards):

- prepare in the built micro-Linux (B261023-122630 initramfs, real mtools,
  UEFI prepare): `SETUP.BAT renamed to SETUP.OFF`, `FreeDOS network: C:\NET
  staged (USOSPKT + mTCP), FDAUTO.BAT calls NETSTART.BAT, read-back PASS`,
  CSMWrap ESP + boot entry as before.
- boot (q35 without i8042, OVMF -> CSMWrap -> SeaBIOS, USB keyboard,
  `-nic user,model=igb`): HimemX, then `USOS: siec gotowa (DHCP)` before the
  FreeDOS welcome; USOSPKT.LOG: 82576 via PCI BIOS, I/O BAR port, IRQ 11 +
  timer, link 1000 full, INT 60h; DHCP.LOG: offer on attempt 1, 10.0.2.15,
  written to C:\NET\MTCP.CFG. Typed `htget -o c:\net\k.htm
  http://68k.news/`: `Server return code: 200 OK`, 99 598 bytes of the real
  page (read back from the disk). FDAUTO.BAT on the disk: 61 lines, all
  CRLF. mTCP warns that TZ is not set (FreeDOS sets `TZ=` empty): file
  timestamps only.
- same disk without a NIC: `USOS: brak obslugiwanej karty sieciowej`, the
  FreeDOS prompt follows at once.

Not covered: the X470 (I211) under FreeDOS; HIMEMX instead of MS-DOS
HIMEM.SYS on the real board (QEMU shows the I/O BAR path under HIMEMX).
