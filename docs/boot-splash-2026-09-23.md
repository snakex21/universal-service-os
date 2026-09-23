# Boot splash, loading time and handover screens (2026-09-23)

The screen used to stay black between the firmware and the first USOS menu
frame, and again when USOS handed over to micro-Linux. This covers what the
time was spent on, what the loading screens look like per path and what was
made faster.

## Where the time went (QEMU, TCG, 1280x800)

UEFI (OVMF), from `BOOTX64.EFI` entry, TSC marks (`EFI\USOS\Logs\boot-timing.txt`):

| Step | Before | After |
|---|---:|---:|
| GOP, memory map, ESP volume, `usos-settings.ini` | 1.3 ms | 3 ms |
| **Splash on screen** | - (black) | **~11 ms** |
| theme.css, font pack parse, lang.bin | 7 ms | 7 ms |
| Pointer devices, off-screen buffer | 35 ms | 32 ms |
| `input-devices.txt` (file + ~1.3 KiB serial) | 46 ms | after the menu |
| DATA catalog (BlockIo, GPT, NTFS mount) | **318 ms** | 8-30 ms |
| First menu frame (render + Blt) | 88 ms | 88 ms |
| **Entry -> first menu frame** | **496 ms** | **163 ms** |
| Opening a category: system icons | **~460 ms** | 5-30 ms (first open reads bios-ui.bin) |

The firmware itself ran ~2.8 s before `BOOTX64.EFI` in QEMU (TSC since reset;
the first line of `boot-timing.txt` shows the same on real hardware).

Legacy BIOS (SeaBIOS), host timestamps of the serial log:

| Step | Before | After |
|---|---:|---:|
| Stage 1 + Core load + CRC | 0.16 s | 0.15 s |
| GPT (ESP + DATA search) | 88 ms | 20 ms |
| FAT32, NTFS mount, INDEX PRE-VBE diagnostics | 0.14 s | 0.05 s |
| VBE probe and mode set | 0.43 s | 0.25 s |
| **First USOS pixels** | 0.80 s | **0.26 s** (splash) |
| `bios-ui.bin` + `lang.bin` | **300 ms** | 95 ms |
| **Menu** | 0.74 s | **0.38 s** |

Causes and fixes:

- **GPT search**: `findUsosPartition` read the header, then 32 sectors for the
  entry CRC, then every 128-byte entry with its own read: 161 reads per
  search, two searches per disk (ESP and DATA), on every disk. It is now one
  pass in whole blocks (4 KiB on UEFI, one sector in the Core). On a PC with
  several disks this also removes hundreds of reads per extra disk.
- **System icons (UEFI)**: each row decoded a 1254x1254 PNG (~500 KiB) to a
  32x32 icon. The rows now use the pre-scaled RLE icons from
  `EFI\USOS\bios-ui.bin` (one 120 KiB read per boot); `icon.png` next to a
  system's `Images` folder still overrides, the PNGs stay the fallback.
- **`bios-ui.bin` (BIOS)**: read with one INT 13h call per sector; now
  `readFileSequentialProgress` over the bulk reader (127 sectors per call).
- **Input report (UEFI)**: written after the first menu frame. On a board
  with a real UART every serial byte costs ~87 us at 115200 baud.

## UEFI splash

`src/platform/uefi/splash.zig`, drawing in `src/gui/splash_screen.zig`.

- Drawn right after GOP and the tiny `usos-settings.ini` read, before
  lang.bin, the theme, the pointer drivers and the catalog: the menu
  background, the USOS logo tile, "Universal Service OS" and a status line.
- The status appears once lang.bin is parsed ("Wczytywanie…" in pl), so the
  screen never flashes English first. Later status changes are shown only
  once the spinner runs, so quick steps do not make the text flicker.
- The 12-dot spinner is driven by a periodic 75 ms timer event at
  `TPL_NOTIFY` (disk drivers keep `TPL_CALLBACK` raised for a whole read) and
  starts only after 150 ms: a quicker load never shows an animation.
  The callback only writes framebuffer pixels.
- The first full frame (menu, resume status or error) ends the splash; there
  is no fade (it would add delay).
- `boot_logo=firmware` in `EFI\USOS\usos-settings.ini` keeps the firmware logo
  like Windows: the ACPI BGRT bitmap is redrawn at its offset on black, the
  spinner and status go below it. No BGRT, a rotated or invalid image falls
  back to the USOS logo. Default: USOS logo. (The installer merges this file,
  so the key survives updates.)

## Legacy BIOS splash

The Core (`src/platform/bios/boot_ui.zig`) draws, right after `4F02`: the menu
background, the logo tile and a thin bar that fills while `bios-ui.bin`
loads. Text is not possible before the font is loaded, and the menu follows
~0.1 s later. Before the VBE mode set (Stage 1, Core load, GPT/FAT/NTFS and
the INDEX PRE-VBE diagnostics, ~0.25 s in QEMU) the screen stays in BIOS text
mode: the NTFS mount deliberately stays before VBE for the pre/post-VBE
INT 13h comparison in the diagnostics (TESTING.md). Core payload: 243,896 of
245,760 bytes (was 243,340; the GPT change saved 128 bytes). The Core has no
FAT32 write, so BIOS timing is only in the serial log.

## Handover screens

- **UEFI -> micro-Linux** and **UEFI -> XP preparation**: the "Uruchamianie…"
  splash replaces the stage screen; the spinner turns while systemd-boot and
  the kernel's EFI stub read their files (TPL permitting) and stops at
  ExitBootServices.
