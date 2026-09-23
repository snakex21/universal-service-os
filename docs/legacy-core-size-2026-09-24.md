# Legacy BIOS Core: where the 240 KiB went, and 43 KiB back

The Core payload shares a 256 KiB slot with the 16 KiB bootstrap window, so it
may use 245 760 bytes. It was 245 588 bytes (172 free) and already built with
`-O ReleaseSmall`; font, icons and strings were already in `bios-ui.bin`.

## Map

`python tools/legacy_core_map.py` rebuilds the Core object exactly like
`tools/build_legacy_bios.ps1` but with symbols, links it with `core.ld` and
prints sections, sizes per module, the largest functions and the largest data
(with their share of zero bytes). Before:

| section | bytes |
|---|---|
| .early (real-mode thunks) | 3 928 |
| .text | 147 548 |
| .rodata | 93 488 |
| .data | 620 |

81 KiB of the image were anonymous constants, and 49 KiB of those were 99 %
zero: one 3 664-byte constant per error that `ntfs.mount` returns (7 errors),
an 11 372-byte one in `dos_iso_source.Source.open`, 3 600 bytes in
`ntfs.collectStream` and five 536-byte ones in `dos_partition.planFat16`.
Zig lowers `return error.X` from a function whose payload is large into a copy
of a comptime constant holding the whole error union (undefined payload stored
as zeros). The largest code: `text_menu.run` 14 KiB, `legacy_boot_actions.execute`
13.7 KiB, `core_main` 9.4 KiB, `graphics_menu.progressFrame` 6.4 KiB.

## Change

- `ntfs.mount`, `ntfs.collectStream`, `dos_iso_source.Source.open` and
  `dos_partition.planFat16` keep their signatures but return their errors from
  a small `Error!void` helper that fills the result in place; the error then
  travels as a runtime value and no template is emitted.
- `ntfs.Stream.runs` has no zero-filled default (only `runs[0..len]` is ever
  read), so `Stream{}` no longer copies a 3.5 KiB constant.

After: .rodata 50 176 bytes, Core 202 172 bytes, **headroom 43 588 bytes**.
Nothing moved to a second stage: the second-stage mechanism (`bios-ui.bin`,
magic + length + CRC32, re-validated before every screen) already holds the
large resources, and the fallback to the built-in 5x7 font and English when it
is missing or corrupt is unchanged.

`tools/build_legacy_bios.ps1` now fails when the headroom drops below 4 096
bytes and prints the headroom on every build.

## Checks

`zig build test`; QEMU/SeaBIOS through `tools/render_boot_ui_screenshots.ps1
-SkipUefi`: menu screenshots (`-BiosUiPack present`), `-BiosUiPack missing`
and `-BiosUiPack corrupt` (Core logs "bios-ui.bin missing or invalid; 5x7
English fallback" and draws the 5x7 English menu with the pointer), `-Splash`
and `-InputTest -InputDevices bios` (PS/2 pointer and wheel).
