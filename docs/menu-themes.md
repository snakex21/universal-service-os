# Menu themes

The boot menu colours come from one `Theme` value (`src/gui/theme.zig`);
every screen of the shared toolkit (`src/gui/ui.zig`, menu screens,
splash, preparation screen) draws with its fields, including the
controller face buttons (`pad_x`, `on_pad`, plus `success`, `danger`,
`warning` for A, B, Y).

## Choosing a theme

`theme=<name>` in `EFI\USOS\usos-settings.ini` (any section; the installer
merges only `[ui] language=` and keeps the key). Tools -> Theme in the
UEFI menu writes it through `settings_store.set`, which replaces or appends
that one key and keeps every other line.

| name | look |
|---|---|
| `default` (or no key) | the USOS palette, pixel-identical to the menu before themes |
| `dark` | neutral graphite, soft blue accent |
| `light` | dark text on white and light grey |
| `high-contrast` | white on black, yellow selection, white borders (accessibility) |
| `retro` | white and yellow on VGA blue, like a BIOS setup |

Any other name is a user theme, name of 1-32 characters `A-Z a-z 0-9 - _`:

1. `\EFI\USOS\themes\<name>.ini` on the ESP: written by the theme editor
   (below) and the shipped examples; the UEFI menu **and the Legacy BIOS**
   read it;
2. `DATA\Themes\<name>\theme.ini`: UEFI menu only.

Examples shipped on the stick (installer payload, `src/gui/themes/`):
`usos-ocean` (deep blue, cyan), `usos-sunset` (warm dark brown, orange),
`usos-forest` (light, green). Updates rewrite them; the editor saves a
copy of an example under the user's own name.

## theme.ini

```
; comments start with ; or #, [sections] are ignored
base=dark             ; optional, must be the first setting
accent=#ff9e40        ; any Theme field, #rrggbb ("-" = "_")
accent_soft=#3a2410
```

All or nothing (`src/gui/theme_file.zig`): an unknown key, a colour that
is not `#rrggbb`, an unknown base, a file over 4 KiB or a theme that breaks
a readability rule gives the default theme. The UEFI menu logs the reason
on the serial port (`[THEME] user theme <name> not used: ...`); Tools ->
Theme shows it and saves nothing.

Readability rules (`src/gui/theme_contrast.zig`, integer WCAG 2
contrast): body text 4.5:1 on background, header, panels and the
selection fill; secondary text, accent, badges and pad letters 3:1;
disabled text 2:1; the selection and hover fills must differ from the
panel, and the four pad faces from the footer and from each other. Every
built-in theme is tested against the same rules.

## Firmware

- UEFI: the splash (drawn before DATA is opened) uses the built-in part of
  the choice; a user theme applies from the first menu frame (DATA is
  opened once more during menu start when a user theme is chosen).
  `\UI\theme.css` still overrides the default theme only.
- Legacy BIOS: the Core reads `usos-settings.ini` once before the splash:
  a built-in theme, or a user theme from `EFI\USOS\themes\<name>.ini`
  (colours only; the same all-or-nothing parser and readability rules,
  `theme_file.resolveTheme` without the problem texts). `DATA\Themes` is
  not read by the BIOS (the NTFS catalog opens later). No editor in the
  BIOS. Cost: 3 616 bytes of Core (headroom 23 356 -> 19 740 bytes,
  build 2026-09-26; the rules and field names are tables, not unrolled
  code, to keep it small). Earlier: built-in themes, 1 428 bytes.

## Preview

`zig build ui-preview`, then
`usos-ui-preview <dir> <w> <h> [lang.bin|-] [theme]`; `theme` is a
built-in name or a `theme.ini` path. Screen `15-tools-theme` is the Tools
-> Theme page.

## Theme editor (UEFI)

Tools -> Theme -> "Create or edit a theme" (`src/platform/uefi/theme_editor.zig`),
built on the shared form component (`src/gui/form.zig`, on-screen keyboard
`src/gui/osk.zig`):

- rows: theme name, base theme (a built-in; changing it starts from its
  colours), element (every `Theme` field, with its colour swatch; Left/Right
  step), colour `#rrggbb` (typed), red/green/blue (Left/Right -/+ 8),
  reset this element, save and use, cancel;
- beside the form a **live preview** drawn with the edited colours
  (`src/gui/theme_preview.zig`: header, panel with a normal and a selected
  row, secondary and disabled text, button, badges, the four pad faces),
  while the form itself keeps the current menu theme (always readable);
- **live contrast**: the first broken rule of `theme_contrast.zig` under
  the preview ("Too little contrast: Text on accent on Accent"); Save is
  refused while a rule fails;
- Save writes `\EFI\USOS\themes\<name>.ini` (`base=` and the colours that
  differ from the base), checks that `theme_file.resolve` reads back the
  same theme, sets `theme=<name>` and applies it at once.

Opening the editor with a user theme chosen loads that theme; with a
built-in one it starts a new theme on that base.

## Open

- Editor in the Go installer (mouse, colour picker): not started.
- Background image and logo in `theme.ini` (not implemented: partial
  redraws fill with `background`, so an image needs toolkit changes).
- The micro-Linux framebuffer UI still uses the default theme.
- Checked in QEMU/OVMF (tools/tests/run_uefi_answer_screen.ps1, editor
  section); not yet on hardware; BIOS user themes not yet run in QEMU.

## Plan: theme editor (ROADMAP N7)

Agreed 2026-09-26. Status 2026-09-26: items 1, 3 and 4 done (above),
item 2 (installer editor) open.

- **UEFI in-menu editor** (Tools -> Theme): live preview and live contrast
  checking with the rules above (`src/gui/theme_contrast.zig`), built on
  the same form / on-screen keyboard component as the answer-profile
  manager. Saves go to the ESP.
- **Editor in the Go installer**: mouse and colour picker, same
  `theme.ini` format and contrast rules.
- **Legacy BIOS uses user themes** (colours only, read from the ESP, where
  the UEFI editor saves them) but gets **no editor**.
- **2–3 example user themes** shipped on the stick.
