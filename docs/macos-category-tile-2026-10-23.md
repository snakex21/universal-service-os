# macOS category tile (UEFI home) — 2026-10-23

The UEFI home screen had 6 categories + Power = 7 cards in a 2-column grid,
so the last row held a single card. macOS now has its own tile (between DOS
and Other systems): 7 categories + Power = 8 cards, four full rows of two.
The Legacy BIOS Core is unchanged (5 categories + Power = 6 cards); macOS,
like Other systems, is UEFI-menu only.

## Behaviour

- `src/catalog/categories.zig`: `all` (UEFI/host) is Windows, Linux, Beta,
  DOS, macOS, Other systems, Utilities; Power is appended by the menu.
- **Add-on detection:** `categories.macosAddonInstalled()` is true when the
  build carries macOS catalog entries (`systems.countInCategory(.macos) > 0`).
  The main release has none, so the tile is shown greyed out with
  "Requires the macOS add-on" (`boot.category.macos.addon`). It stays
  selectable: Enter/click opens a short info screen
  (`boot.macos.addon.*`) and returns to the home screen.
- When the add-on (docs/ROADMAP.md L10, branches `codex/macos-dlc`,
  `codex/macos-archive`, `cx/fix/macos-*`, not merged) is integrated, its
  entries (e.g. `macos-opencore`, now `.category = .other`) must switch to
  `.category = .macos`; the tile then becomes active, shows
  `boot.category.macos.desc` and lists them. No macOS entries existed in the
  Other systems list on this branch, so nothing had to be moved.
- Strings: 7 keys in all 27 locales (`installer/internal/i18n/locales`),
  tables regenerated with `go run ./cmd/usos-i18n-gen -root ..`.

## Icon (single swappable file)

- The tile draws **`media/UI/Icons/Systems/macos.png`** (1254x1254 RGBA, like
  the other system icons). The build packs it into `EFI/USOS/bios-ui.bin`
  as icon id `macos` (`categories.macos_icon_id`); the UEFI menu reads it via
  `system_icons.builtin()`, with the PNG on the ESP as second source and the
  vector `.disc` glyph as fallback when neither exists.
- **To change the icon, replace that one PNG** (any size; it is scaled to
  32x32 for the pack) and rebuild. Nothing else references it.
- Current file: the user's AI-generated apple (GPT Image), converted to the
  tile style (transparent background, silver gradient, rim, soft shadow).
  Provenance and trademark note: see NOTICE.
- Colour icons are drawn on a neutral tile (`Ui.homeCardWith`), greyed out
  when the card is disabled.

## Checks

- Host tests: `categories.zig` (7 categories, macOS position, disabled
  without add-on, no macOS ids under Other systems), `menu_screens.zig`
  (8 cards = 4 even rows at 800x600, 1024x768, 1280x720, 1920x1080, Polish
  string, hit test on the disabled card).
- Screens: `zig build ui-preview`, then
  `usos-ui-preview <out> <w> <h> [lang.bin]` from the repo root writes
  `01-home`, `01b-home-macos-selected`, `01c-macos-addon-info`.
- Not checked on hardware (X470 / ROG Ally); the touch layout uses the
  same `homeCardRect` grid.
