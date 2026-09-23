# Boot UI: font, languages and the installer look (2026-09-23)

## What runs where

| Path | Renderer | Font | Language |
|------|----------|------|----------|
| UEFI menu (`BOOTX64.EFI`) | `src/gui/menu_screens.zig` via `src/platform/uefi/manual_view.zig`, off-screen frame + one GOP Blt | pack embedded in the EFI (both tiers) | `\EFI\USOS\lang.bin` |
| Legacy BIOS menu (Core slot) | same screens via `src/platform/bios/graphics_menu.zig`, straight into the VBE LFB | `EFI/USOS/bios-ui.bin` (1x tier + icons), read into RAM at 32 MiB | `EFI/USOS/lang.bin`, read into the same window |
| micro-Linux (`usos-fb-ui`) | `fb_ui_render.zig` / `fb_menu_render.zig` | pack embedded in the binary | `/etc/usos/lang.bin` from the second initrd `EFI/USOS/lang.cpio`, else the mounted ESP |

All three fall back per string to the built-in English. Without a font pack
(BIOS: missing or corrupt `bios-ui.bin`, or the 32 MiB window is not RAM)
the old 5x7 ASCII font draws English.

## Font

`tools/usos_font_gen.py` rasterizes Roboto Regular/Medium (Apache-2.0) and
a Noto Sans subset for arrows and the check mark (OFL-1.1) with FreeType
hinting into `src/gui/fonts/usos-font.bin`: 4-bit coverage, roles small 13,
body 15, strong 15 (medium), heading 21 px, tiers 1x and 1.5x, 328
codepoints = ASCII + UI punctuation + every character of every `boot.*`
string and language name. Licenses: `assets/fonts/`, shipped to
`EFI/USOS/licenses/fonts/`. UI scale: 1x up to 1600x1000, 1.5x at 1080p,
2x (1x tier doubled) at 1440p, 3x (1.5x tier doubled) at 4K.

`go run ./cmd/usos-i18n-gen -root ..` fails when a language needs a glyph
the pack lacks; after changing strings run the font generator again.

## Strings

`boot.*` in `installer/internal/i18n/locales/*.json` (447 keys).
`boot.lx.*` are the literal English texts the micro-Linux scripts pass to
`usos-fb-ui`; it translates them by reverse lookup, including templates
such as `{0} of {1} files`. All non-English boot strings are machine
translations (`_meta.machine_translated`, for pl
`machine_translated_prefixes: ["boot."]`).

Still English: error names (`@errorName`), Windows 7/Vista ISO inspection
details from `src/windows7_iso.zig`, SMART table headers/attributes, the
serial log and the text-mode fallbacks.

## Legacy BIOS limits

- Core slot: 245760 bytes for code and data; the new Core uses 242868.
  Icons and the font therefore live in `bios-ui.bin` on the ESP; strings
  only the UEFI menu shows are left out of the Core.
- The resource window (32 MiB..33 MiB) is re-checked (CRC) before every
  screen; menus reload it from the ESP when a backend overwrote it.
- VBE modes stay at or below 1280x1024, so the BIOS always uses 1x.
- Hover: moving the mouse over a row selects it (as before); the UEFI menu
  has a separate hover highlight.

## Options that do nothing are hidden

Boot methods that cannot run (wrong image type, no backend, other firmware
mode) are not listed; one runnable method is used without asking. The
answer-file screen is skipped when the system's Unattended folder is
empty, and the summary lists only the settings that apply.

## Screenshots

`tools/render_boot_ui_screenshots.ps1` (elevated) builds a file-backed test
VHD and captures UEFI (OVMF) and BIOS (SeaBIOS) screens per language into
`artifacts/boot-ui/`. `zig build ui-preview` renders the same screens on
the host (`usos-ui-preview <dir> <w> <h> [lang.bin]`).