- **Linux keeps that frame**: the kernel command lines no longer carry
  `fbcon=nodefer`, so fbcon takes the screen only on console output (there
  is none with `quiet` and `/dev/console` on serial). simpledrm keeps the
  firmware framebuffer as it is. `usos-fb-ui` and the menus force one
  `fb_set_par` after drawing their first frame (FBIOPUT_VSCREENINFO with
  FB_ACTIVATE_FORCE, once per boot, marker `/run/usos-fb-scanout`), which
  makes simpledrm scan out the drawn frame; later frames go through fbdev
  deferred I/O as before. The menu no longer writes `ESC[2J` to tty1 (that
  would end the deferred takeover).
- The first frame in init is the same splash (`mode=splash`), so after UEFI
  the takeover is invisible; after the BIOS loader's progress screen it is a
  neutral "Uruchamianie…" for every session.
- Measured (UEFI, QEMU): before, the handover screen stayed through the
  kernel load and then **~3.1 s black** from the fbcon takeover to the first
  usos-fb-ui frame. Now **no black frame** from Start to the preparation
  screen. BIOS -> Hardware & SMART: the Core's loading screen stays through
  the 7 s kernel boot (TCG) to the first usos-fb-ui frame, no black frame.
- **wimboot (Vista/7 from UEFI)**: unchanged; the 3-stage ISO progress
  screen stays until the Windows boot manager draws (wimboot runs `quiet`).
  Not measured in QEMU (needs a Windows ISO on DATA).

Also fixed: the systemd-boot entry written since 8edd5835 read
`optionsconsole=tty0 ...` (no space), so systemd-boot ignored the whole
`options` line and the kernel started without `rdinit=/usos-init` or
`usos.esp_partuuid`. The entry now comes from `MicroLinuxLoaderEntry`
(`installer/internal/winhost/loader_entry.go`) and a test checks its keys.

## Measuring

    powershell -File tools/render_boot_ui_screenshots.ps1 -Splash [-ReuseDisk] [-Languages pl]
        [-SplashLaunch] [-SplashThrottleIops 40] [-SplashBootLogo firmware] [-SkipBios|-SkipUefi]
    python tools/boot_splash_qemu.py --firmware bios --disk <vhd> --out <dir> --launch --keys down,down,ret,up,up,ret

QEMU starts paused, every serial line gets a host timestamp and the screen
is sampled ~20 times a second; `<fw>-<label>-timeline.json` classifies each
sample (black / text / usos), and every visually distinct sample is kept as
PNG. QEMU's disk is much faster than a pendrive: `-SplashThrottleIops`
limits disk requests so the splash and spinner become visible. TCG timings
vary between runs (the TSC rate does too); compare within a run.

Screenshots (pl, 1280x800): `artifacts/boot-ui/splash/` - `uefi-pl-1..3`
(splash, two spinner frames), `uefi-pl-4` (BGRT logo), `uefi-pl-5..6`
(Uruchamianie... handover), `uefi-pl-7..8` (Linux takeover: same splash, then
the first stage screen), `bios-pl-1..2` (BIOS splash and filled bar); raw
samples, timelines and timestamped serial logs next to them.

## Pointer over buttons: no more stale patches (flicker fix)

Cause: the UEFI and BIOS menus drew partial updates (hover, selection,
clock) straight into the visible framebuffer and kept the pointer as a
saved patch taken from that same framebuffer: each hover repaint was
visible in steps (row cleared, then drawn), the pointer was restored and
re-saved around it, and a full frame was Blt without the pointer before the
pointer was drawn on top. In micro-Linux every pointer move re-rendered and
copied the whole screen, which fbdev deferred I/O could flush half-way.

Fix (`src/gui/compositor.zig`): screens are drawn only into a RAM back
buffer; `Presenter.present` diffs it against a copy of what is on screen in
32-row bands, merges touching rectangles (8 on UEFI/Linux, one bounding
rectangle in the BIOS Core), adds the old and new pointer rectangles and
sends each rectangle with the pointer composited from the back buffer in
one operation: a GOP `EfiBltBufferToVideo` on UEFI, row copies into the
LFB/fbdev mapping in BIOS and micro-Linux. The pointer is never in the back
buffer, so nothing can go stale. Hover is repainted only when the hovered
item changes; UEFI pointer frames are limited to ~60 Hz (the input loop
draws the last position when the pointer stops).

- UEFI: back, on-screen copy and scratch are three pool buffers; without
  them the old direct path remains.
- BIOS: the buffers sit at 33..48 MiB (checked in E820); every full menu
  screen and every progress frame (drawn straight to the LFB while a
  backend owns RAM) resend the whole frame; `console.before_wait` presents
  before every key wait, so helper screens are always shown. Without that
  RAM the menu has no pointer. The splash lost its progress bar to fit:
  Core 245,388 of 245,760 bytes.
- micro-Linux menus: a pointer move repaints only the two pointer rectangles.

Tests: `compositor.zig` checks that after a sequence of hover changes and
pointer moves the screen equals a clean full render with the pointer.
`tools/boot_hover_qemu.py --disk <vhd> --out artifacts/boot-ui/hover` sweeps
the PS/2 pointer across every home card in UEFI and BIOS and requires the
final frame to equal the reference pixel for pixel (only the header clock
may differ): both pass.
