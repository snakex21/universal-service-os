# MS-DOS 6.22: USOS install vs. the original Setup (2026-10-24)

Status: **QEMU only.** Reference = the real MS-DOS 6.22 Setup from the user's
`MS-DOS 6.22 EN.iso` (a CD remaster: Setup disks 1-3 + Supplemental Disk in
the root, own boot floppy with an ATAPI driver), QEMU `pc`, SeaBIOS, blank
300 MB IDE disk, US/English defaults, directory `C:\DOS`. USOS = the normal
flow (micro-Linux `dos_csmwrap_target.sh`, then OVMF -> CSMWrap -> NVMe ->
INSTALL.BAT), without a profile and with a Polish profile (DOS.INI
`country=048 codepage=852`).

Setup notes from the reference run:

- From the CD (source E:) Setup cannot configure unallocated space or format
  it: both steps ask for "Setup Disk #1" in E: in a loop (they need a restart
  from a diskette). The run used the media's own `FDISK` (whole disk, active)
  and `FORMAT C:`, then Setup installed on the formatted drive.
- No "optional programs" page appeared: with no Windows found Setup installs
  Backup, Undelete and Anti-Virus in their **Windows + MS-DOS** versions
  (all `MW*` files, `WNTOOLS.GRP`).

## Differences

| Item | Real Setup | USOS (before) | Class | Action |
|---|---|---|---|---|
| `GRAPHICS.PRO` | in `C:\DOS` | missing (`GRAPHICS.PR_` left compressed-name) | a | PREPDOS renames it |
| `MEMMAKER.INF`, `DRVSPACE.INF` | `.INF` | `.INI` (generic `*.IN_` rule) | a | PREPDOS names them first |
| `WNTOOLS.GRP` | `.GRP` | `.GRB` | a | PREPDOS names it as Setup does |
| `C:\DOS\COMMAND.COM` | copy present | missing | a | INSTALL copies `C:\COMMAND.COM` |
| `DEVICE=C:\DOS\SETVER.EXE` | first CONFIG line | absent (DOS only) | a | first line of the MS-DOS CONFIG.SYS (same driver the X470-proven Windows 1.x-3.0 menu loads) |
| Volume label | `MS-DOS_6` | none | c | `LABEL C:MS-DOS_6` |
| Supplemental installer files in `C:\DOS` (`SETUP.BAT`, `SETUP.MSG`, `SD6COPY.BAT`, `720ID0x.BAT`) | absent | present (only work from that diskette) | c | deleted after PREPDOS |
| `C:\USOSDOS` (media copy, MEMDISK, helpers, 11 MB) | n/a | left on the disk | c | DOS-only install: removed by `C:\TEMP\USOSFIN.BAT` just before the restart (Windows installs keep it as before) |
| XMS driver | `HIMEM.SYS` | `HIMEMX.EXE /MAX=32768 /X2MAX32` | b | kept (X470-proven, large RAM) |
| `DOS=HIGH` | yes | yes | - | same |
| `FILES` / `BUFFERS` / `LASTDRIVE` / `SHELL` | `FILES=30` | `FILES=40 BUFFERS=20 LASTDRIVE=Z SHELL=... /E:2048 /P` | b | kept |
| `SMARTDRV.EXE /X` | in AUTOEXEC | absent | b | kept off: INT 13h cache over CSMWrap/SeaBIOS NVMe not X470-tested |
| EMM386 | not loaded | not loaded | - | same (EMM386 breaks the USOSPKT MMIO fallback) |
| `PATH` | `C:\DOS` | `C:\DOS;C:\WINDOWS;C:\PROGRAMS` | b | kept |
| `TEMP` | `C:\DOS` | `C:\TEMP` | b | kept |
| `PROMPT $p$g`, `@ECHO OFF` | yes | yes | - | same |
| VBMOUSE, USOSKEY, `NETSTART.BAT`, `ver` | - | in AUTOEXEC | b | USOS machine support |
| `WINA20.386` in `C:\` | yes | yes (fixed earlier) | - | same |
| `IO.SYS`, `MSDOS.SYS` | root entries 0/1, R H S | same | - | same |
| Root `COMMAND.COM` | R | R | - | same (both via SYS) |
| Boot sector | OEM `MSDOS5.0`, 8 KB clusters (299 MB) | OEM `MSDOS5.0`, 4 KB clusters (256 MiB) | c | same table as DOS FORMAT for the size |
| Extra files in `C:\DOS` | - | Supplemental Disk tools (DOSSHELL, EDLIN, QBasic samples, AccessDOS, ...), USOS helpers, `READY.TAG`, `USOSDOS.LOG` | b/c | kept (superset) |
| Polish profile | (no Polish media) | `COUNTRY=048,852,C:\DOS\COUNTRY.SYS`, `DISPLAY.SYS CON=(EGA,,1)`, `MODE CON CODEPAGE PREPARE/SELECT=852` | - | as a localized Setup writes them; no other difference |

After the fixes `C:\DOS` contains every file the real Setup puts there,
with identical contents (byte compare, QEMU), plus the superset above.

Tests: `tools/tests/test_dos_setup_parity.py` (PREPDOS rename replay over the
PACKING.LST names, INSTALL order and cleanup rules).
