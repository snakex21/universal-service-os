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

Any other name is a user theme: `DATA\Themes\<name>\theme.ini`, name of
1-32 characters `A-Z a-z 0-9 - _`.

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
- Legacy BIOS: the Core reads `usos-settings.ini` once before the splash
  and uses the built-in themes; a user theme name keeps the default.
  Cost: 1 428 bytes of Core (headroom 29 884 -> 28 456).

## Preview

`zig build ui-preview`, then
`usos-ui-preview <dir> <w> <h> [lang.bin|-] [theme]`; `theme` is a
built-in name or a `theme.ini` path. Screen `15-tools-theme` is the Tools
-> Theme page.

## Open

- Background image and logo in `theme.ini` (not implemented: partial
  redraws fill with `background`, so an image needs toolkit changes).
- User themes in the BIOS menu (e.g. copy the chosen `theme.ini` to the
  ESP during "Update USOS").
- The micro-Linux framebuffer UI still uses the default theme.
- Not yet checked on hardware or in QEMU/OVMF (host previews only).
