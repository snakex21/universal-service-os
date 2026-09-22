# Boot UI: hidden technical output and per-path stages (2026-09-22)

## Vista / Windows 7 from UEFI (direct ISO)

The visible file list and "patching" text came from **wimboot**, which the Core
started with only `index=N`. It now gets `quiet index=N`
(`src/flow/boot_console.zig`, used by `src/platform/uefi/windows_native_iso.zig`),
so the USOS screen stays until the Windows boot manager takes over. The WinPE
scripts were already hidden: `usos-launch-*.exe` runs them with CREATE_NO_WINDOW
and writes `usos-startup.log` (copied to `EFI\USOS\Logs`). Windows Setup's own
windows are stock and unchanged. Micro-Linux paths (extract, WIM/VHD boot) were
already quiet: `/dev/console` is ttyS0 (last `console=`) with `loglevel=3`.

## XP (UEFI preparation, isolated micro-Linux)

`src/platform/uefi/xp_preparation.zig` passed `console=ttyS0 console=tty0`, making
the screen `/dev/console`, so every script line and kernel message was drawn over
the framebuffer. It now passes
`console=tty0 console=ttyS0,115200n8 rw quiet loglevel=1 fbcon=nodefer vt.global_cursor_default=0`
(the design already assumed ttyS0; see `legacy_xp_staging.sh`). Interactive steps
use the framebuffer menus (`usos-fb-ui`, `/dev/tty1`) and are unchanged.

## Diagnostics

Create an empty `EFI\USOS\diagnostic-boot.flag` on the USOS ESP to get the old
verbose behaviour: wimboot without `quiet`, and the XP kernel with the screen as
console and `loglevel=7`. Delete it to return to quiet boots. Logs stay available
without it: serial console, `EFI\USOS\Logs` (WinPE), `EFI\USOS-XP\*.log`,
`menu-events.log`, `menu-hardware.txt` and the saved dmesg.

## Progress stages

Each path now shows only the stages it runs, on the same screen and style:

| Path | Stages |
|---|---|
| Micro-Linux preparation (extract, WIM/VHD boot, chainload, XP staging) | 5: start, verify device, workspace, copy, verify/finalize |
| Direct Vista/7 ISO from UEFI | 3: validating ISO, loading boot files, starting Setup |
| XP resume | 1: continuing Windows XP installation |

Previously the direct ISO path passed `total=1` while the renderer always drew
the five fixed micro-Linux labels (`[1/1] .. [5/1]`), and XP resume showed five
completed stages after running one. `preparation_screen.State.labels` now carries
the path's labels and only those rows are drawn. The Linux renderer accepts
`label=` lines; shell paths declare them with `usos_ui_declare_stages 'A|B'`
(`tools/micro_linux_ui.sh`), and done/failure/activity screens use that total.
